# Infrared Converter

Infrared Converter is a native macOS application for developing and converting RAW photographs captured for infrared photography.

Its primary purpose is infrared-specific RAW development — extreme/custom infrared white balance, channel mixing and channel swapping, camera/filter-specific color behavior, and false-color rendering. Conventional RAW editing is a secondary concern.

The project is in early development. macOS is the only target platform.

See [CLAUDE.md](CLAUDE.md) for the full project scope, architecture, and engineering guidance.

## Building

Requires macOS 14+ and a Swift 5.10 (or newer) toolchain. Xcode.app is **not**
required — the Command Line Tools are enough.

```bash
swift build
```

```bash
swift test
```

```bash
swift run InfraredConverter
```

There is no external setup step: LibRaw is vendored into the package and built
from source.

### Continuous integration

`.github/workflows/ci.yml` runs `swift build` and `swift test` on macOS for
pushes to `main` and pull requests targeting it. The RAW fixture is not
committed, so the fixture-backed suites skip themselves there.

## Current status

The workspace now shows the application-owned pipeline's own pixels. Opening a
RAW file runs the whole chain from LibRaw's unpacked sensor mosaic to
display-encoded bytes, and nothing LibRaw processed reaches the screen.

```text
LibRaw unpack                    RAWMosaic (UInt16, active area)
   ↓                             RAWMosaicNormalizer
black subtraction, normalisation LinearRAWMosaic (Float32, unclamped)
   ↓                             RAWWhiteBalanceEstimator / RAWWhiteBalancer
infrared white balance           WhiteBalancedRAWMosaic
   ↓                             RAWDemosaicer
bilinear Bayer demosaic          DemosaicedRAWRGBImage (camera-native RGB)
   ↓                             RAWWorkingColorConverter
explicit camera → working 3×3    WorkingColorRGBImage (extended linear sRGB)
   ↓                             IRChannelMixer
IR channel mixing                IRChannelMixedRGBImage (same space, remixed)
   ↓                             DisplayPreviewRenderer
exposure, clip, sRGB, 8 bit      DisplayEncodedPreviewImage (display referred)
   ↓                             DisplayPreviewCGImageAdapter
tagged sRGB                      CGImage → SwiftUI
```

Everything above the last two rows is **scene-linear**, and stays that way: the
display stage reads it and never touches it. After a preview is rendered the
`IRChannelMixedRGBImage` is bit-identical, every value below `0` and above `1`
still in it.

Every stage is application-owned, non-destructive and provenance-carrying:
each result keeps the state it was produced from, so gains, algorithm,
transform, mix or exposure can be changed without decoding again, and each
records what it did and explicitly did not do.

- **White balance** is per CFA plane in the mosaic domain, with no Kelvin
  limits. Gains are supplied explicitly or estimated from a caller-selected
  neutral patch.
- **Demosaicing** is `bilinearBayer` — the current **correctness / reference
  algorithm**, not an image-quality answer. X-Trans is recognised and
  explicitly refused.
- **Camera → working conversion** always takes an explicit,
  provenance-carrying transform. There is no default and no automatic use of
  the file's visible-light colour matrix.
- **Infrared channel mixing** is the first explicitly creative stage: a linear
  3×3 remix inside the working colour space, with identity, red/blue swap and
  explicit-matrix mixes. It changes no colour space and is recorded as creative
  intent, never as a calibration.
- **Display rendering** is exposure in the linear domain, hard display-range
  clipping to `0...1`, the piecewise sRGB transfer function and 8-bit
  quantisation — in that order, with the settings named at the call site and
  the number of clipped samples recorded. It is deliberately **not** a tone
  pipeline.

What the app-owned pipeline puts on screen, for a freshly opened file: a
centred neutral-patch white balance, bilinear demosaicing, the identity
false-colour camera transform, an identity channel mix, `0 EV`, hard clipping
and sRGB. Those choices are made in the application layer, visibly, because no
processing API has a default to make them.

Still legacy diagnostic behaviour: the LibRaw processed-RGB decode. It is no
longer the workspace image. It supplies the inspector's decoder facts and a
small labelled reference thumbnail, and is kept because comparing the two paths
is useful while the owned one is young.

Still absent: any tone control — contrast, curves, highlight recovery,
saturation; orientation, so a file that asks for a flip displays unrotated;
filter and capture profiles, recipes and presets beyond the two built-in mixes;
export of any kind; a reduced-resolution or cached preview path, so the
workspace renders the full frame each time; Metal.

There are two decode paths, and they are not interchangeable:

- **`decodeMosaic(at:)`** — `open → unpack → RAW-state metadata snapshot →
  RAWMosaic`. `dcraw_process` is never called. One LibRaw-unpacked sample per
  sensor mosaic location, active area only. This is the foundation for the
  application-owned pipeline above.
- **`decode(at:options:)`** — the existing processed-RGB path, kept as a
  diagnostic reference only. LibRaw does the demosaicing and the black/white
  handling here, which is exactly why it is not the foundation, and why it is
  no longer what the workspace displays.

The RAW-stage contract — what a sample is at each stage, what has and has not
been applied, the geometry and coordinate rules, and the reference numbers for
the E-PL3 fixture — is [docs/raw-pipeline.md](docs/raw-pipeline.md). The
decisions behind it are recorded as ADRs in
[docs/decisions/](docs/decisions/).

### Tested formats

| Format | Camera | Status |
| --- | --- | --- |
| ORF | Olympus PEN E-PL3 | verified end to end (metadata, mosaic decode, the whole owned pipeline, display preview) |

Reference values for the E-PL3 fixture under LibRaw 0.22.2, unchanged from
0.21.4 — a future decoder upgrade that moves any of them is a finding to
investigate, not a test to adjust:

| | |
| --- | --- |
| Raw readout / active area | 4080 × 3040 / 4056 × 3040 (both margins 0) |
| Full / half output | 4056 × 3040 / 2028 × 1520 |
| CFA | `0xB4B4B4B4`, `RGBG`, source RAW bit depth 12 |
| Black (pre-unpack, RGB path) | global 0, per-plane `[64, 64, 64, 64]`, no pattern |
| Black (post-unpack, mosaic path) | global 64, per-plane `[0, 0, 0, 0]`, no pattern |
| Effective black level | 64 on every plane, either way |
| Maximum / linear maximum | 4095 / `[3680, 3680, 3680, 3680]` |
| Camera WB | `[0.640625, 1.0, 5.5625, 0.0]` |
| Daylight pre-multipliers | `[2.2629104, 0.9284695, 1.2071348, 0.0]` |

Through the whole owned pipeline — centred neutral patch, bilinear demosaic,
identity false-colour transform, identity mix, `0 EV`:

| | |
| --- | --- |
| Preview geometry | 4056 × 3040, unchanged (no orientation applied) |
| Preview buffer | 36 990 720 bytes, 12 168 per row, 8-bit `R G B`, no alpha |
| Samples clipped low / high | 11 / 0 |
| Non-finite intermediates | 0 |

Other formats LibRaw supports (ARW, NEF/NRW, CR2/CR3, RAF, RW2, …) should decode
through the same path, but none has been verified. Nothing in the decoder is
camera-specific.

The reference camera for this project is the **Olympus PEN E-PL3**.

## RAW decoding

`RAWDecoder` is the application-facing boundary; `LibRawDecoder` is the only
implementation, and the only Swift type that imports the LibRaw shim.

```text
SwiftUI  →  DocumentState  →  RAWDecoder  →  LibRawDecoder  →  C shim  →  LibRaw (C++)
```

### The mosaic

`RAWMosaic` is the application-facing unpacked mosaic: active area only,
tightly packed `UInt16`, in the same active-image coordinates as the CFA and
black-level lookups. Values are **not** rescaled — a 12-bit E-PL3 sample stays
in `0...4095` inside a 16-bit cell.

A sample is a **LibRaw-unpacked sensor sample**, not an ADC value: LibRaw's
unpackers apply per-format linearisation curves inside `unpack()` itself. For
the same reason `RAWMosaic.sourceRawBitDepth` is *file-format* information and
never a white level — `2 ^ depth - 1` must not be used as one; normalisation
takes its white level from `RAWMetadata.Levels`.
Everything after that — black subtraction, normalisation, white balance,
demosaicing, colour matrix, gamma, orientation — is recorded on
`RAWMosaicProcessing` as explicitly not applied, and those facts are `let`
constants rather than parameters a caller could set wrongly.

Black levels stay metadata-only at this stage: the mosaic deliberately still
contains the black offset, and `RAWMosaicNormalizer` is what subtracts it,
using LibRaw's post-unpack black-level model — including any level LibRaw
derived from masked pixels during `unpack()`. The mosaic does not expose the
optical-black border, and the app does not estimate black independently.

The mosaic path's metadata is snapshotted **after** `unpack()`, from
`imgdata.rawdata.{iparams,sizes,color}` — the copy LibRaw itself pairs with the
`raw_image` buffer. `unpack()` can move RAW-level metadata (it derives black
from masked pixels where applicable, then canonicalises the common `cblack`
component into `black`), so an earlier snapshot need not describe the samples
that come out of it. One consequence: the two decode paths split the effective
black level differently between `Levels.black` and `Levels.perPlaneBlack`.
Always combine them via `Levels.blackLevel(row:column:colorPlane:)`.

Only LibRaw's single-channel `raw_image` storage is supported. Three/four-channel,
float, Foveon and the `filters == 1` layout fail explicitly with
`unsupportedRawStorage` / `unsupportedSensorLayout` — there is **no silent
fallback to `dcraw_process`**, so an unsupported camera cannot quietly get a
different pipeline.

Extraction honours LibRaw's `raw_pitch` (in bytes) rather than assuming
`rawWidth × 2`; for the E-PL3 those genuinely differ, 8160 source versus an
8112-byte copied stride.

Failures cross that boundary as `RAWDecodingError`. LibRaw's integer codes are
diagnostic detail, not user-facing text: every string surface a user can see —
`errorDescription`, `failureReason`, and `DecoderDiagnostic`'s
`CustomStringConvertible` form — carries the decoder's message and no code. The
code remains available through `DecoderDiagnostic.logDescription`, which is what
the decoder logs.

### Decoded pixel format

| Property | Value |
| --- | --- |
| Bit depth | 16 bits per channel |
| Channels | 3, interleaved RGB |
| Byte order | host (little-endian on Apple silicon and Intel) |
| Row stride | `width × 3 × 2` bytes, reported as `RAWImage.bytesPerRow` |
| Transfer function | linear (`RAWImage.Encoding.linear`) |
| Colour space | camera-native RGB, no matrix applied (`RAWImage.ColorSpace.cameraNative`) |

### What the decoder does — and does not — do

LibRaw is configured so that no irreversible colour decision happens at the
boundary. Every decode returns a `RAWDecoderProcessing` record stating this
explicitly, so no pipeline stage is ever applied twice.

Applied:

- black-level subtraction,
- a linear scale mapping the camera's saturation level to full 16-bit range,
- demosaicing (AHD by default; skipped entirely in half-size mode). LibRaw can
  silently substitute AHD for the requested algorithm, so
  `RAWDecoderProcessing` reports `requestedDemosaic` and `appliedDemosaic`
  separately,
- camera orientation, when requested **and** when the camera actually recorded a
  non-zero flip. `RAWDecoderProcessing` separates the request
  (`orientationHandlingRequested`) from the outcome
  (`appliedOrientationFlip`, and the derived `orientationTransformApplied`), so
  a no-op orientation does not read as a transform.

**Not** applied:

- white balance of any kind — multipliers are forced to unity, so neither the
  as-shot nor LibRaw's daylight pre-multipliers are baked in,
- any colour matrix or colour-space conversion,
- gamma or any other transfer function,
- auto-brightness or exposure scaling,
- highlight reconstruction,
- noise reduction, median filtering or sharpening,
- LibRaw's automatic saturation-level adjustment.

Camera white-balance multipliers, daylight pre-multipliers, and the camera
colour matrices are exposed as **metadata only**. The matrices are calibrated
for visible light and must not be assumed valid for infrared capture.

Full rationale and the exact parameter table:
[docs/decisions/0001-libraw-integration.md](docs/decisions/0001-libraw-integration.md).

### Metadata exposed

`RAWMetadata` reports identity (make, model, normalised make/model, software),
geometry (raw readout, active area, margins, output size, orientation, pixel
aspect), sensor colour layout (Bayer / X-Trans / Foveon / none, CFA code, colour
plane letters, raw bit depth), levels (see below), colour metadata (as-shot and
daylight multipliers, camera matrices), and exposure (ISO, shutter, aperture,
focal length, capture date), plus lens and artist.

Anything the file does not carry is `nil`, never a substituted default.

#### CFA coordinates

`SensorColorLayout.colorPlaneIndex(row:column:)` takes **active-image**
coordinates — row/column `0` is the top-left of the visible area, i.e.
`topMargin`/`leftMargin` into the raw readout.

This is LibRaw's own convention, and the margins are accounted for exactly once:
LibRaw folds `top_margin`/`left_margin` into the `filters` code and into the
`xtrans` table (built from the sensor-absolute `xtrans_abs`) when it parses the
file, so this API must not add them again. Callers holding raw-readout
coordinates convert with
`colorPlaneIndex(rawReadoutRow:rawReadoutColumn:geometry:)`. Both Bayer and
X-Trans lookups wrap out-of-range and negative coordinates.

LibRaw's non-standard 16×16 layout (`filters == 1`) is reported as `.unknown`
and returns `nil`; that table is not carried yet.

#### Black levels

`RAWMetadata.Levels` carries LibRaw's complete black-level model rather than a
flattened summary: the global `black`, the per-colour-plane offsets
`perPlaneBlack`, and the optional repeating `blackPattern` (dimensions **and**
values). `blackLevel(row:column:colorPlane:)` combines them; the terms are kept
separate because this is the model LibRaw exposes right after `open_file()`,
*before* `adjust_bl()` folds `black` into the per-plane offsets. Pattern
coordinates are active-image coordinates, matching LibRaw's own use of it.

How the total is split between `black` and `perPlaneBlack` depends on which
path produced the metadata, because `unpack()` canonicalises the common
`cblack` component into `black`. For the Olympus E-PL3: `black == 0`,
`perPlaneBlack == [64, 64, 64, 64]` before unpack, and `black == 64`,
`perPlaneBlack == [0, 0, 0, 0]` after — effective level 64 either way, no
pattern. Use `blackLevel(row:column:colorPlane:)`; never compare the raw fields
across paths.

#### Decoder warnings

LibRaw's `process_warnings` bitfield is translated into a small typed
`RAWDecoderProcessing.Warning` set. LibRaw only ever ORs bits into it, so the
set grows as the pipeline advances and is readable from the first successful
open onward — the mosaic path captures the warnings visible after `unpack()`,
the RGB path those visible after `dcraw_process`. That is a genuine subset
relationship, not a suppressed zero; the two flags only `dcraw_process` raises
(AHD fallback, bad camera WB) stay mapped regardless. Only flags this build can
actually raise are mapped; flags belonging to back-ends we do not compile (RawSpeed, the DNG SDK,
LittleCMS) or to options we never pass (bad-pixel maps, dark frames) are
deliberately left unmapped, each with its reason recorded in source. The
complete uninterpreted bitfield stays available as `rawWarningBits` for logging
only, and is never surfaced in UI.

## LibRaw

**LibRaw 0.22.2**, vendored under `Sources/CLibRawVendor/` and built as a
SwiftPM C++ target. There is no Homebrew, `pkg-config`, or system-library
dependency, and no architecture-specific path.

The build is split in two so upstream's warnings can be silenced without
silencing ours:

```text
InfraredConverter (Swift)  →  CLibRaw (our shim)  →  CLibRawVendor (upstream)
```

`CLibRawVendor` is upstream source built with `-w`. `CLibRaw` is our plain-C
boundary, built with `-Wall -Wextra`, and it compiles clean. Swift imports
`CLibRaw` only; LibRaw's C++ API is never exposed, and Swift/C++
interoperability is deliberately not used.

Vendoring details, build defines, exclusions and the update procedure:
[Sources/CLibRaw/VENDOR.md](Sources/CLibRaw/VENDOR.md).

LibRaw is dual-licensed LGPL-2.1 / CDDL-1.0. See the ADR for the obligations
that apply before distributing a binary.

## Test fixtures

RAW files are large and usually not redistributable, so none is committed.
Fixture-dependent tests skip cleanly when no file is present.

To run them, drop an Olympus `.ORF` at `RAW/OLYMPUS.ORF`, or:

```bash
INFRARED_TEST_ORF=/path/to/your.ORF swift test
```

See [RAW/README.md](RAW/README.md).

## Known limitations

- `bilinearBayer` is a correctness reference, not a production demosaicer, and
  no X-Trans algorithm exists.
- The display stage clips and encodes; it does not tone map. Detail above `1`
  and below `0` is destroyed, and the provenance record says how many samples
  that was. There is no highlight recovery, no curve and no automatic
  exposure.
- **Orientation is not applied anywhere.** A file that records a flip displays
  unrotated, and the E-PL3 fixture is one. Deliberate: the pipeline has no
  application-owned orientation stage, and hiding a geometry operation inside
  the display encoder would keep it out of the one record meant to describe
  the pipeline.
- Export does not exist. The 8-bit preview buffer is a preview and must not be
  written to a file as though it were one.
- Exposure is not adjustable from the UI. The renderer takes any EV; the
  workspace passes `0` and offers no control, so the retained scene-linear
  chain that would let it re-render is deliberately not held in memory yet.
- No transform in the project is a validated infrared colour calibration. The
  file's own `rgbFromCamera` is visible-light data and is opt-in and
  diagnostic only.
- The mosaic path supports only single-channel `raw_image` storage; no
  three/four-channel, float, Foveon or `filters == 1` file has a mosaic path.
- The mosaic excludes the optical-black border, so the black level cannot be
  measured from masked pixels independently — the app uses LibRaw's own
  post-unpack estimate. Deliberate for V1; see docs/raw-pipeline.md.
- No RAW fixture in the test set raises a LibRaw warning at any stage, so the
  warning-bit lifecycle is tested structurally rather than against an observed
  non-zero bitfield.
- Only Olympus ORF has been verified against a real file.
- The legacy LibRaw preview interprets camera-native linear samples as linear
  sRGB with no white balance, so a visible-light frame shows the sensor's
  native channel imbalance. That is expected, and it is a reference thumbnail
  rather than the workspace image.
- The owned preview renders the full frame on the CPU on every open, with no
  cache and no reduced-resolution path. Preview strategy is a later decision.
- Infrared white balance, channel mixing and a display boundary exist; no
  false-colour mapping, hue remapping, filter profiles or recipes, no develop
  controls, no export.
- The workspace's white-balance patch is a centred rectangle, not a scene
  analysis. Nothing verifies that what is in the middle of the frame is
  neutral, and there is no picker yet.
- The preview is 8 bit with no dithering, so a smooth gradient can band.
- LibRaw's optional back-ends are not enabled: no libjpeg (lossy DNG, JPEG
  thumbnails), no zlib (deflate-compressed DNG), no LittleCMS, no DNG SDK, no
  RawSpeed, no OpenMP.
- Aperture, focal length and capture date come back `nil` for the E-PL3
  fixture. Not investigated yet; it is a metadata-extraction gap, not a
  pipeline one.
- `filters == 1` (LibRaw's 16×16 layout) is reported as an unknown pattern.
