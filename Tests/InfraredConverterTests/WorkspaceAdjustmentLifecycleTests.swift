import Testing
import Foundation
@testable import InfraredConverter

/// The interval between a user pressing a button and their decision being on
/// disk, and what happens if they leave the photograph while it is still open.
///
/// Two claims are under test, and both used to be false:
///
/// ```text
/// the workspace never says "saved" about a state that is not saved
/// leaving a file mid-render does not silently discard the edit
/// ```
///
/// Serialised, because these tests hold a real render at a gate, and a held
/// render occupies a cooperative-pool thread. Several at once can starve the
/// pool and deadlock the run.
@Suite("Workspace adjustment lifecycle", .serialized)
@MainActor
struct WorkspaceAdjustmentLifecycleTests {

    nonisolated static let urlA = URL(fileURLWithPath: "/tmp/lifecycle-a.orf")
    nonisolated static let urlB = URL(fileURLWithPath: "/tmp/lifecycle-b.orf")

    /// A is 8 × 6 and B is 10 × 4, so a preview from the wrong file is visible
    /// in its dimensions rather than only in a label.
    static func decoder(log: WorkspaceEventLog) -> MultiFileStubDecoder {
        MultiFileStubDecoder(
            mosaics: [
                urlA: WorkspaceStubs.mosaic(url: urlA, width: 8, height: 6),
                urlB: WorkspaceStubs.mosaic(url: urlB, width: 10, height: 4)
            ],
            log: log
        )
    }

    static func state(
        store: StubImageAdjustmentStore,
        log: WorkspaceEventLog,
        gate: GatedRender
    ) -> DocumentState {
        DocumentState(decoder: decoder(log: log), store: store, render: gate.render)
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

    /// Waits for a condition the test is expecting, and fails rather than
    /// hangs if it never arrives.
    ///
    /// Synchronisation is the gate; this only bridges the main-actor hop a
    /// delivery makes on its way back.
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

    // MARK: - The state of a decision on its way to disk

    /// The bug this milestone starts from: a requested state that has not been
    /// written, while the workspace still reported the *previous* state's save.
    @Test("A requested adjustment is not reported as saved while its render runs")
    func aPendingAdjustmentIsNotReportedAsSaved() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.halfTurn])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)

        // A first decision that does reach disk.
        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )
        #expect(state.adjustmentPersistence.isDurable)
        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnRight)

        // A second one, held at the gate: genuinely in flight.
        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()

        #expect(state.orientationAdjustment == .halfTurn)
        guard case .pending = state.adjustmentPersistence else {
            Issue.record("Expected .pending, got \(state.adjustmentPersistence)")
            return
        }
        // The claim that used to be wrong: the state on screen is not saved,
        // even though a *different* state was saved a moment ago.
        #expect(!state.adjustmentPersistence.isDurable)
        #expect(state.adjustmentSaveFailure == nil)
        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnRight)
        #expect(state.hasPendingAdjustmentWork)

        gate.releaseOneRender()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .halfTurn))

        guard case .saved = state.adjustmentPersistence else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
            return
        }
        #expect(store.saved(for: Self.urlA)?.orientation == .halfTurn)
        #expect(!state.hasPendingAdjustmentWork)
    }

    @Test("A refused render leaves the state not-saved, and says which kind")
    func aRefusedRenderIsNotSaved() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, refusing: [.halfTurn])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        state.rotateOrientationRight()
        try await Self.waitUntil("the render refuses") {
            if case .decoded(let loaded) = state.status, case .unavailable = loaded.owned {
                return true
            }
            return false
        }

        guard case .renderRefused = state.adjustmentPersistence else {
            Issue.record("Expected .renderRefused, got \(state.adjustmentPersistence)")
            return
        }
        #expect(!state.adjustmentPersistence.isDurable)
        // The intent stands, the disk holds the last state that rendered, and
        // nothing is pending: no render is coming to rescue this one.
        #expect(state.orientationAdjustment == .halfTurn)
        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnRight)
        #expect(!state.hasPendingAdjustmentWork)
        #expect(store.writeSummary == ["lifecycle-a.orf:rotate90Clockwise:identity"])
    }

    @Test("A rendered adjustment whose write refuses is explicitly not saved")
    func aRefusedWriteIsExplicit() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log)
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        store.refuseSaves(
            with: .cannotWrite(
                sidecar: JSONSidecarImageAdjustmentStore.sidecarURL(for: Self.urlA),
                underlying: CocoaError(.fileWriteNoPermission)
            )
        )
        state.rotateOrientationRight()
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .halfTurn)
        )

        // The image is the new one and stays.
        #expect(preview.effectiveOrientation == .rotated180)
        #expect(state.orientationAdjustment == .halfTurn)
        // And the record on disk is still the older state, explicitly.
        guard case .saveFailed = state.adjustmentPersistence else {
            Issue.record("Expected .saveFailed, got \(state.adjustmentPersistence)")
            return
        }
        #expect(state.adjustmentSaveFailure != nil)
        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnRight)
    }

    // MARK: - Leaving a file while its render is still running

    @Test("An adjustment left mid-render is still saved, to its own sidecar")
    func aPendingAdjustmentSurvivesAFileSwitch() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.quarterTurnRight])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)

        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()
        #expect(store.saved(for: Self.urlA) == nil)

        // The user moves on while that render is still in flight.
        state.open(Self.urlB)
        let second = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))
        #expect(state.selectedFileURL == Self.urlB)
        #expect(second.pixelWidth == 10)
        #expect(second.pixelHeight == 4)
        #expect(state.hasPendingAdjustmentWork)

        // A's render finishes with nowhere to be shown, and does the one thing
        // it may still do.
        gate.releaseOneRender()
        try await Self.waitUntil("A's adjustment reaches its sidecar") {
            store.saved(for: Self.urlA) != nil
        }

        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnRight)
        // Written under A's own URL, and nowhere else.
        #expect(store.writeSummary == ["lifecycle-a.orf:rotate90Clockwise:identity"])
        #expect(store.saved(for: Self.urlB) == nil)
        // Nothing was lost, so nothing is reported as lost.
        #expect(state.unsavedAdjustments.isEmpty)
        #expect(!state.hasPendingAdjustmentWork)

        // B is untouched by any of it: same file, same geometry, no rotation.
        let after = try Self.preview(state)
        #expect(after.userOrientationAdjustment == .identity)
        #expect(after.pixelWidth == 10)
        #expect(after.pixelHeight == 4)
        #expect(WorkspaceStubs.pixelBytes(after.image) == WorkspaceStubs.pixelBytes(second.image))
        #expect(state.orientationAdjustment == .identity)
    }

    @Test("A stale render from the previous file never installs into the new one")
    func aStaleRenderNeverInstalls() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.halfTurn])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationHalfTurn()
        try await gate.waitForGatedRenderToStart()

        state.open(Self.urlB)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))
        gate.releaseOneRender()
        try await Self.waitUntil("A settles") { !state.hasPendingAdjustmentWork }

        // The only rendered states are A's half turn and B's identity, and the
        // one on screen is B's: 10 × 4, unrotated.
        let shown = try Self.preview(state)
        #expect(shown.pixelWidth == 10)
        #expect(shown.pixelHeight == 4)
        #expect(shown.userOrientationAdjustment == .identity)
        #expect(shown.effectiveOrientation == .upright)
        #expect(state.orientationAdjustment == .identity)
        // A half-turned 8 × 6 preview would be 8 × 6, and there is none.
        #expect(log.renderedOrientations.contains(.halfTurn))
    }

    // MARK: - Reopening the same file

    /// The same file, opened twice, with the first open's render still running.
    ///
    /// Two generations of one RAW file share one sidecar, so the second open
    /// waits for the first to finish writing before it reads anything. The
    /// order below is asserted as an order, because that is the claim:
    ///
    /// ```text
    /// G1 render → G1 save → G2 load → G2 decode → G2 first render
    /// ```
    ///
    /// The second generation's **first** render therefore already carries the
    /// state the first one saved. There is no identity render on the way to it,
    /// and no moment at which the screen and the sidecar disagree.
    @Test("A reopen waits for the older generation's write, then starts from it")
    func aReopenWaitsForTheOlderGenerationsWrite() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.quarterTurnRight])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()

        // The reopen is requested while that render is still at the gate.
        state.open(Self.urlA)
        #expect(state.selectedFileURL == Self.urlA)
        // Nothing of the second open has happened yet: it has not read the
        // sidecar, and it has not decoded.
        #expect(log.all == [
            .loadedAdjustments(nil), .decodedMosaic, .rendered(.none)
        ])

        gate.releaseOneRender()
        try await Self.waitUntil("the first generation's write lands") {
            store.saved(for: Self.urlA) != nil
        }
        // The first generation wrote, and installed no preview: the second
        // open is still decoding, and its own first render is at the gate.
        guard case .decoding = state.status else {
            Issue.record("Expected the reopen to still be decoding, got \(state.status)")
            return
        }

        try await gate.waitForGatedRenderToStart()
        gate.releaseOneRender()
        let reopened = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        // The order, as an order.
        #expect(log.all == [
            .loadedAdjustments(nil),
            .decodedMosaic,
            .rendered(.none),
            .rendered(ImageAdjustments(orientation: .quarterTurnRight)),
            .saved(ImageAdjustments(orientation: .quarterTurnRight)),
            .loadedAdjustments(ImageAdjustments(orientation: .quarterTurnRight)),
            .decodedMosaic,
            .rendered(ImageAdjustments(orientation: .quarterTurnRight))
        ])

        // The second generation rendered once, and that render is the saved
        // state. An identity first render would be visible here.
        #expect(reopened.userOrientationAdjustment == .quarterTurnRight)
        #expect(reopened.effectiveOrientation == .rotated90Clockwise)
        #expect(state.orientationAdjustment == .quarterTurnRight)
        #expect(state.unsavedAdjustments.isEmpty)
        #expect(!state.hasPendingAdjustmentWork)
    }

    /// `.unchanged` says "what is on screen is what a reopen would restore".
    /// After a same-URL reopen that waited, that has to be literally true.
    @Test("A freshly reopened file reports unchanged, and it is the disk state")
    func aReopenedFileReportsTheDiskState() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.halfTurn])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationHalfTurn()
        try await gate.waitForGatedRenderToStart()

        state.open(Self.urlA)
        gate.releaseOneRender()
        try await gate.waitForGatedRenderToStart()
        gate.releaseOneRender()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .halfTurn))

        guard case .unchanged = state.adjustmentPersistence else {
            Issue.record("Expected .unchanged, got \(state.adjustmentPersistence)")
            return
        }
        #expect(state.adjustmentPersistence.isDurable)
        // The claim, checked against the store rather than against itself.
        #expect(store.saved(for: Self.urlA)?.orientation == state.orientationAdjustment)
        #expect(store.writeSummary == ["lifecycle-a.orf:rotate180:identity"])
    }

    /// The write-write race this follow-up exists for.
    ///
    /// An older generation of a file must never land on top of a newer
    /// generation's save. Serialising same-URL opens removes the race
    /// structurally: the older generation has already written and been released
    /// before the newer one reads, so there is no moment at which both are
    /// live.
    @Test("An older generation cannot overwrite a newer generation's save")
    func anOlderGenerationCannotOverwriteANewerSave() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.quarterTurnRight])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)

        // Generation 1 asks for a quarter turn and is held mid-render.
        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()

        // Generation 2 is requested, waits, and then starts from what
        // generation 1 wrote.
        state.open(Self.urlA)
        gate.releaseOneRender()
        try await gate.waitForGatedRenderToStart()
        gate.releaseOneRender()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight))
        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnRight)

        // Generation 2's own decision, made and saved after generation 1's.
        state.rotateOrientationHalfTurn()
        let newest = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnLeft)
        )

        guard case .saved = state.adjustmentPersistence else {
            Issue.record("Expected .saved, got \(state.adjustmentPersistence)")
            return
        }
        // Disk, screen and reported state agree, and the older generation's
        // write is behind the newer one rather than on top of it.
        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnLeft)
        #expect(newest.userOrientationAdjustment == .quarterTurnLeft)
        #expect(state.orientationAdjustment == .quarterTurnLeft)
        #expect(store.writeSummary == [
            "lifecycle-a.orf:rotate90Clockwise:identity", "lifecycle-a.orf:rotate270Clockwise:identity"
        ])

        // Nothing older is still moving, so nothing can change the file back —
        // and nothing does.
        #expect(!state.hasPendingAdjustmentWork)
        let settled = store.writeSummary
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.writeSummary == settled)
        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnLeft)
        #expect(state.unsavedAdjustments.isEmpty)
    }

    /// A waiting reopen is not a queue. A newer open replaces it, and the one
    /// it replaced never installs anything.
    @Test("A newer open supersedes a waiting reopen of the same file")
    func aNewerOpenSupersedesAWaitingReopen() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.quarterTurnRight])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()

        // Two reopens of A, both waiting, and then a different file entirely.
        state.open(Self.urlA)
        state.open(Self.urlA)
        state.open(Self.urlB)

        // B does not wait for A: it has its own sidecar and races with nothing.
        let shown = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))
        #expect(shown.pixelWidth == 10)
        #expect(shown.pixelHeight == 4)

        gate.releaseOneRender()
        try await Self.waitUntil("A settles") { !state.hasPendingAdjustmentWork }
        try await Task.sleep(nanoseconds: 50_000_000)

        // A's decision still reached A's sidecar, and neither abandoned reopen
        // of A ever decoded or installed anything: A was decoded once, for the
        // very first open, and B once.
        #expect(store.saved(for: Self.urlA)?.orientation == .quarterTurnRight)
        #expect(store.writeSummary == ["lifecycle-a.orf:rotate90Clockwise:identity"])
        #expect(log.decodeCount == 2)
        #expect(state.selectedFileURL == Self.urlB)
        #expect(try Self.preview(state).pixelWidth == 10)
        #expect(state.unsavedAdjustments.isEmpty)
    }

    /// Two reopens of a settling file collapse to one, and it is the newest.
    @Test("Repeated reopens of a settling file start exactly one decode")
    func repeatedReopensStartOneDecode() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.quarterTurnRight])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()

        state.open(Self.urlA)
        state.open(Self.urlA)
        state.open(Self.urlA)

        gate.releaseOneRender()
        try await gate.waitForGatedRenderToStart()
        gate.releaseOneRender()
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight))
        try await Task.sleep(nanoseconds: 50_000_000)

        // One decode for the first open, one for the surviving reopen.
        #expect(log.decodeCount == 2)
        #expect(log.renderedOrientations == [.identity, .quarterTurnRight, .quarterTurnRight])
        #expect(store.writeSummary == ["lifecycle-a.orf:rotate90Clockwise:identity"])
        #expect(!state.hasPendingAdjustmentWork)
    }

    /// A settling render that refuses still frees its file. The reopen it was
    /// blocking starts, and the decision it lost is still reported.
    @Test("A reopen waiting on a refusing render still opens, and keeps the report")
    func aReopenWaitingOnARefusingRenderStillOpens() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(
            log: log, holding: [.quarterTurnRight], refusing: [.quarterTurnRight]
        )
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()

        state.open(Self.urlA)
        gate.releaseOneRender()
        let reopened = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        )

        // The reopen was not blocked forever by a render that never succeeded.
        #expect(reopened.userOrientationAdjustment == .identity)
        #expect(!state.hasPendingAdjustmentWork)
        // Nothing was written, and the decision that could not be written is
        // still reported after the reopen rather than cleared by it.
        #expect(store.writeSummary.isEmpty)
        let unsaved = try #require(state.unsavedAdjustments.last)
        #expect(unsaved.url == Self.urlA)
        #expect(unsaved.adjustments.orientation == .quarterTurnRight)
        guard case .renderRefused = unsaved.reason else {
            Issue.record("Expected .renderRefused, got \(unsaved.reason)")
            return
        }
    }

    @Test("A left-behind adjustment whose render refuses is reported, not dropped")
    func aRefusedRenderAfterASwitchIsReported() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.quarterTurnRight], refusing: [.quarterTurnRight])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()

        state.open(Self.urlB)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))
        gate.releaseOneRender()
        try await Self.waitUntil("the decision is reported") {
            !state.unsavedAdjustments.isEmpty
        }

        let unsaved = try #require(state.unsavedAdjustments.last)
        #expect(unsaved.url == Self.urlA)
        #expect(unsaved.adjustments.orientation == .quarterTurnRight)
        guard case .renderRefused = unsaved.reason else {
            Issue.record("Expected .renderRefused, got \(unsaved.reason)")
            return
        }
        // An unrenderable state is still never written — to A or to anyone.
        #expect(store.writeSummary.isEmpty)
        #expect(store.saved(for: Self.urlA) == nil)
        #expect(store.saved(for: Self.urlB) == nil)
        #expect(!state.hasPendingAdjustmentWork)
    }

    @Test("Leaving a file after a failed save carries the failure with it")
    func aFailedSaveSurvivesTheSwitch() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log)
        let state = Self.state(store: store, log: log, gate: gate)
        store.refuseSaves(
            with: .cannotWrite(
                sidecar: JSONSidecarImageAdjustmentStore.sidecarURL(for: Self.urlA),
                underlying: CocoaError(.fileWriteNoPermission)
            )
        )

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )
        #expect(state.adjustmentSaveFailure != nil)

        state.open(Self.urlB)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))

        // The new document has nothing of its own to report...
        #expect(state.adjustmentSaveFailure == nil)
        guard case .unchanged = state.adjustmentPersistence else {
            Issue.record("Expected .unchanged, got \(state.adjustmentPersistence)")
            return
        }
        // ...and A's failure did not vanish with A.
        let unsaved = try #require(state.unsavedAdjustments.last)
        #expect(unsaved.url == Self.urlA)
        #expect(unsaved.adjustments.orientation == .quarterTurnRight)
        guard case .saveRefused = unsaved.reason else {
            Issue.record("Expected .saveRefused, got \(unsaved.reason)")
            return
        }
        #expect(store.writeSummary.isEmpty)
        #expect(!state.hasPendingAdjustmentWork)
    }

    @Test("Leaving a file with nothing at stake records nothing")
    func aCleanSwitchRecordsNothing() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log)
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)
        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        state.open(Self.urlB)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))

        #expect(state.unsavedAdjustments.isEmpty)
        #expect(!state.hasPendingAdjustmentWork)
        #expect(store.writeSummary == ["lifecycle-a.orf:rotate90Clockwise:identity"])
    }

    // MARK: - The old guarantees still hold

    @Test("A burst that ends during a file switch still persists one state only")
    func aBurstAcrossASwitchPersistsOnce() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let gate = GatedRender(log: log, holding: [.quarterTurnRight])
        let state = Self.state(store: store, log: log, gate: gate)

        state.open(Self.urlA)
        try await Self.waitUntilSettled(state)

        // The first press is held at the gate; the rest supersede it while it
        // waits there, so the settled state is the composition of all four.
        state.rotateOrientationRight()
        try await gate.waitForGatedRenderToStart()
        state.rotateOrientationRight()
        state.flipOrientationHorizontally()
        state.rotateOrientationRight()
        let settled = state.orientationAdjustment
        #expect(settled != .quarterTurnRight)

        state.open(Self.urlB)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))
        gate.releaseOneRender()
        try await Self.waitUntil("A settles") { !state.hasPendingAdjustmentWork }

        // Exactly one write, of the state the user actually ended on. The held
        // render's own state was superseded and is nowhere on disk.
        #expect(store.writeSummary == ["lifecycle-a.orf:\(settled.persistedToken):identity"])
        #expect(store.saved(for: Self.urlA)?.orientation == settled)
        #expect(store.saved(for: Self.urlB) == nil)
        #expect(state.unsavedAdjustments.isEmpty)
    }
}
