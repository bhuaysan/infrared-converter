# 0013 — The user's adjustments live in a sidecar beside the RAW file

Status: accepted
Date: 2026-09-12

## Context

ADR 0010 built a serialisable, versioned `ImageAdjustments` record and
deliberately stopped short of writing it anywhere:

```text
1. a serialisable adjustment model     existed
2. in-memory ownership                 existed
3. durable on-disk persistence         did not
```

Closing a file, or quitting, lost every decision the user had made. The model
was already the hard half — canonical states, stable tokens, typed refusals, a
schema version that is wire-format metadata rather than settable state — so
what remained was where the bytes go, when they are read, and when they are
written.

This ADR decides only that. It does not introduce a recipe format, a preset
system, a catalogue, an autosave engine or a new adjustment.

## Decision 1 — The RAW file is an immutable input

Nothing in this application writes to a RAW file. Not EXIF, not embedded XMP,
not an appended block, not a temporary replacement, and nothing through LibRaw,
which is opened read-only for decoding and never for writing.

```text
RAW file      an immutable input
sidecar       application-owned; every user decision lives here, and only here
```

This is not a new rule — it is stated in `CLAUDE.md` as a project invariant —
but this is the first milestone that could have broken it, so it is restated
where the writing code lives and tested where the writing happens. The store's
suite asserts that the RAW file's bytes, size and modification date are
unchanged after loads, saves and refusals.

## Decision 2 — One JSON sidecar per photograph, named by rule

**The RAW file's complete name, plus `.iradjustments.json`, in the RAW file's
own directory.**

```text
/Pictures/IR/OLYMPUS.ORF
/Pictures/IR/OLYMPUS.ORF.iradjustments.json
```

The full name, extension included — not the base name — so `SCENE.ORF` and
`SCENE.ARW` in one folder keep separate records instead of fighting over one.

`JSONSidecarImageAdjustmentStore.sidecarURL(for:)` is the only expression of
that rule anywhere in the project. A naming rule spelled out in several places
is a rule that eventually disagrees with itself.

What the form was chosen for:

```text
deterministic     derived from the RAW URL alone; there is no index to consult
non-colliding     a distinct extension; it can never name a RAW file
local             no central database, and no hidden cache that outranks it
visible           a user can see it, copy it, back it up, and delete it
```

It is deliberately **not** XMP. XMP is an interchange format, and writing one
would claim an interoperability nothing here implements. It is equally not a
recipe: a sidecar is the state of *this* photograph, while a recipe is a
reusable set of choices that also references camera, capture-configuration and
filter profiles by stable identity — none of which exist yet.

The wire format is `ImageAdjustments`' own `Codable` conformance, not a
parallel DTO:

```json
{
  "orientation" : "rotate90Clockwise",
  "schemaVersion" : 1
}
```

Sorted keys and indentation, because a user is expected to be able to open this
file and recognise what it says. Sorting also makes the bytes deterministic for
a given record, which the tests assert semantically rather than byte-for-byte —
the format is the two fields and their values, not an arrangement of
whitespace.

## Decision 3 — A narrow store, behind a protocol

```swift
protocol ImageAdjustmentStore: Sendable {
    func load(for rawURL: URL) throws(ImageAdjustmentPersistenceError) -> ImageAdjustments?
    func save(_ adjustments: ImageAdjustments, for rawURL: URL) throws(ImageAdjustmentPersistenceError)
}
```

Two operations, one photograph at a time, and no more. `DocumentState` does not
know that adjustments are JSON or that they are files; a test can substitute an
in-memory store; a future migration happens behind this line rather than inside
the workspace state.

There is no `remove`. Decision 6 makes identity an ordinary saved value, so
nothing in the application has a reason to delete a sidecar, and an unused
delete path on a user's files is not something to carry speculatively.

The throws are typed. The refusals this layer reports are the whole point of
it, and `any Error` at this boundary would be the same flattening the project
already refuses elsewhere.

## Decision 4 — Saved adjustments are read before anything is decoded

```text
load sidecar → prepare RAW → initial render WITH the loaded adjustments → .decoded
```

Not:

```text
prepare → render identity → show it → load sidecar → render again
```

The second order is wrong in four separate ways, and three of them are visible
to a user: a photograph they did not ask for appears and then changes; a full
frame is permuted and encoded twice; and a saved rotation arrives as a late UI
event rather than as part of the document's opening state.

The invariant is instrumented rather than asserted in prose. The workspace's
store, decoder and render seam share an event log, and the test for a file with
a saved quarter turn asserts the whole sequence:

```text
[.loadedAdjustments(.quarterTurnRight), .decodedMosaic, .rendered(.quarterTurnRight)]
```

Exactly one render, with the loaded state, after exactly one decode. An
identity render anywhere in that list fails the test.

The render is injected into `DocumentState` for this reason — so an open's
renders can be counted and one can be made to refuse. Production passes
`DocumentState.pipelineRender`, which is the pipeline's own second half.

## Decision 5 — No sidecar is `ImageAdjustments.none`; an unreadable one is not

```text
no sidecar                → ImageAdjustments.none, a perfectly ordinary open
sidecar, unreadable       → the open stops, with a typed error
```

`nil` from `load` means exactly one thing: no record exists. It is never a
recovery value, and nothing else in the persistence layer may become `.none`.

An unsupported schema version, an unknown orientation token, a missing required
field, malformed JSON, an unreadable file — none of them is repaired, deleted,
or defaulted. Rendering the photograph with no adjustments would look exactly
like success while silently discarding the user's decisions, and the next save
would then overwrite the unreadable record with the substituted one and destroy
it for good.

So the open stops, and the state says which problem it was:

```text
DocumentOpenError         the photograph could not be read
                          → the RAW file, or this application's support for it

DocumentAdjustmentError   the photograph is fine; the saved edits are not
                          → one small JSON file beside it, which the user owns
```

`Status.adjustmentsUnreadable` is a separate case from `Status.failed` for that
reason: folding the two together would tell a user their RAW file failed to
decode when nothing of the kind happened, and would hide the one file they can
actually inspect, move aside or restore from a backup. The typed refusal
survives both boundaries — the file's and the document's — so a caller can
still ask whether the record came from a newer build.

Nothing is decoded before this refusal. The expensive path never starts.

## Decision 6 — Identity is stored, not implied

`ImageAdjustments.none` is written like any other value, and the store never
deletes a sidecar.

The alternative — identity removes the file, so "no sidecar" means "no
adjustments" — is tempting and was rejected. A reset is a decision. "The user
reset this photograph" and "the user never adjusted this photograph" are
different facts, and the file is what tells them apart. Deleting a file a user
can see, as a side effect of pressing Reset, is also a larger action than
anything else in this milestone, and it would make Reset the only control that
removes something from disk.

The cost is a small JSON file for a photograph whose net adjustment is nothing.
That is a file, not a loss.

## Decision 7 — A state is saved only once it has rendered, and only if still current

```text
user presses rotate
    → adjustment recorded in memory, controls update immediately
    → render runs
    → render succeeds and is still wanted
    → preview installed
    → sidecar written
```

Two rules fall out of where that write sits, and both are tested:

- **A superseded render never persists.** The save is inside the same guard
  that stops a stale render reaching the screen — the delivered adjustment must
  still equal the requested one — so a render that lost its race can no more
  write the sidecar than it can install its image. A burst of presses in one
  main-actor turn produces exactly one save, of the settled state.
- **A failed render never persists.** The sidecar keeps the last state that
  actually rendered. Writing an unrenderable state would restore a broken
  workspace on the next launch, automatically, with no way for the user to see
  why.

`CoalescingPreviewRenderer` is untouched. Persistence rides on the guarantees
it already provides rather than adding scheduling of its own: one render in
flight, a burst collapsing to its newest member, a cancelled render never
delivered.

## Decision 8 — Writing is atomic, and a write failure is not a render failure

`Data.write(to:options: [.atomic])`: Foundation writes the bytes to a temporary
file beside the target and renames it over. What that buys is the
**replacement** — nothing ever observes a half-written record at the sidecar's
path, and a write that fails partway leaves the previous record where it was.

It is deliberately not described as a durability guarantee. Foundation promises
nothing here about flushing to the device, so an earlier phrasing of this
decision ("a crash or a full disk leaves either the whole previous record or the
whole new one") claimed more than the mechanism does. Corrected in ADR 0014.

A save that fails does **not** withdraw the image:

```text
render success        the image on screen is correct
persistence failure   the durable copy is missing
```

Rolling the preview back would answer the second by lying about the first. The
failure is reported instead — `Loaded.persistence` carries the typed error, and
the workspace shows a small "Adjustments not saved" warning while it stands.
There is no retry engine and no queue: the user's next successful adjustment
tries again, which is what their next action does anyway.

The write is synchronous, on the main actor. It is one atomic replacement of a
few hundred bytes, and there is exactly one place that writes, so ordering is
correct by construction. Moving it off the main actor would buy nothing
measurable and would need its own guard to stop an older save landing after a
newer one.

## Decision 9 — The forward-compatibility rule is unchanged, and now matters

ADR 0010's rule was written for the day a sidecar exists. This is that day:

**Any new persisted setting whose omission would change the rendered image
requires a new schema version, and an older client must refuse that version
rather than read around it.**

An older build that silently ignored a newer `exposureEV` would open the file,
render a different photograph from the one the user saved, report no problem,
and then write the record back without the field — destroying the edit.
`ImageAdjustments.init(from:)` already refuses a version above the one it
writes; this milestone gives that refusal a file to refuse.

Nothing about the schema changed here. It is still `schemaVersion` and
`orientation`, and version 1.

> Extended by [ADR 0014](0014-adjustment-lifecycle.md), which models the
> interval between a decision and its write, and stops a decision from being
> discarded when the user opens another file mid-render. The rules in Decision
> 7 are unchanged by it.

## Consequences

- A rotation survives closing the file, and survives quitting the application
  once its render has finished. (ADR 0014 states the boundary exactly: leaving
  a *file* mid-render is safe; quitting mid-render is not.)
- Every user decision lives in one visible file per photograph, which a user
  can back up, copy beside the RAW file, or delete to start over.
- A sidecar this build cannot read stops the open, loudly, and is left exactly
  as it is on disk.
- Opening an adjusted file costs one render, not two.
- `DocumentState` gained an injected render seam, which is what makes the
  "exactly one render" and "a failed re-render persists nothing" claims
  testable.
- Still absent, deliberately: recipes and presets, any adjustment other than
  orientation, undo/redo, export, batch processing, watching the sidecar for
  external edits, and any store other than the JSON one.

## What this does not decide

- **The recipe format.** A sidecar is one photograph's state. A reusable recipe
  references camera, capture-configuration and filter profiles by stable
  identity, and none of those exist.
- **What happens when a sidecar changes underneath an open document.** Nothing
  watches the file. The last save from this application wins.
- **Where sidecars live for a read-only volume**, or whether an alternative
  location should ever exist. Today a save simply fails and says so.
- **Migration.** There is one schema version, so there is nothing to migrate
  yet; `ImageAdjustments.init(from:)` is where a migration becomes visible when
  there is.
