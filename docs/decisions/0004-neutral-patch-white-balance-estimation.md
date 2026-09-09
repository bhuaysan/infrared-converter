# 0004 — Neutral-patch infrared white-balance estimation

Status: accepted
Date: 2026-09-10

## Context

[ADR 0003](0003-infrared-white-balance.md) built the *apply* half of infrared
white balance: `RAWWhiteBalancer` multiplies a `LinearRAWMosaic` by explicit
per-CFA-plane gains, literally, and normalises nothing. It deliberately left
the other half open — nothing in the project decided what the gains should be,
and every caller supplied them by hand.

This ADR builds the first producer of those gains.

The general shape is a split, not a pipeline stage appended to the previous
one:

```text
LinearRAWMosaic
       │
       ├── measure the selected patch
       ↓
RAWWhiteBalanceEstimator
       ↓
RAWWhiteBalanceGains
       ↓
RAWWhiteBalancer
       ↓
WhiteBalancedRAWMosaic
```

Estimation reads the mosaic; application transforms it. They meet at the gains.

## Decision 1 — Estimation operates on `LinearRAWMosaic`, before white balance

The estimator's input is the normalised, pre-white-balance mosaic — the same
representation `RAWWhiteBalancer` consumes, not its output.

Estimating from an already-balanced mosaic would fold the previous gains into
the new ones, so changing the selection twice would compound. The signature
enforces the correct input rather than documenting it: `LinearRAWMosaic` has
`whiteBalanceApplied == false` by construction, so a balanced buffer cannot be
passed at all.

## Decision 2 — A point picker will sample a patch, not a pixel

A single CFA sample carries exactly one colour plane. It cannot determine the
other three gains, and no amount of interpolation makes it able to — that would
be estimating white balance from demosaiced values invented by neighbours.

So the eventual UI "neutral point picker" is presentation: it turns a click
into a small rectangle and calls this estimator. The estimator has no concept
of a click, a cursor or a pixel. This is recorded now because the alternative —
a one-sample API that a UI later has to work around — would be expensive to
undo.

## Decision 3 — The first estimator takes a caller-selected rectangle

`RAWActiveAreaRegion` is an application-owned integer rectangle in the same
active-image coordinates `LinearRAWMosaic` uses.

Integer, and not `CGRect`: selecting samples is integer counting, a rectangle
of 63.5 samples has no meaning, and rounding one into existence at a processing
boundary is the kind of silent reinterpretation this pipeline exists to avoid.
Application-owned, and not a CoreGraphics type: it keeps AppKit out of the
processing layer and forces a future UI to convert *into* sample coordinates
deliberately.

Validation refuses a negative origin, a non-positive width or height, a far
edge that overflows `Int`, and any extent past the mosaic's edge. It never
crops a region to fit. A silently shrunk selection would change which samples
were measured without saying so, and the record of the measurement would then
be wrong.

Automatic whole-image estimation, grey-world, and histogram or percentile
methods are explicitly not built here.

## Decision 4 — Statistics are per actual CFA plane, discovered from the layout

The set of colour planes is discovered by walking one complete repeating CFA
cell through the layout's own `colorPlaneIndex(row:column:)` accessor: 8 rows ×
2 columns for `.bayer`, matching the extent of the packed `filters` code, and
6 × 6 for `.xTrans`. No LibRaw CFA decoding is duplicated in the estimator.

`colorCount` is not consulted. The reference camera reports `colorCount == 3`
while its CFA genuinely produces plane `3`, so inferring the plane set from it
would drop the second green — the same trap ADR 0003 sized the four-slot gain
model to avoid. A plane index outside `0..<4` is a typed error rather than a
modulo reduction, because folding it would estimate one colour's gain from
another colour's samples.

`.foveon`, `.none`, `.unknown`, a malformed X-Trans table and LibRaw's
non-standard 16×16 Bayer code (`filters == 1`) all fail with a typed
unsupported-layout error. None of them has a per-plane mosaic to measure.

## Decision 5 — The statistic is the arithmetic mean

Per plane, per patch: a sample count and the arithmetic mean of those samples.

The mean is the simplest statistic that uses every selected sample, and it is
the one whose behaviour under a subsequent multiply is obvious — scaling every
sample of a plane by `g` scales its mean by exactly `g`, which is what makes
the estimator's guarantee checkable. Median, trimmed mean and other
robust estimators are deferred; see "Future work".

## Decision 6 — Finite negative samples participate in the mean

`LinearRAWMosaic` is deliberately unclamped, and negative values in it are
real: sensor noise straddles the black point, and the reference frame contains
11 such samples. They are black-subtracted measurements, not errors.

So the mean includes them, unmodified. Nothing is clamped to `0` or to `1`, no
shadows or highlights are discarded, no absolute value is taken, no epsilon is
added, and no percentile or outlier rejection happens. A dark patch's mean is
genuinely lowered by its negatives, which is the correct answer, and the
synthetic suite names the wrong answer a clamping implementation would give.

A NaN or infinite sample is reported with its coordinate rather than skipped.
Skipping it would change a mean's denominator without saying so.

## Decision 7 — Sums accumulate in `Double`

`LinearRAWMosaic` stores `Float`. The accumulators are `Double`.

This is not the apply stage's hot multiply loop — it runs once over a patch of
a few thousand samples — and summing thousands of `Float32` values in `Float32`
would add avoidable rounding to the single number every gain is derived from.
The cost is four `Double` registers.

## Decision 8 — Required plane means must be strictly positive

Estimation fails, with a typed error carrying the plane index and the measured
value, when a required plane's mean is zero, negative, NaN or infinite.

Dividing by such a mean produces an infinite, sign-flipped or undefined gain,
none of which is white balance. Substituting an epsilon, or clamping to some
maximum, would fabricate a measurement that was never made.

## Decision 9 — The first scale policy is `preserveStrongestMeasuredPlane`

The overall scale of a set of gains is a real choice: `[1, 2, 5, 2.5]` and
`[0.2, 0.4, 1, 0.5]` describe the same colour balance and differ only in
exposure. `RAWWhiteBalancer` has no opinion by design, so the opinion lives in
the estimator, in a typed enum with exactly one case rather than as an unstated
convention.

## Decision 10 — The target is the maximum required-plane mean

```text
target      = max(mean of every colour plane the layout produces)
gain[plane] = target / mean[plane]
```

## Decision 11 — Measured gains never attenuate, and at least one is exactly 1

Because `target` is the maximum, every ratio is at least `1`, and the plane
that supplied the target divides by itself and gets exactly `1`.

That is the point of the policy. Dividing through by the weakest plane, or by
green, would multiply the strongest plane by less than one and quietly darken
it — and for infrared capture the strongest plane is usually the one carrying
most of the signal. An estimator should not attenuate the measurement it is
most confident in.

The consequences, all tested:

1. every measured plane gets a finite, strictly positive gain;
2. at least one measured gain is exactly `1`;
3. no measured gain is below `1`;
4. applying the gains equalises the patch's plane means, to Float32 precision;
5. unused gain slots are exactly `1`;
6. this is estimator policy — the apply stage still multiplies literally.

The gains are not renormalised again afterwards, by either stage.

## Decision 12 — Unused slots are identity; required-but-unmeasured planes are errors

Two absences that look alike are kept apart:

```text
plane not produced anywhere in the layout   → unused        → gain exactly 1
plane in the layout, no samples in patch    → patch too small → typed error
```

A three-plane Bayer layout and an X-Trans table using indices `0...2` both
leave slot `3` at identity, because there is nothing there to balance. A 1×1
region on an RGBG sensor fails, because three real planes were not measured and
inventing gains for them would be fabricating data. Collapsing the two cases
into one would either fail on perfectly good three-plane sensors or silently
return identity gains for planes nobody measured.

## Decision 13 — No `colorCount` modulo addressing

Covered by decision 4, restated because it is the specific bug this milestone
is most exposed to: plane indices are used literally, everywhere, and an
out-of-range index is an error rather than a wrapped index.

## Decision 14 — No camera or daylight multipliers

`cam_mul` and `pre_mul` are visible-light-calibrated diagnostics and are not a
reasonable infrared default. The estimator does not import `CLibRaw`, receives
no LibRaw structure, and receives no `RAWMetadata` at all — so there is no
parameter for them to arrive through. The enforcement is structural, as it is
for `RAWWhiteBalancer`.

## Decision 15 — Estimation and application remain separate types

`RAWWhiteBalanceEstimator` never multiplies a sample, allocates an image-sized
buffer, or produces a mosaic. `RAWWhiteBalancer` never measures anything or
rescales what it is given. Keeping the split means the policy question has one
named home instead of leaking into the apply loop as a hidden normalisation.

The one concession to convenience is a set of `apply(…, estimate:)` overloads
that take an estimate whole. An estimate's gains and the record explaining them
are two halves of one result, and splitting them by hand at each call site is
an easy way to archive a measurement that did not produce the numbers applied.
The overloads add no behaviour beyond passing both halves together.

## Decision 16 — Provenance records region, statistics, target and policy

`RAWWhiteBalanceSource.neutralPatch` carries the region measured, the scale
policy, the per-plane sample counts and means, and the target mean. It
deliberately does **not** repeat the gains: those are already stored, literally,
in `RAWWhiteBalanceProcessing.gains`, and two copies of the same numbers can
disagree.

A gain of `6.8` is not reviewable on its own. "6.8, because plane 2's 1024
samples in a 64×64 patch at (1488, 1996) averaged 0.0084 against a target of
0.0572" is.

As with ADR 0003, the precise claim is bounded: given the same
`LinearRAWMosaic`, the record contains everything needed to reproduce the
estimate and the transformation. It does not contain the source pixels.

## What this ADR does not decide

- Automatic or whole-image white balance.
- Any UI, picker or interaction model.
- Temperature and tint as a representation.
- Filter or capture profiles, and persistence of either.
- The working colour space, which remains downstream of demosaicing.

## Consequences

- `O(samples in the region)` time and constant auxiliary memory: four `Double`
  sums, four counters, no per-plane arrays, no copy of the patch, and no
  full-frame intermediate. `RAWWhiteBalancer`'s allocation model is unchanged.
- The estimator's guarantee is about the *patch*, not the scene. It makes the
  selected samples average equally in every plane; whether that patch was
  actually neutral is the caller's claim.
- `RAWWhiteBalanceSource` is no longer a bare enum, so anything matching on it
  must handle the associated value. That is intended: an estimated result
  should not be indistinguishable from a hand-entered one.

## Future work

- Robust and outlier-aware statistics (median, trimmed mean, per-plane
  saturation exclusion), which matter as soon as a patch can contain a specular
  highlight or a dead pixel.
- Automatic estimation with no user selection.
- Additional scale policies, each named in
  `RAWWhiteBalanceEstimationScalePolicy` rather than assumed.
- Filter and capture profiles as a source of gains.
