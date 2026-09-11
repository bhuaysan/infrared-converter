import Foundation

/// One expensive preview render at a time, always of the newest state asked
/// for.
///
/// ```text
/// request(A)                    → A starts
/// request(B) while A is running → A is cancelled, B becomes pending
/// request(C) while A unwinds    → B is discarded, C becomes pending
/// A unwinds as cancelled        → discarded, never delivered
/// C runs to completion          → delivered
/// ```
///
/// ## What it is for
///
/// Holding a rotate button down produces a burst of adjustment changes. Each
/// one wants a full-frame permutation and display encode, and all but the last
/// are already obsolete by the time they would finish. Three things have to be
/// true at once, and only the last of them was before:
///
/// 1. **At most one expensive render is actually working.** A new request
///    cancels the one in flight, and the replacement starts only once that one
///    has unwound — so renders never pile up on the cooperative pool.
/// 2. **A burst collapses to its newest member.** The pending slot holds
///    exactly one state, so `B` is simply overwritten by `C` and never
///    rendered at all. There is no queue, and nothing replays the presses that
///    produced the state.
/// 3. **A superseded result never reaches the screen.** It is thrown away
///    here, and the caller's own guard on what it asked for is the second
///    line of defence.
///
/// Point 2 is the scheduling counterpart of the rule `ImageAdjustments`
/// already follows: the thing being rendered is a canonical state, never a
/// command history. A queue here would have quietly reintroduced the history
/// the model was shaped to avoid.
///
/// ## Why it is main-actor confined
///
/// The bookkeeping — what is pending, what is in flight — is three lines of
/// mutable state that only ever changes in response to a user action or the
/// end of a render. Putting it on the main actor, where `DocumentState`
/// already lives, makes every transition serialised by construction, with no
/// actor hop, no reentrancy question and no lock. The **work** is not on the
/// main actor: `render` runs in a detached task and must poll the
/// `ProcessingCancellation` it is handed.
///
/// ## What it does not know
///
/// Nothing about orientation, buttons, documents or SwiftUI. It is given a
/// function that renders one `ImageAdjustments`, and a function that receives
/// a settled outcome; what those do is the application layer's business.
@MainActor
final class CoalescingPreviewRenderer {
    /// Renders one adjustment state. Called off the main actor, and must poll
    /// `cancellation` so that a superseded render stops inside the pass.
    typealias Render = @Sendable (
        ImageAdjustments, ProcessingCancellation
    ) throws -> WorkspacePreview

    /// Receives an outcome that is still wanted. Never called for a render
    /// that was superseded.
    typealias Deliver = @MainActor (Result<WorkspacePreview, Error>, ImageAdjustments) -> Void

    private let render: Render
    private let deliver: Deliver

    /// The render currently doing work, if any. Cleared only when that render
    /// has finished unwinding, which is what keeps "at most one" true.
    private var inFlight: Task<Void, Never>?

    /// The newest state asked for and not yet started. One slot, deliberately:
    /// this is where a burst collapses.
    private var pending: ImageAdjustments?

    init(render: @escaping Render, deliver: @escaping Deliver) {
        self.render = render
        self.deliver = deliver
    }

    /// Asks for `adjustments` to be rendered, superseding everything older.
    ///
    /// Returns immediately. Any render in flight is cancelled, and any state
    /// that was waiting to start is forgotten — it is older than this one and
    /// nobody will ever see it.
    func request(_ adjustments: ImageAdjustments) {
        pending = adjustments
        inFlight?.cancel()
        startPendingIfIdle()
    }

    /// Abandons the render in flight and the pending state, for a caller that
    /// no longer wants any of it — a different file, or a closing document.
    ///
    /// `inFlight` is deliberately **not** cleared: only the render's own
    /// completion clears it, so a later request cannot start a second render
    /// beside one that is still unwinding.
    func cancelAll() {
        pending = nil
        inFlight?.cancel()
    }

    /// Whether a render is currently occupying the single slot. Test-facing:
    /// the production path never asks.
    var isRendering: Bool { inFlight != nil }

    private func startPendingIfIdle() {
        guard inFlight == nil, let next = pending else { return }
        pending = nil

        let render = self.render
        // Detached for the same reason the decode is: a full-frame permutation
        // and encode is not work for the main actor. The task's own
        // cancellation is what `.enclosingTask` reports, so cancelling it
        // stops the pass rather than merely discarding its result.
        inFlight = Task.detached(priority: .userInitiated) {
            let outcome = Result { try render(next, .enclosingTask) }
            await MainActor.run { [weak self] in
                self?.finish(next, outcome: outcome)
            }
        }
    }

    private func finish(
        _ adjustments: ImageAdjustments,
        outcome: Result<WorkspacePreview, Error>
    ) {
        inFlight = nil

        if case .failure(let error) = outcome, error is CancellationError {
            // Superseded. Not delivered, and above all not reported as a
            // failure: a user who pressed rotate twice would otherwise see an
            // error message for the press they replaced.
        } else {
            deliver(outcome, adjustments)
        }

        startPendingIfIdle()
    }
}
