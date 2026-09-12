import Testing
import Foundation
@testable import InfraredConverter

/// The channel mix as a **user adjustment**: what a control changes, what it
/// costs, what reaches the sidecar, and what happens when a decision cannot be
/// made durable.
///
/// The stub mosaic is 8 × 6 with every sample distinct, so an orientation is
/// identifiable from the pixels and a dimension swap cannot hide.
///
/// Serialised for the same reason `WorkspaceAdjustmentLifecycleTests` is: some
/// of these hold a real render at a gate, and a held render occupies a
/// cooperative-pool thread.
@Suite("Workspace channel-mix adjustment", .serialized)
@MainActor
struct WorkspaceChannelMixAdjustmentTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/mix-adjustment.orf")
    nonisolated static let otherURL = URL(fileURLWithPath: "/tmp/mix-adjustment-other.orf")

    static func state(
        store: StubImageAdjustmentStore,
        log: WorkspaceEventLog,
        render: DocumentState.PreviewRender? = nil
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
            render: render ?? RecordingRender(log: log).render
        )
    }

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

    // MARK: - The control changes canonical state, and nothing else

    @Test("A fresh open has the identity mix and offers the control")
    func aFreshOpenIsIdentity() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // No automatic infrared detection, deliberately: nothing here knows
        // whether this file is an infrared capture.
        #expect(state.channelMixAdjustment == .identity)
        #expect(try Self.preview(state).channelMixAdjustment == .identity)
        #expect(state.canAdjust)
        #expect(log.renders == [.none])
    }

    @Test("Choosing the swap re-renders and saves the complete state")
    func choosingTheSwapSavesTheCompleteState() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)
        #expect(store.saved(for: Self.url) == nil)

        let wanted = ImageAdjustments(channelMix: .redBlueSwap)
        state.setChannelMix(.redBlueSwap)
        // The intent is recorded immediately, and says it is not durable yet.
        #expect(state.channelMixAdjustment == .redBlueSwap)

        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: wanted)
        )
        #expect(preview.channelMix == IRChannelMix.redBlueSwap)
        #expect(preview.userOrientationAdjustment == .identity)

        // The whole record is written, not one field of it.
        #expect(store.saved(for: Self.url) == wanted)
        #expect(store.saved(for: Self.url)?.channelMix == .redBlueSwap)
        #expect(store.saved(for: Self.url)?.orientation == .identity)
        #expect(store.saved(for: Self.url)?.schemaVersion == 2)
        if case .saved = state.adjustmentPersistence {} else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
        }
    }

    @Test("Asking for the mix already in force does nothing at all")
    func askingForTheSameMixDoesNothing() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.identity)
        try await Task.sleep(nanoseconds: 30_000_000)

        // One render, from the open. No second one, and nothing written.
        #expect(log.renders == [.none])
        #expect(store.saved(for: Self.url) == nil)
        if case .unchanged = state.adjustmentPersistence {} else {
            Issue.record("Expected .unchanged, got \(state.adjustmentPersistence)")
        }
    }

    /// Choosing Identity after a swap is a real decision and is saved. It is
    /// the mix control's way of undoing a swap, and it leaves the orientation
    /// exactly where it was.
    @Test("Identity after a swap is saved, and does not touch the orientation")
    func identityAfterASwapIsSaved() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state,
                adjustments: ImageAdjustments(orientation: .quarterTurnRight)
            )
        )
        state.setChannelMix(.redBlueSwap)
        let swapped = ImageAdjustments(
            orientation: .quarterTurnRight, channelMix: .redBlueSwap
        )
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: swapped))
        #expect(store.saved(for: Self.url) == swapped)

        state.setChannelMix(.identity)
        let back = ImageAdjustments(orientation: .quarterTurnRight, channelMix: .identity)
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: back)
        )

        // The mix went back and the rotation stayed: two decisions, not one.
        #expect(preview.channelMixAdjustment == .identity)
        #expect(preview.userOrientationAdjustment == .quarterTurnRight)
        #expect(store.saved(for: Self.url) == back)
    }

    /// The two resets are separate, and the orientation's does not reach the
    /// mix. A control that quietly discarded a rendering choice along with a
    /// rotation would be the least recoverable button in the application.
    @Test("Resetting the orientation leaves the channel mix alone")
    func resettingTheOrientationKeepsTheMix() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        state.rotateOrientationRight()
        let both = ImageAdjustments(
            orientation: .quarterTurnRight, channelMix: .redBlueSwap
        )
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: both))

        state.resetOrientation()
        let reset = ImageAdjustments(orientation: .identity, channelMix: .redBlueSwap)
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: reset)
        )

        #expect(preview.userOrientationAdjustment == .identity)
        #expect(preview.channelMixAdjustment == .redBlueSwap)
        #expect(state.channelMixAdjustment == .redBlueSwap)
        #expect(store.saved(for: Self.url) == reset)
    }

    // MARK: - Nothing upstream reruns

    /// The claim that makes an interactive mixer worth having. `decodeMosaic`
    /// is the single door to every stage above the retained buffer —
    /// normalisation, the white-balance estimate, the white balance itself,
    /// demosaicing, the camera transform and the reduction are all reachable
    /// only through `prepare`, which begins with it. One call across an open
    /// and four adjustments therefore proves that none of them ran again.
    @Test("Changing the mix never decodes, demosaics or reduces again")
    func changingTheMixRerunsNothingUpstream() async throws {
        let (state, decoder) = WorkspaceStubs.countingDocumentState(url: Self.url)
        state.open(Self.url)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: .none)
        )
        #expect(decoder.mosaicDecodeCount == 1)

        let sequence: [ImageAdjustments] = [
            ImageAdjustments(channelMix: .redBlueSwap),
            ImageAdjustments(channelMix: .identity),
            ImageAdjustments(orientation: .quarterTurnRight, channelMix: .identity),
            ImageAdjustments(orientation: .quarterTurnRight, channelMix: .redBlueSwap),
        ]

        state.setChannelMix(.redBlueSwap)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: sequence[0]))
        state.setChannelMix(.identity)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: sequence[1]))
        state.rotateOrientationRight()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: sequence[2]))
        state.setChannelMix(.redBlueSwap)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: sequence[3]))

        // Four adjustments, still one read of the file.
        #expect(decoder.mosaicDecodeCount == 1)
        // And the LibRaw diagnostic reference was not re-read either.
        #expect(decoder.processedDecodeCount == 1)
    }

    /// The same claim stated about the buffer rather than the decoder: the
    /// retained source is the one the mixer reads, and it is never written to.
    @Test("The retained pre-mix source survives a sequence of mixes untouched")
    func theRetainedSourceSurvivesEveryMix() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        guard case .decoded(let opened) = state.status, let source = opened.source else {
            Issue.record("Expected a retained source")
            return
        }
        let before = source.preview.values

        state.setChannelMix(.redBlueSwap)
        state.rotateOrientationRight()
        state.setChannelMix(.identity)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state,
                adjustments: ImageAdjustments(
                    orientation: .quarterTurnRight, channelMix: .identity
                )
            )
        )

        guard case .decoded(let after) = state.status, let retained = after.source else {
            Issue.record("Expected a retained source")
            return
        }
        #expect(retained.preview.values.count == before.count)
        #expect(
            zip(retained.preview.values, before).allSatisfy { $0.bitPattern == $1.bitPattern }
        )
        // And it is still pre-mix, so the next mix is still one pass.
        #expect(!retained.preview.processing.channelMixApplied)
    }

    // MARK: - Coalescing over the complete state

    /// A burst across **both** controls. Nothing can be delivered between the
    /// calls — a delivery needs a hop back to this actor — so every render but
    /// the last is superseded by construction and the assertion is
    /// deterministic rather than a race.
    ///
    /// ```text
    /// A1  mix swap
    /// A2  rotate right
    /// A3  mix identity
    /// A4  rotate right      ← the only state that may be installed or saved
    /// ```
    @Test("A burst across both controls installs and saves only the newest state")
    func aBurstCollapsesToTheNewestCompleteState() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let a1 = ImageAdjustments(channelMix: .redBlueSwap)
        let a2 = ImageAdjustments(orientation: .quarterTurnRight, channelMix: .redBlueSwap)
        let a3 = ImageAdjustments(orientation: .quarterTurnRight, channelMix: .identity)
        let a4 = ImageAdjustments(orientation: .halfTurn, channelMix: .identity)

        state.setChannelMix(.redBlueSwap)
        state.rotateOrientationRight()
        state.setChannelMix(.identity)
        state.rotateOrientationRight()

        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: a4))
        // Let any superseded render finish unwinding and try to deliver.
        try await Task.sleep(nanoseconds: 50_000_000)

        // The settled state is on screen and on disk.
        #expect(preview.userOrientationAdjustment == .halfTurn)
        #expect(preview.channelMixAdjustment == .identity)
        #expect(store.saved(for: Self.url) == a4)
        #expect(log.saves == [a4])

        // And no intermediate state was installed or written. Each of the
        // three was genuinely requested, which is what makes this an
        // assertion rather than a tautology.
        for intermediate in [a1, a2, a3] {
            #expect(!log.saves.contains(intermediate))
        }
        #expect(store.writeSummary.count == 1)
    }

    /// The burst above collapses before anything renders; this one collapses
    /// around a render that is genuinely in flight. The held state is the
    /// open's own, so the mix changes pile up behind one render slot.
    @Test("States requested while a render is held collapse to the newest")
    func statesBehindAHeldRenderCollapse() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let held = ImageAdjustments(channelMix: .redBlueSwap)
        let gate = GatedRender(log: log, holds: { $0 == held })
        let state = Self.state(store: store, log: log, render: gate.render)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        try await gate.waitForGatedRenderToStart()

        // Two more decisions while the first is stuck at the gate.
        state.rotateOrientationRight()
        state.setChannelMix(.identity)
        let settled = ImageAdjustments(
            orientation: .quarterTurnRight, channelMix: .identity
        )
        #expect(state.channelMixAdjustment == .identity)
        #expect(!state.adjustmentPersistence.isDurable)

        gate.releaseOneRender()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: settled)
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        // The held render was superseded: it never installed and never wrote.
        #expect(store.saved(for: Self.url) == settled)
        #expect(log.saves == [settled])
        #expect(!log.saves.contains(held))
    }

    // MARK: - Opening a file with a saved mix

    /// The first application-owned preview already shows the saved state:
    /// both the geometry and the channels, with no identity render on the way
    /// to it.
    @Test("A saved mix and rotation are the first thing rendered")
    func aSavedMixIsTheFirstRender() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let saved = ImageAdjustments(
            orientation: .quarterTurnRight, channelMix: .redBlueSwap
        )
        store.preload(saved, for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // The decisive assertion: the recorded order. The store answered
        // first, the expensive decode came second, and the only render that
        // ever ran was the one with the whole saved state.
        #expect(log.all == [
            .loadedAdjustments(saved),
            .decodedMosaic,
            .rendered(saved)
        ])
        #expect(log.renders == [saved])
        #expect(log.renders.count == 1)
        #expect(log.decodeCount == 1)

        // No identity-mix flash: neither an unadjusted render nor a
        // rotation-only one ever happened.
        #expect(!log.all.contains(.rendered(.none)))
        #expect(!log.all.contains(
            .rendered(ImageAdjustments(orientation: .quarterTurnRight))
        ))
        #expect(!log.all.contains(.rendered(ImageAdjustments(channelMix: .redBlueSwap))))

        let preview = try Self.preview(state)
        #expect(preview.userOrientationAdjustment == .quarterTurnRight)
        #expect(preview.effectiveOrientation == .rotated90Clockwise)
        #expect(preview.channelMixAdjustment == .redBlueSwap)
        #expect(preview.channelMix == IRChannelMix.redBlueSwap)
        // Quarter-turn geometry, on the 8 × 6 stub.
        #expect(preview.pixelWidth == 6)
        #expect(preview.pixelHeight == 8)
        #expect(state.channelMixAdjustment == .redBlueSwap)

        // Opening writes nothing: nothing was decided this session.
        #expect(log.saves.isEmpty)
        if case .unchanged = state.adjustmentPersistence {} else {
            Issue.record("Expected .unchanged, got \(state.adjustmentPersistence)")
        }
    }

    /// And the restored image is the saved state's image, bit for bit the same
    /// as reaching that state by hand from an unsaved open.
    @Test("The restored image is the image the saved state produces")
    func theRestoredImageIsTheSavedOne() async throws {
        let byHandLog = WorkspaceEventLog()
        let byHandStore = StubImageAdjustmentStore(log: byHandLog)
        let byHand = Self.state(store: byHandStore, log: byHandLog)
        byHand.open(Self.url)
        try await Self.waitUntilSettled(byHand)
        byHand.setChannelMix(.redBlueSwap)
        byHand.rotateOrientationRight()
        let wanted = ImageAdjustments(
            orientation: .quarterTurnRight, channelMix: .redBlueSwap
        )
        let reached = try #require(
            await WorkspaceStubs.waitForPreview(byHand, adjustments: wanted)
        )

        let restoredLog = WorkspaceEventLog()
        let restoredStore = StubImageAdjustmentStore(log: restoredLog)
        restoredStore.preload(wanted, for: Self.url)
        let restored = Self.state(store: restoredStore, log: restoredLog)
        restored.open(Self.url)
        try await Self.waitUntilSettled(restored)

        #expect(
            WorkspaceStubs.pixelBytes(try Self.preview(restored).image)
                == WorkspaceStubs.pixelBytes(reached.image)
        )
    }

    @Test("A saved explicit matrix is restored as an explicit matrix")
    func aSavedExplicitMatrixIsRestored() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let explicit = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0.5, 0, 0, 0, 1, 0, 0, 0, 2]
        )
        let saved = ImageAdjustments(channelMix: explicit)
        store.preload(saved, for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let preview = try Self.preview(state)
        #expect(preview.channelMixAdjustment == explicit)
        #expect(preview.processing.mixSource == .explicit)
        #expect(state.channelMixAdjustment == explicit)
        // The workspace can render one without offering an editor for it.
        #expect(!UserChannelMixAdjustment.selectableCases.contains(explicit))
        #expect(state.canAdjust)
    }

    // MARK: - A refused render is not saved

    /// The rule from ADR 0013, now exercised through the mix: a state that
    /// could not be rendered was never eligible to be written, so the sidecar
    /// keeps the last state that actually rendered.
    ///
    /// The public adjustment type cannot construct an unrenderable mix — a
    /// matrix's nine coefficients are validated at construction — so the
    /// refusal is injected rather than manufactured by bypassing validation.
    @Test("A mix whose render refuses is not saved, and says which kind of failure")
    func aRefusedMixRenderIsNotSaved() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let bad = ImageAdjustments(channelMix: .redBlueSwap)
        let state = Self.state(
            store: store,
            log: log,
            render: RecordingRender(log: log, refuses: { $0 == bad }).render
        )

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // A first decision that does reach disk, so there is a durable state
        // for the refusal to leave alone.
        state.rotateOrientationRight()
        let durable = ImageAdjustments(orientation: .quarterTurnRight)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: durable))
        #expect(store.saved(for: Self.url) == durable)

        // Now a mix whose render refuses. Note this is a *different* complete
        // state from the one the refusal names, so it renders...
        state.setChannelMix(.redBlueSwap)
        try await Self.waitUntil("the requested mix rendered") {
            state.channelMixAdjustment == .redBlueSwap
        }
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state,
                adjustments: ImageAdjustments(
                    orientation: .quarterTurnRight, channelMix: .redBlueSwap
                )
            )
        )

        // ...and the one that is refused is the unrotated swap, reached by
        // resetting the orientation.
        state.resetOrientation()
        try await Self.waitUntil("the refused render was reported") {
            if case .renderRefused = state.adjustmentPersistence { return true }
            return false
        }

        // The state that could not be rendered was not written.
        #expect(store.saved(for: Self.url)?.channelMix == .redBlueSwap)
        #expect(store.saved(for: Self.url)?.orientation == .quarterTurnRight)
        #expect(!log.saves.contains(bad))
        // The user's intent is still recorded in memory; only the durable copy
        // lags, and it lags on the last state that actually worked.
        #expect(state.channelMixAdjustment == .redBlueSwap)
        #expect(state.orientationAdjustment == .identity)
        #expect(!state.adjustmentPersistence.isDurable)
        // And the controls still work, so the user can undo what broke it.
        #expect(state.canAdjust)
    }

    @Test("A save failure keeps the mixed image and reports itself")
    func aSaveFailureKeepsTheMixedImage() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        store.refuseSaves(
            with: .cannotWrite(
                sidecar: JSONSidecarImageAdjustmentStore.sidecarURL(for: Self.url),
                underlying: CocoaError(.fileWriteNoPermission)
            )
        )
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        let wanted = ImageAdjustments(channelMix: .redBlueSwap)
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: wanted)
        )

        // The render succeeded and the image stands. Rolling it back would be
        // a lie about what was rendered.
        #expect(preview.channelMix == IRChannelMix.redBlueSwap)
        #expect(state.channelMixAdjustment == .redBlueSwap)
        let failure = try #require(state.adjustmentSaveFailure)
        guard case .cannotWrite = failure else {
            Issue.record("Expected .cannotWrite, got \(failure)")
            return
        }
        #expect(store.saved(for: Self.url) == nil)
        #expect(log.saves.isEmpty)
    }

    // MARK: - Leaving a file mid-render

    /// ADR 0014, through the mix: a decision made a moment before switching
    /// files still reaches its own sidecar, under its own URL, and the new
    /// document is unaffected.
    @Test("A mix requested just before a file switch still reaches its own sidecar")
    func aPendingMixSettlesAfterASwitch() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let held = ImageAdjustments(channelMix: .redBlueSwap)
        let gate = GatedRender(log: log, holds: { $0 == held })
        let state = DocumentState(
            decoder: MultiFileStubDecoder(
                mosaics: [
                    Self.url: WorkspaceStubs.mosaic(url: Self.url, width: 8, height: 6),
                    Self.otherURL: WorkspaceStubs.mosaic(
                        url: Self.otherURL, width: 10, height: 4
                    ),
                ],
                log: log
            ),
            store: store,
            render: gate.render
        )

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        try await gate.waitForGatedRenderToStart()

        // Leave A while its decision is still being rendered. B appears at
        // once; A settles behind it.
        state.open(Self.otherURL)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: .none)
        )
        let arrived = try Self.preview(state)
        #expect(arrived.pixelWidth == 10)
        #expect(arrived.pixelHeight == 4)
        #expect(state.channelMixAdjustment == .identity)

        gate.releaseOneRender()
        try await Self.waitUntil("A settled") { !state.hasPendingAdjustmentWork }

        // A's decision reached A's sidecar, and only A's.
        #expect(store.saved(for: Self.url) == held)
        #expect(store.saved(for: Self.otherURL) == nil)
        #expect(store.writeSummary == ["mix-adjustment.orf:none:redBlueSwap"])

        // A's preview never landed in B: B is still showing B, at B's size,
        // with B's own identity mix.
        let stillB = try Self.preview(state)
        #expect(stillB.pixelWidth == 10)
        #expect(stillB.pixelHeight == 4)
        #expect(stillB.channelMixAdjustment == .identity)

        // And the settling document's source was the reduced pre-mix one: B's
        // retained source is, and A's was built the same way. Nothing
        // full-resolution was retained by either.
        guard case .decoded(let loaded) = state.status, let source = loaded.source else {
            Issue.record("Expected a retained source")
            return
        }
        #expect(!source.preview.processing.channelMixApplied)
        #expect(
            Mirror(reflecting: source).children.compactMap(\.label)
                == ["preview", "metadata", "url", "neutralPatch"]
        )
    }

    /// The ADR 0014 amendment, through the mix: reopening the **same** file
    /// waits for its older generation to finish writing, so the reopen reads a
    /// sidecar no older generation can still change.
    @Test("Reopening the same file with a pending mix serialises on its sidecar")
    func aSameURLReopenWaitsForItsOwnFile() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let held = ImageAdjustments(channelMix: .redBlueSwap)
        let gate = GatedRender(log: log, holds: { $0 == held })
        let state = Self.state(store: store, log: log, render: gate.render)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        try await gate.waitForGatedRenderToStart()

        // Reopen the same file while its decision is still in flight. Nothing
        // may be decoded yet: the two generations share one sidecar.
        state.open(Self.url)
        let decodesBefore = log.decodeCount
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(log.decodeCount == decodesBefore)
        guard case .decoding = state.status else {
            Issue.record("Expected the reopen to be waiting, got \(state.status)")
            return
        }

        gate.releaseOneRender()
        try await Self.waitUntil("the older generation wrote") {
            store.saved(for: Self.url) == held
        }
        // The reopen's own first render asks for the state it just read, which
        // this gate also holds, so it needs a release of its own.
        gate.releaseOneRender()
        try await Self.waitUntilSettled(state)

        // The older generation wrote first, and the reopen then read exactly
        // what it wrote: the swap is on screen without a second decision.
        #expect(store.saved(for: Self.url) == held)
        let preview = try Self.preview(state)
        #expect(preview.channelMixAdjustment == .redBlueSwap)

        // The order, from the log: the write precedes the reopen's load, and
        // the reopen's load precedes its decode.
        let saveIndex = try #require(log.firstIndex { $0 == .saved(held) })
        let loadIndex = try #require(
            log.all.indices.last {
                if case .loadedAdjustments = log.all[$0] { return true }
                return false
            }
        )
        #expect(saveIndex < loadIndex)
        #expect(log.all[loadIndex] == .loadedAdjustments(held))
        let decodeIndex = try #require(
            log.all.indices.last { log.all[$0] == .decodedMosaic }
        )
        #expect(loadIndex < decodeIndex)
        // And the reopen rendered the saved state directly, with no identity
        // render in front of it.
        #expect(log.renders.last == held)
    }
}
