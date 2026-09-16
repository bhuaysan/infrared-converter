import Testing
import Foundation
@testable import InfraredConverter

/// Authoring a monochrome mix in the workspace: it replaces, it costs the same
/// as any other mix change, and it touches nothing else.
///
/// Every claim here is a claim about *reuse*. A monochrome mix is an explicit
/// channel mix, so it must behave exactly as an explicit channel mix does —
/// same entry point, same scheduling, same retained buffer, same sidecar. A
/// test that passed here for a monochrome-specific reason would mean the
/// milestone had failed.
@Suite("Workspace monochrome mix")
@MainActor
struct WorkspaceMonochromeMixTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/monochrome-mix.orf")

    /// Deliberately asymmetric, and deliberately not any of the four starting
    /// points, so it can only have come from the fields.
    static func authored() throws -> UserChannelMixAdjustment {
        try IRMonochromeMix(red: 1.5, green: -0.25, blue: 0.125).adjustment()
    }

    /// An arbitrary colour mix to author over.
    static func colourMix() throws -> UserChannelMixAdjustment {
        try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0, 1, 0, 0, 0, 1, 1, 0, 0]
        )
    }

    static func waitUntil(
        _ description: String,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Never became true: \(description)")
    }

    // MARK: - Applying replaces, it does not compose

    /// The central workspace claim: `M1` then monochrome `M2` renders `M2`,
    /// not `M2 × M1`. Stated three ways — canonical state, provenance, and the
    /// pixels themselves against a hand-composed product.
    @Test("A monochrome mix over an existing mix replaces it, never composes")
    func aMonochromeMixReplacesTheExistingMix() async throws {
        let store = StubPhotographProcessingStore()
        let (state, decoder) = WorkspaceStubs.countingDocumentState(
            url: Self.url, store: store
        )
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))

        let first = try Self.colourMix()
        let mono = try Self.authored()
        // M2 · M1, computed by hand: with M1 the cyclic permutation
        // (R←G, G←B, B←R), composing moves each monochrome contribution one
        // column along. This is what a composing pipeline would have rendered.
        let composed = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [
                0.125, 1.5, -0.25,
                0.125, 1.5, -0.25,
                0.125, 1.5, -0.25,
            ]
        )

        state.setChannelMix(first)
        let afterFirst = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: first)
            )
        )
        state.setChannelMix(mono)
        let afterMono = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: mono)
            )
        )

        // The canonical state is the monochrome matrix and nothing else.
        #expect(state.channelMixAdjustment == mono)
        #expect(afterMono.channelMixAdjustment == mono)
        #expect(afterMono.channelMix.matrix.rows == [
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
        ])
        // Ordinary creative provenance: there is no monochrome source.
        #expect(afterMono.channelMix.source == .explicit)
        try await Self.waitUntil("the monochrome mix is saved") {
            store.saved(for: Self.url) == ImageAdjustments(channelMix: mono)
        }

        guard case .decoded(let loaded) = state.status, let source = loaded.source else {
            Issue.record("Expected a retained source")
            return
        }
        // One pass of the monochrome matrix over the retained pre-mix buffer …
        let byHand = try WorkspacePreviewPipeline().render(
            source, adjustments: ImageAdjustments(channelMix: mono)
        )
        #expect(
            WorkspaceStubs.pixelBytes(afterMono.image)
                == WorkspaceStubs.pixelBytes(byHand.image)
        )
        // … not the first mix's result, and not the product of the two.
        #expect(
            WorkspaceStubs.pixelBytes(afterMono.image)
                != WorkspaceStubs.pixelBytes(afterFirst.image)
        )
        let asIfComposed = try WorkspacePreviewPipeline().render(
            source, adjustments: ImageAdjustments(channelMix: composed)
        )
        #expect(
            WorkspaceStubs.pixelBytes(afterMono.image)
                != WorkspaceStubs.pixelBytes(asIfComposed.image)
        )
        // And the source the mixer read is still pre-mix, so no previous mix
        // was ever baked into it.
        #expect(!source.preview.processing.channelMixApplied)
        #expect(decoder.mosaicDecodeCount == 1)
    }

    /// The other direction: a colour mix authored *after* a monochrome one
    /// restores colour completely, which it could not do if a monochrome
    /// collapse had been retained.
    @Test("A colour mix after a monochrome one restores colour from the pre-mix source")
    func aColourMixAfterMonochromeRestoresColour() async throws {
        let state = WorkspaceStubs.documentState(url: Self.url)
        state.open(Self.url)
        let initial = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: .none)
        )

        state.setChannelMix(try Self.authored())
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: try Self.authored())
            )
        )
        state.setChannelMix(.identity)
        let restored = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: .identity)
            )
        )

        // Byte for byte the image the identity produced before the monochrome
        // detour: the collapse was never durable.
        #expect(
            WorkspaceStubs.pixelBytes(restored.image)
                == WorkspaceStubs.pixelBytes(initial.image)
        )
    }

    // MARK: - It costs what any channel-mix change costs

    /// Nothing upstream of the creative stage runs again: no decode, no
    /// normalisation, no white-balance estimate, no demosaic, no reduction.
    /// The mosaic decode count is the observable for the decoder half, and
    /// the absence of a `preparedSource` event is the observable for the
    /// white-balance-dependent half.
    @Test("A monochrome edit decodes, demosaics and reduces nothing again")
    func aMonochromeEditRerunsNothingUpstream() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let (state, decoder) = WorkspaceStubs.countingDocumentState(
            url: Self.url, store: store
        )
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        #expect(decoder.mosaicDecodeCount == 1)

        let mono = try Self.authored()
        let equalRGB = try IRMonochromeMix.equalRGB.adjustment()

        state.setChannelMix(mono)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: mono)
            )
        )
        state.setChannelMix(equalRGB)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: equalRGB)
            )
        )
        state.setChannelMix(.identity)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: .identity)
            )
        )

        // Three mixes, still one read of the file — the same count an
        // ordinary channel-mix edit produces.
        #expect(decoder.mosaicDecodeCount == 1)
        // And the LibRaw diagnostic reference was not re-read either.
        #expect(decoder.processedDecodeCount == 1)
    }

    /// The white-balance-dependent half of the pipeline — estimate, balance,
    /// demosaic, convert, reduce — is the expensive one, and a monochrome mix
    /// must not touch it. `preparedSource` is logged once, by the open.
    @Test("A monochrome edit never re-prepares the reduced source")
    func aMonochromeEditNeverRePreparesTheSource() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = DocumentState(
            decoder: RecordingMosaicDecoder(
                wrapped: WorkspaceStubDecoder(
                    result: .success(RAWTestData.decodedRAW(url: Self.url)),
                    mosaic: .success(WorkspaceStubs.mosaic(url: Self.url))
                ),
                log: log
            ),
            store: store,
            render: RecordingRender(log: log).render
        )

        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        let preparationsAfterOpen = log.preparations.count
        let decodesAfterOpen = log.all.filter { $0 == .decodedMosaic }.count

        let mono = try Self.authored()
        state.setChannelMix(mono)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: mono)
            )
        )

        #expect(log.preparations.count == preparationsAfterOpen)
        #expect(log.all.filter { $0 == .decodedMosaic }.count == decodesAfterOpen)
        // One extra render, which is the whole cost of the edit.
        #expect(log.renders.last == ImageAdjustments(channelMix: mono))
    }

    // MARK: - Nothing else changes

    /// A render request is one complete state, so the test asserts on the
    /// complete state: the white balance, the exposure, the orientation and
    /// the capture profile are the ones that were in force before the mix was
    /// authored.
    @Test("Authoring monochrome leaves white balance, exposure, orientation and profile alone")
    func authoringMonochromeLeavesEverythingElseAlone() async throws {
        let store = StubPhotographProcessingStore()
        let state = WorkspaceStubs.documentState(url: Self.url, store: store)
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))

        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.25, originY: 0.25, width: 0.25, height: 0.25
            )
        )
        let exposure = try UserExposureAdjustment(ev: 1.5)
        let before = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .identity,
            exposure: exposure,
            whiteBalance: patch
        )

        state.setWhiteBalance(patch)
        state.rotateOrientationRight()
        state.setExposure(exposure)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: before))
        let profileBefore = state.captureProfile

        let mono = try Self.authored()
        state.setChannelMix(mono)
        var after = before
        after.channelMix = mono
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: after)
        )

        // Canonical state: one field changed, three did not.
        #expect(state.channelMixAdjustment == mono)
        #expect(state.whiteBalanceAdjustment == patch)
        #expect(state.exposureAdjustment == exposure)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.captureProfile == profileBefore)

        // And the rendered preview agrees on every one of them.
        #expect(preview.whiteBalanceAdjustment == patch)
        #expect(preview.exposureAdjustment == exposure)
        #expect(preview.renderedExposureEV == 1.5)
        #expect(preview.userOrientationAdjustment == .quarterTurnRight)

        try await Self.waitUntil("the complete state is saved") {
            store.saved(for: Self.url) == after
        }
    }

    // MARK: - The round trip a person actually makes

    /// Authored, saved, reopened: the same explicit matrix comes back, and the
    /// monochrome editor recognises it from its identical rows — which is what
    /// makes reopening `Monochrome…` show the numbers that were typed.
    @Test("A monochrome mix reopens as the same matrix and is recognised again")
    func aMonochromeMixReopens() async throws {
        let store = StubPhotographProcessingStore()
        let first = WorkspaceStubs.documentState(url: Self.url, store: store)
        first.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(first, adjustments: .none))

        let mono = try Self.authored()
        first.setChannelMix(mono)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                first, adjustments: ImageAdjustments(channelMix: mono)
            )
        )
        try await Self.waitUntil("the monochrome mix is saved") {
            store.saved(for: Self.url) == ImageAdjustments(channelMix: mono)
        }

        let second = WorkspaceStubs.documentState(url: Self.url, store: store)
        second.open(Self.url)
        let reopened = try #require(
            await WorkspaceStubs.waitForPreview(
                second, adjustments: ImageAdjustments(channelMix: mono)
            )
        )

        #expect(second.channelMixAdjustment == mono)
        #expect(reopened.channelMixAdjustment.kind == .matrix)
        #expect(reopened.channelMix.source == .explicit)

        // The editor opening on the restored state shows the typed numbers.
        let recovered = try #require(
            IRMonochromeMix(recognising: second.channelMixAdjustment)
        )
        #expect(recovered == IRMonochromeMix(red: 1.5, green: -0.25, blue: 0.125))
        let draft = MonochromeMixDraft(seeding: second.channelMixAdjustment)
        #expect(draft[contribution: .red] == "1.5")
        #expect(draft[contribution: .green] == "-0.25")
        #expect(draft[contribution: .blue] == "0.125")
    }
}
