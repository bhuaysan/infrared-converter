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
              metadata snapshot          ← taken here, before any processing
                      ↓
                   unpack()
                   ↙      ↘
   copy raw_image          dcraw_process() → dcraw_make_mem_image()
          ↓                          ↓
      RAWMosaic                   RAWImage
   (application-owned          (reference / preview only)
    RAW pipeline)
```

- **Mosaic path** — `LibRawDecoder.decodeMosaic(at:)`. `dcraw_process` is never
  called. This is the foundation the application-owned pipeline will be built
  on.
- **Processed-RGB path** — `LibRawDecoder.decode(at:options:)`. Kept as the
  workspace preview and as a diagnostic reference. It is *not* the foundation
  for future processing, and its demosaicing and black/white handling are
  LibRaw's, not ours.

The metadata snapshot is taken before either branch. This matters: LibRaw's
`adjust_bl()` and `subtract_black_internal()` **mutate** `imgdata.color`,
folding `black` into `cblack[0...3]` and then zeroing both. Metadata read after
processing would describe the post-process state, not the file.

## Sample vocabulary

These terms are distinct and must not be used interchangeably.

| Term | What it means | Where it exists |
| --- | --- | --- |
| **Encoded RAW file values** | The bytes in the file: compressed, packed, vendor-specific. | Not exposed by this project. |
| **LibRaw-unpacked sensor mosaic sample** | After LibRaw's format-specific decoding — bit unpacking, byte order, and, for formats that use one, LibRaw's per-format linearisation curve. One sample per mosaic location. | `RAWMosaic.samples` |
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
| Useful precision | 12 bits |
| Min / max sample | 61 / 2187 |
| Metadata maximum | 4095 (0 samples at or above it) |
| Samples below effective black | 11 |

Black levels remain **metadata only** at this stage: global black 0, per-plane
`[64, 64, 64, 64]`. The mosaic still contains that offset, deliberately. The
11 samples below the effective black level are expected — sensor noise
straddles the black point — and are a reason the future subtraction stage must
decide explicitly what to do with negative results rather than clamping by
accident.

## Not yet decided

- Whether black subtraction produces a signed intermediate or clamps, and where.
- The working colour space (ADR 0002), which is downstream of demosaicing.
- Whether the mosaic path should ever expose the masked border, e.g. for
  measuring the black level from the optical-black region instead of trusting
  metadata.
