# 0011 — Coalesced, cancellable preview rendering

Status: accepted
Date: 2026-09-12

> Numbering note: `CLAUDE.md` uses `0011-metal-render-pipeline.md` as an
> illustrative example of a future ADR filename. This milestone is the decision
> that actually took number `0011`, so that illustrative example now reads
> `0013-metal-render-pipeline.md`. ADR numbers follow the order decisions are
> made; no ADR was renamed.

## Context

ADR 0010 split the workspace pipeline in two so that a user's orientation
correction reruns only the cheap half:

```text
prepare(decoding:using:)    decode → normalise → balance → demosaic → convert → mix
render(_:adjustments:)      orient → display-encode
```

"Cheap" is relative. On the E-PL3 fixture the cheap half is still a full-frame
permutation of roughly 12 megapixels of Float32 followed by a full-frame
exposure, clip, transfer function and quantisation. It takes long enough that a
person holding a rotate button down starts several of them.

`DocumentState` handled that with:

```swift
reprocessTask?.cancel()
reprocessTask = Task.detached {
    let owned = Self.ownedPreview(...)
    guard !Task.isCancelled else { return }
    ...
}
```

which is not cancellation. `ImageOrienter` and `DisplayPreviewRenderer` are
single synchronous passes with no suspension point in them, so `cancel()` could
not interrupt one: every superseded render ran to completion, holding a core
and an output buffer, and the check at the end only declined to install the
finished result. Five rapid presses meant five full-frame renders, four of them
for pictures nobody would ever see, all of them in flight at once.

Three separate properties were wanted, and only the third was true.

## Decision 1 — The stages poll a cancellation signal, and throw

`ProcessingCancellation` is a `Sendable` wrapper around a
`@Sendable () -> Bool`. `ImageOrienter.apply` and `DisplayPreviewRenderer.render`
take one, defaulted to `.none`, and poll it **once before any allocation and
once before each destination row**.

The contract is deliberately narrow:

- **Deterministic granularity.** The poll count for a given image is exactly
  predictable — `1 + rowCount` for a complete run — which is what makes
  "stopped after three rows of a hundred" a testable claim rather than a hope.
- **No half-finished images.** A cancelled stage throws. `ImageOrienter`
  abandons its `unsafeUninitializedCapacity` buffer; `DisplayPreviewRenderer`
  abandons its `Data`. Neither returns a partially written frame, which would
  look like an ordinary black band.
- **Cancellation is not failure.** It is `CancellationError`, deliberately not
  a case of `OrientationError` or `DisplayRenderingError`. "Nobody wants this
  any more" and "the image could not be processed" are different facts, and
  only the second belongs in front of a user.

### Why not `Task.isCancelled` directly in the stages

It would work in production and could not be tested. A synchronous stage
reading the ambient task's cancellation state can only be driven by arranging a
real cancelled task around it, which makes the poll count a race rather than a
measurement. An injected predicate is testable by construction, and
`ProcessingCancellation.enclosingTask` is exactly `{ Task.isCancelled }` for the
callers that want the ambient behaviour.

### Why the stages are allowed to know about cancellation at all

Because it is not a UI concept. A cancellation signal is a `Bool`-returning
function, passed in explicitly, in exactly the way `RAWWhiteBalancer` takes
gains and `IRChannelMixer` takes a mix: something a caller decided. Nothing in
`ImageOrienter` or `DisplayPreviewRenderer` learns what a button, a document or
a view is.

## Decision 2 — One render slot, one pending state

`CoalescingPreviewRenderer` is a `@MainActor` class holding two fields: the
render in flight, and **one** pending state.

```text
request(A)                    → A starts
request(B) while A is running → A is cancelled, B becomes pending
request(C) while A unwinds    → B is discarded, C becomes pending
A unwinds as cancelled        → discarded, never delivered
C runs to completion          → delivered
```

- **At most one expensive render works at a time.** `inFlight` is cleared only
  by the render's own completion, so a replacement starts after its predecessor
  has unwound. Renders cannot pile up on the cooperative pool.
- **A burst collapses to its newest member.** The pending slot holds one state,
  so intermediate states are overwritten before they are ever rendered. A
  five-press burst costs two renders, not five.
- **No history is replayed.** This is the scheduling counterpart of ADR 0010's
  Decision 6: the thing being rendered is a canonical state, never a command
  history. A queue here would have quietly reintroduced the history the model
  was shaped to avoid.

`DocumentState` keeps its own guard on the delivered adjustment as the second
line of defence, for a render that finishes before it notices the signal.

### Why main-actor confinement rather than an actor

The bookkeeping is two mutable fields that change only when a user acts or a
render ends. `DocumentState` is already `@MainActor`, so putting the scheduler
there makes every transition serialised by construction: no actor hop, no
reentrancy question, no lock, and no possibility of two requests interleaving
mid-decision. The **work** is not on the main actor — `render` runs in a
detached task, as it did before.

## Decision 3 — The expensive half stays uncancellable, for now

`prepare(decoding:using:)` polls nothing. Making it cooperative would mean
threading a signal through the normaliser, the estimator, the balancer, the
demosaicer, the colour converter and the mixer — six stages, none of which a
user can re-trigger by holding a button down. The half that a burst of presses
re-runs is the half that can now be stopped.

Opening a file is therefore still abandoned only at the task boundary, after
the pass. That is a known limitation, recorded here rather than discovered
later.

## Consequences

- Holding a rotate key down costs two full-frame renders instead of one per
  press, and one core instead of several.
- A superseded render stops inside its pass, at a row boundary, rather than
  finishing work that will be discarded.
- A superseded render is never delivered, and never reported as an error — the
  failure mode where replacing a press shows a message about the press it
  replaced cannot occur.
- The scheduler is testable without the workspace, the workspace without the
  scheduler, and the stages without either.
- Every existing caller of the two stages is unchanged: the parameter defaults
  to never cancelling.
- Opening a file is still not interruptible mid-decode.
