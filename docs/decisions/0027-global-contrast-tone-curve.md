# 0027 — A global contrast tone curve

Status: accepted
Date: 2026-09-18

## Context

Every tone operation in the pipeline so far has been *affine*. Exposure is a
gain, `× 2^EV` ([ADR 0017](0017-interactive-exposure.md)). Levels are a gain
and an offset, `(x − b) / (w − b)` ([ADR 0026](0026-linear-levels.md)). Between
them they can put black at black and white at white, and they can do nothing
whatsoever about what happens in between: an affine map preserves every ratio
of differences, so a flat infrared frame stays flat no matter where its
endpoints are put.

That flatness is not incidental to this project. A 720 nm capture through a
converted sensor routinely produces a histogram bunched around the middle, and
the thing a photographer reaches for next — after setting black and white — is
a control that separates the midtones. Until now there was none, and the
pipeline had no nonlinear stage at all.

It also had nowhere to put one. `LeveledLinearRGBImage` was, by construction,
"the one type both destinations take", and its whole claim was
`linearLightEncoded == true`: no transfer function applied, nothing compressed,
no curve evaluated. A curve evaluated on those values makes that claim false.

## Decision

**A global RGB contrast curve becomes the sixth canonical user adjustment,
applied by a stage of its own between the levels and the destination, shared by
preview and export, and persisted at sidecar schema version 7.**

```text
ImageAdjustments
├── orientation     UserOrientationAdjustment
├── channelMix      UserChannelMixAdjustment
├── exposure        UserExposureAdjustment
├── whiteBalance    UserWhiteBalanceAdjustment
├── levels          UserLevelsAdjustment
└── contrast        UserContrastAdjustment          ← new
```

### Decision 1 — The equation, and one authority for it

```text
c = contrast amount, in −1 … +1
k = 2^c

f(x) = x                                x ≤ 0  or  x ≥ 1
f(x) = x^k / (x^k + (1 − x)^k)          0 < x < 1
```

Applied independently and identically to R, G and B. Evaluated in `Double` and
narrowed to `Float` exactly once, per component. `k` is computed once per curve
value, never once per component.

It is written in exactly one place, `GlobalContrastCurve`, for the reason
`SceneLinearExposure` and `LinearLevels` are: two consumers apply it, and two
copies of a numeric rule drift invisibly. An export that evaluated `pow` in
`Float32`, or that recomputed `2^c` per pixel, would look entirely plausible
and would not match the preview.

```text
UserContrastAdjustment      the person's intent, validated and persisted
GlobalContrastCurve         the mathematics, shared by every consumer
GlobalContrastApplier       the stage that runs it over an image
```

### Decision 2 — Why this curve and not a slope about the midpoint

Four properties hold for **every** amount in the supported range, and each of
them is a failure mode of the obvious alternative:

```text
identity at 0          k = 1 makes f the identity on the whole extended
                       domain — not "close to" it. The implementation
                       branches on it rather than computing pow(x, 1)

three fixed points     f(0) = 0, f(0.5) = 0.5, f(1) = 1, exactly. The
                       midpoint is exact rather than approximate: x and
                       1 − x are the same number there, so a/(a+b) is a/2a

strictly monotone      inside 0…1 the curve never flattens and never turns
                       over. No tone inverts, and no two distinct values
                       become one

symmetric              f(1 − x) = 1 − f(x). What the curve takes from the
                       shadows it gives to the highlights, so +c and −c are
                       mirror images rather than two unrelated shapes
```

The obvious alternative — a linear slope about `0.5`, `0.5 + s(x − 0.5)` —
fails three of the four. It pushes values out of `0…1` at every positive
setting, so it needs a clamp, and that clamp destroys exactly the highlight and
shadow detail this pipeline has carried unclipped since the mosaic. This curve
needs no clamp, because `x^k / (x^k + (1−x)^k)` is *in* `0…1` whenever `x` is.

The form is standard: the logistic map applied to the log-odds of `x`, with `k`
scaling the odds. Nothing in it is tuned, fitted or measured, and no constant
was chosen to taste — `k = 2^c` is the whole parameterisation. There is
therefore no invented constant to justify, which is the only kind of curve this
project is in a position to ship.

### Decision 3 — The amount's domain is a definition, not a discovery

```text
UserLevelsAdjustment     domain derived from IEEE 754 — what the arithmetic
                         can represent, and nothing else

UserContrastAdjustment   domain is −1 … +1 by definition of the control
```

This is the opposite of ADR 0026's reasoning, deliberately. The levels bounds
had to be derived, because an affine remap is meaningful for any ordered pair a
person might mean and only representability rules anything out. Here the
arithmetic rules out nothing: the curve evaluates perfectly well at `k = 2^5`.
**The control's definition is what picks `±1`**, in the way "eight
orientations" is part of what an orientation adjustment is.

Stating it in the adjustment rather than in a slider is what makes it a
definition rather than a slider's opinion. A value outside it is **refused**,
never clamped, and NaN and infinity are refused too.

The curve keeps a separate, weaker applicability rule of its own — finite
amount, finite positive exponent — because a curve built directly from a raw
amount, by a test or a future recipe, is checked against what the arithmetic
needs and not against a control's range.

### Decision 4 — The extended domain passes through untouched

```text
x ≤ 0     returned unchanged, bit for bit, −0.0 included
x ≥ 1     returned unchanged, bit for bit
```

This is the contract, not a shortcut. By this point a component may
legitimately be `−0.25` or `1.7`: the white balance, a creative mix with
negative coefficients, exposure and a black point above zero all produce
working coordinates outside the unit interval, and every stage so far has
carried them with their magnitude intact.

Three things the stage therefore refuses to be:

```text
not an extrapolation   the S-curve is not continued past the endpoints. x^k
                       for negative x is not a real number, and any rule that
                       invented one — abs, sign-preserving power, reflection —
                       would be a fabrication this project has no basis for

not a clamp            −0.25 stays −0.25, and −0.25 and −0.5 stay distinct.
                       Clipping belongs to the destination, downstream, where
                       it is counted

not a range policy     the same point from the other side: the contrast stage
                       must not quietly become the thing that decides what a
                       display can show
```

A value the destination will later clip is still distinct here, which is what
lets a subsequent exposure or levels change bring it back.

### Decision 5 — The result is not linear-light, and the type says so

```text
LeveledLinearRGBImage    sceneLinear false, linearLightEncoded TRUE
        │
        │  GlobalContrastApplier
        ↓
ToneCurvedRGBImage       sceneLinear false, linearLightEncoded FALSE   ← new
```

Every stage above this one is a permutation, a matrix on colour coordinates, a
gain or an affine remap — none of which bends the relationship between
neighbouring values. A tone curve does. After it, "no transfer function has
been applied, nothing has been compressed" is simply false, and naming the
result `SceneLinear…` or `LinearLight…` would be exactly the plausible-looking
label this project refuses: a reader would take it as a licence to do linear
arithmetic on values that no longer support it.

`linearLightEncoded` is `false` **value-independently**, including at amount
`0`, for the reason `LeveledLinearRGBImage.sceneLinear` is `false` at neutral
levels: a reader asking "has a curve been evaluated on this data?" of a stage
that is licensed to evaluate one should get one answer, not an answer that
depends on the value. The weaker, value-dependent fact is
`preservesLinearLightEncoding`, and it is derived from the curve rather than
stored.

What the values still are is short and matters to the encoder that follows:
working-space RGB coordinates, same primaries and white point, unclamped,
floating point, not yet transfer-encoded, not yet quantised.

### Decision 6 — Where it sits, and why exactly there

```text
working RGB → channel mix → orientation → exposure → levels → CONTRAST
            → range policy → transfer function → quantisation
```

**After the levels**, because the curve's three fixed points — `0`, `0.5` and
`1` — are meaningless until something has decided where black and white are.
Contrast asks "how steeply does the image move between the black point and the
white point"; that question has no answer before those points exist. Running
the curve first would make the levels reinterpret a distribution the user had
already shaped, and each control would change what the other one did.

**Before the range policy**, because the curve leaves extended values alone
deliberately. Clipping first would destroy the headroom the pipeline has
carried since the mosaic.

It is not inside `DisplayPreviewRenderer` and not inside `ExportImageEncoder`.
Those are destinations: they clip, encode and quantise, and nothing more. This
is the same rule that moved exposure out of the display renderer in ADR 0026,
applied once more.

The order is proved in **pixels**. A sample is chosen for which
`contrast(levels(x))` and `levels(contrast(x))` differ, and the workspace is
shown to produce the first.

### Decision 7 — Preview and export share the one stage

```text
WorkspacePreviewPipeline      FullResolutionExportPipeline
  levels                        levels
  → GlobalContrastApplier       → GlobalContrastApplier      the same stage
  → DisplayPreviewRenderer      → ExportImageEncoder
```

Both destination encoders now take `ToneCurvedRGBImage`, and they still differ
only at resolution, range policy, bit depth and destination. Neither contains
`pow`, `exp2`, a midpoint or a curve evaluation.

### Decision 8 — It is a global RGB curve, and it changes colour

The curve is applied independently and identically to R, G and B. That is the
whole of it, and it is worth naming what it is not, because a per-component
curve is routinely mistaken for each of these:

```text
not luminance contrast     no luminance is computed, and none could be —
                           infrared false-colour channels do not carry the
                           visible-light meanings a luminance weighting is
                           defined against. The same reason ADR 0025 refuses
                           Rec. 709 weights for monochrome
not Lab or HSL lightness   no conversion out of the working RGB space happens
not perceptual             nothing here models vision
not local contrast         every component is evaluated from its own value and
                           nothing else. No neighbourhood, kernel or region is
                           read, so this is not clarity, texture or dehaze
not automatic              no histogram is built or read, no statistic is
                           computed. If a value changed the rendering, a
                           person chose it
not a calibration          it is creative intent, like the channel mix
```

And it **changes channel ratios**. A nonlinear function applied independently
to three components does not preserve the ratios between them, so colour
appearance changes — saturation typically rises with positive contrast. That is
stated rather than compensated for. A hidden saturation correction would be a
second operation, unasked for and unnamed, and this project does not add those.

### Decision 9 — The control scale is not a percentage

```text
slider      −100 … +100 display units
model       −1 … +1 amount
display     = amount × 100
```

`+35` means `amount = 0.35`, which means `k = 2^0.35`. It does not mean 35 % of
slope, of luminance, or of contrast in any measurable sense, and the label
carries no `%` for exactly that reason.

Unlike the exposure and levels controls, this slider reaches **exactly** the
supported domain, because that domain is the control's own definition. There is
therefore no pinned-thumb case. What remains is the finer-value case, handled
the way the others handle it: a saved `0.355` is a valid decision, the thumb
sits at `35.5`, the label reads `+36`, and **displaying it never rewrites it**.

### Decision 10 — Schema version 7

Contrast is image-affecting state, so it takes a version rather than being
slipped into version 6 as an optional field. The sixth time the rule in
`PhotographProcessingStatePersistence` has been applied rather than merely
written down.

```json
{
  "schemaVersion": 7,
  "captureProfileID": "builtin.uncalibrated",
  "adjustments": {
    "…": "…",
    "levels": { "blackPoint": 0.05, "whitePoint": 1.2 },
    "contrast": 0.35
  }
}
```

A bare number rather than an object, for the reason `exposureEV` is one: the
decision *is* one number. The levels are an object because that decision is a
pair with an invariant between its halves; this one is not. The exponent `k` is
deliberately **not** written beside it — it is derived, and a record carrying
both could disagree with itself.

Versions 1 to 6 migrate to **neutral** contrast. That is a migration rather
than a default: a neutral amount gives an exponent of exactly `1`, the identity
is what every build that wrote those versions applied — they had no contrast
stage at all — and the claim is checked by rendering both states and comparing
the buffers rather than taken on trust, on the preview path and the export path
alike.

Version 7 requires the field and refuses its absence, an explicit `null`, a
non-numeric value, and a value outside `−1 … +1`. A pre-version-7 record
carrying a `contrast` field is refused, under the same one-authority-per-field
rule every earlier version follows.

### Decision 11 — Creative presets are unchanged

`IRCreativePreset` stays at schema version 1 and stays channel-mix-only. A
preset is a *creative channel mix* preset, not a develop recipe, for the reason
[ADR 0026](0026-linear-levels.md) gave about the levels. Whether white balance,
mix, exposure, levels, contrast and orientation should be reusable together is
a recipe decision, and this project has not made it.

## Consequences

### What this buys

- The first control that can change the *shape* of the tone distribution
  rather than only its endpoints.
- A nonlinear stage with an explicit, complete mathematical contract: three
  fixed points, monotone, symmetric, identity at neutral, no clamp.
- A type boundary that stops the linear-light claim at exactly the point it
  stops being true.

### What it costs

- One more transient full-frame `Float32` buffer on each path, at non-neutral
  amounts. Neutral contrast hands the input's immutable buffer back and
  allocates nothing.
- Two `pow` calls per component at non-neutral amounts. No `Double` frame
  buffer is introduced; each component is evaluated in `Double` and narrowed
  once.
- Every reader of a destination encoder's provenance now reaches the levels
  through `contrastProcessing.levelsProcessing`. The forwarding accessors are
  kept, so no existing property changed meaning.

### Deliberately deferred

Arbitrary control points, bezier and spline curves, a curve editor,
per-channel R/G/B curves, luminance-only contrast, a histogram, histogram-based
auto contrast, auto levels, highlights, shadows, clarity, texture, dehaze,
local contrast, saturation, vibrance, hue, HSL, LUTs, a gamma control, filmic
mapping, ACES, Reinhard, HDR output, a soft highlight shoulder,
wavelength-specific curve behaviour, recipe expansion, and GPU/Metal
optimisation.

Each is a separate decision. None is blocked by this one: the stage takes a
curve value, and a richer curve would be a different value applied at the same
point in the pipeline.
