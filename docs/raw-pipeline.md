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
| **Black-corrected sample** | The above, minus the effective black level. | Not implemented yet. |
| **Normalised sample** | Black-corrected and rescaled against the saturation level. | Not implemented yet. |
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
  `imgdata.color.raw_bps`) describes the *file*: how many bits a sample
  occupied before LibRaw touched it. It is optional, and stays `nil` when the
  decoder reports nothing — no `16` is ever substituted.
- **The unpacked numeric domain** is whatever `unpack()` produced. Several
  formats pass samples through a per-format linearisation curve inside
  `unpack()`, which can move values outside the source depth's nominal range;
  LibRaw updates `maximum` when it does.
- **The white level** is `RAWMetadata.Levels.maximum` (and per-plane
  `linearMaximum`), read from the same post-unpack RAW state as the samples.

So `2 ^ sourceRawBitDepth - 1` is **not** the authoritative white level and must
never be used as one. The future normalisation stage is conceptually

```text
(sample - black) / (white - black)
```

with `black` from `Levels.blackLevel(row:column:colorPlane:)` and `white` from
the level metadata or an explicitly selected white-level model — never derived
from the bit depth. None of this is implemented yet.

For `.uint16` mosaic storage a reported source depth of `1...16` is accepted and
`nil` is accepted; `0`, a negative value, or anything above `16` makes
`RAWMosaic.isGeometryConsistent` false. A depth wider than the storage is a
claim the storage cannot hold, so it is rejected rather than believed — and in
no case is the value used to rescale samples.

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
and are a reason the future subtraction stage must decide explicitly what to do
with negative results rather than clamping by accident.

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

- Whether black subtraction produces a signed intermediate or clamps, and where.
- The working colour space (ADR 0002), which is downstream of demosaicing.
- Whether the mosaic path should ever expose the masked border, e.g. for
  measuring the black level from the optical-black region instead of trusting
  LibRaw's own estimate (see "Masked pixels and who owns black estimation").
