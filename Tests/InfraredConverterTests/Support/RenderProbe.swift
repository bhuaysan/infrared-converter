import Foundation
@testable import InfraredConverter

/// A stand-in for the expensive preview render that the test drives by hand
/// and can then interrogate.
///
/// Every call blocks until the test releases it, so a render is "in flight"
/// for exactly as long as the test wants it to be. Nothing sleeps and nothing
/// polls a clock: the handshake is two semaphores, and every wait a test
/// performs is `async`, on a thread of its own, so the main actor stays free
/// for the renderer's own bookkeeping.
///
/// What it records is the point of the whole suite:
///
/// ```text
/// startedCount    renders that actually began work
/// completedCount  renders that ran to the end
/// cancelledCount  renders that saw the signal and abandoned their work
/// requested       the adjustment states that were rendered, in order
/// ```
///
/// A scheduler that merely discarded stale results would show `startedCount`
/// equal to the number of button presses. That is the failure this suite is
/// built to catch, and no assertion on the final image could catch it.
///
/// ## Why the suite using this must be serialised
///
/// A render blocked here occupies a Swift concurrency cooperative-pool thread
/// for as long as the test holds it, because the render it stands in for is
/// synchronous and so is this. Several of these in parallel can exhaust the
/// pool, at which point a later render cannot start, the test waiting for it
/// never releases its own, and the run deadlocks — which it did, before the
/// suite was marked `.serialized`. One blocked thread at a time is fine; a
/// poolful is not.
///
/// Every wait is bounded as a second line of defence, so a mistake of that
/// kind surfaces as a failed test rather than a hung run.
final class RenderProbe: @unchecked Sendable {
    /// A wait that never returned. Always a fault in the test, never in the
    /// code under test — reported as an error so it fails rather than hangs.
    struct Stalled: Error {}

    /// A hang guard, not a timing the tests depend on.
    ///
    /// It has to clear the longest a `@MainActor` suite in this package can
    /// hold the main actor, because these tests need it to make their next
    /// request. `EPL3OrientationCorrectionTests` renders the full fixture on
    /// the main actor and takes minutes, so a short bound reports a starved
    /// test as a broken scheduler — which it did, at thirty seconds.
    ///
    /// It therefore has to be far longer than anything healthy, and exists only
    /// so that a genuine deadlock fails the run instead of hanging it.
    ///
    /// It was ten minutes, and that stopped clearing the bar: a full run with
    /// the RAW fixture now takes eight minutes of its own, so a starved test
    /// could exceed the guard and report a scheduling failure that was really
    /// contention. Observed once, as exactly that. Thirty minutes restores the
    /// property the guard is supposed to have — longer than any healthy run,
    /// rather than comparable to one.
    static let waitLimit = DispatchTimeInterval.seconds(1800)

    private let lock = NSLock()
    private var started = 0
    private var completed = 0
    private var cancelled = 0
    private var states: [UserOrientationAdjustment] = []

    /// Signalled by each render as it begins.
    private let didStart = DispatchSemaphore(value: 0)
    /// Awaited by each render before it finishes. One signal releases one
    /// render.
    private let release = DispatchSemaphore(value: 0)

    /// The preview every completed render returns. Real, so the type is not
    /// faked out from under the code under test.
    private let preview: WorkspacePreview

    init(preview: WorkspacePreview) {
        self.preview = preview
    }

    var startedCount: Int { withLock { started } }
    var completedCount: Int { withLock { completed } }
    var cancelledCount: Int { withLock { cancelled } }
    var requested: [UserOrientationAdjustment] { withLock { states } }

    /// The render function to hand `CoalescingPreviewRenderer`.
    ///
    /// It blocks where a real full-frame render would be working, and checks
    /// cancellation where a real one polls it.
    var render: CoalescingPreviewRenderer.Render {
        { [self] adjustments, cancellation in
            withLock {
                started += 1
                states.append(adjustments.orientation)
            }
            didStart.signal()

            // Stand in for the pass over the frame. The test decides when this
            // render reaches its next cancellation check.
            guard release.wait(timeout: .now() + Self.waitLimit) == .success else {
                throw Stalled()
            }

            if cancellation.isCancelled {
                withLock { cancelled += 1 }
                throw CancellationError()
            }
            withLock { completed += 1 }
            return preview
        }
    }

    /// Suspends until the next render has begun.
    ///
    /// The blocking wait happens on a global queue, never on the main actor,
    /// so the renderer can keep finishing and starting renders while the test
    /// waits for one.
    func waitForRenderToStart() async throws {
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(
                    returning: didStart.wait(timeout: .now() + Self.waitLimit) == .success
                )
            }
        }
        guard started else { throw Stalled() }
    }

    /// Lets the render currently in flight proceed to its cancellation check.
    func releaseOneRender() { release.signal() }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
