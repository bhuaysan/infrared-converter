# 0006 — Extended linear sRGB as the working colour space

Status: accepted
Date: 2026-09-10

> Numbering note: `CLAUDE.md` originally named `0002-working-color-space.md` as
> the expected filename for this decision. `0002` was taken by
> [RAW normalisation](0002-raw-normalization.md), which recorded at the time
> that the working-colour-space decision would take the next free number. That
> number is `0006`. No ADR was renamed, and `CLAUDE.md` now points here.

## Context

[ADR 0005](0005-application-owned-bayer-demosaicing.md) produced
`DemosaicedRAWRGBImage`: three linear Float32 values per pixel, camera-native,
in no colour space at all. Its documentation ended with the same sentence four
ADRs in a row ended with — that converting camera-native RGB into a defined
working representation is a later, explicit stage, and that the working colour
space was still undecided.

Everything after demosaicing needs that decision. An infrared channel mixer, an
exposure control, a tone curve and a display encoding all have to know what the
numbers they operate on mean. This ADR makes the decision, and separates it
from a second one it is routinely confused with.

```text
DemosaicedRAWRGBImage             linear camera-native sensor RGB
        ↓
explicit RAWCameraToWorkingColorTransform
        ↓
RAWWorkingColorConverter
        ↓
WorkingColorRGBImage              extended linear sRGB, unclamped Float32
        ↓
[FUTURE: IR channel mixer / false-colour creative transform]
        ↓
[FUTURE: exposure / tone]
        ↓
[FUTURE: display encoding / preview]
```

## The distinction this ADR is built on

Two decisions, not one:

```text
a working colour space   defines the COORDINATE SYSTEM the numbers live in

a camera / IR transform  decides HOW sensor-native RGB is MAPPED into it
```

Choosing extended linear sRGB answers the first. It says nothing whatsoever
about the second. For a visible-light camera the second question has a
conventional answer supplied by a vendor calibration; for an infrared-modified
camera photographing through a 720 nm filter, it does not — and pretending the
first decision settled the second is exactly how a project ends up believing
that "the working space is sRGB" means "the colours are correct".

Everything below follows from keeping them apart.

## Decision 1 — The first working colour space is extended linear sRGB

`RAWWorkingColorSpace` has exactly one case, `.extendedLinearSRGB`. Display P3,
ProPhoto RGB, Adobe RGB, ACES, XYZ and Rec.2020 are deliberately absent: a case
is a claim that the pipeline can produce and interpret that space, and a case
that exists but is unimplemented is worse than one that does not exist.

## Decision 2 — sRGB primaries and D65, with a linear transfer function

```text
primaries      sRGB / IEC 61966-2-1
white point    D65
transfer       linear — light is proportional to the number
storage        Float32
```

The nonlinear sRGB transfer function is **not** applied. No gamma is applied.
Linearity is what makes channel mixing, exposure and matrix arithmetic
meaningful downstream, and it is what a later display stage will encode *from*.

The practical reason for these primaries over another set: macOS already
understands extended-range linear sRGB, so a future Core Image or Metal preview
bridge is a labelling exercise rather than a conversion design.

## Decision 3 — Values below zero and above one are retained

"Extended" means only that the range is not clipped. Finite values below `0`,
inside `0...1` and above `1` are all legal and all preserved.

- **Below zero** because black-subtracted sensor noise straddles the black
  point, and because a matrix with negative coefficients — which infrared work
  legitimately uses — produces negative coordinates from positive inputs.
- **Above one** because highlights above the normalisation white level are
  preserved rather than clipped, and because a matrix may amplify.

This continues the numeric contract [ADR 0002](0002-raw-normalization.md) set
for the mosaic domain, unchanged.

## Decision 4 — Working-space selection and the camera transform are separate

The two decisions live in two types. `RAWWorkingColorSpace` names the
coordinate system; `RAWCameraToWorkingColorTransform` decides the mapping and
carries its own provenance. No API lets one imply the other.

## Decision 5 — `DemosaicedRAWRGBImage` remains camera-native

Nothing about this ADR changes the demosaiced representation. It stays linear
camera-native sensor RGB, in no colour space, and remains the input every
camera-to-working conversion starts from.

## Decision 6 — `WorkingColorRGBImage` represents extended-linear-sRGB coordinates

A separate type, with the same storage layout and a different meaning:

```text
DemosaicedRAWRGBImage   = linear CAMERA-NATIVE RGB sensor responses
WorkingColorRGBImage    = EXTENDED LINEAR sRGB coordinates
```

The shared layout — tightly packed, row-major, interleaved `R G B`, three
Float32 per pixel — is a coincidence of storage, not a shared meaning, and is
deliberately **not** a reason to introduce a generic image type. The semantic
difference is what lets a function signature refuse the wrong input.

## Decision 7 — Every conversion requires an explicit transform

`RAWWorkingColorConverter.convert(_:using:)` has no default argument, on any
overload. The caller names one of three things, visibly, at the call site.

## Decision 8 — There is no implicit metadata or default transform

There is no `defaultTransform`, no `cameraTransform`, no `fromMetadata`, and no
converter entry point that discovers a matrix for itself. There is no fallback
order — nothing "falls back to `rgbFromCamera` when a profile is missing",
because that policy does not exist. The converter receives no `RAWMetadata` and
has no parameter one could arrive through.

## Decision 9 — The IR-safe first transform is identity false-colour assignment

`RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor` assigns:

```text
camera sensor R  →  working-space R coordinate
camera sensor G  →  working-space G coordinate
camera sensor B  →  working-space B coordinate
```

with the exact identity matrix. It is the assumption-minimal way to place an
infrared capture's sensor responses into a defined coordinate system: the
coordinates become well-defined, and nothing is claimed about how they relate
to perceived colour.

## Decision 10 — Identity assignment is explicitly not a calibration

It is not called a camera calibration, "correct colour" or "accurate sRGB", and
the wording is enforced in the source name, the documentation, the recorded
provenance and the fixture diagnostics.
`RAWCameraToWorkingColorTransformSource.isValidatedInfraredCalibration` is
`false` for every source this milestone can produce, written as an exhaustive
switch so a future source has to answer the question rather than inherit an
answer.

## Decision 11 — Identity conversion is bit-preserving

The identity matrix takes a dedicated path that performs no arithmetic, so for
every input `Float`:

```text
output bitPattern == input bitPattern
```

including `-0.0`, negative values, values above `1` and very large finite
values. Routing identity through `1×r + 0×g + 0×b` in `Double` would turn
`-0.0` into `+0.0`; the dedicated path does not.

The values are handed to the result as the same immutable `Array`, so
copy-on-write shares one backing buffer rather than duplicating 148 MB to prove
the stage allocated something. Both sides expose `let` values, so the sharing
is unobservable. Bit identity is the contract; a `memcpy` would satisfy it more
expensively and no more truly.

The input is still swept for non-finite values on this path, so a
converter-produced image holds finite values whichever path made it.

## Decision 12 — Custom 3×3 transforms are supported explicitly

`RAWCameraToWorkingColorTransform.explicit(matrix:)` carries a caller-supplied
matrix with `.explicit` provenance. This is the route a future profile system
will use: it can produce transforms without the converter primitive changing at
all.

## Decision 13 — Matrix coefficients are immutable `Double` values

`RAWColorMatrix3x3` holds nine `Double` coefficients in a fixed shape, with one
documented convention:

```text
             ⎡ m00 m01 m02 ⎤   ⎡ cameraR ⎤
workingRGB = ⎢ m10 m11 m12 ⎥ × ⎢ cameraG ⎥
             ⎣ m20 m21 m22 ⎦   ⎣ cameraB ⎦
```

Rows are output channels; columns are input camera channels. Nine scalars
rather than nested arrays, so the shape cannot be malformed and size validation
belongs only where variable-shaped data actually enters the project. `Double`
because nine coefficients cost nothing and matrix arithmetic benefits; image
storage stays `Float32`.

## Decision 14 — Arithmetic accumulates in `Double` and stores `Float`

Each output channel is one dot product accumulated in `Double` and narrowed to
`Float` exactly once. `Float32` intermediates can overflow where the
mathematical result cannot: `2 × greatestFiniteMagnitude − greatestFiniteMagnitude`
reaches infinity on the first multiplication in `Float` and never returns, while
`Double` finishes at a value `Float` represents perfectly.

There is no `Double` image buffer — the widening lives in three local
accumulators. A `Double` result that is not finite, and a finite `Double` that
overflows on narrowing, both fail with a typed error carrying the coordinate
and the channel rather than being clamped to a plausible number.

## Decision 15 — Matrices may be negative, singular and non-normalised

Only non-finite coefficients are refused. Zero, negative and greater-than-one
coefficients, singular matrices, channel-swap matrices and rows that do not sum
to `1` are all accepted. Requiring positivity, invertibility or normalisation
would import visible-light colour-matrix expectations into a project whose
subject is infrared false colour. Nothing in this milestone inverts a matrix.

## Decision 16 — No clamping occurs

Not to `0...1`, not by absolute value, not by per-pixel renormalisation, not by
row normalisation, and not by gamut mapping. A later display or export stage
decides what to do with out-of-range coordinates.

## Decision 17 — Visible-light `rgbFromCamera` is opt-in only

`RAWCameraToWorkingColorTransform.visibleLightMetadata(from:)` is the only
route to it, and the words `visibleLight` are in the name deliberately. There
is no ambiguous `fromMetadata`, `cameraTransform` or `defaultTransform`.

## Decision 18 — Visible-light metadata is not assumed IR-valid

`rgbFromCamera` is vendor or decoder data calibrated for visible light. An
infrared-converted body shooting through an IR filter is precisely the case it
does not describe. Using it is a diagnostic act, and every result derived from
it is labelled as a **visible-light metadata transform, diagnostic only for
this IR capture** — not an IR camera calibration, not a camera-model IR
profile, not a filter profile, not a recommendation, and not a claim of
colourimetric accuracy.

## Decision 19 — The 3×4 metadata matrix is representable only with a zero fourth column

The demosaiced image has exactly three input channels. LibRaw's matrix has four
columns, so it can be represented here only when the fourth contributes nothing:

```text
⎡ r0 r1 r2 0 ⎤        ⎡ r0 r1 r2 ⎤
⎢ g0 g1 g2 0 ⎥   →    ⎢ g0 g1 g2 ⎥
⎣ b0 b1 b2 0 ⎦        ⎣ b0 b1 b2 ⎦
```

Both `+0.0` and `-0.0` count as zero. There is deliberately **no epsilon**: the
contract is exact. Structural problems — a missing matrix, the wrong number of
rows, a row that is not four coefficients long, a non-finite coefficient — are
each their own typed error, and malformed nested arrays are never indexed past.

For the reference camera this is not hypothetical: the E-PL3 fixture's
`rgbFromCamera` fourth column is exactly zero, so the matrix is representable
and the adapter derives its first three columns unchanged.

## Decision 20 — The fourth component is never silently discarded

A non-zero fourth coefficient fails with
`incompatibleVisibleLightCameraMatrix`, carrying the row and the value. It is
not truncated, not merged into another column, not reduced modulo anything, and
not reinterpreted.

## Decision 21 — Camera and daylight white-balance metadata is not reapplied

White balance already happened, per CFA plane, in the mosaic domain
([ADR 0003](0003-infrared-white-balance.md)). `cameraMultipliers` and
`daylightMultipliers` are read by no code path in this stage; applying them
here would be a second white balance.

## Decision 22 — `cameraFromXYZ` is not used or inverted

The first colour adapter uses only the explicitly requested `rgbFromCamera`
path. `cameraFromXYZ` is not read, not inverted, and not used to synthesise a
transform when `rgbFromCamera` is absent. An absent matrix is an error, not an
invitation to invent one.

## Decision 23 — No gamma, tone mapping or display encoding happens

The stage's provenance record states all of it: not clamped, no gamma, no tone
mapping, no display encoding, no orientation. No `CGImage`, `CIImage`,
`NSImage` or SwiftUI `Image` is produced, and nothing is quantised to 8-bit.
The milestone ends at a linear working-space Float image.

## Decision 24 — Processed upstream state is retained for reprocessing

`WorkingColorProcessedRAWImage` holds the `DemosaicedProcessedRAWImage` it came
from, which holds the white-balanced mosaic, the normalised mosaic, and the
decoded `UInt16` mosaic with its metadata.

```text
change the transform      → restart at DemosaicedRAWRGBImage
change demosaic algorithm → restart at WhiteBalancedRAWMosaic
change the gains          → restart at ProcessedRAWMosaic (normalised)
```

Transforms never compose: `convert(using:replacing:)` reaches through `.source`
and never touches the previous working buffer, so replacing `M1` with `M2`
yields `M2 × cameraRGB`, not `M2 × (M1 × cameraRGB)`.

The wrapper's initialiser is module-internal from the start, as all three
upstream wrappers now are: outside the module the pairing can be read in full
but not minted, so a source from one run cannot be attached to a result from
another. The same protection `RAWWhiteBalanceEstimate` gives gains and their
provenance, and `RAWCameraToWorkingColorTransform` gives a matrix and its
source.

## Decision 25 — Future IR profiles need no new converter primitive

A filter or capture profile that decides a transform produces a
`RAWCameraToWorkingColorTransform` and hands it to the same `convert`. A new
provenance case would be added when such a subsystem exists — not before, which
is why the source enum has exactly three cases today.

## Decision 26 — Creative channel mixing belongs after this boundary

The channel-swap matrix in the tests is a **mathematical test of the generic
3×3 primitive's orientation**, not an infrared channel mixer. The creative IR
transform is a separate, explicitly named future stage that operates on the
working representation, after the coordinate system is established. Collapsing
creative intent into camera-to-working provenance would make it impossible to
say later what a rendering actually claimed.

## Decision 27 — Preview and display conversion is a separate stage

Encoding these values for a monitor — transfer function, gamut handling,
quantisation — is a later decision this ADR does not make.

## What this ADR does not decide

- **Physical IR colour calibration methodology.** No transform here is a
  validated infrared calibration, and none claims to be.
- The **camera / filter profile format**.
- **Automatic profile selection.** Nothing selects a transform on its own.
- The **channel-mixer model**.
- **Exposure controls.**
- **Tone mapping.**
- **Gamut mapping.**
- **Display encoding.**
- **Export colour management**, including which space files are written in.
- A **Metal / GPU implementation**. This is a CPU reference implementation; no
  optimised-build measurement has been taken and no performance claim is made.
- **Final production demosaicing quality**, which remains where
  [ADR 0005](0005-application-owned-bayer-demosaicing.md) left it.

## Consequences

- The project has a defined working representation for the first time, so
  downstream stages can be designed against something concrete.
- Every camera-to-working mapping is explicit and carries provenance, so a
  rendering can be audited for what it claimed rather than trusted.
- The identity path costs nothing numerically and nothing in memory, which
  makes the IR-safe choice also the cheap one.
- A visible-light matrix can be examined when someone wants to, without it ever
  becoming a default.
- Nothing downstream of this stage exists yet. A `WorkingColorRGBImage` is not
  displayable and must not be written to a file as though it were sRGB until a
  display or export encoding stage exists.
