import Foundation

/// One expensive pass at a time, always of the newest state asked for.
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
/// Holding a rotate button down produces a burst of adjustment changes.
/// Clicking a neutral patch repeatedly produces a burst of white-balance
/// changes. Each one wants a long synchronous pass over millions of pixels,
/// and all but the last are already obsolete by the time they would finish.
/// Three things have to be true at once:
///
/// 1. **At most one expensive pass is actually working.** A new request
///    cancels the one in flight, and the replacement starts only once that one
///    has unwound — so passes never pile up on the cooperative pool.
/// 2. **A burst collapses to its newest member.** The pending slot holds
///    exactly one state, so `B` is simply overwritten by `C` and never run at
///    all. There is no queue, and nothing replays the presses that produced
///    the state.
/// 3. **A superseded result never reaches the screen.** It is thrown away
///    here, and the caller's own guard on what it asked for is the second
///    line of defence.
///
/// Point 2 is the scheduling counterpart of the rule `ImageAdjustments`
/// already follows: the thing being rendered is a canonical state, never a
/// command history. A queue here would have quietly reintroduced the history
/// the model was shaped to avoid.
///
/// ## Why it is generic
///
/// Because there are two of these, and they are the same algorithm. A document
/// has a **fast** slot that re-renders the retained reduced preview, and a
/// **heavy** slot that re-prepares that preview from the retained normalised
/// mosaic when the white balance changes. Writing the second by hand would
/// have meant two copies of the "cancel, replace, start when idle" logic, and
/// the invariants above proved once instead of twice.
///
/// ```text
/// PreviewRenderSlot            a render request  → a WorkspacePreview
/// WhiteBalancePreparationSlot  a white balance   → a reduced pre-mix Source
/// ```
///
/// What it deliberately does not know is which of the two it is. There is no
/// `Request: Equatable` requirement and no comparison here: this type
/// schedules, and deciding whether a settled result is still wanted — or
/// whether a new request is worth making at all — belongs to the caller that
/// knows what the user has asked for since. `target` is what it asks.
///
/// ## Why it is main-actor confined
///
/// The bookkeeping — what is pending, what is in flight — is two pieces of
/// mutable state that only ever change in response to a user action or the end
/// of a pass. Putting it on the main actor, where `DocumentState` already
/// lives, makes every transition serialised by construction, with no actor
/// hop, no reentrancy question and no lock. The **work** is not on the main
/// actor: `work` runs in a detached task and must poll the
/// `ProcessingCancellation` it is handed.
///
/// ## What it does not know
///
/// Nothing about orientation, patches, buttons, documents or SwiftUI. It is
/// given a function that produces an output from a request, and a function
/// that receives a settled outcome; what those do is the application layer's
/// business.
@MainActor
final class CoalescingRenderSlot<Request: Sendable, Output: Sendable> {
    /// Produces one output. Called off the main actor, and must poll
    /// `cancellation` so that a superseded pass stops inside itself.
    typealias Work = @Sendable (Request, ProcessingCancellation) throws -> Output

    /// Receives an outcome that is still wanted. Never called for a pass that
    /// was superseded.
    typealias Deliver = @MainActor (Result<Output, Error>, Request) -> Void

    private let work: Work
    private let deliver: Deliver

    /// The pass currently doing work, if any. Cleared only when that pass has
    /// finished unwinding, which is what keeps "at most one" true.
    private var inFlight: Task<Void, Never>?

    /// The newest request made and not yet started. One slot, deliberately:
    /// this is where a burst collapses.
    private var pending: Request?

    /// What this slot is currently aiming at: the request in flight, or the
    /// one waiting to replace it. `nil` when the slot is idle.
    ///
    /// ## Why a caller needs it
    ///
    /// Because "ask again for what is already being worked on" and "ask for
    /// something new" are different instructions, and only the caller knows
    /// which one it means. `request(_:)` unconditionally supersedes — that is
    /// its job — so a caller that re-requested the in-flight state would
    /// cancel a pass that was about to produce exactly the right answer and
    /// start it again from the beginning, forever, if the caller kept asking.
    ///
    /// That is not hypothetical: the workspace reaches `adjust` for **every**
    /// adjustment, and a change of exposure while a white balance is being
    /// prepared still wants that same white balance. It asks this first and
    /// stays quiet when the answer is already on its way.
    ///
    /// Comparing is the caller's job too. This type has no `Equatable`
    /// requirement, deliberately — one of its two concrete requests carries
    /// megabytes of `Float` — so the caller compares the part that means
    /// something.
    private(set) var target: Request?

    init(work: @escaping Work, deliver: @escaping Deliver) {
        self.work = work
        self.deliver = deliver
    }

    /// Asks for `request` to be processed, superseding everything older.
    ///
    /// Returns immediately. Any pass in flight is cancelled, and any request
    /// that was waiting to start is forgotten — it is older than this one and
    /// nobody will ever see it.
    func request(_ request: Request) {
        pending = request
        target = request
        inFlight?.cancel()
        startPendingIfIdle()
    }

    /// Abandons the pass in flight and the pending request, for a caller that
    /// no longer wants any of it — a different file, or a closing document.
    ///
    /// `inFlight` is deliberately **not** cleared: only the pass's own
    /// completion clears it, so a later request cannot start a second pass
    /// beside one that is still unwinding.
    func cancelAll() {
        pending = nil
        target = nil
        inFlight?.cancel()
    }

    /// Whether a pass is currently occupying the single slot. Test-facing:
    /// the production path never asks.
    var isRendering: Bool { inFlight != nil }

    private func startPendingIfIdle() {
        guard inFlight == nil, let next = pending else { return }
        pending = nil

        let work = self.work
        // Detached for the same reason the decode is: a full-frame pass is not
        // work for the main actor. The task's own cancellation is what
        // `.enclosingTask` reports, so cancelling it stops the pass rather
        // than merely discarding its result.
        inFlight = Task.detached(priority: .userInitiated) {
            let outcome = Result { try work(next, .enclosingTask) }
            await MainActor.run { [weak self] in
                self?.finish(next, outcome: outcome)
            }
        }
    }

    private func finish(_ request: Request, outcome: Result<Output, Error>) {
        inFlight = nil
        // The slot stops aiming at anything only when nothing is waiting. A
        // pass that unwound because a newer request replaced it leaves that
        // newer request as the target, which is exactly what it is.
        if pending == nil { target = nil }

        if case .failure(let error) = outcome, error is CancellationError {
            // Superseded. Not delivered, and above all not reported as a
            // failure: a user who pressed rotate twice would otherwise see an
            // error message for the press they replaced.
        } else {
            deliver(outcome, request)
        }

        startPendingIfIdle()
    }
}

/// What one interactive re-render is asked for: the reduced pre-mix source to
/// start from, and the complete adjustment state to apply to it.
///
/// ## Why the source travels with the request
///
/// It used to be captured once, when the render slot was built for a file, and
/// that was right while nothing could replace it. The white balance can: a new
/// neutral patch re-prepares the reduced preview, so a document's source is
/// now something that changes during its life.
///
/// Rebuilding the slot each time the source changed would have been the other
/// answer, and a worse one — it throws away a slot that may still be unwinding
/// a cancelled pass, which is exactly the state "at most one pass at a time"
/// depends on. Carrying the source in the request keeps one slot per document
/// for its whole life, and makes "which pixels was this rendered from" a
/// property of the request rather than of a closure nobody can inspect.
///
/// It is deliberately not `Equatable`. Deciding whether a settled render is
/// still wanted is a question about `adjustments`, which the document compares
/// itself; comparing megabytes of `Float` to answer it would be both slow and
/// beside the point.
struct PreviewRenderRequest: Sendable {
    /// The reduced, unmixed, unoriented scene-linear image to render from.
    let source: WorkspacePreviewPipeline.Source
    /// The complete canonical state to apply to it.
    let adjustments: ImageAdjustments
}

/// The fast slot: one complete adjustment state applied to a reduced pre-mix
/// preview.
typealias PreviewRenderSlot = CoalescingRenderSlot<PreviewRenderRequest, WorkspacePreview>

/// The heavy slot: one white-balance decision re-prepared from the retained
/// normalised mosaic into a new reduced pre-mix preview.
///
/// Separate from the fast slot rather than folded into it, because the two
/// have different costs, different inputs and different results, and because
/// "at most one at a time" is a claim each needs to make about itself. A white
/// balance being re-prepared must not stop the exposure from re-rendering once
/// it lands, and a render must not stop a newer patch from starting.
typealias WhiteBalancePreparationSlot = CoalescingRenderSlot<
    UserWhiteBalanceAdjustment, WorkspacePreviewPipeline.Source
>
