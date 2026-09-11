import Testing
import Foundation
@testable import InfraredConverter

/// The single render slot: what it starts, what it cancels, and what it never
/// renders at all.
///
/// The assertions here are about **work performed**, not about the final
/// image. A scheduler that started a render per button press and discarded the
/// stale results would produce exactly the same final image and fail this
/// suite on the first assertion.
/// Serialised: the probe blocks a cooperative-pool thread for as long as a
/// render is held in flight, and several of these at once can exhaust the
/// pool. See `RenderProbe`.
@Suite("Coalescing preview renderer", .serialized)
@MainActor
struct CoalescingPreviewRendererTests {

    static let url = URL(fileURLWithPath: "/tmp/example.orf")

    /// One real preview, so the probe returns the genuine type rather than a
    /// stub the production code could not have produced.
    static func makePreview() throws -> WorkspacePreview {
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url))
        )
        return try WorkspacePreviewPipeline().render(decoding: url, using: decoder)
    }

    /// Collects what was actually delivered, in order.
    @MainActor
    final class Delivered {
        var states: [UserOrientationAdjustment] = []
        var failures: [Error] = []
    }

    /// Waits for the render slot to empty, bounded so a scheduling mistake
    /// fails the test instead of hanging the run.
    static func waitUntilIdle(_ renderer: CoalescingPreviewRenderer) async throws {
        // Yields rather than sleeps, and is bounded generously for the same
        // reason `RenderProbe.waitLimit` is: another suite can hold the main
        // actor for minutes, and a starved test is not a broken scheduler.
        for _ in 0..<1_000_000 {
            guard renderer.isRendering else { return }
            await Task.yield()
        }
        throw RenderProbe.Stalled()
    }

    static func adjustments(_ orientation: UserOrientationAdjustment) -> ImageAdjustments {
        ImageAdjustments(orientation: orientation)
    }

    static func makeRenderer(
        probe: RenderProbe, delivered: Delivered
    ) -> CoalescingPreviewRenderer {
        CoalescingPreviewRenderer(
            render: probe.render,
            deliver: { outcome, adjustments in
                switch outcome {
                case .success: delivered.states.append(adjustments.orientation)
                case .failure(let error): delivered.failures.append(error)
                }
            }
        )
    }

    // MARK: - The ordinary case is unchanged

    @Test("A single request renders once and is delivered")
    func oneRequestRendersOnce() async throws {
        let probe = RenderProbe(preview: try Self.makePreview())
        let delivered = Delivered()
        let renderer = Self.makeRenderer(probe: probe, delivered: delivered)

        renderer.request(Self.adjustments(.quarterTurnRight))
        try await probe.waitForRenderToStart()
        probe.releaseOneRender()

        try await Self.waitUntilIdle(renderer)

        #expect(probe.startedCount == 1)
        #expect(probe.completedCount == 1)
        #expect(probe.cancelledCount == 0)
        #expect(probe.requested == [.quarterTurnRight])
        #expect(delivered.states == [.quarterTurnRight])
        #expect(delivered.failures.isEmpty)
    }

    // MARK: - A burst

    /// The requirement in one test: four presses in a burst produce **two**
    /// renders, not four, and the two intermediate states are never rendered
    /// at all.
    @Test("A burst of requests renders the first and the newest, and nothing between")
    func aBurstCollapsesToTheNewestState() async throws {
        let probe = RenderProbe(preview: try Self.makePreview())
        let delivered = Delivered()
        let renderer = Self.makeRenderer(probe: probe, delivered: delivered)

        // The first press starts a render, and it is still working.
        renderer.request(Self.adjustments(.quarterTurnRight))
        try await probe.waitForRenderToStart()

        // Three more presses arrive while it works. The first two are
        // overwritten in the single pending slot before they can start.
        renderer.request(Self.adjustments(.halfTurn))
        renderer.request(Self.adjustments(.quarterTurnLeft))
        renderer.request(Self.adjustments(.horizontalFlip))

        // Nothing new has begun: the slot is still occupied.
        #expect(probe.startedCount == 1)

        // Let the superseded render reach its cancellation check.
        probe.releaseOneRender()

        // The replacement starts, and it is the newest state — not the oldest
        // pending one, and not a queue of three.
        try await probe.waitForRenderToStart()
        #expect(probe.startedCount == 2)
        #expect(probe.requested == [.quarterTurnRight, .horizontalFlip])

        probe.releaseOneRender()
        try await Self.waitUntilIdle(renderer)

        #expect(probe.startedCount == 2)
        #expect(probe.completedCount == 1)
        #expect(probe.cancelledCount == 1)

        // The superseded render was never delivered, and never reported as a
        // failure either.
        #expect(delivered.states == [.horizontalFlip])
        #expect(delivered.failures.isEmpty)
    }

    @Test("A superseded render is cancelled, not merely discarded")
    func aSupersededRenderIsCancelled() async throws {
        let probe = RenderProbe(preview: try Self.makePreview())
        let delivered = Delivered()
        let renderer = Self.makeRenderer(probe: probe, delivered: delivered)

        renderer.request(Self.adjustments(.quarterTurnRight))
        try await probe.waitForRenderToStart()
        renderer.request(Self.adjustments(.halfTurn))

        probe.releaseOneRender()
        try await probe.waitForRenderToStart()
        probe.releaseOneRender()
        try await Self.waitUntilIdle(renderer)

        // The first render observed the signal itself. That is the whole
        // claim: it stopped its own work rather than having its result thrown
        // away afterwards.
        #expect(probe.cancelledCount == 1)
        #expect(probe.completedCount == 1)
        #expect(delivered.states == [.halfTurn])
    }

    @Test("At most one render is ever working")
    func onlyOneRenderWorksAtATime() async throws {
        let probe = RenderProbe(preview: try Self.makePreview())
        let delivered = Delivered()
        let renderer = Self.makeRenderer(probe: probe, delivered: delivered)

        renderer.request(Self.adjustments(.quarterTurnRight))
        try await probe.waitForRenderToStart()

        for orientation in [UserOrientationAdjustment.halfTurn, .quarterTurnLeft, .verticalFlip] {
            renderer.request(Self.adjustments(orientation))
            // Still exactly one render has begun: the replacement cannot start
            // until the one in flight has unwound.
            #expect(probe.startedCount == 1)
        }

        probe.releaseOneRender()
        try await probe.waitForRenderToStart()
        #expect(probe.startedCount == 2)
        probe.releaseOneRender()
        try await Self.waitUntilIdle(renderer)
        #expect(probe.startedCount == 2)
    }

    // MARK: - Failures and abandonment

    @Test("Cancelling everything renders nothing further and reports nothing")
    func cancelAllAbandonsThePendingState() async throws {
        let probe = RenderProbe(preview: try Self.makePreview())
        let delivered = Delivered()
        let renderer = Self.makeRenderer(probe: probe, delivered: delivered)

        renderer.request(Self.adjustments(.quarterTurnRight))
        try await probe.waitForRenderToStart()
        renderer.request(Self.adjustments(.halfTurn))
        renderer.cancelAll()

        probe.releaseOneRender()
        try await Self.waitUntilIdle(renderer)

        #expect(probe.startedCount == 1)
        #expect(probe.cancelledCount == 1)
        #expect(delivered.states.isEmpty)
        #expect(delivered.failures.isEmpty)
    }

    @Test("A render that genuinely fails is delivered as a failure")
    func aRealFailureIsDelivered() async throws {
        let delivered = Delivered()
        let renderer = CoalescingPreviewRenderer(
            render: { _, _ in
                throw OrientationError.invalidGeometry(reason: "test")
            },
            deliver: { outcome, adjustments in
                switch outcome {
                case .success: delivered.states.append(adjustments.orientation)
                case .failure(let error): delivered.failures.append(error)
                }
            }
        )

        renderer.request(Self.adjustments(.quarterTurnRight))
        try await Self.waitUntilIdle(renderer)

        #expect(delivered.states.isEmpty)
        #expect(delivered.failures.count == 1)
        #expect(delivered.failures.first is OrientationError)
    }
}
