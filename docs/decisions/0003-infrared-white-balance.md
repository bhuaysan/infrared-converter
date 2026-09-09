# 0003 — Infrared white balance as explicit per-CFA-plane gains

Status: accepted
Date: 2026-09-10

## Context

[ADR 0002](0002-raw-normalization.md) established `LinearRAWMosaic`: one
unclamped `Float32` per CFA location, black-subtracted and normalised, with no
white balance, no demosaicing and no colour interpretation applied.

Infrared white balance is the next stage, and it is a core feature rather than
a slider. Infrared capture routinely needs multipliers far outside anything
visible-light processing would produce, because a converted body behind a 720 nm
filter records a wildly unbalanced signal — one plane can be nearly empty while
another is near saturation.

Several future features will all need to *decide* what the multipliers should
be: a neutral-point picker, a neutral-patch sampler, an automatic IR estimator,
filter profiles, saved recipes. This ADR is about what they all *feed into*.

## Decision 1 — White balance happens before demosaicing

The order is:

```text
black subtraction → normalisation → infrared white balance → demosaic
```

Gains are applied to the CFA mosaic, one value per sensor location. There is
still exactly one value per CFA position after this stage, and it is not RGB.

Balancing after demosaicing would mean the interpolation had already mixed
planes that are grossly different in level, which is the condition
demosaicing is worst at. Balancing first also keeps the operation a pure
per-plane multiply, which is trivially testable.

## Decision 2 — The primitive operates on `LinearRAWMosaic`

`RAWWhiteBalancer` takes a `LinearRAWMosaic` and a set of gains, and returns a
`WhiteBalancedRAWMosaic`. It is application-owned: it does not import
`CLibRaw`, reads no LibRaw structure, and does not know which decoder produced
its input.

## Decision 3 — White balance is represented as explicit linear multipliers

`RAWWhiteBalanceGains` holds one `Float` multiplier per CFA colour plane. That
is the representation, not a derived convenience over some other one.

## Decision 4 — Four plane slots, indexed by CFA colour plane

The gain index is the CFA colour-plane index returned by
`SensorColorLayout.colorPlaneIndex(row:column:)`, and there are four slots.

This is deliberate and is the subtlest point in the design. On the reference
camera:

```text
colorDescription = "RGBG"
colorCount       = 3

plane 0 = R
plane 1 = G1
plane 2 = B
plane 3 = G2   ← real, reachable, and not covered by colorCount
```

The CFA lookup returns `3`, even though the decoder reports three distinct
colours. Sizing or validating the gain model from `colorCount` would therefore
be wrong, and `gains[plane % colorCount]` would silently apply red's gain to
every second green sample. Four slots, addressed literally, avoid both. A
colour plane outside `0...3` is a typed error, never folded onto an existing
slot.

## Decision 5 — G1 and G2 are independently representable

`plane1` and `plane3` are separate values and nothing forces them to agree.
The CFA model exposes the two green positions as distinct planes and some
sensors and metadata treat them differently, so collapsing them here would
delete information the primitive exists to carry. A future estimator or UI may
choose to link them; that is policy above this type, not inside it.

## Decision 6 — Gains are applied literally

For every sample:

```text
output = input * gainForThatSamplesColorPlane
```

So `0.25` with a gain of `4` is exactly `1.0`, and doubling every gain doubles
every output value.

## Decision 7 — No hidden gain normalisation

This stage does **not** normalise green to `1`, divide through by the largest
or smallest gain, preserve average luminance, normalise exposure, or rescale
the gains against camera or daylight multipliers.

Choosing a canonical scale is a real decision, but it belongs to whichever
future component *produces* the gains — which will then have to state its
policy explicitly, rather than inheriting a hidden one from the apply stage.
Estimation and application are separate concerns:

```text
ESTIMATE gains  (future)  →  RAWWhiteBalanceGains  →  APPLY gains  (this ADR)
```

Gains must be finite and strictly greater than zero. There is deliberately no
upper bound: `0.01`, `20` and `100` are all valid, and an arbitrary ceiling
would rule out legitimate infrared work.

## Decision 8 — `cam_mul` and `pre_mul` are never silently applied

`RAWMetadata.Color.cameraMultipliers` (LibRaw's `cam_mul`) and
`daylightMultipliers` (`pre_mul`) are visible-light-calibrated diagnostics.
They are not a reasonable default for infrared capture, so they are not applied
here.

The enforcement is structural rather than a rule someone has to remember:
`RAWWhiteBalancer.apply(to:gains:)` receives a mosaic and a set of gains and no
metadata at all, so there is nothing for a camera white balance to leak in
through. The metadata stays reachable on the wrapper for diagnostics and for a
future estimator that may deliberately consult it.

## Decision 9 — Negative and above-one values remain unclamped

Values below `0` (sensor noise straddling the black point) stay negative, and
values above `1` stay above `1`. Nothing is clipped before or after the
multiply.

Negatives matter specifically for later neutral-region statistics: flooring
them at zero would bias any mean computed over a dark patch, which is exactly
the measurement a future gain estimator will depend on. Highlight handling is a
later, explicit stage.

A finite input that overflows `Float32` when multiplied by a finite gain is a
typed error, never clamped to `greatestFiniteMagnitude` and never stored as an
infinity. A non-finite input value is likewise reported rather than propagated.

## Decision 10 — Gain estimation is out of scope *for this stage*

No grey-world, no percentile, no neutral patch, no neutral pixel, no picker, no
histogram estimator, no camera-WB conversion, no temperature/tint model. This
stage consumes gains supplied by its caller and does not decide what they
should be.

This decision still holds and has not been superseded. It constrains
`RAWWhiteBalancer`, not the project: neutral-patch estimation now exists as a
separate type, `RAWWhiteBalanceEstimator`, which produces gains and hands them
here. See
[ADR 0004](0004-neutral-patch-white-balance-estimation.md).

## Decision 11 — Temperature and tint are not the core representation

Infrared white balance regularly lands far outside the assumptions behind
visible-light correlated-colour-temperature models, so the core representation
stays direct multipliers, unbounded by any Kelvin range. A later UI may offer
higher-level controls, but those must resolve down to explicit gains; it is not
the other way round.

## Decision 12 — Re-balancing always restarts from the normalised source

The invariant:

```text
new result = apply(new gains, the normalised mosaic)
       NOT   apply(new gains, the previous white-balanced result)
```

Chaining would compound: gains of `2` followed by gains of `3` would silently
mean `6`. `WhiteBalancedProcessedRAWMosaic` keeps the whole pre-white-balance
`ProcessedRAWMosaic` reachable, and
`RAWWhiteBalancer.apply(gains:replacing:)` reaches through it to that source,
so the correct behaviour is also the convenient one. Nothing is mutated in
place, so re-balancing needs neither a LibRaw decode nor a second run of black
subtraction and normalisation.

## What this ADR does not decide

The working colour space. That decision is downstream of demosaicing and
remains open; nothing here depends on it.

## Consequences

- One additional `Float32` full-frame allocation per white-balance run: about
  49 MB for the reference camera, alongside the normalised mosaic it is derived
  from. Keeping the source is what makes non-compounding re-balance possible,
  and is a deliberate trade.
- Provenance records the exact gains rather than a label like "custom white
  balance", so given the same `LinearRAWMosaic`,
  `RAWWhiteBalanceProcessing` contains the exact gains required to reproduce
  the white-balance transformation. It does not contain the source pixels, so
  it reproduces the transformation and not the image by itself.
- `RAWWhiteBalanceSource` has a single case, `.explicit`. Estimated sources
  will be added as the features that produce them are built, not before.
