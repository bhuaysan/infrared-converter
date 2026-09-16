# 0026 — Linear levels: a black point and a white point

Status: accepted
Date: 2026-09-16

## Context

Before this decision the pipeline had exactly one tone-shaped control:
exposure, `× 2^EV`, applied in the linear domain by
[ADR 0017](0017-interactive-exposure.md). It is a *gain*, and a gain can only
move the whole scale at once. An infrared frame whose blacks sit at `0.08` and
whose useful highlights stop at `0.6` cannot be made to use the display's range
by exposure alone: lifting it to reach white also lifts the blacks, and the
picture gets brighter rather than fuller.

What was missing is the ability to say *where black is* and *where white is* —
the oldest and most mathematically explicit tone control there is, and the one
with the fewest hidden assumptions.

The stage also has to go somewhere the existing architecture did not have a
gap. `DisplayPreviewRenderer` applied exposure, clipped and encoded in one
fused pass. Levels must sit **after** exposure and **before** clipping, and
nothing can be inserted between two halves of one pass.

## Decision

**A black point and a white point become the fifth canonical user adjustment,
applied by a stage of their own between exposure and the destination, shared by
preview and export, and persisted at sidecar schema version 6.**

```text
ImageAdjustments
├── orientation     UserOrientationAdjustment
├── channelMix      UserChannelMixAdjustment
├── exposure        UserExposureAdjustment
├── whiteBalance    UserWhiteBalanceAdjustment
└── levels          UserLevelsAdjustment            ← new
```

### Decision 1 — The equation, and one authority for it

```text
span   = whitePoint − blackPoint
scale  = 1 / span                         computed once per image
output = (input − blackPoint) × scale     per component, in Double,
                                          narrowed to Float32 exactly once
```

Written in exactly one place, `LinearLevels`, for the reason
`SceneLinearExposure` exists: two consumers apply it, and two copies of a
numeric rule drift invisibly. An export that subtracted in `Float32`, or
computed the reciprocal per component rather than once, would look entirely
plausible and would not match the preview.

`scale` is a reciprocal and a multiply rather than a divide per component: one
rounding of the reciprocal, shared by every pixel, is what makes preview and
export agree bit for bit at the same input.

```text
black = 0.0, white = 1.0      0.0 → 0.0      0.5 → 0.5      1.0 → 1.0
black = 0.1, white = 0.9      0.1 → 0.0      0.5 → 0.5      0.9 → 1.0
                              0.0 → −0.125   1.0 → 1.125
```

Neutral — black `0`, white `1` — is a scale of exactly `1` and an offset of
exactly `0`, so it is the identity for every finite `Float32` including signed
zeros and subnormals. The stage's identity path hands its input's buffer back
rather than copying it.

### Decision 2 — Exposure precedes levels, and they are not folded together

```text
working RGB → channel mix → orientation → exposure → LEVELS
            → destination range policy → transfer function → quantisation
```

A gain and an affine remap could be composed into a single
gain-and-offset — and must not be. They are different decisions with different
meanings: exposure asks "how much light was there", levels ask "where are black
and white in the result". Folded together, each control would change what the
other one did, and neither slider would mean what its label says.

The order is what makes the labels true. `(2x − b)/(w − b)` is not
`2·((x − b)/(w − b))` for any `b ≠ 0`, so reversing the two stages is a visible
difference rather than a matter of taste.

Levels are equally not folded into the channel mix (a 3×3 matrix on colour
coordinates has no offset term, and giving it one would make a creative mix
carry a tone decision) nor into the destination's clipping policy (see
Decision 4).

### Decision 3 — The result is linear-light, and it is no longer scene-linear

This is the semantic cost of the offset, and it is carried in the type system
rather than in a comment.

```text
ExposedSceneLinearRGBImage   scene-linear: proportional to the light that
                             reached the sensor. Every stage above it is a
                             permutation, a matrix on colour coordinates, or a
                             gain — none of which moves the origin.

LeveledLinearRGBImage        linear-light: no transfer function has been
                             applied, nothing has been curved or compressed,
                             and the destination's transfer function is still
                             the next thing that will happen to it. But after
                             subtracting a black point it is no longer
                             proportional to scene radiance.
```

`LinearLevelsProcessing.sceneLinear` is therefore `false`, **including at
neutral levels and including at a black point of exactly zero**. A reader
asking "is this scene-linear data?" of a stage licensed to subtract an offset
should get one answer, not an answer that depends on the value.

The weaker, value-dependent fact is available separately and is *derived*
rather than stored: `preservesProportionalityToSceneRadiance` is true exactly
when `blackPoint == 0`, which makes the map the pure gain `x / whitePoint`.

Carrying the distinction in a type is the point. A future measurement, a
calibration fit or an exposure-invariant statistic can refuse this image in its
signature instead of trusting a caller to know.

### Decision 4 — Levels do not clip; the destination does

Nothing in the stage clamps, compresses, rolls off or normalises. A value the
equation pushes below `0` or above `1` reaches the destination's range policy
with its magnitude intact.

That is not tidiness — it is the whole point of a black point above zero. If
the stage clipped, the shadows it was asked to open would be destroyed by the
very operation that opened them, and a later change could not bring them back.

```text
black 0.1, white 0.9      −0.2 → −0.375       2.0 → 2.375
```

`DisplayRangePolicy.hardClipToDisplayRange` and
`ExportRangePolicy.hardClipToExportRange` remain the only authorities on
clipping, they remain downstream, and they continue to **count** what they
destroyed.

### Decision 5 — The supported domain is IEEE 754, not photography

```text
blackPoint finite
whitePoint finite
blackPoint < whitePoint
span and 1/span both representable
```

That is the whole rule, and no magnitude limit is imposed on either endpoint.
This pipeline carries extended values deliberately — black-subtracted noise
straddles zero, a creative mix with negative coefficients produces negative
coordinates, white balance and highlight headroom push values well above one —
so `black = −0.25, white = 2.0` is a useful setting rather than an error, and
`black = −1e300, white = 1e300` maps `1.0` to `0.5` correctly and is allowed.

The last clause is the only one that is not obvious, and it is not a margin
invented to feel careful. It rules out exactly two failures that a check on the
endpoints alone would let through:

```text
endpoints ~1e308 apart    the subtraction overflows, the scale becomes exactly
                          0, and every pixel renders black while every number
                          involved stays finite

endpoints ~1e-308 apart   the reciprocal overflows, and every finite input
                          becomes an infinity
```

Nothing is clamped, reordered or substituted. A reversed pair is **refused**,
never swapped: exchanging the two inverts the photograph, and that is a
decision nobody made. An equal pair is refused rather than nudged apart.

A slider's range is a different thing entirely and never reaches the model.
`LevelsControlScale.range` is `−0.5 … 1.5`; a saved pair outside it pins the
thumbs, shows its real values, and is not altered by being displayed.

### Decision 6 — The pair is one adjustment

`blackPoint < whitePoint` cannot be stated about either number alone. Two loose
`Double` fields on `ImageAdjustments` would let a record exist in which the
invariant is false, and would push the check out to every reader of a sidecar,
a control and a render. Held together in `UserLevelsAdjustment`, the record
either describes an interval or refuses to exist.

### Decision 7 — Exposure left the display stage, and both destinations now share a type

Levels have to sit between exposure and the clip, so the fused pass had to be
opened. Exposure moved to `SceneLinearExposer` — where the export path had
already been calling it since [ADR 0018](0018-full-resolution-tiff-export.md) —
and levels follow it as `LinearLevelsApplier`.

```text
OrientedSceneLinearRGBImage
  → SceneLinearExposer        adjustments.exposure
  → LinearLevelsApplier       adjustments.levels
  → LeveledLinearRGBImage ─┬─ DisplayPreviewRenderer   8-bit sRGB, on screen
                           └─ ExportImageEncoder      16-bit sRGB, in a file
```

`DisplayRenderSettings` is therefore what `ExportRenderSettings` already was: a
range policy and an encoding, and nothing a user chooses. The absence of
`exposureEV` is structural rather than tidy — the image these settings describe
has already been exposed and levelled, and settings carrying an exposure would
offer a second, silent application of it. The renderer cannot double-expose
because it is not given an exposure.

`DisplayRenderingError` lost its two exposure cases rather than keeping cases
that cannot occur, and its input case was renamed `nonFiniteLinearInput` for
what the stage now receives. `ExportEncodingError`'s was renamed the same way.

The two destination encoders now take the **same type** from the **same
stages** with the **same values**. Preview and export differ at resolution,
range policy, bit depth and destination, and nowhere above that line — which is
what makes a parity test a comparison of one shared value rather than an
argument about two pipelines.

The processed-wrapper chain gained the two links the new stages mint,
`ExposedProcessedRAWImage` and `LeveledProcessedRAWImage`, so changing an
exposure or a levels setting restarts from the right image rather than
composing onto the last one.

### Decision 8 — It is the cheapest adjustment, and it is scheduled like the others

A levels edit is applied below the retained reduced preview, so it reruns the
mix, the orientation, the exposure and its own arithmetic and nothing above
them. No decode, no normalisation, no white-balance estimate, no demosaic, no
camera-to-working conversion and no preview reduction.

It goes through exactly the path the other four adjustments take: the complete
`ImageAdjustments` record is updated, persistence becomes pending, and one
request goes to the existing coalescing renderer. A slider drag is a burst of
such calls; the renderer collapses it to the newest state, and only that state
can be installed or written. There is no timer, no debounce and no
levels-specific queue.

Applying `L2` after `L1` renders `L2(exposed)`, never `L2(L1(exposed))` — the
retained preview is upstream of this stage, so there is nothing for a new
decision to compose onto. Reset is exactly `black 0, white 1`, which reproduces
the downstream input that would have been produced had the levels never
changed. State, not history.

The interactive path allocates two more reduced-resolution `Float32` buffers
than before — the exposed image and the levelled one — both unreachable the
moment `render` returns. At the default preview policy that is tens of
megabytes, and `0 EV` and neutral levels each hand their input's buffer back
rather than copying it, so the common case allocates neither.

### Decision 9 — The sidecar schema advances to 6

A new image-affecting persisted setting, so the version advances rather than
gaining an optional field. This is the clearest case the forward-compatibility
rule has had: a build that ignored `levels` would render the photograph with
the black point the user pulled up sitting back at `0`, would say nothing, and
would then write the record back without the field — destroying the edit.

```json
"levels": { "blackPoint": 0.05, "whitePoint": 1.2 }
```

One key rather than two, because the pair is one decision. Both fields are
required; a missing one, a non-finite bound, a reversed pair or an
unrepresentable interval is refused rather than repaired or defaulted.

```text
v1 → v6   builtin.uncalibrated, identity mix, 0 EV, default patch, neutral levels
v2 → v6   builtin.uncalibrated, 0 EV, default patch, neutral levels
v3 → v6   builtin.uncalibrated, default patch, neutral levels
v4 → v6   builtin.uncalibrated, neutral levels
v5 → v6   neutral levels
v6        read as written
v7+       refused
```

Neutral is a **migration**, not a default: it is mathematically the identity,
and the identity is exactly what every build that wrote versions 1 to 5
applied, because none of them had a levels stage at all. A version 5 photograph
therefore renders after this milestone exactly as it did before it, and a test
renders both and compares the buffers rather than taking that on trust.

One authority per field still holds in both directions: a version 5 record
carrying `levels` is refused, as is a version 6 record without it.

### Decision 10 — Creative presets are unchanged

`IRCreativePreset` stays at schema version 1 and gains no levels field.
[ADR 0024](0024-reusable-creative-presets.md) made it deliberately a reusable
**channel-mix** preset, not a develop recipe, and this milestone does not
quietly turn it into one. Whether exposure, levels, white balance and
orientation belong together in a reusable recipe is a decision for the recipe
feature to make, with its own format and its own version.

### Decision 11 — Provenance answers the questions a person would ask

```text
Were levels applied?          yes — true even at black 0 / white 1, because
                              traversing the stage and asking for the identity
                              is a different fact from never running it
Which black point?            the user's value
Which white point?            the user's value
Was anything clamped here?    no
Tone mapping?                 no
Tone curve?                   no
Contrast?                     no
Automatic levels?             no
Histogram read?               no
Highlight reconstruction?     no
Shadow recovery?              no
Per-channel levels?           no
Still scene-linear?           no — see Decision 3
Still linear-light?           yes
```

Every one of those `no`s names something an affine rescale is routinely
mistaken for. The workspace inspector shows the rendered pair and says, in
words, whether the result is still proportional to scene radiance.

## Consequences

- Five canonical adjustments; `ImageAdjustments.isDefault` compares five fields.
- `DisplayPreviewRenderer` no longer applies exposure, and its input type
  changed. Every call site and test moved with it.
- One more full-frame buffer on the export path (about 148 MB at the reference
  camera's resolution) and two more reduced buffers on the preview path, all
  transient.
- A photograph saved by this build cannot be opened by an earlier one, which is
  the forward-compatibility rule working as intended.

## Explicitly deferred

Contrast, an S-curve, a parametric curve, an arbitrary tone curve, a histogram,
auto levels, auto contrast, highlight recovery, shadow recovery, local
contrast, clarity, dehaze, saturation, vibrance, sharpening, denoise, LUTs, a
gamma slider, wavelength-specific tone behaviour, per-channel RGB levels and a
separate monochrome levels control are all **not implemented**, and none of
them is half-implemented behind this stage. Each is its own decision.

## Alternatives rejected

**Pasting the arithmetic into both encoders.** Two copies of a numeric rule
drift, and the drift would be invisible: an export one narrowing order away
from the preview looks entirely plausible.

**Keeping the fused display pass and applying levels inside it.** It would put
a user adjustment back inside a destination encoder, make `DisplayRenderSettings`
the authority on a linear-domain decision again, and leave the export path to
reproduce the fusion. The boundary was the thing worth changing.

**Clamping the result to `0…1` inside the stage.** It would destroy exactly the
values the adjustment exists to move, and would make the destination's counted
clip a lie.

**A photographic validity range such as `−1 … 2`.** That is a slider's opinion
wearing a validity rule's clothes. It would refuse legitimate decisions a
hand-edited sidecar or a future recipe could hold, and it would still not rule
out the two representability failures that actually matter.

**Reordering a reversed pair, or nudging an equal one apart.** Both silently
render a photograph the record does not describe. Inverting an image is a
decision; it is not a repair.

**Folding levels into exposure as one gain-and-offset control.** Each slider
would change what the other did.

**Adding levels to `IRCreativePreset`.** Out of scope, and it would decide by
accident what a reusable recipe is.

## Test evidence

- `LinearLevelsTests` — the identity bit for bit; the documented `0.1/0.9`
  mapping; affinity as equal steps inside and outside the interval; the four
  inapplicable cases including the two a magnitude check would miss; the
  extended domain; no clipping; proportionality derived rather than asserted.
- `UserLevelsAdjustmentTests` — what a record may hold and what it refuses by
  name; the wire shape; round-trips; missing, reversed and unrepresentable
  pairs refused rather than repaired.
- `LinearLevelsApplierTests` — per-component arithmetic; no per-channel form;
  the identity fast path bit for bit; out-of-range results surviving; a second
  setting restarting from the exposed image; refusals; cancellation polled once
  per row on both paths; provenance.
- `WorkspaceLevelsAdjustmentTests`, `WorkspaceLevelsPipelineTests` — the
  workspace scheduling, the stage order, and that a levels edit decodes,
  demosaics and reduces nothing.
- `FullResolutionExportLevelsTests` — the export's pre-encoding values against
  the equation, the encoded samples against the destination policy, neutrality,
  and identical behaviour after identity, red/blue swap, an arbitrary matrix
  and a monochrome matrix.
- `LevelsSidecarMigrationTests` — the migration contract stated explicitly, and
  a version 5 state rendering byte-identically to the version 6 state it
  migrates to.
