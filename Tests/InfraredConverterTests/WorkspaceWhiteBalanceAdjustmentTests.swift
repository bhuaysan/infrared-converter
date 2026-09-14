import Testing
import Foundation
@testable import InfraredConverter

/// The white balance as a canonical user decision: what it reruns, what it
/// deliberately does not, and which state wins when two of them are in flight.
///
/// The assertions here are about **work performed and state installed**, not
/// about the final image. An architecture that re-decoded the RAW file on
/// every pick would produce exactly the same pictures and fail the first test
/// in this suite.
///
/// Serialised, because several tests hold a real preparation or render at a
/// gate, and a held pass occupies a cooperative-pool thread. See `GatedRender`.
@Suite("Workspace white-balance adjustment", .serialized)
@MainActor
struct WorkspaceWhiteBalanceAdjustmentTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/white-balance.orf")
    nonisolated static let other = URL(fileURLWithPath: "/tmp/white-balance-other.orf")

    /// Two patches that measure genuinely different parts of the frame, so a
    /// preview prepared for the wrong one is distinguishable in its pixels and
    /// not only in a label.
    static func patchA() throws -> UserWhiteBalanceAdjustment {
        .neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0, originY: 0, width: 0.5, height: 0.5
            )
        )
    }

    static func patchB() throws -> UserWhiteBalanceAdjustment {
        .neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.5, originY: 0.5, width: 0.5, height: 0.5
            )
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
        _ description: String, _ condition: () -> Bool
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

    // MARK: - The performance claim, as a counted fact

    /// The central architectural test of this milestone. The RAW file is read
    /// **once**, and every subsequent patch is estimated, balanced, demosaiced,
    /// converted and reduced from the retained normalised mosaic.
    ///
    /// A counting decoder is the only way to state that: the pictures are
    /// identical either way.
    @Test("Changing the neutral patch never decodes the RAW file again")
    func pickingAPatchDoesNotRedecode() async throws {
        let patchA = try Self.patchA()
        let patchB = try Self.patchB()
        let log = WorkspaceEventLog()
        let counting = CountingStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: Self.url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
        )
        let document = DocumentState(
            decoder: counting,
            store: StubPhotographProcessingStore(log: log),
            render: RecordingRender(log: log).render,
            prepareSource: RecordingPreparation(log: log).prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        #expect(counting.mosaicDecodeCount == 1)

        for patch in [patchA, patchB] {
            document.setWhiteBalance(patch)
            _ = try #require(
                await WorkspaceStubs.waitForPreview(
                    document, adjustments: ImageAdjustments(whiteBalance: patch)
                )
            )
        }
        document.resetWhiteBalance()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(document, adjustments: .none)
        )

        // One decode, for the open. Nothing below the retained mosaic ran
        // again: no `decodeMosaic`, and therefore no normalisation either,
        // because normalisation is reachable only through it.
        #expect(counting.mosaicDecodeCount == 1)

        // And the heavy half above the mosaic ran exactly as often as it had
        // to: once for the open and once per decision.
        #expect(
            log.preparations == [
                .defaultNeutralPatch, patchA, patchB,
                .defaultNeutralPatch,
            ]
        )
    }

    /// The other half of the same claim: the three *fast* adjustments never
    /// reach the heavy half at all.
    @Test("Rotating, mixing and exposing never re-prepare the source")
    func fastAdjustmentsDoNotReprepare() async throws {
        let patchA = try Self.patchA()
        let log = WorkspaceEventLog()
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: StubPhotographProcessingStore(log: log),
            render: RecordingRender(log: log).render,
            prepareSource: RecordingPreparation(log: log).prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        // A patch first, so the source being re-rendered from is one the heavy
        // half produced rather than the opening one.
        document.setWhiteBalance(patchA)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchA)
            )
        )
        let preparationsAfterPick = log.preparations.count

        document.rotateOrientationRight()
        document.setChannelMix(.redBlueSwap)
        document.setExposure(try UserExposureAdjustment(ev: 1.5))

        let expected = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1.5),
            whiteBalance: patchA
        )
        _ = try #require(
            await WorkspaceStubs.waitForPreview(document, adjustments: expected)
        )

        // Not one more preparation: the patch did not change, so no estimate,
        // no demosaic and no reduction ran.
        #expect(log.preparations.count == preparationsAfterPick)
        // And the reduced source those renders read is still the one patch A
        // produced.
        #expect(try Self.preview(document).whiteBalanceAdjustment == patchA)
    }

    // MARK: - Different patches really do produce different balances

    /// Without this the rest of the suite would be scheduling theatre: the
    /// patch has to reach the estimator and change the gains.
    @Test("Two patches over different samples produce different gains")
    func differentPatchesProduceDifferentGains() async throws {
        let patchA = try Self.patchA()
        let patchB = try Self.patchB()
        let document = WorkspaceStubs.documentState(url: Self.url, width: 16, height: 12)

        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        let defaultGains = try Self.preview(document).whiteBalanceGains

        document.setWhiteBalance(patchA)
        let a = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchA)
            )
        )

        document.setWhiteBalance(patchB)
        let b = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchB)
            )
        )

        #expect(a.whiteBalanceGains != b.whiteBalanceGains)
        #expect(a.whiteBalanceGains != defaultGains || b.whiteBalanceGains != defaultGains)
        // Every gain is finite and usable, whichever patch produced it.
        for gains in [defaultGains, a.whiteBalanceGains, b.whiteBalanceGains] {
            try gains.validate()
        }

        // The measured regions differ too, and each is the one the adjustment
        // names — resolved against the sensor's own active area.
        #expect(a.neutralPatch != b.neutralPatch)
        let resolvedA = try patchA.resolvedRegion(
            activeAreaWidth: 16, activeAreaHeight: 12
        )
        #expect(a.neutralPatch == resolvedA)
    }

    /// Gains never compound. Picking B after A measures B against the
    /// **normalised** mosaic, not against a mosaic A already scaled.
    @Test("A second patch is measured from the unbalanced mosaic, not the first result")
    func patchesDoNotCompound() async throws {
        let patchA = try Self.patchA()
        let patchB = try Self.patchB()
        let document = WorkspaceStubs.documentState(url: Self.url, width: 16, height: 12)
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        document.setWhiteBalance(patchA)
        let firstA = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchA)
            )
        )

        document.setWhiteBalance(patchB)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchB)
            )
        )

        // Back to A. If the mosaic carried B's gains, A's second estimate
        // would differ from its first.
        document.setWhiteBalance(patchA)
        let secondA = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchA)
            )
        )

        #expect(secondA.whiteBalanceGains == firstA.whiteBalanceGains)
        #expect(
            WorkspaceStubs.pixelBytes(secondA.image)
                == WorkspaceStubs.pixelBytes(firstA.image)
        )
    }

    // MARK: - The decision is canonical state

    @Test("A picked patch becomes part of the complete adjustment record")
    func aPickedPatchIsCanonicalState() async throws {
        let patchA = try Self.patchA()
        let store = StubPhotographProcessingStore()
        let document = WorkspaceStubs.documentState(
            url: Self.url, width: 16, height: 12, store: store
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        #expect(document.whiteBalanceAdjustment == .defaultNeutralPatch)

        document.setWhiteBalance(patchA)
        // The control shows the request at once, before anything has rendered.
        #expect(document.whiteBalanceAdjustment == patchA)

        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchA)
            )
        )
        #expect(store.saved(for: Self.url)?.whiteBalance == patchA)
        #expect(document.adjustmentPersistence.isDurable)
        #expect(document.exportRequest?.adjustments.whiteBalance == patchA)
    }

    @Test("Asking for the white balance already in force does nothing at all")
    func anIdenticalRequestDoesNothing() async throws {
        let log = WorkspaceEventLog()
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: StubPhotographProcessingStore(log: log),
            render: RecordingRender(log: log).render,
            prepareSource: RecordingPreparation(log: log).prepare
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let preparations = log.preparations.count
        let renders = log.renders.count
        document.setWhiteBalance(.defaultNeutralPatch)
        document.resetWhiteBalance()

        #expect(log.preparations.count == preparations)
        #expect(log.renders.count == renders)
        #expect(document.adjustmentPersistence.isDurable)
    }

    /// Reset returns to the historical centred patch and touches nothing else.
    @Test("Reset restores the default patch and leaves the other three alone")
    func resetLeavesTheOtherAdjustmentsAlone() async throws {
        let patchB = try Self.patchB()
        let document = WorkspaceStubs.documentState(url: Self.url, width: 16, height: 12)
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        document.rotateOrientationRight()
        document.setChannelMix(.redBlueSwap)
        document.setExposure(try UserExposureAdjustment(ev: -1))
        document.setWhiteBalance(patchB)

        let picked = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: -1),
            whiteBalance: patchB
        )
        _ = try #require(
            await WorkspaceStubs.waitForPreview(document, adjustments: picked)
        )

        document.resetWhiteBalance()
        var expected = picked
        expected.whiteBalance = .defaultNeutralPatch
        let after = try #require(
            await WorkspaceStubs.waitForPreview(document, adjustments: expected)
        )
        #expect(after.userOrientationAdjustment == .quarterTurnRight)
        #expect(after.channelMixAdjustment == .redBlueSwap)
        #expect(after.renderedExposureEV == -1)
        #expect(after.whiteBalanceAdjustment == .defaultNeutralPatch)
    }

    // MARK: - Picking through the geometry seam

    @Test("A click in active-area coordinates becomes a canonical patch")
    func pickingAPointBecomesAPatch() async throws {
        let document = WorkspaceStubs.documentState(url: Self.url, width: 16, height: 12)
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        document.pickNeutralPatch(atX: 0.25, y: 0.75)
        let expected = UserWhiteBalanceAdjustment.neutralPatch(
            try UserWhiteBalanceAdjustment.pickedRegion(
                atX: 0.25, y: 0.75, activeAreaWidth: 16, activeAreaHeight: 12
            )
        )
        #expect(document.whiteBalanceAdjustment == expected)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: expected)
            )
        )
    }

    @Test("A pick that cannot make a region changes nothing")
    func anImpossiblePickChangesNothing() async throws {
        let document = WorkspaceStubs.documentState(url: Self.url, width: 16, height: 12)
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        document.pickNeutralPatch(atX: .nan, y: 0.5)
        #expect(document.whiteBalanceAdjustment == .defaultNeutralPatch)
        #expect(document.adjustmentPersistence.isDurable)
    }

    @Test("The active area a pick is a fraction of is the sensor's, not the preview's")
    func theActiveAreaIsTheSensorsOwn() async throws {
        let document = WorkspaceStubs.documentState(
            url: Self.url, width: 16, height: 12,
            previewPolicy: PreviewResolutionPolicy(maximumLongestEdge: 4)
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let size = try #require(document.activeAreaSize)
        #expect(size.width == 16)
        #expect(size.height == 12)
        // The preview really is smaller, so the two could have been confused.
        #expect(try Self.preview(document).sourcePixelWidth == 4)
    }

    // MARK: - Coalescing

    /// A burst of picks collapses to the newest one. The ones in between are
    /// never estimated at all — not estimated and discarded, not estimated.
    @Test("A burst of picks prepares the first and the last, never the middle")
    func aBurstOfPicksCoalesces() async throws {
        let patchA = try Self.patchA()
        let patchB = try Self.patchB()
        let log = WorkspaceEventLog()
        let gate = GatedPreparation(log: log, holdingPicks: true)
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: StubPhotographProcessingStore(log: log),
            render: RecordingRender(log: log).render,
            prepareSource: gate.prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        #expect(log.preparations == [.defaultNeutralPatch])

        // A starts and is held at the gate.
        let a = patchA
        document.setWhiteBalance(a)
        try await gate.waitForGatedPreparationToStart()

        // B and C arrive while A is held, and D after them. Only D survives.
        let b = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.1, originY: 0.1, width: 0.3, height: 0.3
            )
        )
        let c = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.2, originY: 0.2, width: 0.3, height: 0.3
            )
        )
        let d = patchB
        document.setWhiteBalance(b)
        document.setWhiteBalance(c)
        document.setWhiteBalance(d)
        #expect(document.whiteBalanceAdjustment == d)

        // Release A, which is cancelled on its way out; D then starts and is
        // held; release it too.
        gate.releaseOnePreparation()
        try await gate.waitForGatedPreparationToStart()
        gate.releaseOnePreparation()

        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: d)
            )
        )

        // B and C were never even attempted: the pending slot holds one
        // request, so each simply replaced the one before it.
        #expect(!log.preparationAttempts.contains(b))
        #expect(!log.preparationAttempts.contains(c))
        // A was attempted — it had already started — and D is the one that
        // finished and was installed.
        #expect(log.preparations.last == d)
        #expect(try Self.preview(document).whiteBalanceAdjustment == d)
    }

    /// The superseded pass installs nothing, renders nothing and saves
    /// nothing — even when it runs to completion after the newer one was
    /// requested.
    @Test("A superseded preparation never replaces the retained source")
    func aSupersededPreparationInstallsNothing() async throws {
        let patchA = try Self.patchA()
        let patchB = try Self.patchB()
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let a = patchA
        let b = patchB
        // Only A is gated, so it is the one that finishes late.
        let gate = GatedPreparation(log: log, holds: { $0 == a })
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: store,
            render: RecordingRender(log: log).render,
            prepareSource: gate.prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        document.setWhiteBalance(a)
        try await gate.waitForGatedPreparationToStart()
        document.setWhiteBalance(b)

        gate.releaseOnePreparation()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: b)
            )
        )

        // Nothing about A reached the screen or the disk.
        #expect(try Self.preview(document).whiteBalanceAdjustment == b)
        #expect(store.saved(for: Self.url)?.whiteBalance == b)
        #expect(!log.renders.contains { $0.whiteBalance == a })
        #expect(!log.saves.contains { $0.whiteBalance == a })
    }

    // MARK: - The races between the two costs

    /// The interleaving this architecture had to get right. An exposure
    /// changed while a patch is being prepared is in the **result**, not a
    /// stop behind it: the render that follows a preparation is of the latest
    /// complete state, not of a snapshot taken when the patch was picked.
    @Test("An exposure changed during a preparation is in the rendered result")
    func anExposureChangedDuringAPreparationSurvives() async throws {
        let patchA = try Self.patchA()
        let log = WorkspaceEventLog()
        let gate = GatedPreparation(log: log, holdingPicks: true)
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: StubPhotographProcessingStore(log: log),
            render: RecordingRender(log: log).render,
            prepareSource: gate.prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let patch = patchA
        document.setWhiteBalance(patch)
        try await gate.waitForGatedPreparationToStart()

        // While the heavy half is working, the user moves the exposure. No
        // render is requested for it: the retained source is still the old
        // balance, and rendering it would put the old white balance on screen
        // under the new state's name.
        let rendersBefore = log.renders.count
        document.setExposure(try UserExposureAdjustment(ev: 2))
        #expect(log.renders.count == rendersBefore)

        gate.releaseOnePreparation()

        let expected = ImageAdjustments(
            exposure: try UserExposureAdjustment(ev: 2), whiteBalance: patch
        )
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(document, adjustments: expected)
        )
        #expect(preview.renderedExposureEV == 2)
        #expect(preview.whiteBalanceAdjustment == patch)
        // And the whole state reached disk as one record.
        try await Self.waitUntil("the complete state is saved") {
            document.adjustmentPersistence.isDurable
        }
    }

    /// Two patches and an exposure, all in flight. Only the newest patch and
    /// the newest exposure may survive.
    @Test("Two preparations and an exposure change settle on the newest of each")
    func twoPreparationsAndAnExposure() async throws {
        let patchA = try Self.patchA()
        let patchB = try Self.patchB()
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let a = patchA
        let b = patchB
        let gate = GatedPreparation(log: log, holds: { !$0.isDefault })
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: store,
            render: RecordingRender(log: log).render,
            prepareSource: gate.prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        document.setWhiteBalance(a)
        try await gate.waitForGatedPreparationToStart()
        document.setWhiteBalance(b)
        document.setExposure(try UserExposureAdjustment(ev: -1.5))

        // A is released and is superseded on its way out; B then runs.
        gate.releaseOnePreparation()
        try await gate.waitForGatedPreparationToStart()
        gate.releaseOnePreparation()

        let expected = ImageAdjustments(
            exposure: try UserExposureAdjustment(ev: -1.5), whiteBalance: b
        )
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(document, adjustments: expected)
        )
        #expect(preview.whiteBalanceAdjustment == b)
        #expect(preview.renderedExposureEV == -1.5)

        try await Self.waitUntil("the complete state is saved") {
            document.adjustmentPersistence.isDurable
        }
        #expect(store.saved(for: Self.url) == expected)
        // Nothing that named A was ever rendered or written.
        #expect(!log.renders.contains { $0.whiteBalance == a })
        #expect(!log.saves.contains { $0.whiteBalance == a })
    }

    /// Going back to the white balance the retained source already describes
    /// takes the fast path and abandons the outstanding preparation.
    @Test("Returning to the prepared white balance re-renders without re-preparing")
    func returningToThePreparedBalanceIsFast() async throws {
        let patchA = try Self.patchA()
        let log = WorkspaceEventLog()
        let gate = GatedPreparation(log: log, holdingPicks: true)
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: StubPhotographProcessingStore(log: log),
            render: RecordingRender(log: log).render,
            prepareSource: gate.prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        let preparationsAfterOpen = log.preparations.count

        document.setWhiteBalance(patchA)
        try await gate.waitForGatedPreparationToStart()
        // Straight back to the default, which the retained source already is.
        document.resetWhiteBalance()
        gate.releaseOnePreparation()

        _ = try #require(
            await WorkspaceStubs.waitForPreview(document, adjustments: .none)
        )
        // Nothing new was prepared: the held pass was abandoned and the fast
        // path re-rendered the source that was already correct.
        #expect(log.preparations.count == preparationsAfterOpen)
        #expect(try Self.preview(document).whiteBalanceAdjustment == .defaultNeutralPatch)
    }

    // MARK: - Failure

    /// A preparation that refuses behaves exactly as a refused rotation does:
    /// the typed failure is reported, the requested intent stays in the
    /// controls, and the sidecar keeps the last state that rendered.
    @Test("A refused preparation is reported and does not reach the sidecar")
    func aRefusedPreparationIsReported() async throws {
        let patchA = try Self.patchA()
        let patchB = try Self.patchB()
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let bad = patchB
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: store,
            render: RecordingRender(log: log).render,
            prepareSource: RecordingPreparation(log: log, refuses: { $0 == bad }).prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        // A good patch first, so there is a durable state to keep.
        document.setWhiteBalance(patchA)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchA)
            )
        )
        #expect(store.saved(for: Self.url)?.whiteBalance == patchA)

        document.setWhiteBalance(bad)
        try await Self.waitUntil("the refusal is reported") {
            if case .renderRefused = document.adjustmentPersistence { return true }
            return false
        }

        // The intent stays where the user left it, so they can pick again.
        #expect(document.whiteBalanceAdjustment == bad)
        // The sidecar still holds the last state that actually rendered.
        #expect(store.saved(for: Self.url)?.whiteBalance == patchA)
        #expect(!log.saves.contains { $0.whiteBalance == bad })
        // The failure is reported rather than shown as a picture.
        guard case .decoded(let loaded) = document.status,
              case .unavailable = loaded.owned
        else {
            Issue.record("Expected the refusal to be reported, got \(document.status)")
            return
        }
    }

    /// A render that succeeds and a save that fails are two facts. The image
    /// is not withdrawn because the file system refused.
    @Test("A save failure keeps the new white balance and the new preview")
    func aSaveFailureKeepsTheImage() async throws {
        let patchA = try Self.patchA()
        let store = StubPhotographProcessingStore()
        store.refuseSaves(with: .cannotWrite(
            sidecar: URL(fileURLWithPath: "/tmp/nope"),
            underlying: CocoaError(.fileWriteNoPermission)
        ))
        let document = WorkspaceStubs.documentState(
            url: Self.url, width: 16, height: 12, store: store
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        document.setWhiteBalance(patchA)
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patchA)
            )
        )
        #expect(preview.whiteBalanceAdjustment == patchA)
        #expect(document.whiteBalanceAdjustment == patchA)
        #expect(document.adjustmentSaveFailure != nil)
        // The export still uses the canonical state, saved or not.
        #expect(document.exportRequest?.adjustments.whiteBalance == patchA)
    }

    // MARK: - Opening a file with a saved patch

    /// A saved patch affects the **first** owned preview. There is no pass
    /// with the default patch, not even one that is immediately replaced.
    @Test("A saved patch is used for the first preparation there is")
    func aSavedPatchIsUsedImmediately() async throws {
        let patchB = try Self.patchB()
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let saved = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1),
            whiteBalance: patchB
        )
        store.preload(saved, for: Self.url)

        let document = DocumentState(
            decoder: RecordingMosaicDecoder(
                wrapped: WorkspaceStubDecoder(
                    result: .success(RAWTestData.decodedRAW(url: Self.url)),
                    mosaic: .success(
                        WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12)
                    )
                ),
                log: log
            ),
            store: store,
            render: RecordingRender(log: log).render,
            prepareSource: RecordingPreparation(log: log).prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        // Exactly one preparation and one render, both for the saved state.
        #expect(log.preparations == [patchB])
        #expect(log.renders == [saved])
        #expect(try Self.preview(document).whiteBalanceAdjustment == patchB)

        // The order: the sidecar is read before anything is decoded or
        // prepared, so the saved patch cannot arrive after a default one.
        let loadIndex = try #require(
            log.firstIndex { if case .loadedAdjustments = $0 { return true } else { return false } }
        )
        let decodeIndex = try #require(log.firstIndex { $0 == .decodedMosaic })
        let prepareIndex = try #require(
            log.firstIndex { if case .preparedSource = $0 { return true } else { return false } }
        )
        let renderIndex = try #require(
            log.firstIndex { if case .rendered = $0 { return true } else { return false } }
        )
        #expect(loadIndex < decodeIndex)
        #expect(decodeIndex < prepareIndex)
        #expect(prepareIndex < renderIndex)

        // Reading changed nothing on disk.
        #expect(store.writeSummary.isEmpty)
    }

    // MARK: - Leaving the file, and coming back to it

    /// A document left mid-preparation still has two passes to make, and makes
    /// both — with no screen — so the decision the user committed reaches its
    /// own sidecar.
    @Test("A document left during a preparation still settles and saves")
    func leavingDuringAPreparationStillSaves() async throws {
        let patchA = try Self.patchA()
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let gate = GatedPreparation(log: log, holdingPicks: true)
        let document = DocumentState(
            decoder: MultiFileStubDecoder(
                mosaics: [
                    Self.url: WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12),
                    Self.other: WorkspaceStubs.mosaic(url: Self.other, width: 10, height: 8),
                ],
                log: log
            ),
            store: store,
            render: RecordingRender(log: log).render,
            prepareSource: gate.prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let patch = patchA
        document.setWhiteBalance(patch)
        try await gate.waitForGatedPreparationToStart()

        // The user leaves for another photograph. The other file's own
        // opening preparation is not gated, so it opens immediately.
        document.open(Self.other)
        try await Self.waitUntilSettled(document)
        #expect(document.selectedFileURL == Self.other)

        // The departed document finishes its preparation and its render, and
        // writes its own sidecar — under its own URL.
        gate.releaseOnePreparation()
        try await Self.waitUntil("the departed document saved") {
            store.saved(for: Self.url)?.whiteBalance == patch
        }
        #expect(document.unsavedAdjustments.isEmpty)
        // And nothing of it reached the document on screen.
        #expect(try Self.preview(document).sourcePixelWidth == 10)
        #expect(try Self.preview(document).whiteBalanceAdjustment == .defaultNeutralPatch)
    }

    /// The ADR 0014 ordering guarantee, extended to the longer wait: reopening
    /// the same file waits for its older generation to finish writing, so the
    /// reopen never reads a sidecar that is about to change.
    @Test("Reopening the same file waits for its pending patch to be written")
    func reopeningWaitsForThePendingPatch() async throws {
        let patchA = try Self.patchA()
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let gate = GatedPreparation(log: log, holdingPicks: true)
        let document = DocumentState(
            decoder: MultiFileStubDecoder(
                mosaics: [
                    Self.url: WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12)
                ],
                log: log
            ),
            store: store,
            render: RecordingRender(log: log).render,
            prepareSource: gate.prepare
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let patch = patchA
        document.setWhiteBalance(patch)
        try await gate.waitForGatedPreparationToStart()

        // Reopen the same file. It must not read the sidecar yet.
        document.open(Self.url)
        let loadsBefore = log.all.filter {
            if case .loadedAdjustments = $0 { return true } else { return false }
        }.count

        // The settling generation's preparation finishes, renders and writes.
        gate.releaseOnePreparation()
        try await Self.waitUntil("the departed generation wrote its patch") {
            store.saved(for: Self.url)?.whiteBalance == patch
        }

        // Only then does the reopen start — and its own preparation is gated
        // too, because it inherits the saved patch. Releasing it lets the
        // reopened document finish.
        gate.releaseOnePreparation()
        try await Self.waitUntil("the reopen settled") {
            if case .decoded = document.status { return true }
            return false
        }
        let loadsAfter = log.all.filter {
            if case .loadedAdjustments = $0 { return true } else { return false }
        }.count
        #expect(loadsAfter > loadsBefore)

        // The write came before the read that followed it, so the reopened
        // document shows the patch rather than a stale default.
        let writeIndex = try #require(
            log.all.lastIndex { if case .saved = $0 { return true } else { return false } }
        )
        let readIndex = try #require(
            log.all.lastIndex {
                if case .loadedAdjustments = $0 { return true } else { return false }
            }
        )
        #expect(writeIndex < readIndex)
        #expect(document.whiteBalanceAdjustment == patch)
    }

    // MARK: - Export

    /// The sharpest demonstration of "canonical state, not displayed state":
    /// an export started while a new patch is still being prepared renders the
    /// **new** patch.
    @Test("An export during a pending preparation uses the new patch")
    func exportDuringAPendingPreparationUsesTheNewPatch() async throws {
        let patchA = try Self.patchA()
        let log = WorkspaceEventLog()
        let gate = GatedPreparation(log: log, holdingPicks: true)
        let recorder = RecordingExport()
        let document = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
            ),
            store: StubPhotographProcessingStore(log: log),
            render: RecordingRender(log: log).render,
            prepareSource: gate.prepare,
            exportRun: recorder.run
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let patch = patchA
        document.setWhiteBalance(patch)
        try await gate.waitForGatedPreparationToStart()

        // The preview on screen is still the default patch; the canonical
        // state is the new one.
        #expect(try Self.preview(document).whiteBalanceAdjustment == .defaultNeutralPatch)
        #expect(document.whiteBalanceAdjustment == patch)

        document.exportTIFF(to: URL(fileURLWithPath: "/tmp/white-balance-export.tiff"))
        try await Self.waitUntil("the export ran") { recorder.startedCount == 1 }

        // The export took the canonical state, not the displayed one — and it
        // did not wait for the preview.
        #expect(recorder.started.first?.request.adjustments.whiteBalance == patch)

        gate.releaseOnePreparation()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(whiteBalance: patch)
            )
        )
    }
}
