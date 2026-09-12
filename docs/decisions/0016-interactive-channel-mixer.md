# 0016 — The interactive infrared channel mixer

Status: accepted
Date: 2026-09-13

> Numbering note: `CLAUDE.md` used `0016-metal-render-pipeline.md` as an
> illustrative example of a future ADR filename. This milestone is the decision
> that actually took number `0016`, so that illustrative example now reads
> `0017-metal-render-pipeline.md`. ADR numbers follow the order decisions are
> made; no ADR was renamed.

## Context

[ADR 0007](0007-infrared-channel-mixing.md) built the creative channel-mix
stage and called the red/blue swap "the canonical first infrared creative
operation". A user could not perform it.

```text
IRChannelMix            existed: identity, redBlueSwap, explicit(matrix:)
IRChannelMixer          existed: three exact paths, provenance, refusals
a way to choose one     did not
```

The application chose `.identity` once, inside `prepare`, and nothing could
ever choose anything else. The project's stated differentiator was a constant.

Two things stood in the way, and only one of them was the user interface.

**The retained buffer was already mixed.** ADR 0015 reduced the working-colour
image to preview resolution and then applied `WorkspacePreviewPipeline.initialMix`
before retaining the result:

```text
prepare   … → convert → reduce → mix(.identity) → RETAIN
render    retained mixed preview → orientation → display
```

`IRChannelMixer` correctly refuses to mix an already-mixed preview, because
mixes must never compose (ADR 0007, Decision 27). So the retained value was
exactly the one value a new mix could not be applied to. Changing the mix would
have had to re-decode, re-normalise, re-balance, re-demosaic, re-convert and
re-reduce the whole file — the full-resolution work ADR 0015 had just removed.

**`ImageAdjustments` had one field.** The mix had no persisted representation,
so a choice would have survived neither a file switch nor a session.

## Decision

**The creative channel mix becomes a canonical user adjustment. The workspace
retains the pre-mix reduced preview, and the mix moves from `prepare` to
`render`.**

```text
prepare   decode → normalise → balance → demosaic → convert → reduce
          → RETAIN the pre-mix reduced preview

render    retained pre-mix preview
          → IRChannelMixer          adjustments.channelMix
          → ImageOrienter           file orientation + adjustments.orientation
          → DisplayPreviewRenderer
```

Seven parts, each decided separately.

### 1. What the workspace retains is pre-creative

`WorkspacePreviewPipeline.Source` holds a `SceneLinearPreviewImage` that has
been reduced and nothing else. It is the last state before the first creative
stage.

The alternative that was rejected is subtler than it looks. Retaining an
identity-mixed buffer costs **no memory** — the identity path hands the same
immutable array back, and copy-on-write shares it — so the choice is not about
bytes. It is about what a later mix can be applied to. A mixed buffer admits
only composition, and composition is the one thing this stage may not do:

```text
new result = M2 × the pre-mix preview
       NOT   M2 × (M1 × the pre-mix preview)
```

Two swaps in a row would otherwise cancel, and a swap followed by a collapse
would be neither operation. Nothing about that result looks malformed — it is
simply a different rendering from the one the user asked for.

### 2. The invariant is structural, not checked

ADR 0015 gave the reduced domain **one** image type with an optional
`mix: IRChannelMix?`, and protected the rule with two runtime guards:
`IRChannelMixer` refused a preview that already carried a mix, and
`ImageOrienter` refused one that did not.

That was adequate while the mix ran once and was never replaced. It stops being
adequate when the mix is an adjustment: both states are then live in one call
graph on every interaction, several times a second, and a runtime refusal on
that path is one refactor away from being a composed matrix on screen.

So the reduced domain now has two types:

```text
SceneLinearPreviewImage        reduced, PRE-mix    ← retained
IRChannelMixedPreviewImage     reduced, post-mix   ← one render long
```

`IRChannelMixer.apply` accepts the first and returns the second.
`ImageOrienter.apply` accepts the second. There is no overload through which a
second mix can reach a mixed preview, and none through which an unmixed one can
reach the geometry stage. Neither mistake compiles.

Two consequences follow, and both are deliberate:

- **Two `PreviewReductionError` cases were removed.**
  `channelMixAlreadyApplied` and `channelMixNotApplied` describe states that no
  longer exist, and an error case for an impossible state is a claim about
  nothing. `IRProcessingError.channelMixWorkingColorSpaceMismatch` is
  deliberately **not** treated the same way: it is unreachable because one
  working space exists today, and it becomes reachable the day a second one
  does.
- **Two tests were removed, and could not be rewritten.** They constructed the
  two refused calls in order to assert that they were refused. Neither
  compiles now. What replaced them is the positive claim — two mixes of one
  source are each applied to the unmixed values, and two swaps of one source
  are the same rendering rather than the identity.

This reverses ADR 0015's "one type, one optional" in the light of what the
milestone after it actually needed. The cost is one image type's worth of
duplicated geometry accessors, which is what every other stage in this project
already pays.

### 3. The mix is a field of the one canonical adjustment record

```swift
struct ImageAdjustments {
    var orientation: UserOrientationAdjustment
    var channelMix: UserChannelMixAdjustment
}
```

`UserChannelMixAdjustment` is a separate type from `IRChannelMix`, for the same
reason `UserOrientationAdjustment` is separate from `RAWImageOrientation`: one
is an editing decision and the other is a processing instruction, and a
signature that accepted either would let them be confused exactly once.

```text
UserChannelMixAdjustment    .identity | .redBlueSwap | .explicit(matrix)
        ↓  derived, computed, never stored
IRChannelMix                working space + 3×3 matrix + provenance
```

Persisting `IRChannelMix` directly was considered and rejected on two counts.
It would put the working colour space on disk, inviting a sidecar that selects
one when the project has exactly one by invariant (ADR 0006). And it would put
a matrix on disk beside a provenance token, so a record could say
`redBlueSwap` and carry coefficients that are not the swap — a publicly
constructible value that does not round-trip, which is the modelling error ADR
0010 already corrected once for `schemaVersion`.

`.explicit` exists in the model and has no editor. It is what makes the
persisted format able to express the mix the processing stage can already
apply, and adding it later would have cost another schema version.

### 4. One render request is one complete state

`render` takes a `Source` and one `ImageAdjustments`. It is never asked for "the
new mix" or "the new rotation".

That is what makes ADR 0011's coalescing cover both controls with no second
scheduler. A burst across both collapses to its newest member:

```text
mix swap        → A1
rotate right    → A2
mix identity    → A3
rotate right    → A4    ← the only state installed, and the only state saved
```

`DocumentState.adjust(_:)` is the single path every control goes through: it
changes the record, sets `.pending` in the same assignment, and requests a
render of the whole record. There is no per-field request, no per-field
persistence, and no queue.

### 5. Ordering: colour, then geometry, then encoding

```text
reduced working RGB  →  channel mix  →  orientation  →  display encode
```

The mix and the orientation commute in principle — a per-pixel colour map and a
whole-pixel permutation cannot interfere, and a test asserts that they agree
either way round. The order is still fixed, for two structural reasons: the
orientation stage is where the provenance chain is assembled, and the display
stage is the first point at which a value stops being proportional to light. A
colour operation after either would be a different kind of claim.

### 6. Persistence: schema version 2, and a real migration

```text
v1    orientation
v2    orientation, channelMix
```

The channel mix changes the rendered image, so it arrived with a version of its
own rather than as an optional field inside version 1. That is ADR 0010's
forward-compatibility rule applied for the first time rather than merely
written down: a build that reads only version 1 refuses a version 2 record
outright rather than opening it with no mix, rendering a different photograph
and then writing the field away.

Reading version 1 is a **migration**, not a default:

```text
v1 record  →  orientation as written, channelMix = .identity
```

Version 1 predates the creative stage, so a version 1 record describes a
photograph that was rendered with no remapping. Identity is the state it was
actually saved in, which is why this is not a guess about a missing field. A
migrated record is written back as version 2 the next time it is saved.

A version 1 record that nonetheless carries a `channelMix` key is **refused**.
It is self-contradictory, and reading around the field would break the rule in
the one direction that destroys data.

The wire format:

```json
{
  "schemaVersion" : 2,
  "orientation" : "rotate90Clockwise",
  "channelMix" : { "kind" : "redBlueSwap" }
}
```

```json
{ "kind" : "identity" }
{ "kind" : "redBlueSwap" }
{ "kind" : "matrix", "matrix" : [ 0, 0, 1, 0, 1, 0, 1, 0, 0 ] }
```

- A keyed object rather than a bare string, because one of the three cases
  carries data and a format that changes shape between cases is worse than one
  that always has a `kind`.
- The tokens are `UserChannelMixAdjustment.Kind.rawValue`, so there is one list
  of them. They are a wire format: changing one is a breaking change.
- A built-in persists as its token **alone**. Its nine numbers are derived from
  the token, and two authorities for one matrix is how a record comes to
  disagree with itself.
- The matrix is nine `Double`s, **row-major**, in `RAWColorMatrix3x3`'s own
  convention. Any other count is refused; a non-finite coefficient is refused.
- The working colour space is not written. See Decision 3.
- Encoding is deterministic: sorted keys, and the same state produces the same
  bytes.

Four new typed refusals carry those rules across the file boundary:
`unknownChannelMixKind`, `missingChannelMixField`,
`malformedChannelMixMatrix`, `nonFiniteChannelMixCoefficient`. A fifth,
`unexpectedAdjustment`, is the mirror image of `missingAdjustment` and is what
refuses a version 1 record carrying a version 2 field. None of them recovers to
identity, for the reason ADR 0013 Decision 5 gives.

### 7. The default is identity, and nothing infers infrared

A file with no saved decision gets `.identity`. Not the red/blue swap, however
much this is an infrared application:

```text
what the application knows      a RAW file, its metadata, its sensor data
what it does not know           whether this photograph is an infrared capture
```

There is no filter metadata, no camera-conversion database and no filename
heuristic in this project, and swapping a visible-light frame's channels would
simply be wrong. The swap is creative user intent. `initialChannelMix` on
`WorkspacePreviewPipeline` is the one place the default is stated, and it is
stated as the initial value of an adjustment rather than as a fallback inside a
processing stage — no processing entry point has a default mix, and none gained
one here.

## Cancellation

The mix is now on the interactive path, so it follows ADR 0011's contract like
every other stage there: one poll before anything is allocated, one per row,
`CancellationError` on refusal, and never a partially written buffer. All three
execution paths poll, the identity path included — its finiteness sweep is
per-row cancellable rather than reading a whole frame before noticing.

`SceneLinearPreviewReducer`'s pass-through path was corrected in the same way,
and for the same reason. Its documentation claimed one poll before allocation
plus one per destination row; the path taken by an image already within the
preview limit performed only the first, then swept the whole buffer. The sweep
now polls per row, so the documented granularity is true on both paths rather
than on one.

## What a change of mix costs

Nothing above the retained buffer runs again:

```text
does NOT rerun    RAW decode, normalisation, white balance, demosaic,
                  camera → working transform, preview reduction
does rerun        channel mix, orientation, display encode
```

On the E-PL3 fixture that is one pass over 3.1 megapixels rather than a decode
and six full-resolution stages over 12.3. A counting decoder proves it: an open
followed by four adjustments across both controls reads the file exactly once,
and the diagnostic LibRaw decode exactly once.

## Consequences

- The project's stated differentiator is a control a person can use. The
  red/blue swap is one click, survives the session, and is recorded as creative
  intent rather than as calibration.
- The retained source is pre-creative, so every future per-pixel adjustment in
  the working space — exposure, contrast, tone, saturation, false colour —
  lands in `render` beside the mix rather than forcing a re-prepare.
- Mixes cannot compose, and that is now a property of the types rather than of
  two runtime guards and a comment.
- The sidecar has a second version and a tested migration path, so the
  forward-compatibility rule has been exercised rather than assumed.
- `ImageAdjustments.isIdentity` now means "no net effect on the image" across
  the whole record. It never meant "the user decided nothing" (ADR 0014,
  Decision 6) and it still does not.
- The persistence rules are untouched. A state is written only after exactly
  that state has rendered; a superseded render writes nothing; a failed render
  writes nothing and leaves the previous record; a failed write does not
  withdraw the image; a document the workspace leaves keeps its render slot to
  write its own sidecar; two generations of one file are serialised. What
  changed is only that the record being written has two fields.

## Non-goals

Not in this milestone, deliberately:

- **A matrix editor.** `.explicit` is persistable, applicable and testable, and
  there is no user interface that produces one. Per-channel percentage sliders
  are a separate design question.
- **Automatic infrared detection.** See Decision 7.
- **Presets, recipes and filter profiles.** A recipe references camera,
  capture-configuration and filter profiles by stable identity, and none of
  those exist. When they do, they produce `UserChannelMixAdjustment` values and
  hand them to the same render.
- **Hue remapping, false-colour LUTs, Aerochrome and CandyChrome renderings.**
  All are separate operations, not this 3×3 one.
- **White-balance, exposure or tone controls.** White balance in particular
  cannot be interactive on this architecture: it is a mosaic-domain operation,
  upstream of the reduction, and changing it re-prepares from the file (ADR
  0015).
- **Export**, full-resolution rendering, zoom, crop, and any GPU path.
- **Undo/redo.** The adjustment is a canonical state, not a history, and a
  history is a separate decision.

## Amendment (2026-09-13) — schema-v2 hardening

Two defects in Decision 6 were found before a third schema version was added,
and both were fixed first, because both would have become data-loss paths the
moment one was.

### Schema dispatch is exhaustive

The migration dispatched the version as a bare `Int`:

```text
switch version {
case 1:    migrate
default:   decode as version 2
}
```

Its comment claimed that adding version 3 would be a compile error there. It
would not: `default` catches 3, and every version 3 record would have been
decoded by version 2's rules — with any version 3 field silently ignored, and
then written away on the next save.

The version is now converted to a closed internal type before anything is
decoded:

```text
raw Int
  → refuse below PersistedSchemaVersion.first
  → refuse above PersistedSchemaVersion.current
  → PersistedSchemaVersion(rawValue:)
  → exhaustive switch, no default
```

```swift
enum PersistedSchemaVersion: Int, CaseIterable {
    case orientationOnly = 1
    case channelMix = 2
}
```

`currentSchemaVersion` is derived from `PersistedSchemaVersion.current`, so the
version written and the set of versions read cannot disagree. Adding a case is
a compile error in the migration until someone decides what that version's
record contains. A test pins the set as exactly `1...current` with no gap and
`current` as its highest member, and a second test decodes each version's own
minimal record through its own branch.

### A built-in mix carrying a matrix is contradictory, and refused

The wire format in Decision 6 says a built-in persists as its token **alone**.
The decoder enforced that when writing and not when reading:

```json
{ "kind" : "redBlueSwap", "matrix" : [ 9, 9, 9, 9, 9, 9, 9, 9, 9 ] }
```

decoded as the swap, with the nine numbers silently ignored. That is the
"record that disagrees with itself" Decision 3 was written to make
unrepresentable, accepted at the one boundary where it can still arrive.

The table is now enforced in both directions:

```text
identity    + matrix            refused   unexpectedChannelMixField
redBlueSwap + matrix            refused   unexpectedChannelMixField
matrix      without matrix      refused   missingChannelMixField
matrix      wrong count         refused   malformedChannelMixMatrix
matrix      non-finite          refused   nonFiniteChannelMixCoefficient
```

A built-in carrying a matrix is refused whatever the coefficients are, the
built-in's own included; ignoring them and trusting them are both guesses. Only
the `matrix` key is policed inside `channelMix`, because it is the one that
contradicts the token. Unknown keys elsewhere in the record remain subject to
the forward-compatibility rule, unchanged.
