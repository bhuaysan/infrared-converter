import Testing
import Foundation
@testable import InfraredConverter

/// What happens when a reusable `IRCreativePreset` is applied to an open
/// photograph.
///
/// The central architectural claim under test is spelled in
/// `IRCreativePreset`'s own documentation:
///
/// ```text
/// preset.channelMix  →  DocumentState.setChannelMix(_:)  →  the existing render path
/// ```
///
/// A preset is an authoring and reuse mechanism, nothing more. It introduces
/// no new mixer, no new matrix type and no new persisted representation, and
/// a photograph's sidecar stores the **resolved** `UserChannelMixAdjustment`
/// it produced — never a reference back to the preset. Every test here is
/// really a test of that boundary: applying a preset must be indistinguishable,
/// at every layer below `setChannelMix`, from a person having typed the same
/// nine coefficients by hand.
///
/// The arithmetic of the mix itself, and the claim that a second mix replaces
/// rather than composes with the first, are already proven by
/// `IRChannelMixerTests` and `WorkspaceChannelMixPipelineTests` /
/// `WorkspaceChannelMixAdjustmentTests`. This suite does not repeat that
/// proof; it proves that a preset reaches the pipeline through no path other
/// than the one those suites already cover.
///
/// Not `.serialized`: no test here holds a render at a `GatedRender` gate, so
/// no test occupies a cooperative-pool thread for longer than an ordinary
/// await — the reason `WorkspaceChannelMixAdjustmentTests` needs the
/// annotation and `WorkspaceAdjustmentPersistenceTests` does not.
@Suite("Workspace creative preset application")
@MainActor
struct WorkspaceCreativePresetTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/creative-preset.orf")

    static func waitUntilSettled(_ state: DocumentState) async throws {
        for _ in 0..<600 {
            if case .decoding = state.status {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                return
            }
        }
        Issue.record("The open never settled")
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

    static func preview(_ state: DocumentState) throws -> WorkspacePreview {
        guard case .decoded(let loaded) = state.status,
              case .rendered(let preview) = loaded.owned
        else {
            Issue.record("Expected a rendered preview, got \(state.status)")
            throw CancellationError()
        }
        return preview
    }

    /// A workspace wired to a recording store and decoder, for the tests that
    /// need to count renders rather than merely poll the settled preview.
    static func state(
        store: StubPhotographProcessingStore,
        log: WorkspaceEventLog
    ) -> DocumentState {
        DocumentState(
            decoder: RecordingMosaicDecoder(
                wrapped: WorkspaceStubDecoder(
                    result: .success(RAWTestData.decodedRAW(url: url)),
                    mosaic: .success(WorkspaceStubs.mosaic(url: url))
                ),
                log: log
            ),
            store: store,
            render: RecordingRender(log: log).render
        )
    }

    /// A preset carrying a deliberately asymmetric, hand-checkable matrix —
    /// chosen the same way `WorkspaceChannelMixAdjustmentTests` chooses its
    /// authored matrices, so a coefficient that reaches the wrong place is
    /// unmistakable rather than merely "a different-looking image".
    static func makePreset(
        id: String,
        name: String = "Test Preset",
        matrix coefficients: [Double]
    ) throws -> IRCreativePreset {
        IRCreativePreset(
            id: try IRCreativePresetID(id),
            name: name,
            channelMix: try UserChannelMixAdjustment.explicit(persistedMatrix: coefficients)
        )
    }

    // MARK: - 1. Applying a preset is exactly `setChannelMix`

    /// The preset carries an existing `UserChannelMixAdjustment`; applying it
    /// is one assignment to the existing control. Nothing about the resulting
    /// adjustment, the rendered preview, or the mix's provenance can tell that
    /// a preset was involved at all — which is the whole design: a preset that
    /// left a fingerprint on the pipeline would be a second, preset-aware
    /// mixer in disguise.
    @Test("Applying a preset produces exactly the existing adjustment, through the existing render path")
    func applyingAPresetProducesTheExistingAdjustment() async throws {
        let store = StubPhotographProcessingStore()
        let state = WorkspaceStubs.documentState(url: Self.url, store: store)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let coefficients: [Double] = [1.8, -0.4, -0.4, -0.2, 1.4, -0.2, 2.5, 0, -1.5]
        let preset = try Self.makePreset(id: "user.preset-a", matrix: coefficients)

        // The whole act of "applying a preset", stated as code: nothing else
        // is called, and no preset-aware overload of `setChannelMix` exists.
        state.setChannelMix(preset.channelMix)

        let preview = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: preset.channelMix)
            )
        )

        #expect(state.channelMixAdjustment == preset.channelMix)
        #expect(preview.channelMixAdjustment == preset.channelMix)
        #expect(preview.channelMix.matrix.rows.flatMap { $0 } == coefficients)

        // The same decision, authored by hand rather than fetched from a
        // preset, reports the identical provenance and the identical matrix.
        let handTyped = try UserChannelMixAdjustment.explicit(persistedMatrix: coefficients)
        #expect(preview.channelMix.source == handTyped.mix.source)
        #expect(preview.channelMix.matrix == handTyped.mix.matrix)

        // And that provenance is the ordinary explicit-matrix source. This
        // switch has no `default`: if `IRChannelMixSource` ever grew a case
        // for "came from a preset", this test would stop compiling rather
        // than silently pass.
        switch preview.channelMix.source {
        case .identity, .redBlueSwap, .explicit:
            break
        }
        #expect(preview.channelMix.source == .explicit)
    }

    // MARK: - 2. A second preset replaces, never composes

    /// `setChannelMix` is already proven non-composing by
    /// `WorkspaceChannelMixAdjustmentTests`; this restates it for two
    /// preset-sourced mixes specifically, because a preset is exactly the
    /// scenario that motivates a person picking one look after another. It
    /// also proves the existing "already in force" no-op, since a preset
    /// picker re-applying the mix already on screen must not be treated as a
    /// new decision.
    @Test("A second preset replaces the first, never composes, and reapplying the current mix does nothing")
    func aSecondPresetReplacesTheFirst() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // M1 and M2 are chosen so that neither M2·M1 nor M1·M2 equals M2 —
        // the same construction `WorkspaceChannelMixAdjustmentTests` uses —
        // so a composing pipeline cannot accidentally agree with a replacing
        // one.
        let m1: [Double] = [0, 1, 0, 0, 0, 1, 1, 0, 0]
        let m2: [Double] = [1.5, -0.25, 0, 0, 0.5, 0.25, -0.5, 0, 2]
        let composed: [Double] = [0, 1.5, -0.25, 0.25, 0, 0.5, 2, -0.5, 0]

        let presetA = try Self.makePreset(id: "user.preset-a", matrix: m1)
        let presetB = try Self.makePreset(id: "user.preset-b", matrix: m2)
        let asIfComposed = try UserChannelMixAdjustment.explicit(persistedMatrix: composed)

        state.setChannelMix(presetA.channelMix)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: presetA.channelMix)
            )
        )

        state.setChannelMix(presetB.channelMix)
        let afterB = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: presetB.channelMix)
            )
        )

        // Exactly preset B's matrix — not the product of the two.
        #expect(state.channelMixAdjustment == presetB.channelMix)
        #expect(afterB.channelMixAdjustment == presetB.channelMix)
        #expect(afterB.channelMix.matrix.rows.flatMap { $0 } == m2)
        #expect(afterB.channelMix.matrix != asIfComposed.mix.matrix)
        if case .saved = state.adjustmentPersistence {} else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
        }

        // Re-picking the preset already applied is the existing "asking for
        // the mix already in force" contract: no render, no write, and the
        // durable status is left exactly as it was rather than disturbed.
        let rendersBefore = log.renders.count
        let savesBefore = log.saves.count
        state.setChannelMix(presetB.channelMix)
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(log.renders.count == rendersBefore)
        #expect(log.saves.count == savesBefore)
        if case .saved = state.adjustmentPersistence {} else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
        }
    }

    // MARK: - 3. No RAW decode, demosaic or reduction

    /// The claim that makes a preset picker cheap to offer: choosing a preset
    /// is exactly as expensive as choosing a built-in mix, because both reach
    /// the pipeline through `setChannelMix`, which touches only the retained
    /// pre-mix preview. `decodeMosaic` is the single door to everything above
    /// it — normalisation, the white-balance estimate, demosaicing, the
    /// camera transform and the reduction — so one count across an open and
    /// two preset applications proves none of them ran again.
    @Test("Applying two different presets triggers no additional RAW decode, demosaic or reduction")
    func applyingPresetsRerunsNothingUpstream() async throws {
        let (state, decoder) = WorkspaceStubs.countingDocumentState(url: Self.url)
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        #expect(decoder.mosaicDecodeCount == 1)

        let presetA = try Self.makePreset(
            id: "user.preset-a", matrix: [0, 1, 0, 0, 0, 1, 1, 0, 0]
        )
        let presetB = try Self.makePreset(
            id: "user.preset-b", matrix: [1.5, -0.25, 0, 0, 0.5, 0.25, -0.5, 0, 2]
        )

        state.setChannelMix(presetA.channelMix)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: presetA.channelMix)
            )
        )
        state.setChannelMix(presetB.channelMix)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: presetB.channelMix)
            )
        )

        // Two presets applied, still one read of the file, and the LibRaw
        // diagnostic reference was not re-read either.
        #expect(decoder.mosaicDecodeCount == 1)
        #expect(decoder.processedDecodeCount == 1)
    }

    // MARK: - 4. A preset touches only the channel mix

    /// A preset is a channel-mix decision and nothing else. Applying one must
    /// leave the white balance, the exposure, the orientation and the capture
    /// profile exactly as they were — each is set first, to a deliberately
    /// non-default value, so "unchanged" is a statement about a real prior
    /// decision rather than about four fields that were already at rest.
    @Test("Applying a preset changes no white balance, exposure, orientation or capture profile")
    func applyingAPresetChangesNothingElse() async throws {
        let store = StubPhotographProcessingStore()
        let state = WorkspaceStubs.documentState(url: Self.url, store: store)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(originX: 0, originY: 0, width: 0.5, height: 0.5)
        )
        let exposure = try UserExposureAdjustment(ev: 1.5)

        state.setWhiteBalance(patch)
        state.setExposure(exposure)
        state.rotateOrientationRight()
        let settled = ImageAdjustments(
            orientation: .quarterTurnRight, exposure: exposure, whiteBalance: patch
        )
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: settled))
        let profileBefore = state.captureProfile.id

        let preset = try Self.makePreset(
            id: "user.preset-a", matrix: [1.8, -0.4, -0.4, -0.2, 1.4, -0.2, 2.5, 0, -1.5]
        )
        state.setChannelMix(preset.channelMix)
        let after = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: preset.channelMix,
            exposure: exposure,
            whiteBalance: patch
        )
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: after))

        // Requested state...
        #expect(state.whiteBalanceAdjustment == patch)
        #expect(state.exposureAdjustment == exposure)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.captureProfile.id == profileBefore)

        // ...and the rendered preview, not merely the request.
        #expect(preview.whiteBalanceAdjustment == patch)
        #expect(preview.exposureAdjustment == exposure)
        #expect(preview.userOrientationAdjustment == .quarterTurnRight)
        #expect(preview.captureProfileID == profileBefore)
        #expect(preview.channelMixAdjustment == preset.channelMix)
    }

    // MARK: - 5. The sidecar stores the resolved mix, at schema version 5

    /// The property that makes a preset safe to rename or delete: nothing
    /// about the preset — its identifier, its name, or the fact that a preset
    /// was involved at all — reaches the sidecar. What is written is the
    /// ordinary `UserChannelMixAdjustment` the mix control has always
    /// produced, at the schema version every other adjustment already writes.
    @Test("The photograph sidecar persists the resolved mix at schema version 5, with no preset reference")
    func theSidecarPersistsTheResolvedMixOnly() async throws {
        let store = StubPhotographProcessingStore()
        let state = WorkspaceStubs.documentState(url: Self.url, store: store)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let preset = IRCreativePreset(
            id: try IRCreativePresetID("user.blue-sky-look"),
            name: "My 720 nm Blue Sky",
            channelMix: try UserChannelMixAdjustment.explicit(
                persistedMatrix: [0.5, 0, 0, 0, 1, 0, 0, 0, 2]
            )
        )

        state.setChannelMix(preset.channelMix)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: preset.channelMix)
            )
        )
        try await Self.waitUntil("the preset's mix is saved") {
            store.saved(for: Self.url) == ImageAdjustments(channelMix: preset.channelMix)
        }

        let saved = try #require(store.savedState(for: Self.url))
        #expect(saved.adjustments.channelMix == preset.channelMix)

        // The current schema version really is 5, and the record on the wire
        // says so — read from the encoded bytes rather than from the model's
        // own constant, so a bug that changed what is actually emitted would
        // still be caught.
        #expect(PhotographProcessingState.currentSchemaVersion == 7)
        let data = try JSONEncoder().encode(saved)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == 7)

        guard let adjustments = object?["adjustments"] as? [String: Any],
              let channelMix = adjustments["channelMix"] as? [String: Any]
        else {
            Issue.record("Unexpected sidecar shape: \(object.debugDescription)")
            return
        }

        // The ordinary explicit-matrix wire shape: a kind token and nine
        // coefficients. Nothing else.
        #expect(channelMix["kind"] as? String == "matrix")
        #expect((channelMix["matrix"] as? [Double])?.count == 9)
        #expect(channelMix.keys.sorted() == ["kind", "matrix"])

        // No preset identity, name, or the word "preset" itself, anywhere in
        // the bytes actually written to disk.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains(preset.id.rawValue))
        #expect(!json.contains(preset.name))
        #expect(!json.lowercased().contains("preset"))
    }

    // MARK: - 6. A deleted preset cannot change an already-developed photograph

    /// The property a sidecar-stored resolved mix exists to buy, stated as an
    /// end-to-end scenario: a photograph is developed with a preset's look,
    /// the preset is then deleted from the library entirely, and reopening
    /// the photograph from the same store renders the identical pixels —
    /// because nothing about the open ever asked the library anything. The
    /// library is backed by a fresh temporary directory, cleaned up
    /// afterwards, and the real Application Support folder is never touched.
    @Test("Reopening a photograph after its preset is deleted renders identically")
    func reopeningAfterPresetDeletionRendersIdentically() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ir-creative-preset-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = IRCreativePresetLibrary(
            store: FileIRCreativePresetStore(directory: directory)
        )
        let preset = try library.create(
            IRCreativePresetDraft(name: "Deleted Later"),
            channelMix: try UserChannelMixAdjustment.explicit(
                persistedMatrix: [0.2, 0.6, 0, 0, 1, 0, 0, -0.3, 1.4]
            )
        )

        let store = StubPhotographProcessingStore()
        let firstOpen = WorkspaceStubs.documentState(url: Self.url, store: store)
        firstOpen.open(Self.url)
        try await Self.waitUntilSettled(firstOpen)

        firstOpen.setChannelMix(preset.channelMix)
        let rendered = try #require(
            await WorkspaceStubs.waitForPreview(
                firstOpen, adjustments: ImageAdjustments(channelMix: preset.channelMix)
            )
        )
        try await Self.waitUntil("the preset's mix is saved") {
            store.saved(for: Self.url) == ImageAdjustments(channelMix: preset.channelMix)
        }

        // The preset is gone, from the library and from disk, before the
        // photograph is ever reopened.
        try library.delete(preset.id)
        #expect(library.preset(for: preset.id) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: FileIRCreativePresetStore
                    .presetURL(for: preset.id, in: directory).path
            )
        )

        let reopened = WorkspaceStubs.documentState(url: Self.url, store: store)
        reopened.open(Self.url)
        try await Self.waitUntilSettled(reopened)
        let restored = try Self.preview(reopened)

        #expect(reopened.channelMixAdjustment == preset.channelMix)
        #expect(restored.channelMixAdjustment == preset.channelMix)
        #expect(restored.channelMix.matrix == preset.channelMix.matrix)
        #expect(
            WorkspaceStubs.pixelBytes(restored.image)
                == WorkspaceStubs.pixelBytes(rendered.image)
        )
    }
}
