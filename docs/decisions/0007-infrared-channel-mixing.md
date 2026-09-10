# 0007 — Infrared creative channel mixing

Status: accepted
Date: 2026-09-10

> Numbering note: `CLAUDE.md` previously used `0007-metal-render-pipeline.md`
> as an illustrative example of a future ADR filename. This milestone is the
> decision that actually took number `0007`, so that illustrative example now
> reads `0008-metal-render-pipeline.md`. ADR numbers follow the order decisions
> are made; no ADR was renamed.

## Context

[ADR 0006](0006-working-color-space.md) established the working colour space —
extended linear sRGB, unclamped `Float32` — and, in its Decision 26, said that
creative channel mixing belongs *after* that boundary as a separate, explicitly
named stage. This ADR is that stage.

```text
DemosaicedRAWRGBImage             linear camera-native sensor RGB
        ↓
explicit RAWCameraToWorkingColorTransform
        ↓
WorkingColorRGBImage              extended linear sRGB, unclamped Float32
        │
        │ explicit IRChannelMix
        ↓
IRChannelMixer
        ↓
IRChannelMixedRGBImage            the SAME space, creatively remixed
        ↓
[FUTURE: exposure / tone]
        ↓
[FUTURE: display encoding / preview]
```

Channel swapping is the operation infrared photography is built on. Until now
the project could describe it only as a mathematical test of a 3×3 primitive's
orientation. It is time it became a stage — and the point of making it one is
as much about what it *is not* as about what it does.

## The distinction this ADR is built on

```text
RAWCameraToWorkingColorTransform
    How do camera-native sensor responses enter our working colour space?

IRChannelMix
    Once we are already in that space, how do we creatively remix RGB
    for infrared rendering?
```

Both can be written as a 3×3 matrix. They are not the same operation, and
folding them into one would destroy the ability to say later what a rendering
actually claimed. A future filter or capture profile may well carry both — it
will carry them as two values with two provenances, never as one composed
matrix.

## Decision 1 — Creative channel mixing is a separate stage

`IRChannelMixer` runs after `RAWWorkingColorConverter`, never merged with it,
and never before the working colour space is established.

## Decision 2 — The input is `WorkingColorRGBImage`

Not the camera-native image, not a mosaic. Coefficients that remix RGB are
meaningful only once the axes they remix are defined.

## Decision 3 — The output stays in the same working colour space

`IRChannelMixedRGBImage` holds extended-linear-sRGB coordinates, exactly as its
input did. No primaries change, no chromatic adaptation happens, no conversion
occurs. The two types differ in **processing state**, not in colour-space
identity, and that distinction is stated in both types' documentation.

## Decision 4 — This stage is creative intent, not calibration

What happens here must never be recorded as camera calibration, camera colour
conversion, white balance, working-space establishment or filter calibration.
`IRChannelMixSource` is a separate provenance type from
`RAWCameraToWorkingColorTransformSource` for that reason.

## Decision 5 — The first mixer is a linear 3×3 RGB transform

```text
outputRGB = M × inputRGB
```

Hue remapping, LUTs, false-colour lookup and per-channel curves are all
separate operations, not this one.

## Decision 6 — `RAWColorMatrix3x3` is reused as the shared primitive

A second, nearly identical 3×3 type would duplicate the convention, the
validation and the arithmetic, and would eventually disagree with the first.

## Decision 7 — Its convention is generalised to input RGB → output RGB

The primitive's documentation no longer says every input is camera RGB or every
output working RGB. It describes a linear map between RGB triples; which
representation either side names is the interpreting stage's statement.
`RAWProcessingError.invalidWorkingColorMatrix` was renamed
`.invalidColorMatrix3x3` for the same reason. The multiplication convention,
the coefficient precision, the determinant diagnostic and the finiteness check
are unchanged.

## Decision 8 — Rows are output channels, columns are input channels

```text
            ⎡ m00 m01 m02 ⎤   ⎡ inputR ⎤
outputRGB = ⎢ m10 m11 m12 ⎥ × ⎢ inputG ⎥
            ⎣ m20 m21 m22 ⎦   ⎣ inputB ⎦
```

Tested with a deliberately non-symmetric matrix whose transposed reading is
asserted *not* to match.

## Decision 9 — There is no constant or offset term

The operation is linear, never affine. A Photoshop-style channel-mixer constant
shifts black, which on a scene-linear representation is a different operation;
if it is ever wanted it is a separate decision, not a parameter quietly added
here.

## Decision 10 — A mix is tied to the working colour space it was authored for

Coefficients mean something only relative to the RGB axes they were written
for. `IRChannelMix` therefore records a `RAWWorkingColorSpace` rather than
assuming one.

## Decision 11 — A space mismatch is rejected, not converted

`IRChannelMixer` compares the image's space with the mix's and throws
`IRProcessingError.channelMixWorkingColorSpaceMismatch`. It does not convert
between working spaces and does not reinterpret coefficients in place. Exactly
one space exists today, so the check is unreachable in practice; it stays
because the invariant is about the first day a second one exists. No fake enum
case was added to make it testable — an exhaustive switch in the test suite
stops compiling when a second space arrives, which is when the real mismatch
test gets written.

## Decision 12 — `IRChannelMix` pairs space, matrix and provenance immutably

All three properties are `let`; the memberwise initialiser is module-internal;
the only ways in are the factories. The same protection
`RAWWhiteBalanceEstimate` and `RAWCameraToWorkingColorTransform` already use,
for the same reason: a bare matrix plus a separately supplied label can be
mismatched.

## Decision 13 — Three public factories

```text
IRChannelMix.identity
IRChannelMix.redBlueSwap
IRChannelMix.explicit(matrix:)
```

There is no default mix on any entry point. Which rendering an infrared capture
deserves is a creative decision, made at the call site, visibly.

## Decision 14 — No profile, preset or recipe provenance exists yet

`IRChannelMixSource` has exactly three cases. A case naming a subsystem the
project has not built would be a claim about nothing. When a profile system
arrives it either produces an `.explicit` mix or gains a case of its own.

## Decision 15 — Identity is an explicit creative no-op

`.identity` means *no creative remapping was requested, and the stage was
traversed anyway*. A rendering that went through the creative stage and asked
for nothing is a different fact from one that never reached it, and the
provenance chain records which.

## Decision 16 — Identity preserves the bit pattern of every value it accepts

A dedicated path performs no arithmetic: `-0.0`, negatives, values above `1`,
`greatestFiniteMagnitude` and `leastNonzeroMagnitude` all survive unchanged.
The values are handed back as the same immutable array, so `Array`'s
copy-on-write makes the path free in memory as well as in arithmetic.

The set this promise covers is the **finite** values, which is the stage's
input contract. NaN and infinity are refused on this path exactly as on the
others (Decision 26) — they are not preserved and not passed through. So the
claim is "no accepted value is altered", never "every `Float32` bit pattern
reaches the output": the two differ precisely on the values the stage rejects.

## Decision 17 — Red/blue swap is the canonical first IR creative operation

```text
0 0 1        outputR = inputB
0 1 0        outputG = inputG
1 0 0        outputB = inputR
```

It is a creative rendering choice — not a calibration, not a white balance, not
a working-space transform, and not a physical model of any filter.

## Decision 18 — The swap is a bit-preserving permutation, not three dot products

`0*R + 0*G + 1*B` is mathematically right and can still change a signed zero's
sign. A permutation moves values, so the implementation moves them: one
reordered output buffer, every accepted source value's bit pattern intact.

The same qualification as Decision 16 applies, and for the same reason: the
values moved are the finite ones, because the non-finite ones are refused
before anything is moved.

## Decision 19 — An explicit matrix equal to a built-in stays `.explicit`

The **execution path is decided by the matrix's value**; the **provenance by
how the mix was constructed**. An `.explicit` identity or swap matrix takes the
optimised path and keeps `.explicit`. The two facts never contaminate each
other, and both directions are tested.

## Decision 20 — Negative coefficients are allowed

They are how infrared channel mixing subtracts one channel's contribution from
another, and they legitimately produce negative output coordinates.

## Decision 21 — Coefficients above one are allowed

Amplifying a channel is a normal creative operation and legitimately produces
coordinates above `1`.

## Decision 22 — Singular matrices are allowed

A rank-1 monochrome collapse is a legitimate creative mix. Nothing here inverts
a matrix, so invertibility is not required. No monochrome preset is built in;
the singular case is proven by test only.

## Decision 23 — Rows are not normalised

Row sums need not be `1`, coefficients are not turned into percentages, and
nothing is rescaled. Normalising would silently change the rendering the caller
asked for.

## Decision 24 — Nothing is clamped

Output below `0`, inside `0...1` and above `1` is preserved exactly as the
arithmetic produced it. No per-pixel normalisation, no whole-image rescaling,
no absolute value, no gamut mapping.

## Decision 25 — Generic arithmetic accumulates in `Double`, stores `Float32`

Each output channel is one dot product accumulated in `Double` and narrowed to
`Float` exactly once. `Float32` intermediates can overflow where the
mathematical result cannot — `2 × greatestFiniteMagnitude −
greatestFiniteMagnitude` is infinity in `Float` and exact in `Double`. There is
no `Double` image buffer; the widening lives in three local accumulators.

## Decision 26 — Non-finite inputs and results are errors

NaN and infinity in the input are refused with the coordinate and channel, on
every path. On the output side three arithmetic outcomes are refused, not two:

```text
infinite Double accumulation   the magnitude left Double's range
NaN Double accumulation        (+infinity) + (-infinity) from opposing terms
Float32 narrowing overflow     finite in Double, infinite as Float32
```

None is clamped to `greatestFiniteMagnitude` and none is replaced with zero.
They share one case, `nonFiniteChannelMixResult`, because the property that
matters to a caller is the same for all three — the number is not usable — and
because splitting them would name an implementation detail in a user-visible
message. For the same reason the case is named for **finiteness** rather than
for magnitude, and its description says so: a NaN result is not a value too
large to represent, and describing it that way would be false. The bare image
types are publicly constructible, so this is a real boundary.

`IRProcessingError` is a separate type from `RAWProcessingError`: this stage
has no sensor data left to interpret, and reporting its input as a
"camera-native working-colour conversion input" would name the wrong stage.
Matrix construction is the one deliberate exception — the primitive is shared
infrastructure and keeps one error.

## Decision 27 — Changing a mix restarts from the pre-mix working image

```text
new result = M2 × the working-colour image
       NOT   M2 × (M1 × the working-colour image)
```

`IRChannelMixedProcessedRAWImage` retains the pre-mix state and
`apply(mix:replacing:)` reaches through `previous.source`, never reading
`previous.image`. Two swaps in a row would otherwise cancel, and a swap
followed by a collapse would be neither operation.

## Decision 28 — Metadata is not consulted

The core entry point is `WorkingColorRGBImage + IRChannelMix` and has no
parameter a `RAWMetadata` could arrive through. `rgbFromCamera`,
`cameraFromXYZ`, `cameraMultipliers`, `daylightMultipliers` and the camera's
make and model cannot change a single output value; a test varies all of them
and requires bit-identical output.

## Decision 29 — White balance is not reapplied

It happened per CFA plane in the mosaic domain. There are no CFA planes here,
`sensorColorLayout` and the gains are provenance rather than input, and no
white-balance mathematics runs.

## Decision 30 — The camera-to-working conversion is not reapplied

No second camera transform, no matrix inversion, no XYZ round trip.

## Decision 31 — No gamma, tone mapping or display encoding happens

The output is still scene-linear and still not displayable. Encoding it for a
monitor remains a later, separate stage.

## Decision 32 — Upstream processing state remains reachable

`IRChannelMixedProcessedRAWImage` reaches the working-colour image, the
camera-native image, the white-balanced mosaic, the normalised mosaic, the
decoded `UInt16` mosaic, the metadata and the URL. `IRChannelMixProcessing`
reads the working space, the matrix, the camera transform, the demosaic
algorithm and the gains *through* the values that already hold them rather than
copying them, so two records of one history cannot disagree.

## Decision 33 — The CPU implementation is a correctness reference

`O(pixel count)`, one owned output allocation for the paths that need one, the
nine coefficients loaded once outside the loop, no full-frame temporary and no
per-pixel allocation. Accelerate, vDSP, Metal and Core Image are deliberately
absent. Only debug (`-Onone`) timings have been taken and no performance claim
is made from them.

## What this ADR does not decide

- The **camera / filter profile format**.
- An **IR filter database**.
- **Automatic profile selection.** Nothing selects a mix on its own.
- The **saved recipe format**.
- **Preset UX**, and any preset beyond the two built-ins here.
- **Channel-mixer UI percentages**, or any UI at all.
- **Offset / constant terms.**
- **Exposure controls.**
- **Tone mapping.**
- **Contrast, saturation, HSL and curves.**
- **Gamut mapping.**
- **Display encoding.**
- **Export**, including which space files are written in.
- A **GPU / Metal implementation.**
- **Final production demosaicing quality**, which remains where
  [ADR 0005](0005-application-owned-bayer-demosaicing.md) left it.

## Consequences

- The project has its first explicitly creative stage, and creative intent is
  now recorded separately from every calibration-shaped decision upstream.
- The canonical infrared operation — the red/blue swap — is available as a
  named, bit-exact, provenance-carrying primitive rather than as a matrix
  someone typed at a call site.
- A future profile or recipe system has a target: it produces `IRChannelMix`
  values and hands them to the same `apply`, without a new mixer primitive.
- Reprocessing stays honest at one more level: changing a mix costs one pass
  over the working image, not a decode.
- Nothing downstream of this stage exists yet. An `IRChannelMixedRGBImage` is
  still not displayable and must not be written to a file as though it were
  sRGB until a display or export encoding stage exists.
