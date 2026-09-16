import Testing
import Foundation
@testable import InfraredConverter

/// Levels as a **user adjustment**: what the control changes, what a slider
/// burst costs, what reaches the sidecar, and what happens to a decision when
/// a render or a write refuses.
///
/// Levels have no scheduler of their own — every test here exercises the one
/// `CoalescingPreviewRenderer` every other control already uses — and they are
/// the cheapest adjustment there is, applied below the retained reduced
/// preview.
///
/// Serialised for the reason `WorkspaceExposureAdjustmentTests` is: some of
/// these hold a real render at a gate.
@Suite("Workspace levels adjustment", .serialized)
@MainActor
struct WorkspaceLevelsAdjustmentTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/levels-adjustment.orf")

    nonisolated static func levels(
        _ black: Double, _ white: Double
    ) throws -> UserLevelsAdjustment {
        try UserLevelsAdjustment(blackPoint: black, whitePoint: white)
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

    @Test("A freshly opened document has neutral levels, and they are rendered")
    func aFreshDocumentIsNeutral() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        #expect(state.levelsAdjustment == .neutral)
        #expect(state.levelsAdjustment.isIdentity)
        let preview = try Self.preview(state)
        #expect(preview.levelsAdjustment == .neutral)
        // Recorded as applied even at the identity: traversing the stage and
        // asking for `black 0, white 1` is a different fact from never running
        // it at all.
        #expect(preview.processing.levelsApplied)
        #expect(preview.renderedLevels.isIdentity)
        #expect(preview.renderedLevels.blackPoint == 0)
        #expect(preview.renderedLevels.whitePoint == 1)
    }

    // MARK: - The control changes canonical state, and only that field

    @Test("Setting the levels re-renders and saves the complete state at schema 6")
    func settingTheLevelsSavesTheCompleteState() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let wanted = ImageAdjustments(levels: try Self.levels(0.05, 0.9))
        state.setLevels(try Self.levels(0.05, 0.9))
        // The intent is recorded at once, and is not durable yet.
        #expect(state.levelsAdjustment.blackPoint == 0.05)
        #expect(state.levelsAdjustment.whitePoint == 0.9)
        #expect(!state.adjustmentPersistence.isDurable)

        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: wanted))
        #expect(preview.renderedLevels.blackPoint == 0.05)
        #expect(preview.renderedLevels.whitePoint == 0.9)
        #expect(store.saved(for: Self.url) == wanted)
        #expect(store.savedState(for: Self.url)?.captureProfile == .builtinUncalibrated)
        #expect(store.writeSummary == [
            "levels-adjustment.orf:builtin.uncalibrated:none:identity:0.0EV:defaultNeutralPatch:0.05-0.9"
        ])
        guard case .saved = state.adjustmentPersistence else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
            return
        }
    }

    /// The claim that the record has five independent fields: changing one of
    /// them changes exactly one of them.
    @Test("A levels change leaves the other four adjustments and the profile alone")
    func levelsChangeNothingElse() async throws {
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
        let before = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 0.75),
            whiteBalance: patch
        )
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: before))

        state.setLevels(try Self.levels(-0.1, 1.3))
        var after = before
        after.levels = try Self.levels(-0.1, 1.3)
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: after))

        // Exactly one field moved.
        #expect(state.levelsAdjustment == after.levels)
        #expect(state.whiteBalanceAdjustment == patch)
        #expect(state.exposureAdjustment.ev == 0.75)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.channelMixAdjustment == .redBlueSwap)
        #expect(state.captureProfile.id == .builtinUncalibrated)
        #expect(preview.captureProfile.id == .builtinUncalibrated)
        #expect(preview.exposureAdjustment.ev == 0.75)
        #expect(preview.channelMixAdjustment == .redBlueSwap)
        #expect(preview.whiteBalanceAdjustment == patch)
        #expect(store.saved(for: Self.url) == after)
    }

    @Test("Asking for the levels already in force does nothing at all")
    func askingForTheSameLevelsDoesNothing() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setLevels(.neutral)
        state.resetLevels()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(log.renders == [.none])
        #expect(log.saves.isEmpty)
        guard case .unchanged = state.adjustmentPersistence else {
            Issue.record("Expected .unchanged, got \(state.adjustmentPersistence)")
            return
        }
    }

    // MARK: - Reset

    @Test("Reset Levels returns exactly to neutral and leaves everything else alone")
    func resetLevelsChangesOnlyTheLevels() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        state.rotateOrientationRight()
        state.setExposure(try UserExposureAdjustment(ev: 1))
        state.setLevels(try Self.levels(0.2, 0.8))
        let all = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1),
            levels: try Self.levels(0.2, 0.8)
        )
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: all))

        state.resetLevels()
        let reset = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1)
        )
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: reset))

        #expect(state.levelsAdjustment == .neutral)
        #expect(preview.renderedLevels.isIdentity)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.channelMixAdjustment == .redBlueSwap)
        #expect(state.exposureAdjustment.ev == 1)
        #expect(store.saved(for: Self.url) == reset)
    }

    /// Reset is a state, not an undo: the pixels after it are the pixels that
    /// would have been produced had the levels never been touched at all.
    @Test("Neutral after another setting reproduces the untouched rendering")
    func resetReproducesTheUntouchedRendering() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let original = try Self.preview(state)
        let originalBytes = WorkspaceStubs.pixelBytes(original.image)

        state.setLevels(try Self.levels(0.15, 0.85))
        let lifted = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(levels: try Self.levels(0.15, 0.85))
            )
        )
        #expect(WorkspaceStubs.pixelBytes(lifted.image) != originalBytes)

        state.resetLevels()
        let back = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        #expect(WorkspaceStubs.pixelBytes(back.image) == originalBytes)
    }

    @Test("The other controls' resets leave the levels alone")
    func otherResetsKeepTheLevels() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setLevels(try Self.levels(-0.05, 1.1))
        state.rotateOrientationLeft()
        state.setChannelMix(.redBlueSwap)
        state.setExposure(try UserExposureAdjustment(ev: 0.5))
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state,
                adjustments: ImageAdjustments(
                    orientation: .quarterTurnLeft,
                    channelMix: .redBlueSwap,
                    exposure: try UserExposureAdjustment(ev: 0.5),
                    levels: try Self.levels(-0.05, 1.1)
                )
            )
        )

        state.resetOrientation()
        state.setChannelMix(.identity)
        state.resetExposure()
        let kept = ImageAdjustments(levels: try Self.levels(-0.05, 1.1))
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: kept))
        #expect(preview.renderedLevels.blackPoint == -0.05)
        #expect(preview.renderedLevels.whitePoint == 1.1)
        #expect(store.saved(for: Self.url) == kept)
    }

    // MARK: - A slider burst

    /// The scheduling claim, at the cheapest adjustment there is. A drag
    /// produces fifteen requests while the first is still rendering; the first
    /// is held at a gate so every later request arrives while a render is
    /// genuinely in flight.
    ///
    /// An install needs a completed render, so a render log holding only the
    /// open and the newest state proves nothing in between was installed; the
    /// store's own log proves nothing in between was written.
    @Test("A levels burst faster than rendering renders, installs and saves only the newest")
    func aSliderBurstCollapsesToTheNewest() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let held = ImageAdjustments(levels: try Self.levels(0.01, 1))
        let gate = GatedRender(log: log, holds: { $0 == held })
        let state = Self.state(store: store, log: log, render: gate.render)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setLevels(try Self.levels(0.01, 1))
        try await gate.waitForGatedRenderToStart()

        var requested = [held]
        for step in 2...15 {
            let levels = try Self.levels(Double(step) / 100, 1)
            state.setLevels(levels)
            requested.append(ImageAdjustments(levels: levels))
        }
        let newest = try #require(requested.last)
        #expect(newest.levels.blackPoint == 0.15)

        // While the render is held: the control is already at the newest
        // requested value, and the preview on screen still describes the image
        // actually rendered.
        #expect(state.levelsAdjustment.blackPoint == 0.15)
        #expect(!state.adjustmentPersistence.isDurable)
        #expect(try Self.preview(state).renderedLevels.isIdentity)

        gate.releaseOneRender()
        let settled = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: newest))
        // Let anything superseded finish unwinding and try to deliver.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(settled.renderedLevels.blackPoint == 0.15)
        #expect(try Self.preview(state).renderedLevels.blackPoint == 0.15)
        // Rendered: the open, then the newest. Nothing in between.
        #expect(log.renders == [.none, newest])
        // Written: the newest, once.
        #expect(log.saves == [newest])
        #expect(store.writeSummary == [
            "levels-adjustment.orf:builtin.uncalibrated:none:identity:0.0EV:defaultNeutralPatch:0.15-1.0"
        ])
        for intermediate in requested.dropLast() {
            #expect(!log.renders.contains(intermediate))
            #expect(!log.saves.contains(intermediate))
        }
        guard case .saved = state.adjustmentPersistence else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
            return
        }
    }

    @Test("An ungated levels burst still persists only the newest state")
    func anUngatedBurstPersistsOnlyTheNewest() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        for value in [0.02, 0.04, 0.08, 0.1] {
            state.setLevels(try Self.levels(value, 1))
        }
        let newest = ImageAdjustments(levels: try Self.levels(0.1, 1))
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: newest))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(log.saves == [newest])
        #expect(store.saved(for: Self.url) == newest)
        #expect(try Self.preview(state).renderedLevels.blackPoint == 0.1)
    }

    // MARK: - Nothing upstream reruns

    /// Levels are the cheapest adjustment there is: they are applied below the
    /// retained reduced preview, so a change reruns the mix, the orientation,
    /// the exposure and the levels themselves, and nothing above them.
    ///
    /// The decode is the proof, because normalisation, the white-balance
    /// estimate, the balancer, the demosaicer, the camera-to-working
    /// conversion and the preview reduction are all reachable only through it.
    @Test("Levels changes never decode, white balance, demosaic or reduce again")
    func levelsChangesRerunNothingUpstream() async throws {
        let (state, decoder) = WorkspaceStubs.countingDocumentState(url: Self.url)
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        #expect(decoder.mosaicDecodeCount == 1)

        for (black, white) in [(0.02, 1.0), (0.05, 0.95), (-0.1, 1.2), (0.0, 0.5)] {
            state.setLevels(try Self.levels(black, white))
            _ = try #require(
                await WorkspaceStubs.waitForPreview(
                    state, adjustments: ImageAdjustments(levels: try Self.levels(black, white))
                )
            )
        }
        state.resetLevels()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))

        // Five levels changes, one read of the file.
        #expect(decoder.mosaicDecodeCount == 1)
        #expect(decoder.processedDecodeCount == 1)
    }

    /// The same claim stated against the *white balance*, which is the one
    /// adjustment that does re-prepare. A levels change must not be mistaken
    /// for one.
    @Test("A levels change is a cheap render, not a re-preparation")
    func levelsDoNotRePrepare() async throws {
        let (state, decoder) = WorkspaceStubs.countingDocumentState(url: Self.url)
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))

        state.setLevels(try Self.levels(0.1, 0.9))
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(levels: try Self.levels(0.1, 0.9))
            )
        )
        #expect(decoder.mosaicDecodeCount == 1)

        // A white-balance change, by contrast, re-prepares from the retained
        // mosaic — still without decoding again, which is what the retention
        // is for.
        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(originX: 0.1, originY: 0.1, width: 0.2, height: 0.2)
        )
        state.setWhiteBalance(patch)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state,
                adjustments: ImageAdjustments(
                    whiteBalance: patch, levels: try Self.levels(0.1, 0.9)
                )
            )
        )
        #expect(decoder.mosaicDecodeCount == 1)
        // And the levels survived the re-preparation unchanged.
        #expect(state.levelsAdjustment.blackPoint == 0.1)
    }

    // MARK: - Opening a file with saved levels

    @Test("Saved levels are the first thing rendered, never neutral first")
    func savedLevelsAreTheFirstRender() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let saved = ImageAdjustments(
            orientation: .quarterTurnLeft,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1.25),
            levels: try Self.levels(0.08, 1.4)
        )
        store.preload(saved, for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // Loaded first, decoded once, rendered once — with all of it.
        #expect(log.all == [.loadedAdjustments(saved), .decodedMosaic, .rendered(saved)])
        // Never with neutral levels first.
        var neutralFirst = saved
        neutralFirst.levels = .neutral
        #expect(!log.all.contains(.rendered(neutralFirst)))
        #expect(!log.all.contains(.rendered(.none)))

        let preview = try Self.preview(state)
        #expect(preview.renderedLevels.blackPoint == 0.08)
        #expect(preview.renderedLevels.whitePoint == 1.4)
        #expect(preview.levelsAdjustment == saved.levels)
        #expect(state.levelsAdjustment == saved.levels)
        #expect(log.saves.isEmpty)
    }

    /// A valid saved pair the sliders cannot reach opens, renders and is shown
    /// as saved; nothing writes it back altered.
    @Test("Saved levels beyond the sliders open unchanged and are not rewritten")
    func savedLevelsBeyondTheSlidersAreKept() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let saved = ImageAdjustments(levels: try Self.levels(-2, 4))
        store.preload(saved, for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        #expect(state.levelsAdjustment.blackPoint == -2)
        #expect(state.levelsAdjustment.whitePoint == 4)
        #expect(try Self.preview(state).renderedLevels.blackPoint == -2)
        #expect(LevelsControlScale.isBeyondSliders(state.levelsAdjustment))
        #expect(LevelsControlScale.blackSliderPosition(for: state.levelsAdjustment) == -0.5)
        #expect(LevelsControlScale.whiteSliderPosition(for: state.levelsAdjustment) == 1.5)
        // A slider echoing its end stop asks for nothing.
        #expect(
            LevelsControlScale.adjustment(
                forBlackSliderValue: -0.5, current: state.levelsAdjustment
            ) == nil
        )
        #expect(
            LevelsControlScale.adjustment(
                forWhiteSliderValue: 1.5, current: state.levelsAdjustment
            ) == nil
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(log.renders == [saved])
        #expect(log.saves.isEmpty)
    }

    /// The whole round trip through the real sidecar, at schema version 6.
    @Test("Levels reach the sidecar and reopen as the first render")
    func levelsRoundTripThroughTheSidecar() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("levels-roundtrip-\(UUID().uuidString)")
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
        first.setLevels(try Self.levels(0.05, 1.2))
        let wanted = ImageAdjustments(levels: try Self.levels(0.05, 1.2))
        let reached = try #require(await WorkspaceStubs.waitForPreview(first, adjustments: wanted))
        try await Self.waitUntil("saved") {
            if case .saved = first.adjustmentPersistence { return true }
            return false
        }

        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: JSONSidecarPhotographProcessingStore.sidecarURL(for: raw))
            ) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 6)
        let adjustments = try #require(object["adjustments"] as? [String: Any])
        let levels = try #require(adjustments["levels"] as? [String: Any])
        #expect(levels["blackPoint"] as? Double == 0.05)
        #expect(levels["whitePoint"] as? Double == 1.2)
        // One authority per field: nothing is left at the top level.
        #expect(object["levels"] == nil)

        let secondLog = WorkspaceEventLog()
        let second = DocumentState(
            decoder: decoder, store: store, render: RecordingRender(log: secondLog).render
        )
        second.open(raw)
        try await Self.waitUntilSettled(second)

        #expect(secondLog.renders == [wanted])
        let restored = try Self.preview(second)
        #expect(WorkspaceStubs.pixelBytes(restored.image) == WorkspaceStubs.pixelBytes(reached.image))
        #expect(second.levelsAdjustment == wanted.levels)
    }

    // MARK: - Refusals

    @Test("Levels whose render refuses stay requested and are not saved")
    func aRefusedLevelsRenderIsNotSaved() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let bad = try Self.levels(0.3, 0.4)
        let state = Self.state(
            store: store,
            log: log,
            render: RecordingRender(log: log, refuses: { $0.levels == bad }).render
        )
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let durable = ImageAdjustments(levels: try Self.levels(0.1, 0.9))
        state.setLevels(try Self.levels(0.1, 0.9))
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: durable))
        #expect(store.saved(for: Self.url) == durable)

        state.setLevels(bad)
        try await Self.waitUntil("the refused render was reported") {
            if case .renderRefused = state.adjustmentPersistence { return true }
            return false
        }

        // The requested pair is kept in memory; the sidecar keeps the last
        // state that actually rendered.
        #expect(state.levelsAdjustment == bad)
        #expect(store.saved(for: Self.url) == durable)
        #expect(!log.saves.contains(ImageAdjustments(levels: bad)))
        #expect(state.canAdjust)
    }

    @Test("A save failure keeps the levelled image and reports itself")
    func aSaveFailureKeepsTheLevelledImage() async throws {
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

        state.setLevels(try Self.levels(0.05, 0.95))
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(levels: try Self.levels(0.05, 0.95))
            )
        )

        #expect(preview.renderedLevels.blackPoint == 0.05)
        #expect(state.levelsAdjustment.blackPoint == 0.05)
        let failure = try #require(state.adjustmentSaveFailure)
        guard case .cannotWrite = failure else {
            Issue.record("Expected .cannotWrite, got \(failure)")
            return
        }
        #expect(store.saved(for: Self.url) == nil)
        #expect(log.saves.isEmpty)
    }
}
