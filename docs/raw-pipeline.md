# RAW pipeline — the RAW-stage contract

This document defines what a sample *is* at each stage of the RAW path, and
which stages have and have not run. It covers the RAW stage only: everything
from demosaicing onward, including the working colour space, is deliberately
out of scope and undecided.

`CLAUDE.md` holds the project invariants; this file records the concrete
implementation as it currently stands.

## Two paths out of LibRaw

The project currently has two decode paths. They share an open and an unpack
and then diverge, and they are not interchangeable.

```text
                 open_file()
                      ↓
        current-state metadata snapshot     ← imgdata.{idata,sizes,color}
                      ↓
                   unpack()
                   ├─ format-specific decode / optional linearisation
                   ├─ crop_masked_pixels() where applicable
                   └─ cblack/black canonicalisation, then the RAW-state copy
                   ↙      ↘
  RAW-state metadata        dcraw_process() → dcraw_make_mem_image()
   snapshot                            ↓
          ↓                         RAWImage
   copy raw_image              (reference / preview only)
          ↓
      RAWMosaic
   (application-owned
    RAW pipeline)
```

- **Mosaic path** — `LibRawDecoder.decodeMosaic(at:)`. `dcraw_process` is never
  called. This is the foundation the application-owned pipeline will be built
  on.
- **Processed-RGB path** — `LibRawDecoder.decode(at:options:)`. Kept as the
  workspace preview and as a diagnostic reference. It is *not* the foundation
  for future processing, and its demosaicing and black/white handling are
  LibRaw's, not ours.

## The application-owned pipeline so far

```text
RAW file
   ↓
LibRaw unpack
   ↓
RAWMosaic (UInt16)                    ← LibRaw's responsibility ends here
   ↓
application black subtraction         ┐
   ↓                                  ├ RAWMosaicNormalizer
application normalisation to Float32  ┘
   ↓
LinearRAWMosaic (Float32, unclamped)
   ↓
explicit per-CFA-plane IR gains       ┐
   ↓                                  ├ RAWWhiteBalancer
WhiteBalancedRAWMosaic (Float32)      ┘
   ↓
[FUTURE: IR white-balance gain estimation — picker, patch, profiles]
   ↓
[FUTURE: demosaic]
```

Both processing stages are application-owned and neither imports `CLibRaw`.

`RAWMosaicNormalizer` takes a `DecodedRAWMosaic` (or a bare `RAWMosaic` plus
level metadata) and returns a `ProcessedRAWMosaic`, which keeps the original
`UInt16` mosaic reachable on `.source` — nothing is mutated in place.

`RAWWhiteBalancer` takes a `ProcessedRAWMosaic` (or a bare `LinearRAWMosaic`
plus gains) and returns a `WhiteBalancedProcessedRAWMosaic`, which keeps the
normalised mosaic reachable on `.source` for the same reason.

**Gain estimation does not exist yet.** Nothing in the project decides what the
gains should be; every caller supplies them. The estimation stage above is a
placeholder for future work, not a description of current behaviour.

### Black subtraction and normalisation

For every sample, with `black` the effective black level at that coordinate and
colour plane and `white` the white-level policy's level:

```text
black = levels.blackLevel(row:column:colorPlane:)
white = levels.maximum                       (.metadataMaximum policy)

value = (Float(sample) - Float(black)) / Float(white - black)
```

| Input | Output |
| --- | --- |
| `sample == black` | `0` |
| `sample == white` | `1` |
| `sample < black` | `< 0`, preserved |
| `sample > white` | `> 1`, preserved |

**Nothing is clamped, in either direction.** Negatives are real — sensor noise
straddles the black point — and values above 1 are highlight information that a
later, explicit stage may want. `Levels.linearMaximum` is metadata only: it is
never applied, clipped at, or normalised against. `sourceRawBitDepth` is not
used at all. See `docs/decisions/0002-raw-normalization.md`.

Invalid decoded metadata fails loudly rather than being worked around. A white
level that is not above the effective black level has no denominator and raises
`RAWProcessingError.invalidNormalizationRange`, carrying both levels and the
coordinate and plane where it was found. For any metadata this stage accepts,
every output value is finite.

Only the *sum* `Levels.blackLevel(...)` returns is ever read, so how the
effective black is split between `black`, `perPlaneBlack` and `blackPattern`
cannot change the result — the pre-unpack and post-unpack E-PL3 splits produce
bit-identical output.

### Infrared white balance

For every sample, with `gain` the multiplier for that sample's CFA colour
plane:

```text
value = linear * gain
```

That is the whole operation: no offset, no renormalisation, no exposure
compensation. Gains are **literal**. `0.25` with a gain of `4` is exactly `1.0`,
and doubling every gain doubles every output value. Nothing normalises green to
`1`, divides through by the largest or smallest gain, preserves luminance, or
rescales against camera metadata.

`RAWWhiteBalanceGains` carries **four** slots, indexed by the CFA colour-plane
index from `SensorColorLayout.colorPlaneIndex(row:column:)` — not by
`colorCount`. On the E-PL3 the layout reports `colorDescription "RGBG"` and
`colorCount 3`, yet the CFA lookup returns plane `3`:

```text
0 1     R  G1
3 2     G2 B
```

Sizing the gain model from `colorCount`, or reducing a plane index modulo it,
would apply red's gain to every second green sample. The two green gains are
independently representable and are never forced to agree; a plane index
outside `0...3` raises `RAWProcessingError.missingWhiteBalanceGain` rather than
being folded onto an existing slot.

Gains must be finite and strictly greater than zero. There is no upper bound:
infrared capture legitimately needs extreme multipliers, and `0.01`, `20` and
`100` are all accepted. Zero, negative, NaN and infinite gains raise
`RAWProcessingError.invalidWhiteBalanceGain`, validated in full before any
pixel is touched.

Nothing is clamped. Negatives stay negative, which matters for later
neutral-region statistics, and values above `1` stay above `1`. A finite input
that overflows `Float32` raises
`RAWProcessingError.nonFiniteWhiteBalanceResult` rather than being clamped to
`greatestFiniteMagnitude` or stored as an infinity; a non-finite input raises
`RAWProcessingError.nonFiniteInputValue`.

`cam_mul` and `pre_mul` are **never** applied. They are visible-light-calibrated
diagnostics and are not a reasonable infrared default. The enforcement is
structural: `apply(to:gains:)` receives a mosaic and a set of gains and no
metadata at all, so there is nothing for a camera white balance to leak in
through. The metadata stays reachable on the wrapper for display and for a
future estimator that may deliberately consult it.

Changing gains always restarts from the normalised mosaic:

```text
new result = apply(new gains, the normalised mosaic)
       NOT   apply(new gains, the previous white-balanced result)
```

`apply(gains:replacing:)` reaches through a previous result to its normalised
source, so gains cannot compound. See
`docs/decisions/0003-infrared-white-balance.md`.

### What the linear stage does not do

| Stage | Applied? |
| --- | --- |
| Black subtraction | **yes** |
| White-level normalisation | **yes** |
| Clamping / clipping | no |
| White balance | no |
| Demosaicing | no |
| Camera colour matrix | no |
| Gamma / transfer function | no |
| Orientation | no |

Each is recorded as a `let` constant on `RAWLinearProcessing`, alongside the
white-level policy and the white level actually used.

### What the white-balance stage does not do

| Stage | Applied? |
| --- | --- |
| Per-CFA-plane white-balance gains | **yes** |
| Clamping / clipping | no |
| Gain normalisation of any kind | no |
| Camera / daylight multipliers | no |
| Gain estimation | no |
| Demosaicing | no |
| Camera colour matrix | no |
| Gamma / transfer function | no |
| Orientation | no |

Each is recorded on `RAWWhiteBalanceProcessing`, alongside the exact gains
applied and their `RAWWhiteBalanceSource` (only `.explicit` exists today). The
gains are recorded as numbers, not as a label, so any result is reproducible
from provenance alone.

### The two metadata snapshots

Both paths snapshot metadata before any *processing*, but they snapshot
different LibRaw state, deliberately.

| | Mosaic path | Processed-RGB path |
| --- | --- | --- |
| Taken | after `unpack()` | after `open_file()` |
| Source | `imgdata.rawdata.{iparams,sizes,color}` | `imgdata.{idata,sizes,color}` |
| Describes | the samples in `RAWMosaic` | the file as parsed |

Why the mosaic path waits, and why it reads `rawdata`:

- **`unpack()` can change RAW-level metadata.** For `raw_image` files it calls
  `crop_masked_pixels()` to derive black levels from the optical-black border,
  and then canonicalises the common component of `cblack[0...3]` into `black`
  (`i = min(cblack[0...3])`, subtracted from each entry and added to `black`).
  A snapshot taken before `unpack()` therefore need not describe the samples
  that come out of it.
- **`imgdata.rawdata.color` is the copy LibRaw itself takes** at the very end
  of `unpack()`, in the same statement block that publishes the `raw_image`
  buffer. It is the state LibRaw pairs with those samples. The live
  `imgdata.color`, by contrast, is what `raw2image_ex()` restores *from*
  `rawdata` and then `adjust_bl()`/`subtract_black_internal()` mutate — folding
  `black` into `cblack[0...3]` and zeroing both — and `scale_colors()` rewrites
  `maximum`.

So the mosaic's metadata and its samples describe the same RAW state by
construction, not because the path happens to stop early. Immediately after
`unpack()` the two states are identical copies; they diverge only once
`dcraw_process` runs.

The consequence for callers: **how the effective black level is split between
`Levels.black` and `Levels.perPlaneBlack` differs between the two paths**, and
neither split is wrong. Always combine them through
`Levels.blackLevel(row:column:colorPlane:)`; never compare the fields across
paths and never pre-sum them by hand.

## Sample vocabulary

These terms are distinct and must not be used interchangeably.

| Term | What it means | Where it exists |
| --- | --- | --- |
| **Encoded RAW file values** | The bytes in the file: compressed, packed, vendor-specific. | Not exposed by this project. |
| **LibRaw-unpacked sensor mosaic sample** | After LibRaw's format-specific decoding — bit unpacking, byte order, and, for formats that use one, LibRaw's per-format linearisation curve. One sample per mosaic location. | `RAWMosaic.samples` |
| **Source RAW bit depth** | How wide a sample was *in the file*, per the format parser. Source/file-format information only. | `RAWMosaic.sourceRawBitDepth`, `SensorColorLayout.sourceRawBitDepth` |
| **White / saturation level** | The value a normalisation stage treats as full scale. | `RAWMetadata.Levels.maximum` / `linearMaximum` |
| **Black-corrected sample** | The above, minus the effective black level. | An intermediate inside `RAWMosaicNormalizer`; never a stored representation. |
| **Normalised sample** | Black-corrected and rescaled against the saturation level, as `Float32`. Not clamped. | `LinearRAWMosaic.values` |
| **Demosaiced camera RGB** | Three channels per pixel, camera-native primaries, no matrix applied. | `RAWImage` (produced by LibRaw, on the reference path only) |
| **Working representation** | The project's defined internal processing space. | Not defined. Requires ADR 0002. |

### Unpacked samples are not ADC values

This is worth stating explicitly because it is easy to assume otherwise.

LibRaw's unpackers are not pure bit-shufflers. Several apply a per-format
linearisation curve during `unpack()` itself — the `RAW(row, col) = curve[...]`
pattern in `Sources/CLibRawVendor/src/decoders/decoders_dcraw.cpp` and
elsewhere. So a `RAWMosaic` sample is *LibRaw's unpacked value*, which is the
most upstream representation this project can obtain through LibRaw, but it is
**not** guaranteed to be an untouched sensor ADC reading.

Describing these as "raw sensor values" would overstate the guarantee. The
codebase and this document use "LibRaw-unpacked" throughout.

## What the mosaic path does and does not apply

Every one of these is recorded as a fact on `RAWMosaicProcessing`, as a `let`
constant rather than a caller-settable parameter.

| Stage | Applied? | Why |
| --- | --- | --- |
| LibRaw format decoding + linearisation curve | **yes** | Inherent to `unpack()`; see above. |
| Black-level subtraction | no | `adjust_bl()`/`subtract_black_internal()` are reachable only from `dcraw_process`/`raw2image_ex`. |
| White-level normalisation | no | Same. |
| White balance | no | Verified: `unpack()` and every file in `src/decoders/` read **no** `imgdata.params` fields at all, so `user_mul`, `use_camera_wb` and the rest cannot affect the mosaic. |
| Demosaicing | no | One sample per mosaic location. |
| Camera colour matrix | no | `dcraw_process` only. |
| Gamma / transfer function | no | `dcraw_process` only. |
| Orientation | no | Mosaic geometry is the sensor's own active-area layout. |

## Bit depth is not a white level

These three are distinct, and conflating them would silently mis-scale every
image:

```text
source RAW bit depth
        ≠
LibRaw-unpacked sample numeric domain
        ≠
white / saturation level
```

- **Source RAW bit depth** (`RAWMosaic.sourceRawBitDepth`, from LibRaw's
  `imgdata.color.raw_bps`) describes the *file*: for most cameras, including
  the reference fixture, how many bits a sample occupied before LibRaw touched
  it. It is optional, and stays `nil` when the decoder reports nothing — no
  `16` is ever substituted.

  It is not universally a literal bit depth. For some formats — Phase One
  among them — LibRaw sets `raw_bps` to a RAW format code instead. No
  processing behaviour is built on this value, which is why that ambiguity is
  harmless here, and it is exactly why nothing downstream may start depending
  on it.
- **The unpacked numeric domain** is whatever `unpack()` produced. Several
  formats pass samples through a per-format linearisation curve inside
  `unpack()`, which can move values outside the source depth's nominal range;
  LibRaw updates `maximum` when it does.
- **The white level** is `RAWMetadata.Levels.maximum` (and per-plane
  `linearMaximum`), read from the same post-unpack RAW state as the samples.

So `2 ^ sourceRawBitDepth - 1` is **not** the authoritative white level and must
never be used as one. The normalisation stage described below takes `black`
from `Levels.blackLevel(row:column:colorPlane:)` and `white` from an explicitly
selected white-level policy — never from the bit depth.

Because it is not universally a literal bit depth, it is **diagnostic metadata
and never a storage invariant**. `RAWMosaic.isGeometryConsistent` validates
facts about the in-memory representation — width, height, stride, byte count,
overflow, sample storage — and does not consult `sourceRawBitDepth` at all. Any
reported value, `nil` included, leaves an otherwise valid `UInt16` mosaic valid
and its samples untouched; the value is never used to rescale anything.

## Masked pixels and who owns black estimation

For V1, application-owned black subtraction will use **LibRaw's post-unpack
black-level model**, including any black level LibRaw derived from masked
(optical-black) pixels inside `crop_masked_pixels()` during `unpack()`. This is
a deliberate choice, not an oversight.

The project does **not**:

- expose the optical-black border samples in `RAWMosaic` (it is active-area
  only),
- independently estimate black from that border,
- override LibRaw's black estimation.

Independent black estimation from masked pixels is a plausible later
calibration feature, and would be its own explicit, testable stage. It is out
of scope here.

## Geometry and coordinates

`RAWMosaic` contains the **active image area only** — LibRaw's optical-black
border is excluded.

```text
raw readout (raw_width × raw_height)
 ┌─────────────────────────────────┐
 │  optical black / masked border  │
 │   ┌─────────────────────────┐   │
 │   │  active area            │   │  ← RAWMosaic covers exactly this
 │   │  (0,0) here             │   │
 │   └─────────────────────────┘   │
 └─────────────────────────────────┘
   ↑ leftMargin      ↑ topMargin
```

Coordinates are **active-image coordinates**, the same convention used by
`SensorColorLayout.colorPlaneIndex(row:column:)` and
`Levels.blackLevel(row:column:colorPlane:)`. Margins are applied exactly once,
by the extraction; do not apply them again when indexing.

### Row stride

`RAWMosaic` **supports padded row stride**: `bytesPerRow` need only be at least
`width × bytesPerSampleValue`, and both its own sample lookup and
`RAWMosaicNormalizer` honour whatever stride it declares. `LibRawDecoder`'s
current active-area extraction happens to produce tightly packed rows, but that
is a property of that one producer, not a guarantee of the type.

LibRaw's source buffer uses `imgdata.sizes.raw_pitch`, **in bytes**, which is
not always `raw_width × 2` — some decoders set a wider pitch. The extraction
honours it row by row and copies into a tightly packed destination:

```text
source raw pitch  →  copied tight RAWMosaic stride
raw_pitch bytes      width × 2 bytes
```

For the Olympus E-PL3 these genuinely differ — 8160 bytes source, 8112 bytes
destination — because the raw readout is 24 columns wider than the active area.

## Supported RAW storage

`unpack()` zeroes all six of LibRaw's `rawdata` storage aliases and then
populates exactly one, so classifying by which is non-null is valid.

| LibRaw storage | Supported | Result |
| --- | --- | --- |
| `raw_image` | **yes** | `RAWMosaic` |
| `color3_image`, `color4_image` | no | `unsupportedRawStorage` |
| `float_image`, `float3_image`, `float4_image` | no | `unsupportedRawStorage` |
| nothing populated | no | `unsupportedRawStorage` |
| Foveon, or `filters == 1` (16×16 layout) | no | `unsupportedSensorLayout` |

There is **no silent fallback to `dcraw_process()`**. An unsupported file fails
explicitly, so a future camera cannot quietly get a different pipeline.

## Reference values — Olympus E-PL3

Measured from `RAW/OLYMPUS.ORF` under LibRaw 0.22.2.

| | |
| --- | --- |
| Raw readout | 4080 × 3040 |
| Active mosaic | 4056 × 3040, margins 0 / 0 |
| LibRaw `raw_pitch` | 8160 bytes |
| Copied row stride | 8112 bytes |
| Storage / format | `raw_image`, `UInt16` |
| Source RAW bit depth | 12 |
| Min / max sample | 61 / 2187 |
| Metadata maximum / linear maximum | 4095 (0 samples at or above it) / `[3680, 3680, 3680, 3680]` |
| Samples below effective black | 11 |
| Per-CFA-plane means (sparse) | 584.5 / 423.3 / 137.2 / 430.4 |

Black levels remain **metadata only** at this stage, and this fixture shows the
`unpack()` redistribution concretely:

| State | `black` | `cblack[0...3]` | effective per-plane black |
| --- | --- | --- | --- |
| pre-unpack (`imgdata.color`) | 0 | `[64, 64, 64, 64]` | 64 |
| post-unpack (`imgdata.rawdata.color`) | 64 | `[0, 0, 0, 0]` | 64 |

`crop_masked_pixels()` contributes nothing here — the E-PL3 reports zero
margins, so there is no masked border to estimate from — and the entire change
is the canonicalisation. The effective level is unchanged, which is why nothing
downstream that goes through `blackLevel(row:column:colorPlane:)` moves.

The mosaic still contains that offset, deliberately. The 11 samples below the
effective black level are expected — sensor noise straddles the black point —
and they are why the subtraction stage decides explicitly to keep negative
results rather than clamping by accident.

### After normalisation

Measured over the full 12 330 240-value buffer, white level 4095, effective
black 64, denominator 4031.

| | |
| --- | --- |
| Minimum | −0.000744 = `(61 − 64) / 4031` |
| Maximum | 0.526668 = `(2187 − 64) / 4031` |
| Mean | 0.082318 |
| Per-plane means (0/1/2/3) | 0.129994 / 0.089637 / 0.018121 / 0.091529 |
| Values below 0 | 11 (0.0000892 %) |
| Values exactly 0 | 6 |
| Values above 1 | 0 (0 %) |
| Non-finite values | 0 |
| Output storage | `[Float]`, 49 320 960 bytes |

No value in this frame exceeds 1 because its largest sample, 2187, is well
under the white level. That is a fact about this exposure, not a clamp; the
synthetic suite proves values above 1 survive.

### After white balance with diagnostic test gains

> These gains are **test-only**. They are not an E-PL3 calibration, not a
> recommendation, not an IR filter profile, and not the output of any
> estimator. They are four distinct numbers chosen so each plane's
> contribution is individually identifiable — in particular so plane 3 cannot
> be confused with plane 1.

Gains by CFA colour plane: `[2, 3, 4, 5]`, applied to the normalised buffer
above.

| | Before WB | After WB |
| --- | --- | --- |
| Minimum | −0.000744 | −0.002977 |
| Maximum | 0.526668 | 2.333168 |
| Mean | 0.082318 | 0.264747 |
| Plane 0 mean (R, gain 2) | 0.129994 | 0.259987 |
| Plane 1 mean (G1, gain 3) | 0.089637 | 0.268910 |
| Plane 2 mean (B, gain 4) | 0.018112 | 0.072448 |
| Plane 3 mean (G2, gain 5) | 0.091529 | 0.457644 |
| Values below 0 | 11 | 11 |
| Values exactly 0 | 6 | 6 |
| Values above 1 | 0 | 32 208 (0.261 %) |
| Non-finite values | 0 | 0 |
| Output storage | 49 320 960 bytes | 49 320 960 bytes |

Each per-plane mean scales by exactly its own plane's gain, which is what makes
this table a check on plane addressing rather than a set of magic numbers. The
two green planes scale by 3 and 5 respectively, confirming they are handled
independently despite `colorCount == 3`.

The negative count is unchanged, because every gain is strictly positive and
multiplying by a positive number cannot change a sign. Values above 1 appear
for the first time and are kept.

Apply time for the full 12 330 240-value buffer is roughly 2.7 s in a **debug**
build (`-Onone`, bounds checks on, one CFA lookup per sample). No optimised-build
measurement has been taken, and no performance claim is made from this number.

## Decoder warnings by stage

LibRaw accumulates `process_warnings` with `|=` and never clears it outside
`recycle()`, so the set only grows as the pipeline advances. The shim's
`ir_libraw_warning_bits` therefore requires only a successful open, **not** a
successful `dcraw_process`.

| Warning | Raised in | Mosaic path | RGB path |
| --- | --- | --- | --- |
| `vendorCropSuggested` | `identify()` | yes | yes |
| `jpegDecodingUnavailable` | `identify()` | yes | yes |
| `fujiProcessingApplied` | `parse_fuji()` | yes | yes |
| `fallbackToAHDDemosaic` | `dcraw_process()` | no | yes |
| `badCameraWhiteBalance` | `scale_colors()` | no | yes |

What the mosaic path reports is a genuine prefix of the full set, not a
suppressed zero. Flags one path cannot raise stay mapped, because the other
can.

## Not yet decided

- The working colour space, which is downstream of demosaicing.
- How infrared white-balance gains should be *chosen*. ADR 0003 records how
  they are applied; nothing yet estimates them.
- Whether the mosaic path should ever expose the masked border, e.g. for
  measuring the black level from the optical-black region instead of trusting
  LibRaw's own estimate (see "Masked pixels and who owns black estimation").
