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
- ~~**Reopening a file that is still settling.**~~ Decided in the amendment
  below: a reopen waits for its own file to settle before it reads the sidecar.
  The case turned out to lose a write, not merely to display a stale one.
- **Retrying a failed write.** There is no retry engine; the next successful
  adjustment writes again.
- **Anything about preview cost.** Full-resolution renders, no cache, no
  reduced-resolution path: unchanged, and still the open question.

---

## Amendment (2026-09-12) — a reopen waits for its own file

Decision 2 let every open proceed immediately and left one case under "What
this does not decide": reopening a file that is still settling. The entry said
the workspace would show the older state for the length of one render and
called it a disagreement, not a loss.

That was too generous. The same shape also loses a write:

```text
G1  A opened, quarter turn requested, render running
G2  A reopened → reads the sidecar (no record yet), renders identity
G2  user asks for a half turn → renders → writes rotate180
G1  settles → writes rotate90Clockwise
```

The sidecar ends up holding the older generation's state, and the screen holds
the newer one. Nothing reports a problem, because from each generation's own
point of view everything worked.

### The cause

Generation routing (Decision 3) protects the **preview**: a delivery can only
install into the generation it belongs to. It says nothing about the **sidecar**,
which is not addressed by generation at all. Two generations of one RAW file
share one destination, and both were free to write to it in whatever order
their renders happened to finish.

### The fix: serialise opens of the same file, and only those

```text
different file    the reopen starts at once; the previous document settles behind it
same file         the reopen waits until that file has no settling generation left,
                  and only then reads its sidecar and starts decoding
```

The rule follows the destination, not the document:

```text
two different RAW files      two different sidecars      no race       no waiting
two generations of one RAW   one shared sidecar          a real race   serialised
```

So the user-facing decision from Decision 2 is untouched where it matters.
Opening the *next* photograph never waits — that is the common case, and the one
that would feel broken. Reopening the file you just left waits for one render,
which is also the only case where waiting buys anything.

### What that makes structurally true

`settle` writes, releases the settling slot, and then starts the waiting open —
in that order, all on the main actor. The write has therefore already returned
before the next generation of that file reads anything. Two consequences follow
without a single comparison of generation numbers:

- **A generation never reads a sidecar that an older generation of the same
  file is about to change.** The first render of a reopen already carries the
  state the previous generation saved, so there is no identity render on the way
  to it and no moment at which screen and disk disagree.
- **An older generation can never overwrite a newer generation's save**, because
  the two are never live at the same time. The older one has finished and been
  released before the newer one exists as anything but a waiting request.

A "last writer generation" comparison guarding each write was considered and
rejected: it would leave both generations live and racing, and merely arbitrate
the collision after the fact. Removing the overlap removes the collision.

### The waiting open is one slot, newest wins

A deferred open is a URL and the generation it was given, and there is at most
one. A newer open replaces it, whatever file it names, so a superseded reopen
disappears without ever touching `status` — the generation it belongs to is no
longer the current one, and the resume path checks exactly that. Three reopens
of a settling file therefore produce one decode, not three, which is the same
collapsing rule the render slot already applies to a burst of presses.

A settling document always delivers: nothing cancels it, and its render slot
either has work in flight or work pending. A refused render frees the file just
as a successful one does — it records the lost decision and releases the slot —
so a waiting open cannot be blocked by a render that will never succeed.

### `hasUnsettledAdjustments` is now `hasPendingAdjustmentWork`

The old name suggested "there are adjustments that are not settled", which
reads as a close-safety predicate and is not one. Two states are equally not
durable and deliberately not counted, because nothing is in flight for them and
waiting would never make them safe:

```text
pending work        hasPendingAdjustmentWork
known unsaved work  .renderRefused, .saveFailed, unsavedAdjustments
```

A future close guard must consult both: the first says wait, the second says
tell the user. The name now says only what the property means.

### What this still does not decide

- **Quitting with a render in flight.** Unchanged, and still waiting for a real
  document lifecycle.
- **Two RAW files in different directories with the same name.** Sidecars are
  addressed by full URL, so they do not collide; nothing here changes that.
- **External writers.** Serialisation covers this application's own generations.
  Another process editing a sidecar is out of scope, as it was in ADR 0013.
