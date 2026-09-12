import Testing
import Foundation
@testable import InfraredConverter

/// What the workspace does with saved adjustments: when it reads them, what it
/// renders first, when it writes them, and — above all — when it does not.
///
/// The stub mosaic is 8 × 6 with every sample distinct, so an orientation can
/// be identified from the pixels alone and a dimension swap cannot hide.
@Suite("Workspace adjustment persistence")
@MainActor
struct WorkspaceAdjustmentPersistenceTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/persistence-example.orf")
    nonisolated static let otherURL = URL(fileURLWithPath: "/tmp/persistence-other.orf")

    /// A workspace wired to a recording store, a recording decoder and the
    /// real render.
    static func state(
        url: URL = WorkspaceAdjustmentPersistenceTests.url,
        flip: Int = 0,
        store: StubImageAdjustmentStore,
        log: WorkspaceEventLog,
        refusing: [UserOrientationAdjustment] = []
    ) -> DocumentState {
        DocumentState(
            decoder: RecordingMosaicDecoder(
                wrapped: WorkspaceStubDecoder(
                    result: .success(RAWTestData.decodedRAW(url: url)),
                    mosaic: .success(WorkspaceStubs.mosaic(url: url, flip: flip))
                ),
                log: log
            ),
            store: store,
            render: RecordingRender(log: log, refusing: refusing).render
        )
    }

    static func waitUntilSettled(_ state: DocumentState) async throws {
        for _ in 0..<400 {
            if case .decoding = state.status {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                return
            }
        }
        Issue.record("The open never settled")
    }

    /// Waits until the owned preview reports a refusal.
    static func waitForOwnedFailure(_ state: DocumentState) async throws {
        for _ in 0..<400 {
            if case .decoded(let loaded) = state.status, case .unavailable = loaded.owned {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("The owned preview never reported a failure")
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

    // MARK: - A. No sidecar

    @Test("With no saved adjustments the file opens exactly as it always did")
    func noSidecarOpensWithNoAdjustments() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let preview = try Self.preview(state)
        #expect(preview.userOrientationAdjustment == .identity)
        #expect(preview.effectiveOrientation == .upright)
        #expect(state.orientationAdjustment == .identity)

        // The absence of a sidecar is not a failure, and the store was still
        // consulted before anything was decoded.
        #expect(log.all == [
            .loadedAdjustments(nil), .decodedMosaic, .rendered(.none)
        ])
        // Opening writes nothing. Nothing was decided.
        #expect(store.saved(for: Self.url) == nil)
        if case .unchanged = state.adjustmentPersistence {} else {
            Issue.record("Expected .unchanged, got \(state.adjustmentPersistence)")
        }
    }

    // MARK: - B. An existing sidecar is part of the opening state

    @Test("Saved adjustments are read before the file is decoded or rendered")
    func savedAdjustmentsAreReadFirst() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        store.preload(ImageAdjustments(orientation: .quarterTurnRight), for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // The decisive assertion: the recorded order. The store answered
        // first, the expensive decode came second, and the only render that
        // ever ran was the one with the saved adjustment.
        #expect(log.all == [
            .loadedAdjustments(ImageAdjustments(orientation: .quarterTurnRight)),
            .decodedMosaic,
            .rendered(ImageAdjustments(orientation: .quarterTurnRight))
        ])

        let preview = try Self.preview(state)
        #expect(preview.userOrientationAdjustment == .quarterTurnRight)
        #expect(preview.sourceOrientation == .upright)
        #expect(preview.effectiveOrientation == .rotated90Clockwise)
        #expect(preview.pixelWidth == 6)
        #expect(preview.pixelHeight == 8)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.canAdjust)
    }

    /// The strongest form of "no identity image was ever on screen": there was
    /// exactly one render, and it produced the rotated pixels.
    @Test("Opening with a sidecar renders once, not once per state")
    func openingWithASidecarRendersOnce() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        store.preload(ImageAdjustments(orientation: .halfTurn), for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        #expect(log.renderedOrientations == [.halfTurn])
        #expect(log.renderedOrientations.count == 1)
        // The preparation still happens exactly once, as it always did.
        #expect(log.decodeCount == 1)
        #expect(!log.all.contains(.rendered(.none)))
    }

    /// And the pixels are the saved state's pixels — bit for bit the same as
    /// reaching that state by hand from an unsaved open.
    @Test("The restored image is the image the saved adjustment produces")
    func theRestoredImageIsTheSavedOne() async throws {
        let byHandLog = WorkspaceEventLog()
        let byHandStore = StubImageAdjustmentStore(log: byHandLog)
        let byHand = Self.state(store: byHandStore, log: byHandLog)
        byHand.open(Self.url)
        _ = try await WorkspaceStubs.waitForPreview(byHand, adjustment: .identity)
        byHand.rotateOrientationRight()
        let rotated = try #require(
            await WorkspaceStubs.waitForPreview(byHand, adjustment: .quarterTurnRight)
        )

        let restoredLog = WorkspaceEventLog()
        let restoredStore = StubImageAdjustmentStore(log: restoredLog)
        restoredStore.preload(ImageAdjustments(orientation: .quarterTurnRight), for: Self.url)
        let restored = Self.state(store: restoredStore, log: restoredLog)
        restored.open(Self.url)
        try await Self.waitUntilSettled(restored)

        #expect(
            WorkspaceStubs.pixelBytes(try Self.preview(restored).image)
                == WorkspaceStubs.pixelBytes(rotated.image)
        )
    }

    // MARK: - C, D. Saving a rendered adjustment

    @Test("A successfully rendered adjustment is saved")
    func aRenderedAdjustmentIsSaved() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        #expect(store.saved(for: Self.url) == nil)

        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        #expect(store.saved(for: Self.url)?.orientation == .quarterTurnRight)
        #expect(store.saved(for: Self.url)?.schemaVersion == ImageAdjustments.currentSchemaVersion)
        if case .saved = state.adjustmentPersistence {} else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
        }
        #expect(state.adjustmentSaveFailure == nil)
        // The save follows the render, never precedes it.
        let turned = ImageAdjustments(orientation: .quarterTurnRight)
        let renderIndex = try #require(log.firstIndex { $0 == .rendered(turned) })
        let saveIndex = try #require(log.firstIndex { $0 == .saved(turned) })
        #expect(renderIndex < saveIndex)
    }

    @Test("After several settled changes the store holds the current state only")
    func severalChangesLeaveTheCurrentState() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)

        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )
        state.rotateOrientationRight()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .halfTurn))
        state.flipOrientationHorizontally()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .verticalFlip))
        state.resetOrientation()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))

        // One record, always the canonical state — never a history of presses.
        #expect(store.saved(for: Self.url)?.orientation == .identity)
        #expect(store.saved(for: Self.url)?.orientation == state.orientationAdjustment)
        // A reset is a decision, so it is written like any other. Identity is
        // stored, not implied by an absent record.
        #expect(store.saved(for: Self.url) != nil)
        #expect(log.savedOrientations == [.quarterTurnRight, .halfTurn, .verticalFlip, .identity])
    }

    // MARK: - E. Superseded renders never persist

    /// A burst of presses in one main-actor turn. Nothing can be delivered
    /// between them — delivery needs a hop back to this actor — so every
    /// render but the last is superseded by construction, and the assertion is
    /// deterministic rather than a race.
    @Test("A burst of changes persists the settled state and nothing else")
    func aBurstPersistsOnlyTheSettledState() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)

        state.rotateOrientationRight()
        state.rotateOrientationRight()
        state.flipOrientationHorizontally()
        state.rotateOrientationRight()

        let settled = state.orientationAdjustment
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: settled))
        // Let any superseded render finish unwinding and try to deliver.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(log.savedOrientations == [settled])
        #expect(store.saved(for: Self.url)?.orientation == settled)
        // Intermediate states were requested and are nowhere on disk.
        #expect(!log.savedOrientations.contains(.quarterTurnRight))
        #expect(!log.savedOrientations.contains(.halfTurn))
    }

    // MARK: - F. A failed re-render persists nothing

    @Test("A failed re-render leaves the last saved adjustment in place")
    func aFailedRenderLeavesTheSavedState() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store, log: log, refusing: [.halfTurn])
        state.open(Self.url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)

        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )
        #expect(store.saved(for: Self.url)?.orientation == .quarterTurnRight)

        state.rotateOrientationRight()
        try await Self.waitForOwnedFailure(state)

        // The state that could not be rendered was not written. Restoring it
        // on the next launch would restore a broken workspace.
        #expect(store.saved(for: Self.url)?.orientation == .quarterTurnRight)
        #expect(log.savedOrientations == [.quarterTurnRight])
        // The user's intent is still recorded in memory; only the durable copy
        // lags, and it lags on the last state that actually worked.
        #expect(state.orientationAdjustment == .halfTurn)
        #expect(state.canAdjust)
    }

    // MARK: - Render succeeded, save failed

    @Test("A save failure keeps the image and reports itself")
    func aSaveFailureKeepsTheImage() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        store.refuseSaves(
            with: .cannotWrite(
                sidecar: URL(fileURLWithPath: "/tmp/persistence-example.orf.iradjustments.json"),
                underlying: CocoaError(.fileWriteNoPermission)
            )
        )
        let state = Self.state(store: store, log: log)
        state.open(Self.url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)

        state.rotateOrientationRight()
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        // The render succeeded and the image stands. Rolling it back would be
        // a lie about what was rendered.
        #expect(preview.effectiveOrientation == .rotated90Clockwise)
        #expect(state.orientationAdjustment == .quarterTurnRight)

        // And the failure is reported rather than swallowed: the user's
        // decision is not durable yet, and nothing pretends otherwise.
        let failure = try #require(state.adjustmentSaveFailure)
        guard case .cannotWrite = failure else {
            Issue.record("Expected .cannotWrite, got \(failure)")
            return
        }
        #expect(failure.errorDescription?.isEmpty == false)
        #expect(store.saved(for: Self.url) == nil)
        #expect(log.savedOrientations.isEmpty)
    }

    // MARK: - G. An unreadable sidecar

    @Test("An unreadable sidecar stops the open instead of rendering identity")
    func anUnreadableSidecarStopsTheOpen() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let sidecar = JSONSidecarImageAdjustmentStore.sidecarURL(for: Self.url)
        store.refuseLoad(
            for: Self.url,
            with: .cannotDecode(
                sidecar: sidecar,
                underlying: ImageAdjustmentError.unsupportedSchemaVersion(found: 2, supported: 1)
            )
        )
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        guard case .adjustmentsUnreadable(let failedURL, let error) = state.status else {
            Issue.record("Expected .adjustmentsUnreadable, got \(state.status)")
            return
        }
        #expect(failedURL == Self.url)
        #expect(error.url == Self.url)
        #expect(error.sidecar == sidecar)
        // The typed refusal survived the file boundary and the document
        // boundary both.
        #expect(error.adjustment == .unsupportedSchemaVersion(found: 2, supported: 1))
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.failureReason?.isEmpty == false)

        // No identity image was rendered, and the expensive decode never ran:
        // the refusal happens before any of it.
        #expect(log.all == [.adjustmentLoadRefused])
        #expect(log.renderedOrientations.isEmpty)
        #expect(log.decodeCount == 0)
        // Nothing was repaired, reset or written over.
        #expect(log.savedOrientations.isEmpty)
        #expect(store.saved(for: Self.url) == nil)
        // And the controls offer nothing, because nothing is open.
        #expect(!state.canAdjust)
        #expect(state.selectedFileURL == Self.url)
    }

    // MARK: - H. Adjustments belong to their own file

    @Test("Switching files does not carry one file's adjustments to another")
    func adjustmentsDoNotCrossFiles() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        store.preload(ImageAdjustments(orientation: .quarterTurnRight), for: Self.url)
        let state = Self.state(store: store, log: log)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)
        #expect(try Self.preview(state).userOrientationAdjustment == .quarterTurnRight)

        state.open(Self.otherURL)
        try await Self.waitUntilSettled(state)
        let second = try Self.preview(state)
        #expect(second.userOrientationAdjustment == .identity)
        #expect(state.orientationAdjustment == .identity)

        state.flipOrientationVertically()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .verticalFlip))

        // Each record stayed with its own photograph: the second file's flip
        // was written to the second file's record, and the first file's
        // rotation is exactly as it was loaded.
        #expect(store.saved(for: Self.otherURL)?.orientation == .verticalFlip)
        #expect(store.saved(for: Self.url)?.orientation == .quarterTurnRight)
        #expect(log.savedOrientations == [.verticalFlip])
    }

    // MARK: - End to end, through the real sidecar file

    /// The whole milestone in one test, with the production store: a rotation
    /// survives the document being closed and reopened, the sidecar is where
    /// the rule says it is, and the RAW file is byte-identical afterwards.
    @Test("A rotation survives a reopen, and the RAW file is untouched")
    func aRotationSurvivesAReopen() async throws {
        let sandbox = try JSONSidecarImageAdjustmentStoreTests.Sandbox(rawName: "E-PL3.ORF")
        defer { sandbox.cleanUp() }
        let before = try Data(contentsOf: sandbox.raw)

        let first = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: sandbox.raw)),
                mosaic: .success(WorkspaceStubs.mosaic(url: sandbox.raw))
            ),
            store: JSONSidecarImageAdjustmentStore()
        )
        first.open(sandbox.raw)
        _ = try await WorkspaceStubs.waitForPreview(first, adjustment: .identity)
        first.rotateOrientationRight()
        let rotated = try #require(
            await WorkspaceStubs.waitForPreview(first, adjustment: .quarterTurnRight)
        )

        // The sidecar is beside the RAW file, named by the rule, and readable.
        #expect(FileManager.default.fileExists(atPath: sandbox.sidecar.path))
        #expect(sandbox.sidecar.lastPathComponent == "E-PL3.ORF.iradjustments.json")
        let text = try sandbox.sidecarText()
        #expect(text.contains("rotate90Clockwise"))
        #expect(text.contains("\"schemaVersion\""))

        // A second, independent workspace opens the same file and starts where
        // the first left off.
        let second = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: sandbox.raw)),
                mosaic: .success(WorkspaceStubs.mosaic(url: sandbox.raw))
            ),
            store: JSONSidecarImageAdjustmentStore()
        )
        second.open(sandbox.raw)
        try await Self.waitUntilSettled(second)

        let reopened = try Self.preview(second)
        #expect(reopened.userOrientationAdjustment == .quarterTurnRight)
        #expect(reopened.effectiveOrientation == .rotated90Clockwise)
        #expect(
            WorkspaceStubs.pixelBytes(reopened.image) == WorkspaceStubs.pixelBytes(rotated.image)
        )

        // The RAW file itself: not written, not appended to, not re-tagged.
        #expect(try Data(contentsOf: sandbox.raw) == before)
        #expect(sandbox.rawIsUnchanged)
    }
}
