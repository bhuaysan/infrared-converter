# 0010 — User-owned orientation adjustment

Status: accepted
Date: 2026-09-11

> Numbering note: `CLAUDE.md` uses `0010-metal-render-pipeline.md` as an
> illustrative example of a future ADR filename. This milestone is the decision
> that actually took number `0010`, so that example now reads
> `0011-metal-render-pipeline.md`. ADR numbers follow the order decisions are
> made; no ADR was renamed. This is the fourth time that example has moved, for
> the same reason it moved the first three times.

## Context

[ADR 0009](0009-application-owned-orientation.md) gave the pipeline an
orientation stage and had it read the file's metadata and nothing else. It
listed, under what it did not decide:

> **A user-facing orientation control.** The workspace reads metadata; nothing
> lets a person override it yet.

This is that decision.

It has a concrete motivating case. The Olympus E-PL3 reference fixture is a
cityscape taken with the camera turned, and the body wrote EXIF/TIFF tag 274
as `1` — the tag is physically present in IFD0, a `SHORT` of count 1 at file
offset `118`, which a test reads from the file's bytes rather than inferring
from LibRaw's `flip == 0`. Metadata will therefore never make that photograph
upright. Only a person can.

## Decision 1 — Three concepts, three types, none collapsed

```text
recorded / decoder orientation      RAWMetadata.Geometry.orientation
            +
user orientation adjustment         UserOrientationAdjustment
            =
effective orientation               EffectiveImageOrientation.applied
```

The source orientation is an **immutable fact about the input**. Nothing in
the adjustment path can write to it: rotating the image does not change
`RAWMetadata.Geometry.flip`, and a test asserts that after every operation.
Writing a user's rotation back into metadata would make an editing decision
look like something the camera said, and the file would then have no record
of what it actually recorded.

The adjustment is an **application-owned editing decision**. The effective
orientation is **derived**, never stored as a third independent field, so the
three can never disagree.

A caller holding an `OrientationProvenance` can answer all three questions:
what did the decoder report, what did the user request, and what was applied.

## Decision 2 — The adjustment is a distinct type wrapping a shared algebra

`UserOrientationAdjustment` holds one `RAWImageOrientation` and is
deliberately not one.

The **type** is separate because a signature that accepted either would allow
the two to be confused exactly once, quietly, in the direction that matters.
The **algebra** is shared because there is only one algebra: both are elements
of the same eight-element group, and a second implementation of composition
would be a second thing to keep correct.

So the group element is wrapped, not re-derived.

## Decision 3 — Composition, and the order

`RAWImageOrientation.composed(with:)` means **apply the receiver first, then
the argument**:

```swift
a.composed(with: b)     // do a, and then do b to the result
```

The derivation is therefore:

```swift
effective = source.composed(with: userAdjustment.transform)
```

Source first. The file's own orientation is what makes the stored pixels
viewable as the camera intended; the user's correction is applied to what they
are looking at. Pressing "rotate right" turns the picture on screen a quarter
turn clockwise, not the sensor readout, and that is only true in this order.

It genuinely matters, because composition does not commute once reflections
are involved:

```text
transposed         then rotated90Clockwise  =  mirroredHorizontally
rotated90Clockwise then transposed          =  mirroredVertically
```

Both results are valid orientations and neither looks broken. Rotations, by
contrast, commute with each other — so a test built only from quarter turns
would pass with the arguments swapped and prove nothing about the convention.
The suite therefore pins the order with reflected examples.

## Decision 4 — The arithmetic is integer, on the canonical decomposition

Every orientation is written as "mirror horizontally if needed, then turn some
number of quarter turns clockwise":

```text
orientation = R^k ∘ M^m        R = quarter turn clockwise, M = horizontal mirror
```

| | `isMirrored` | `quarterTurnsClockwise` |
| --- | --- | --- |
| `upright` | no | 0 |
| `rotated90Clockwise` | no | 1 |
| `rotated180` | no | 2 |
| `rotated270Clockwise` | no | 3 |
| `mirroredHorizontally` | yes | 0 |
| `transverse` | yes | 1 |
| `mirroredVertically` | yes | 2 |
| `transposed` | yes | 3 |

A mirror reverses the sense of a rotation it passes — `M R = R⁻¹ M` — so
composition collapses to two integer operations:

```text
mirrored = mA XOR mB
turns    = (kB ± kA) mod 4,   minus when B is mirrored
```

No floating-point matrices, and no 64-entry lookup table to mistype. Inverses
follow: the four reflections are their own inverses, and the two quarter turns
invert to each other.

The mirrored half of that table is the part worth checking rather than
trusting. A horizontal mirror followed by **one** quarter turn clockwise is
`transverse`; **three** gives `transposed`. Swapping those two is invisible on
a symmetrical subject.

## Decision 5 — The tests do not check the algebra against itself

All 64 composition pairs are validated twice, against two oracles that know
nothing about the composition arithmetic:

- **pixels** — apply A with `ImageOrienter`, apply B to the result, and
  compare with applying `a.composed(with: b)` once, on an asymmetric image in
  which every pixel is uniquely identifiable;
- **coordinates** — compose the two destination-to-source mappings by hand on
  a deliberately non-square 7 × 3 grid.

The canonical decomposition table above is likewise derived from pixel
behaviour rather than asserted. Identity from both sides, inverses from both
sides, quarter-turn cycles, half-turn cycles, reflection involutions,
associativity over all 512 triples, closure, and explicit non-commuting pairs
are covered.

This mattered: writing the suite caught four wrong entries in a hand-written
expectation table while the production arithmetic was right.

## Decision 6 — The adjustment is a canonical state, never a history

Every operation returns the **single orientation the whole sequence adds up
to**, because the eight are closed under composition:

```swift
UserOrientationAdjustment.identity
    .rotatedRight().rotatedRight().rotatedRight().rotatedRight()
    == .identity
```

Four rotate-rights persist as `"none"`, not as four commands. There is no
command log, no undo stack and no accumulated transform list, and this
milestone deliberately does not introduce one.

Two consequences follow, and both are tested:

- **The persisted form is bounded.** One of eight tokens, whatever the user
  did to get there.
- **Pixels are permuted exactly once.** The pipeline applies the effective
  orientation to the retained, **unoriented** channel-mixed image. It never
  orients an already-oriented buffer, so nothing accumulates and nothing
  degrades — a permutation is lossless, but repeating one is still the wrong
  answer.

## Decision 7 — Reset means identity, not upright

```text
reset       userAdjustment = .identity
NOT         effectiveOrientation = .upright
```

Those are different whenever the metadata itself specifies a rotation or a
reflection. A file recording a quarter turn, corrected by the user and then
reset, gets its quarter turn back — because that is what the file asks for and
the user has withdrawn their correction, not overridden it with upright.

The two coincide only for a file recording upright, which is exactly why the
distinction is invisible if only that case is tested. Every non-upright source
orientation is tested.

"Make the image upright whatever the file says" is a different operation, and
`EffectiveImageOrientation.adjustmentMakingUpright` is where it would come
from. No control offers it yet.

## Decision 8 — `ImageOrienter` learns nothing

The stage still takes one orientation and performs one permutation. It does
not know about buttons, adjustments, persistence or documents, and it does not
read mutable state.

The application layer derives the effective orientation and passes the result
in — exactly as it already passes a mix, a transform and display settings that
it chose.

## Decision 9 — Persistence: a serialisable model, in-memory ownership, no disk

Three layers, deliberately separated, and **only the first two exist**:

```text
1. a serialisable adjustment model     ImageAdjustments — exists, round-trips, tested
2. in-memory ownership                 DocumentState, per open file — exists
3. durable on-disk persistence         does not exist
```

There is no sidecar, no document format, no restore on relaunch. Opening the
same file again starts from `ImageAdjustments.none`. Claiming otherwise would
be the kind of thing a reader only discovers by losing work.

`ImageAdjustments` is a record rather than another property on `DocumentState`
because exposure, the white-balance choice, the channel mix, tone settings and
crop belong beside orientation rather than as more unrelated fields, and
because a recipe has to serialise as a **set** — "all of these together" is
the thing that gets reused across images.

It is deliberately **not** the `InfraredRecipe` format `CLAUDE.md` describes.
A recipe also references camera profiles, capture configurations and filter
profiles by stable identity, and none of those exist. Defining the whole
format now would mean versioning guesses about types that have not been
designed. Schema version `1` with one field is the honest amount of format to
commit to today, and it is versioned from the first persisted form onward —
the only time that is free.

## Decision 10 — The persisted form is semantic, and refusals are typed

An adjustment persists as one stable token:

```text
none  rotate90Clockwise  rotate180  rotate270Clockwise
flipHorizontal  flipVertical  transposeMainDiagonal  transposeAntiDiagonal
```

Not a case index or an `allCases` position — those break silently on a
declaration-order change, by reading as a different valid orientation. Not a
LibRaw `flip` bitfield — that is a third-party library's private encoding, and
persisting it would tie saved user edits to a decoder we may replace. Not an
EXIF code — that describes what a **file** recorded, which is the one thing
this type is defined not to be.

`ImageAdjustmentError` covers what can go wrong:

```text
unknownOrientationAdjustment   a token this version does not model
unsupportedSchemaVersion       above what this build reads, or below 1
missingAdjustment              a field the declared version requires
```

**Nothing recovers to identity.** Identity is a meaningful adjustment — it
means the user asked for no correction — so substituting it for a value we
failed to read would silently discard their edit and present the result as
their own decision. An unreadable record is reported, and the caller decides.
That is the same policy `RAWImageOrientation.init?(decoderFlip:)` applies to
an unmodelled decoder value, for the same reason.

A newer schema version is refused rather than partly applied, because it may
carry adjustments whose omission would change the image. An unknown *extra
field* at a readable version is ignored, which is what makes the record
extensible.

## Decision 11 — The pipeline splits in two, and retains the scene-linear state

```text
prepare(decoding:using:)       decode → normalise → estimate → balance
                               → demosaic → convert → mix        once per file
      ↓  WorkspacePreviewPipeline.Source        retained, unoriented
render(_:adjustments:)         effective orientation → ImageOrienter
                               → display encode                  once per change
```

Changing an adjustment reruns two stages. Nothing decodes, normalises,
white-balances, demosaics, converts or remixes again — the project's own
architectural red-flag list names "full RAW decode on every slider move" for a
reason.

The cost is real and is stated rather than discovered:
`IRChannelMixedProcessedRAWImage` reaches the working-colour image, the
camera-native image and both mosaics through its `source` chain, so a
4056 × 3040 frame retains roughly half a gigabyte of `Float32` buffers for as
long as the file is open. Reduced-resolution previews, caching and eviction
are all undecided; this is the simple thing, and nothing has measured it.

Renders are detached and the previous one is cancelled, so holding a key down
does not queue work. A late result whose adjustment has been superseded is
dropped rather than displayed.

## Decision 12 — No view transform

The controls change one adjustment value. No `rotationEffect`, no
`CGAffineTransform`, no `CGImagePropertyOrientation`, and no correction in the
view layer — for the reason [ADR 0009](0009-application-owned-orientation.md)
Decision 14 gives: a view transform would orient the picture on screen while
leaving every buffer, every test and every future export in sensor order.

## What this ADR does not decide

- **Arbitrary-angle rotation, straightening, crop and perspective
  correction**, and therefore any resampling or interpolation. This is still
  the eight discrete arrangements, applied as an exact permutation of whole
  pixels.
- **Durable persistence.** No sidecar, no document format, no relaunch
  restore.
- **The `InfraredRecipe` format**, profile identity, and reuse of a recipe
  across images.
- **Undo/redo history.** The adjustment is a state; an undo architecture is a
  separate problem and the canonical representation does not prejudge it.
- **Any other adjustment.** Exposure, white-balance choice, channel mix and
  tone remain fixed application-layer choices.
- **A "make upright" control**, as distinct from reset.
- **Export**, which has no stage at all and will need its own orientation
  decisions.
- **Preview resolution strategy, caching, eviction** and whether half a
  gigabyte of retained buffers is acceptable at more than one open file.

## Consequences

- A photograph can be corrected by hand, non-destructively, whatever its
  metadata says — including the E-PL3 fixture, which no metadata reading could
  ever have made upright.
- The file's recorded orientation remains readable and unchanged after any
  number of corrections.
- Orientation composition is trustworthy before it becomes persisted editing
  state, which was the point of testing it exhaustively first.
- The project has its first serialisable, versioned, user-owned adjustment
  model — one field wide, and shaped so the next adjustment is an addition
  rather than a redesign.
- Reprocessing costs one permutation and one encode instead of a decode.
- A full frame's scene-linear chain now stays resident while a file is open.

---

## Amendment (2026-09-12) — the schema version is wire-format metadata

Decision 10 above versioned the persisted form and specified typed refusals for
anything unreadable. It got one thing wrong, and the error was in the shape of
the type rather than in the policy.

`ImageAdjustments` stored `schemaVersion` and exposed it as a public
initialiser parameter, while `encode(to:)` always wrote
`Self.currentSchemaVersion`. So this compiled:

```swift
ImageAdjustments(orientation: .halfTurn, schemaVersion: 999)
```

and did not round-trip: a publicly constructible value encoded to something
that decoded back as a different value. Harmless while nothing is written to
disk. A corruption bug on the day a sidecar is.

### The correction

```swift
public init(orientation: UserOrientationAdjustment = .identity)

public var schemaVersion: Int { Self.currentSchemaVersion }
```

The version is **wire-format metadata, not user-settable application state**.
It is no longer stored and no longer nameable. A historical version exists
only inside `init(from:)`, for exactly as long as it takes to decide whether
this build can read it — which today is the only version it can. When a second
version arrives, that is where a migration becomes visible, and the decoded
version stops being discardable.

Round-tripping is now a property of the type rather than of careful callers:
there is no publicly reachable value that fails it.

### The forward-compatibility rule, stated

Decision 10 allowed a reader to ignore an unknown field, and a test pinned that
behaviour using `exposureEV` as the example. That example stated the wrong
contract, and it is corrected here.

```text
non-semantic field      may be added within a schema version, and ignored
                        a note, an author, a timestamp

image-affecting field   requires a schema-version bump
                        exposure, a channel mix, a crop, a curve
```

**Any new persisted setting whose omission would change the rendered image
requires a new schema version, and an older client must refuse that version
rather than read around it.**

The failure mode this forbids is quiet and complete. An older client that
ignored a newer `exposureEV` would open the file, render a different photograph
from the one the user saved, report no problem at all, and then write the
record back without the field — destroying the edit while looking like it
worked. That is the same class of failure as decoding a corrupt record into
"the user asked for nothing", which Decision 10 already refuses.

`init(from:)` already enforces the refusal. This rule is the instruction to a
future author about when to raise the number.
