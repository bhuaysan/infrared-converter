import Testing
import Foundation
@testable import InfraredConverter

/// Exposure as a **user adjustment**, and as the first continuous one: what the
/// control changes, what a slider burst costs, what reaches the sidecar, and
/// what happens to a decision when a render or a write refuses, or the user
/// leaves the photograph.
///
/// Exposure has no scheduler of its own. Every test here exercises the one
/// `CoalescingPreviewRenderer` the discrete controls already use.
///
/// Serialised for the reason `WorkspaceChannelMixAdjustmentTests` is: some of
/// these hold a real render at a gate.
@Suite("Workspace exposure adjustment", .serialized)
@MainActor
struct WorkspaceExposureAdjustmentTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/exposure-adjustment.orf")
    nonisolated static let otherURL = URL(fileURLWithPath: "/tmp/exposure-adjustment-other.orf")

    nonisolated static func ev(_ value: Double) throws -> UserExposureAdjustment {
        try UserExposureAdjustment(ev: value)
    }

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

    // MARK: - The control changes canonical state

    @Test("Setting the exposure re-renders and saves the complete state at schema 3")
    func settingTheExposureSavesTheCompleteState() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)
        #expect(state.exposureAdjustment == .neutral)
        #expect(try Self.preview(state).renderedExposureEV == 0)

        let wanted = ImageAdjustments(exposure: try Self.ev(0.7))
        state.setExposure(try Self.ev(0.7))
        // The intent is recorded at once, and is not durable yet.
        #expect(state.exposureAdjustment.ev == 0.7)
        #expect(!state.adjustmentPersistence.isDurable)

        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: wanted))
        #expect(preview.renderedExposureEV == 0.7)
        #expect(store.saved(for: Self.url) == wanted)
        #expect(store.saved(for: Self.url)?.schemaVersion == 3)
        guard case .saved = state.adjustmentPersistence else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
            return
        }
    }

    @Test("Asking for the exposure already in force does nothing at all")
    func askingForTheSameExposureDoesNothing() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setExposure(.neutral)
        state.resetExposure()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(log.renders == [.none])
        #expect(log.saves.isEmpty)
        guard case .unchanged = state.adjustmentPersistence else {
            Issue.record("Expected .unchanged, got \(state.adjustmentPersistence)")
            return
        }
    }

    @Test("Reset Exposure returns to 0 EV and leaves the mix and orientation alone")
    func resetExposureChangesOnlyTheExposure() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        state.rotateOrientationRight()
        state.setExposure(try Self.ev(1))
        let all = ImageAdjustments(
            orientation: .quarterTurnRight, channelMix: .redBlueSwap, exposure: try Self.ev(1)
        )
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: all))

        state.resetExposure()
        let reset = ImageAdjustments(orientation: .quarterTurnRight, channelMix: .redBlueSwap)
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: reset))

        #expect(preview.renderedExposureEV == 0)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.channelMixAdjustment == .redBlueSwap)
        #expect(store.saved(for: Self.url) == reset)
    }

    @Test("The other controls' resets leave the exposure alone")
    func otherResetsKeepTheExposure() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setExposure(try Self.ev(-1.5))
        state.rotateOrientationLeft()
        state.setChannelMix(.redBlueSwap)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state,
                adjustments: ImageAdjustments(
                    orientation: .quarterTurnLeft, channelMix: .redBlueSwap, exposure: try Self.ev(-1.5)
                )
            )
        )

        state.resetOrientation()
        state.setChannelMix(.identity)
        let kept = ImageAdjustments(exposure: try Self.ev(-1.5))
        let preview = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: kept))
        #expect(preview.renderedExposureEV == -1.5)
        #expect(store.saved(for: Self.url) == kept)
    }

    // MARK: - A slider burst

    /// The claim the milestone rests on. A drag from 0 to +1.5 EV in tenths
    /// produces fifteen requests while the first is still rendering. The
    /// first is held at a gate, so every later request arrives while a render
    /// is genuinely in flight — faster than rendering, deterministically.
    ///
    /// ```text
    /// +0.1   in flight, held        → cancelled when released; never delivered
    /// +0.2 … +1.4                   → each replaces the pending slot; never started
    /// +1.5                          → the only state rendered, installed and saved
    /// ```
    ///
    /// An install needs a completed render, so a render log holding only the
    /// open and `+1.5` is the proof that nothing in between was installed; the
    /// store's own log proves nothing in between was written.
    @Test("A slider burst faster than rendering renders, installs and saves only the newest state")
    func aSliderBurstCollapsesToTheNewest() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let held = ImageAdjustments(exposure: try Self.ev(0.1))
        let gate = GatedRender(log: log, holds: { $0 == held })
        let state = Self.state(store: store, log: log, render: gate.render)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setExposure(try Self.ev(0.1))
        try await gate.waitForGatedRenderToStart()

        var requested = [held]
        for step in 2...15 {
            let exposure = try Self.ev(Double(step) / 10)
            state.setExposure(exposure)
            requested.append(ImageAdjustments(exposure: exposure))
        }
        let newest = try #require(requested.last)
        #expect(newest.exposure.ev == 1.5)

        // While the render is held: the control is already at the newest
        // requested value, and the preview on screen — whose provenance the
        // inspector reads — still describes the image actually rendered.
        #expect(state.exposureAdjustment.ev == 1.5)
        #expect(!state.adjustmentPersistence.isDurable)
        let displayed = try Self.preview(state)
        #expect(displayed.renderedExposureEV == 0)
        #expect(displayed.exposureAdjustment == .neutral)

        gate.releaseOneRender()
        let settled = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: newest))
        // Let anything superseded finish unwinding and try to deliver.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(settled.renderedExposureEV == 1.5)
        #expect(try Self.preview(state).renderedExposureEV == 1.5)
        // Rendered: the open, then the newest. Nothing in between.
        #expect(log.renders == [.none, newest])
        // Written: the newest, once.
        #expect(log.saves == [newest])
        #expect(store.writeSummary == ["exposure-adjustment.orf:none:identity:1.5EV"])
        for intermediate in requested.dropLast() {
            #expect(!log.renders.contains(intermediate))
            #expect(!log.saves.contains(intermediate))
        }
        guard case .saved = state.adjustmentPersistence else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
            return
        }
    }

    /// The same burst with nothing held. Some early render may finish before
    /// the next request cancels it; `DocumentState`'s own guard then refuses
    /// to install or save it, because it is not the state requested now.
    @Test("An ungated burst still persists only the newest state")
    func anUngatedBurstPersistsOnlyTheNewest() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        for value in [0.2, 0.4, 0.8, 1.0] {
            state.setExposure(try Self.ev(value))
        }
        let newest = ImageAdjustments(exposure: try Self.ev(1.0))
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: newest))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(log.saves == [newest])
        #expect(store.saved(for: Self.url) == newest)
        #expect(try Self.preview(state).renderedExposureEV == 1.0)
    }

    // MARK: - Nothing upstream reruns

    @Test("Exposure, mix and rotation changes never decode, demosaic or reduce again")
    func exposureChangesRerunNothingUpstream() async throws {
        let (state, decoder) = WorkspaceStubs.countingDocumentState(url: Self.url)
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        #expect(decoder.mosaicDecodeCount == 1)

        state.setExposure(try Self.ev(0.2))
        _ = try #require(await WorkspaceStubs.waitForPreview(
            state, adjustments: ImageAdjustments(exposure: try Self.ev(0.2))))
        state.setExposure(try Self.ev(0.5))
        _ = try #require(await WorkspaceStubs.waitForPreview(
            state, adjustments: ImageAdjustments(exposure: try Self.ev(0.5))))
        state.setChannelMix(.redBlueSwap)
        _ = try #require(await WorkspaceStubs.waitForPreview(
            state, adjustments: ImageAdjustments(channelMix: .redBlueSwap, exposure: try Self.ev(0.5))))
        state.setExposure(try Self.ev(1.0))
        _ = try #require(await WorkspaceStubs.waitForPreview(
            state, adjustments: ImageAdjustments(channelMix: .redBlueSwap, exposure: try Self.ev(1.0))))
        state.rotateOrientationRight()
        _ = try #require(await WorkspaceStubs.waitForPreview(
            state,
            adjustments: ImageAdjustments(
                orientation: .quarterTurnRight, channelMix: .redBlueSwap, exposure: try Self.ev(1.0)
            )))
        state.setExposure(try Self.ev(-0.3))
        _ = try #require(await WorkspaceStubs.waitForPreview(
            state,
            adjustments: ImageAdjustments(
                orientation: .quarterTurnRight, channelMix: .redBlueSwap, exposure: try Self.ev(-0.3)
            )))

        // Six adjustments, one read of the file — so no normalisation, white
        // balance, demosaic, camera transform or reduction ran again, since
        // every one of those is reachable only through the decode.
        #expect(decoder.mosaicDecodeCount == 1)
        #expect(decoder.processedDecodeCount == 1)
    }

    // MARK: - Opening a file with a saved exposure

    @Test("A saved exposure, mix and rotation are all in the first render")
    func aSavedExposureIsTheFirstRender() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let saved = ImageAdjustments(
            orientation: .quarterTurnLeft, channelMix: .redBlueSwap, exposure: try Self.ev(1.25)
        )
        store.preload(saved, for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // Loaded first, decoded once, rendered once — with all three.
        #expect(log.all == [.loadedAdjustments(saved), .decodedMosaic, .rendered(saved)])
        // Never at 0 EV first.
        #expect(!log.all.contains(.rendered(
            ImageAdjustments(orientation: .quarterTurnLeft, channelMix: .redBlueSwap)
        )))
        #expect(!log.all.contains(.rendered(.none)))

        let preview = try Self.preview(state)
        #expect(preview.renderedExposureEV == 1.25)
        #expect(preview.exposureAdjustment.ev == 1.25)
        #expect(preview.channelMixAdjustment == .redBlueSwap)
        #expect(preview.effectiveOrientation == .rotated270Clockwise)
        #expect(preview.pixelWidth == 6)
        #expect(preview.pixelHeight == 8)
        #expect(state.exposureAdjustment.ev == 1.25)
        #expect(log.saves.isEmpty)
    }

    /// A valid saved value the slider cannot reach is opened, rendered and
    /// shown as saved, and nothing writes it back altered.
    @Test("A saved exposure beyond the slider opens unchanged and is not rewritten")
    func aSavedExposureBeyondTheSliderIsKept() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let saved = ImageAdjustments(exposure: try Self.ev(6))
        store.preload(saved, for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        #expect(state.exposureAdjustment.ev == 6)
        #expect(try Self.preview(state).renderedExposureEV == 6)
        #expect(ExposureControlScale.sliderPosition(for: state.exposureAdjustment) == 4)
        // The slider echoing its end stop asks for nothing.
        #expect(
            ExposureControlScale.adjustment(forSliderValue: 4, current: state.exposureAdjustment) == nil
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(log.renders == [saved])
        #expect(log.saves.isEmpty)
    }

    /// The whole round trip through the real sidecar: all three decisions
    /// reach the file at schema 3, and a fresh workspace reopening the file
    /// renders exactly that state — and exactly those pixels — first.
    @Test("Mix, orientation and exposure reach the sidecar and reopen as the first render")
    func allThreeRoundTripThroughTheSidecar() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("exposure-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("IR.ORF")
        let store = JSONSidecarImageAdjustmentStore()
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: raw)),
            mosaic: .success(WorkspaceStubs.mosaic(url: raw))
        )

        let firstLog = WorkspaceEventLog()
        let first = DocumentState(decoder: decoder, store: store, render: RecordingRender(log: firstLog).render)
        first.open(raw)
        try await Self.waitUntilSettled(first)
        first.setChannelMix(.redBlueSwap)
        first.rotateOrientationRight()
        first.setExposure(try Self.ev(1))
        let wanted = ImageAdjustments(
            orientation: .quarterTurnRight, channelMix: .redBlueSwap, exposure: try Self.ev(1)
        )
        let reached = try #require(await WorkspaceStubs.waitForPreview(first, adjustments: wanted))
        try await Self.waitUntil("saved") {
            if case .saved = first.adjustmentPersistence { return true }
            return false
        }

        #expect(reached.pixelWidth == 6)
        #expect(reached.pixelHeight == 8)
        #expect(reached.processing.mixSource == .redBlueSwap)
        #expect(reached.renderedExposureEV == 1)

        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: JSONSidecarImageAdjustmentStore.sidecarURL(for: raw))
            ) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 3)
        #expect(object["orientation"] as? String == "rotate90Clockwise")
        #expect((object["channelMix"] as? [String: Any])?["kind"] as? String == "redBlueSwap")
        #expect(object["exposureEV"] as? Double == 1)

        let secondLog = WorkspaceEventLog()
        let second = DocumentState(decoder: decoder, store: store, render: RecordingRender(log: secondLog).render)
        second.open(raw)
        try await Self.waitUntilSettled(second)

        #expect(secondLog.renders == [wanted])
        let restored = try Self.preview(second)
        #expect(WorkspaceStubs.pixelBytes(restored.image) == WorkspaceStubs.pixelBytes(reached.image))
        #expect(second.exposureAdjustment.ev == 1)
        #expect(second.channelMixAdjustment == .redBlueSwap)
        #expect(second.orientationAdjustment == .quarterTurnRight)
    }

    // MARK: - Refusals

    @Test("An exposure whose render refuses stays requested and is not saved")
    func aRefusedExposureRenderIsNotSaved() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let bad = try Self.ev(1.0)
        let state = Self.state(
            store: store,
            log: log,
            render: RecordingRender(log: log, refuses: { $0.exposure == bad }).render
        )
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let durable = ImageAdjustments(exposure: try Self.ev(0.5))
        state.setExposure(try Self.ev(0.5))
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: durable))
        #expect(store.saved(for: Self.url) == durable)

        state.setExposure(bad)
        try await Self.waitUntil("the refused render was reported") {
            if case .renderRefused = state.adjustmentPersistence { return true }
            return false
        }

        // The requested value is kept in memory; the sidecar keeps the last
        // state that actually rendered.
        #expect(state.exposureAdjustment == bad)
        #expect(store.saved(for: Self.url) == durable)
        #expect(!log.saves.contains(ImageAdjustments(exposure: bad)))
        #expect(state.canAdjust)
    }

    @Test("A save failure keeps the exposed image and reports itself")
    func aSaveFailureKeepsTheExposedImage() async throws {
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

        state.setExposure(try Self.ev(0.7))
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustments: ImageAdjustments(exposure: try Self.ev(0.7)))
        )

        #expect(preview.renderedExposureEV == 0.7)
        #expect(state.exposureAdjustment.ev == 0.7)
        let failure = try #require(state.adjustmentSaveFailure)
        guard case .cannotWrite = failure else {
            Issue.record("Expected .cannotWrite, got \(failure)")
            return
        }
        #expect(store.saved(for: Self.url) == nil)
        #expect(log.saves.isEmpty)
    }

    // MARK: - Leaving a file mid-render

    @Test("A slider state still rendering when another file opens reaches its own sidecar")
    func aPendingExposureSettlesAfterASwitch() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let held = ImageAdjustments(exposure: try Self.ev(1.2))
        let gate = GatedRender(log: log, holds: { $0 == held })
        let state = DocumentState(
            decoder: MultiFileStubDecoder(
                mosaics: [
                    Self.url: WorkspaceStubs.mosaic(url: Self.url, width: 8, height: 6),
                    Self.otherURL: WorkspaceStubs.mosaic(url: Self.otherURL, width: 10, height: 4),
                ],
                log: log
            ),
            store: store,
            render: gate.render
        )

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // A short drag whose newest state is held in flight.
        state.setExposure(try Self.ev(0.4))
        state.setExposure(try Self.ev(0.8))
        state.setExposure(try Self.ev(1.2))
        try await gate.waitForGatedRenderToStart()

        state.open(Self.otherURL)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustments: .none))
        let arrived = try Self.preview(state)
        #expect(arrived.pixelWidth == 10)
        #expect(arrived.pixelHeight == 4)
        #expect(state.exposureAdjustment == .neutral)

        gate.releaseOneRender()
        try await Self.waitUntil("A settled") { !state.hasPendingAdjustmentWork }

        // A's complete newest state reached A's sidecar, and only A's.
        #expect(store.saved(for: Self.url) == held)
        #expect(store.saved(for: Self.otherURL) == nil)
        #expect(store.writeSummary == ["exposure-adjustment.orf:none:identity:1.2EV"])

        // A's preview never landed in B.
        let stillB = try Self.preview(state)
        #expect(stillB.pixelWidth == 10)
        #expect(stillB.pixelHeight == 4)
        #expect(stillB.renderedExposureEV == 0)
    }

    @Test("Reopening the same file with a pending exposure serialises on its sidecar")
    func aSameURLReopenWaitsForItsOwnFile() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let held = ImageAdjustments(exposure: try Self.ev(1.2))
        let gate = GatedRender(log: log, holds: { $0 == held })
        let state = Self.state(store: store, log: log, render: gate.render)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setExposure(try Self.ev(1.2))
        try await gate.waitForGatedRenderToStart()

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
        // The reopen's first render asks for the state it just read, which
        // this gate also holds.
        gate.releaseOneRender()
        try await Self.waitUntilSettled(state)

        let preview = try Self.preview(state)
        #expect(preview.renderedExposureEV == 1.2)
        #expect(state.exposureAdjustment.ev == 1.2)

        let saveIndex = try #require(log.firstIndex { $0 == .saved(held) })
        let loadIndex = try #require(
            log.all.indices.last {
                if case .loadedAdjustments = log.all[$0] { return true }
                return false
            }
        )
        #expect(saveIndex < loadIndex)
        #expect(log.all[loadIndex] == .loadedAdjustments(held))
        #expect(log.renders.last == held)
    }
}
