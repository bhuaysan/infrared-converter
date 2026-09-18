import Testing
import Foundation
@testable import InfraredConverter

/// Contrast as a **user adjustment**: what the control changes, what a slider
/// burst costs, what reaches the sidecar, and what happens to a decision when
/// a render or a write refuses.
///
/// Contrast has no scheduler of its own — every test here exercises the one
/// `CoalescingPreviewRenderer` every other control already uses — and it is as
/// cheap as the levels, applied below the retained reduced preview.
///
/// Serialised for the reason `WorkspaceLevelsAdjustmentTests` is: some of
/// these hold a real render at a gate.
@Suite("Workspace contrast adjustment", .serialized)
@MainActor
struct WorkspaceContrastAdjustmentTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/contrast-adjustment.orf")

    nonisolated static func contrast(_ amount: Double) throws -> UserContrastAdjustment {
        try UserContrastAdjustment(amount: amount)
    }

    static func state(
        store: StubPhotographProcessingStore,
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

    static func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
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

    // MARK: - A fresh document

    @Test("A freshly opened document has neutral contrast, and it is rendered")
    func aFreshDocumentIsNeutral() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        #expect(state.contrastAdjustment == .neutral)
        #expect(state.contrastAdjustment.isIdentity)
        let preview = try Self.preview(state)
        #expect(preview.contrastAdjustment == .neutral)
        // Recorded as applied even at the identity: traversing the stage and
        // asking for `0` is a different fact from never running it at all.
        #expect(preview.processing.contrastApplied)
        #expect(preview.renderedContrastCurve.isIdentity)
        #expect(preview.renderedContrastCurve.exponent == 1)
    }

    // MARK: - The control changes canonical state, and only that field

    @Test("Setting the contrast re-renders and saves the complete state at schema 7")
    func settingTheContrastSavesTheCompleteState() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let wanted = ImageAdjustments(contrast: try Self.contrast(0.35))
        state.setContrast(try Self.contrast(0.35))
        // The intent is recorded at once, and is not durable yet.
        #expect(state.contrastAdjustment.amount == 0.35)
        #expect(!state.adjustmentPersistence.isDurable)

        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: wanted))
        #expect(preview.renderedContrastCurve.amount == 0.35)
        #expect(store.saved(for: Self.url) == wanted)
        #expect(store.savedState(for: Self.url)?.captureProfile == .builtinUncalibrated)
        #expect(store.writeSummary == [
            "contrast-adjustment.orf:builtin.uncalibrated:none:identity:0.0EV:defaultNeutralPatch:0.0-1.0:0.35C"
        ])
        guard case .saved = state.adjustmentPersistence else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
            return
        }
    }

    /// The claim that the record has six independent fields: changing one of
    /// them changes exactly one of them.
    @Test("A contrast change leaves the other five adjustments and the profile alone")
    func contrastChangesNothingElse() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(originX: 0.1, originY: 0.2, width: 0.2, height: 0.2)
        )
        state.setWhiteBalance(patch)
        state.setChannelMix(.redBlueSwap)
        state.rotateOrientationRight()
        state.setExposure(try UserExposureAdjustment(ev: 0.75))
        state.setLevels(try UserLevelsAdjustment(blackPoint: 0.05, whitePoint: 0.9))
        let before = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 0.75),
            whiteBalance: patch,
            levels: try UserLevelsAdjustment(blackPoint: 0.05, whitePoint: 0.9)
        )
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: before))

        state.setContrast(try Self.contrast(-0.4))
        var after = before
        after.contrast = try Self.contrast(-0.4)
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: after))

        // Exactly one field moved.
        #expect(state.contrastAdjustment == after.contrast)
        #expect(state.whiteBalanceAdjustment == patch)
        #expect(state.exposureAdjustment.ev == 0.75)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.channelMixAdjustment == .redBlueSwap)
        #expect(state.levelsAdjustment.blackPoint == 0.05)
        #expect(state.captureProfile.id == .builtinUncalibrated)
        #expect(preview.captureProfile.id == .builtinUncalibrated)
        #expect(preview.exposureAdjustment.ev == 0.75)
        #expect(preview.channelMixAdjustment == .redBlueSwap)
        #expect(preview.whiteBalanceAdjustment == patch)
        #expect(preview.levelsAdjustment.whitePoint == 0.9)
        #expect(store.saved(for: Self.url) == after)
    }

    @Test("Asking for the contrast already in force does nothing at all")
    func askingForTheSameContrastDoesNothing() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setContrast(.neutral)
        state.resetContrast()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(log.renders == [.none])
        #expect(log.saves.isEmpty)
        guard case .unchanged = state.adjustmentPersistence else {
            Issue.record("Expected .unchanged, got \(state.adjustmentPersistence)")
            return
        }
    }

    // MARK: - Reset

    @Test("Reset Contrast returns exactly to neutral and leaves everything else alone")
    func resetContrastChangesOnlyTheContrast() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        state.rotateOrientationRight()
        state.setExposure(try UserExposureAdjustment(ev: 1))
        state.setLevels(try UserLevelsAdjustment(blackPoint: 0.2, whitePoint: 0.8))
        state.setContrast(try Self.contrast(0.8))
        let all = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1),
            levels: try UserLevelsAdjustment(blackPoint: 0.2, whitePoint: 0.8),
            contrast: try Self.contrast(0.8)
        )
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: all))

        state.resetContrast()
        var reset = all
        reset.contrast = .neutral
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: reset))

        #expect(state.contrastAdjustment == .neutral)
        #expect(preview.renderedContrastCurve.isIdentity)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.channelMixAdjustment == .redBlueSwap)
        #expect(state.exposureAdjustment.ev == 1)
        #expect(state.levelsAdjustment.blackPoint == 0.2)
        #expect(store.saved(for: Self.url) == reset)
    }

    /// Reset is a state, not an undo: the pixels after it are the pixels that
    /// would have been produced had the contrast never been touched at all.
    @Test("Neutral after another amount reproduces the untouched rendering")
    func resetReproducesTheUntouchedRendering() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let original = try Self.preview(state)
        let originalBytes = WorkspaceStubs.pixelBytes(original.image)

        state.setContrast(try Self.contrast(0.75))
        let steeper = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(contrast: try Self.contrast(0.75))
            )
        )
        #expect(WorkspaceStubs.pixelBytes(steeper.image) != originalBytes)

        state.resetContrast()
        let back = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        #expect(WorkspaceStubs.pixelBytes(back.image) == originalBytes)
    }

    @Test("The other controls' resets leave the contrast alone")
    func otherResetsKeepTheContrast() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setContrast(try Self.contrast(-0.25))
        state.rotateOrientationLeft()
        state.setChannelMix(.redBlueSwap)
        state.setExposure(try UserExposureAdjustment(ev: 0.5))
        state.setLevels(try UserLevelsAdjustment(blackPoint: -0.05, whitePoint: 1.1))
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state,
                adjustments: ImageAdjustments(
                    orientation: .quarterTurnLeft,
                    channelMix: .redBlueSwap,
                    exposure: try UserExposureAdjustment(ev: 0.5),
                    levels: try UserLevelsAdjustment(blackPoint: -0.05, whitePoint: 1.1),
                    contrast: try Self.contrast(-0.25)
                )
            )
        )

        state.resetOrientation()
        state.setChannelMix(.identity)
        state.resetExposure()
        state.resetLevels()
        let kept = ImageAdjustments(contrast: try Self.contrast(-0.25))
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: kept))
        #expect(preview.renderedContrastCurve.amount == -0.25)
        #expect(store.saved(for: Self.url) == kept)
    }

    // MARK: - State, not history

    /// `C1` then `C2` is `C2(levelled)`, not `C2(C1(levelled))`. Two curves of
    /// this family do not compose into a third, so the difference is real.
    @Test("A second amount replaces the first rather than composing with it")
    func amountsDoNotCompose() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // C1, then C2.
        state.setContrast(try Self.contrast(0.5))
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(contrast: try Self.contrast(0.5))
            )
        )
        state.setContrast(try Self.contrast(0.75))
        let chained = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(contrast: try Self.contrast(0.75))
            )
        )

        // C2 alone, on a fresh document.
        let directLog = WorkspaceEventLog()
        let directStore = StubPhotographProcessingStore(log: directLog)
        let direct = Self.state(store: directStore, log: directLog)
        direct.open(Self.url)
        try await Self.waitUntilSettled(direct)
        direct.setContrast(try Self.contrast(0.75))
        let alone = try #require(
            await WorkspaceStubs.waitForPreview(
                direct, adjustments: ImageAdjustments(contrast: try Self.contrast(0.75))
            )
        )

        #expect(WorkspaceStubs.pixelBytes(chained.image) == WorkspaceStubs.pixelBytes(alone.image))
        #expect(chained.renderedContrastCurve.amount == 0.75)
    }

    // MARK: - A slider burst

    /// The scheduling claim. A drag produces fifteen requests while the first
    /// is still rendering; the first is held at a gate so every later request
    /// arrives while a render is genuinely in flight.
    @Test("A contrast burst faster than rendering renders, installs and saves only the newest")
    func aSliderBurstCollapsesToTheNewest() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let held = ImageAdjustments(contrast: try Self.contrast(0.01))
        let gate = GatedRender(log: log, holds: { $0 == held })
        let state = Self.state(store: store, log: log, render: gate.render)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setContrast(try Self.contrast(0.01))
        try await gate.waitForGatedRenderToStart()

        var requested = [held]
        for step in 2...15 {
            let amount = try Self.contrast(Double(step) / 100)
            state.setContrast(amount)
            requested.append(ImageAdjustments(contrast: amount))
        }
        let newest = try #require(requested.last)
        #expect(newest.contrast.amount == 0.15)

        // While the render is held: the control is already at the newest
        // requested value, and the preview on screen still describes the image
        // actually rendered.
        #expect(state.contrastAdjustment.amount == 0.15)
        #expect(!state.adjustmentPersistence.isDurable)
        #expect(try Self.preview(state).renderedContrastCurve.isIdentity)

        gate.releaseOneRender()
        let settled = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: newest))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(settled.renderedContrastCurve.amount == 0.15)
        #expect(try Self.preview(state).renderedContrastCurve.amount == 0.15)
        // Rendered: the open, then the newest. Nothing in between.
        #expect(log.renders == [.none, newest])
        #expect(log.saves == [newest])
        for intermediate in requested.dropLast() {
            #expect(!log.renders.contains(intermediate))
            #expect(!log.saves.contains(intermediate))
        }
        guard case .saved = state.adjustmentPersistence else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
            return
        }
    }

    @Test("An ungated contrast burst still persists only the newest state")
    func anUngatedBurstPersistsOnlyTheNewest() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        for value in [0.02, 0.04, 0.08, 0.1] {
            state.setContrast(try Self.contrast(value))
        }
        let newest = ImageAdjustments(contrast: try Self.contrast(0.1))
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: newest))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(log.saves == [newest])
        #expect(store.saved(for: Self.url) == newest)
        #expect(try Self.preview(state).renderedContrastCurve.amount == 0.1)
    }

    // MARK: - Nothing upstream reruns

    /// A contrast change is applied below the retained reduced preview, so it
    /// reruns the mix, the orientation, the exposure, the levels and its own
    /// curve, and nothing above them.
    ///
    /// The decode is the proof, because normalisation, the white-balance
    /// estimate, the balancer, the demosaicer, the camera-to-working
    /// conversion and the preview reduction are all reachable only through it.
    @Test("Contrast changes never decode, white balance, demosaic or reduce again")
    func contrastChangesRerunNothingUpstream() async throws {
        let (state, decoder) = WorkspaceStubs.countingDocumentState(url: Self.url)
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        #expect(decoder.mosaicDecodeCount == 1)

        for amount in [0.1, -0.25, 0.9, -1.0, 1.0] {
            state.setContrast(try Self.contrast(amount))
            _ = try #require(
                await WorkspaceStubs.waitForPreview(
                    state, adjustments: ImageAdjustments(contrast: try Self.contrast(amount))
                )
            )
        }
        state.resetContrast()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))

        // Six contrast changes, one read of the file.
        #expect(decoder.mosaicDecodeCount == 1)
        #expect(decoder.processedDecodeCount == 1)
    }

    /// The same claim stated against the *white balance*, which is the one
    /// adjustment that does re-prepare. A contrast change must not be mistaken
    /// for one.
    @Test("A contrast change is a cheap render, not a re-preparation")
    func contrastDoesNotRePrepare() async throws {
        let (state, decoder) = WorkspaceStubs.countingDocumentState(url: Self.url)
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))

        state.setContrast(try Self.contrast(0.4))
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(contrast: try Self.contrast(0.4))
            )
        )
        #expect(decoder.mosaicDecodeCount == 1)

        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(originX: 0.1, originY: 0.1, width: 0.2, height: 0.2)
        )
        state.setWhiteBalance(patch)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state,
                adjustments: ImageAdjustments(
                    whiteBalance: patch, contrast: try Self.contrast(0.4)
                )
            )
        )
        #expect(decoder.mosaicDecodeCount == 1)
        // And the contrast survived the re-preparation unchanged.
        #expect(state.contrastAdjustment.amount == 0.4)
    }

    // MARK: - When a render or a write refuses

    @Test("Contrast whose render refuses stays requested and is not saved")
    func aRefusedRenderKeepsTheRequestAndSavesNothing() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let bad = try Self.contrast(0.6)
        let state = Self.state(
            store: store,
            log: log,
            render: RecordingRender(log: log, refuses: { $0.contrast == bad }).render
        )
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let durable = ImageAdjustments(contrast: try Self.contrast(0.2))
        state.setContrast(try Self.contrast(0.2))
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: durable))
        #expect(store.saved(for: Self.url) == durable)

        state.setContrast(bad)
        try await Self.waitUntil("the refused render was reported") {
            if case .renderRefused = state.adjustmentPersistence { return true }
            return false
        }

        // The requested amount is kept in memory; the sidecar keeps the last
        // state that actually rendered.
        #expect(state.contrastAdjustment == bad)
        #expect(store.saved(for: Self.url) == durable)
        #expect(!log.saves.contains(ImageAdjustments(contrast: bad)))
        #expect(state.canAdjust)
    }

    @Test("A save failure keeps the rendered image and reports itself")
    func aSaveFailureKeepsTheImage() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        store.refuseSaves(
            with: .cannotWrite(
                sidecar: JSONSidecarPhotographProcessingStore.sidecarURL(for: Self.url),
                underlying: CocoaError(.fileWriteNoPermission)
            )
        )
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let wanted = ImageAdjustments(contrast: try Self.contrast(0.5))
        state.setContrast(try Self.contrast(0.5))
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: wanted))

        // The render succeeded and is not withdrawn because the write failed.
        #expect(preview.renderedContrastCurve.amount == 0.5)
        #expect(state.contrastAdjustment.amount == 0.5)
        let failure = try #require(state.adjustmentSaveFailure)
        guard case .cannotWrite = failure else {
            Issue.record("Expected .cannotWrite, got \(failure)")
            return
        }
        #expect(store.saved(for: Self.url) == nil)
        #expect(log.saves.isEmpty)
    }

    // MARK: - Opening a file with saved contrast

    @Test("Saved contrast is the first thing rendered, never neutral first")
    func savedContrastIsTheFirstRender() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let saved = ImageAdjustments(
            orientation: .quarterTurnLeft,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1.25),
            levels: try UserLevelsAdjustment(blackPoint: 0.08, whitePoint: 1.4),
            contrast: try Self.contrast(-0.65)
        )
        store.preload(saved, for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // Loaded first, decoded once, rendered once — with all of it.
        #expect(log.all == [.loadedAdjustments(saved), .decodedMosaic, .rendered(saved)])
        // Never with neutral contrast first.
        var neutralFirst = saved
        neutralFirst.contrast = .neutral
        #expect(!log.all.contains(.rendered(neutralFirst)))
        #expect(!log.all.contains(.rendered(.none)))

        let preview = try Self.preview(state)
        #expect(preview.renderedContrastCurve.amount == -0.65)
        #expect(preview.contrastAdjustment == saved.contrast)
        #expect(state.contrastAdjustment == saved.contrast)
        #expect(log.saves.isEmpty)
    }

    /// The whole round trip through the real sidecar, at schema version 7.
    @Test("Contrast reaches the sidecar and reopens as the first render")
    func contrastRoundTripsThroughTheSidecar() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("contrast-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("IR.ORF")
        let store = JSONSidecarPhotographProcessingStore()
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: raw)),
            mosaic: .success(WorkspaceStubs.mosaic(url: raw))
        )

        let firstLog = WorkspaceEventLog()
        let first = DocumentState(
            decoder: decoder, store: store, render: RecordingRender(log: firstLog).render
        )
        first.open(raw)
        try await Self.waitUntilSettled(first)
        first.setContrast(try Self.contrast(0.35))
        let wanted = ImageAdjustments(contrast: try Self.contrast(0.35))
        _ = try #require(await WorkspaceStubs.waitForPreview(first, adjustments: wanted))
        try await Self.waitUntil("saved") {
            if case .saved = first.adjustmentPersistence { return true }
            return false
        }

        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: JSONSidecarPhotographProcessingStore.sidecarURL(for: raw))
            ) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 7)
        let adjustments = try #require(object["adjustments"] as? [String: Any])
        // A bare number, not an object, and no exponent beside it.
        #expect(adjustments["contrast"] as? Double == 0.35)
        #expect(adjustments["contrast"] as? [String: Any] == nil)
        #expect(adjustments["contrastExponent"] == nil)
        // One authority per field: nothing is left at the top level.
        #expect(object["contrast"] == nil)

        let secondLog = WorkspaceEventLog()
        let second = DocumentState(
            decoder: decoder, store: store, render: RecordingRender(log: secondLog).render
        )
        second.open(raw)
        try await Self.waitUntilSettled(second)

        #expect(second.contrastAdjustment.amount == 0.35)
        #expect(secondLog.renders == [wanted])
        #expect(!secondLog.renders.contains(.none))
    }
}
