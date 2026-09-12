# 0014 — The life of one adjustment, from the press to the disk

Status: accepted
Date: 2026-09-12

## Context

[ADR 0013](0013-adjustment-sidecar.md) gave the user's adjustments a durable
home and got the hard rules right: a state is written only after exactly that
state has rendered, a superseded render never writes, a failed render never
writes, and a failed write never withdraws the image.

What it did not model is the **interval**. A decision takes time to become
durable, and during that time the workspace held two things that disagreed:

```text
disk         quarterTurnRight      the last state that was written
on screen    halfTurn              the state the user just asked for
persistence  .saved                a claim about neither
```

`AdjustmentPersistence` was set only when a render was delivered, so requesting
a new adjustment left the previous state's `.saved` standing. Nothing read it
wrongly yet — the UI only looks for a failure — but it is the kind of state that
is read wrongly the first time somebody trusts it, and a close guard is exactly
the kind of thing that would.

The second gap was worse, because it lost work:

```text
rotate A            → render starts
open B              → renderer.cancelAll()
```

The render was the only thing that could make that rotation eligible to be
written, and cancelling it discarded the decision. No message, no record, no
sidecar. A user who rotates a photograph and immediately clicks the next one
loses the rotation and is told nothing.

## Decision 1 — The persistence state describes the state on screen

`AdjustmentPersistence` is one closed enum about the **currently requested**
adjustment, never about the last one that happened to be written:

```text
unchanged      nothing decided since the file opened
pending        decided, render not delivered yet
saved          decided and durable
renderRefused  its render refused it, so it was never eligible
saveFailed     it rendered, and the write refused
```

`isDurable` is true for the first and third only.

Booleans were rejected: `isSaved`, `isDirty` and `saveFailed` side by side admit
combinations that mean nothing, and every reader would have to work out which
ones are real. The two failure cases are kept apart because the reasons differ
and so does what a reader can do — and in both, the sidecar still holds the last
state that actually rendered and saved.

Requesting an adjustment now sets `.pending` **in the same assignment** that
records the intent:

```swift
loaded.adjustments.orientation = updated
loaded.persistence = .pending
```

One statement cannot get out of step with the next. There is no window in which
the workspace holds one state and claims another is saved.

The last durable value is deliberately **not** stored beside it. The store is
the authority on what is on disk, and a second copy here would be one more
thing to keep in agreement for no reader that needs it.

## Decision 2 — Leaving a file hands its render over; it does not cancel it

```text
nothing decided, or decided and saved   the render slot is cancelled and dropped
decided, render still running           the slot keeps running, to persist and nothing else
decided, render refused it              recorded as unsaved; it can never be written
decided, rendered, save refused         recorded as unsaved; the sidecar is older
```

A *settling document* has no screen and no controls. It keeps its render slot,
its URL and the newest state it was asked for, frozen at the moment the
workspace left it — nothing can change that state afterwards, because nothing is
attached to it. It may do exactly one thing more: **write its own sidecar, once
its own render succeeds.** It cannot install a preview and it cannot touch
`status`.

The rule from ADR 0013 is untouched by this. A settling document still writes
only a state that rendered, and still only the newest state it was asked for; a
superseded render inside it is discarded exactly as before, and the document
stays open until the state it is actually waiting for arrives.

### The alternatives, and why not

- **Save the pending state at switch time.** Forbidden by the rule it would
  break: that state has not rendered, so nothing knows it can be rendered.
- **Defer the switch until the current document settles.** Correct, and it
  makes the user wait for a full-frame render before the file they asked for
  appears. It also inverts the grain of everything else here, where the newest
  intent wins immediately and older work gets out of the way. Opening a file is
  the most direct thing a user can ask for; blocking it to finish bookkeeping
  is the wrong trade.
- **Cancel, and warn that the edit was lost.** Honest, and it throws away work
  that was seconds from being safe for no reason but tidiness.

### What it costs, stated rather than discovered

A settling document holds its scene-linear source until it settles, so a switch
made mid-render briefly retains two of them — on the E-PL3 fixture, roughly a
gigabyte instead of half. It is released the moment the render delivers.

For the same interval, two full-frame renders can be in flight: the departing
document's and the new one's initial one. ADR 0011's "at most one expensive
render at a time" is a property of one render slot and still holds for each;
this is the one place where two slots exist at once, and it lasts exactly as
long as the render that was already running.

## Decision 3 — Deliveries are routed by generation, not by URL

Every `open(_:)` increments a counter, and each render slot captures the
generation it was built for.

```text
generation == current   the document is on screen: install, then save
generation in settling  the document has been left: save, and nothing else
neither                 nothing; there is nowhere for the result to go
```

URL routing would have been almost right, and wrong in the case that matters:
the same file can be opened twice, and the first open's late render must not
replace the second open's preview merely because the paths match. Generations
make that impossible by construction rather than by a comparison someone has to
remember to write.

## Decision 4 — What cannot be saved is recorded, not dropped

`AdjustmentPersistence` reports the document on screen. Once the workspace moves
on there is no `Loaded` left to carry it, so a decision that could not be made
durable is moved to `unsavedAdjustments` — the file, the adjustment, and whether
the render or the write refused — and logged.

That list is the difference between "the edit is not on disk" and "the edit is
gone and nobody said so". It is normally empty: a successful save adds nothing
to it.

The UI shows the most recent entry as a small warning beside the orientation
controls. It does **not** show `.pending`: a save follows a render that normally
takes well under a second, so an indicator for it would flash on every rotation
and tell the user nothing they can act on. The pending state exists where
correctness needs it, not where it would only flicker.

## Decision 5 — The close boundary: what exists, and what waits

There is no document lifecycle in this application yet — one window, one
`DocumentState`, no close hook, no termination handler. So this ADR does not
invent one.

**What is guaranteed today:** leaving a file does not lose a decision whose
render was still running, and any decision that could not be made durable is
recorded and reported.

**What is not:** quitting the application, or the process ending, while a render
is in flight. That decision is lost, and nothing can currently observe the
moment to prevent it.

What this milestone does provide is the seam. `hasUnsettledAdjustments` answers
"is any decision still on its way to disk" for the open document and every
settling one, in one question with one answer. A real close guard — whenever
there is a real document lifecycle to hang it on — waits on that rather than
reconstructing it from render slots and status cases.

## Decision 6 — Two documentation corrections

**`.atomic` is a replacement, not a durability promise.** ADR 0013 said a crash
or a full disk leaves either the whole previous record or the whole new one.
Foundation promises nothing of the kind. What `Data.write(to:options:
[.atomic])` does is write to a temporary file beside the target and rename it
over, which means nothing ever observes a half-written record at the sidecar's
path and a write that fails partway leaves the previous record where it was.
That is what the code and ADR 0013 now say.

**`ImageAdjustments.isIdentity` is not "the user decided nothing".** It said so,
and that stopped being true the moment identity became a persisted value: a
reset is a decision, it is written to the sidecar, and a saved identity record
is a user's choice. The property compares the adjustment with the identity, and
its documentation now says only that.

## Consequences

- The workspace never reports a state as saved unless exactly that state is
  durable.
- A rotation made a moment before switching files still reaches its own
  sidecar, under its own URL.
- A decision that cannot be made durable is visible instead of silent.
- A late render from an earlier open cannot install into a later one, even for
  the same file.
- Two scene-linear sources and two renders can overlap briefly during a switch.

## What this does not decide

- **Quitting with a render in flight.** See Decision 5.
- **Reopening a file that is still settling.** The new open reads the sidecar
  before the settling write lands, so the workspace can show the older state
  while the newer one reaches disk a moment later. Nothing is corrupted and
  nothing is lost — the next open shows the saved state — but the two disagree
  for the length of one render. Fixing it means making an open wait for its own
  file to settle, which is the deferred-switch design Decision 2 rejected for
  the general case and may be worth it for this specific one.
- **Retrying a failed write.** There is no retry engine; the next successful
  adjustment writes again.
- **Anything about preview cost.** Full-resolution renders, no cache, no
  reduced-resolution path: unchanged, and still the open question.
