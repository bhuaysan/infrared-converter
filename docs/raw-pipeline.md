# RAW pipeline — the RAW-stage contract

This document defines what a sample *is* at each stage of the RAW path, and
which stages have and have not run.

It now covers two domains. The **mosaic domain** runs from LibRaw's unpacked
samples to a white-balanced CFA mosaic: one value per sensor location, colour
known only through the sensor layout. The **camera-native RGB domain** begins
at demosaicing: three values per pixel, still linear, still camera-native, and
still not in any colour space.

Demosaicing itself is decided — one application-owned reference algorithm, see
`docs/decisions/0005-application-owned-bayer-demosaicing.md`. What comes after
it is not: the working colour space, the camera colour transform, tone mapping
and display encoding all remain undecided.

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
════════════════════ MOSAIC DOMAIN ═════════════════════
one value per CFA location; colour only via the layout

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
   │
   ├───→ measure a selected patch   ┐
   │              ↓                 ├ RAWWhiteBalanceEstimator
   │     RAWWhiteBalanceGains       ┘
   │              │
   ↓              ↓
   └───→ apply per-CFA-plane IR gains   ┐
                  ↓                     ├ RAWWhiteBalancer
       WhiteBalancedRAWMosaic           ┘

═══════════ the mosaic domain ends here ════════════════
                  ↓
       application bilinear Bayer demosaic   ┐
                  ↓                          ├ RAWDemosaicer
       DemosaicedRAWRGBImage                 ┘

═══════════ CAMERA-NATIVE RGB DOMAIN ═══════════════════
three Float32 per pixel; linear; NOT a colour space

                  ↓
       [FUTURE: camera-native RGB → working colour space]
                  ↓
       [FUTURE: exposure / tone / display encoding]
                  ↓
       [FUTURE: preview / export]
```

`DemosaicedRAWRGBImage` is **not** sRGB, and must not be labelled as such. No
camera colour matrix has been applied to it; see "Demosaicing" below.

Estimation is **not** a stage downstream of white balance. It reads the
pre-white-balance `LinearRAWMosaic`, produces a `RAWWhiteBalanceGains`, and
that value is what `RAWWhiteBalancer` then applies to the same mosaic. The two
halves meet at the gains, not at the image.

All four stages are application-owned and none imports `CLibRaw`.

`RAWMosaicNormalizer` takes a `DecodedRAWMosaic` (or a bare `RAWMosaic` plus
level metadata) and returns a `ProcessedRAWMosaic`, which keeps the original
`UInt16` mosaic reachable on `.source` — nothing is mutated in place.

`RAWWhiteBalancer` takes a `ProcessedRAWMosaic` (or a bare `LinearRAWMosaic`
plus gains) and returns a `WhiteBalancedProcessedRAWMosaic`, which keeps the
normalised mosaic reachable on `.source` for the same reason.

`RAWWhiteBalanceEstimator` takes a `LinearRAWMosaic` and a rectangular region
and returns a `RAWWhiteBalanceEstimate` — the gains plus the measurement that
produced them. It never multiplies a sample or allocates an image-sized buffer.

`RAWDemosaicer` takes a `WhiteBalancedProcessedRAWMosaic` (or a bare
`WhiteBalancedRAWMosaic`) and returns a `DemosaicedProcessedRAWImage`, which
keeps the white-balanced mosaic reachable on `.source` — and the normalised one
below that — so changing the gains, re-estimating them or switching algorithm
all restart from the right earlier representation.

**Automatic estimation does not exist yet.** The caller still chooses which
samples to measure; nothing decides that on its own, and no filter profile or
saved recipe supplies gains.

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

### Infrared white-balance estimation

`RAWWhiteBalanceEstimator` decides what the gains should be by measuring a
rectangle of the **pre**-white-balance mosaic. It is the only place in the
project with an opinion about that; `RAWWhiteBalancer` still multiplies
literally.

```text
target      = max(mean of every colour plane the layout produces)
gain[plane] = target / mean[plane]        (.preserveStrongestMeasuredPlane)
gain[plane] = 1                           for plane indices the layout never produces
```

`RAWActiveAreaRegion` is an application-owned integer rectangle in the same
active-image coordinates the mosaic uses — not `CGRect`, because selecting
samples is integer counting and a rectangle of 63.5 samples means nothing here.
A negative origin, a non-positive width or height, a far edge that overflows
`Int`, or any extent past the mosaic's edge raises
`RAWProcessingError.invalidActiveAreaRegion`. **A region is never cropped to
fit**: a silently shrunk selection would change which samples were measured
without saying so.

Which colour planes exist is **discovered**, by walking one complete repeating
CFA cell through `SensorColorLayout.colorPlaneIndex(row:column:)` — 8 × 2 for
Bayer, matching the packed `filters` code, and 6 × 6 for X-Trans. No LibRaw CFA
decoding is duplicated. `colorCount` is not consulted, for the same reason the
gain model has four slots. `.foveon`, `.none`, `.unknown`, a malformed X-Trans
table and `filters == 1` all raise
`unsupportedSensorLayoutForEstimation`; a plane index outside `0...3` raises
`unsupportedColorPlaneIndex` rather than being folded.

Two absences that look alike are kept apart:

| Situation | Result |
| --- | --- |
| Plane index the layout never produces | Unused: gain exactly `1` |
| Plane in the layout, no samples in the patch | `insufficientPatchSamples` |

So a three-plane Bayer sensor and an X-Trans table using indices `0...2` both
leave slot `3` at identity, while a 1×1 region on an RGBG sensor fails — which
is exactly why a future UI point picker has to sample a patch, not a pixel.

The statistic is the arithmetic mean, accumulated in `Double` even though the
mosaic stores `Float`: this runs once over a small patch, not per sample in a
12-megapixel loop, and `Float32` accumulation would add avoidable error to the
one number every gain derives from.

**Every finite sample in the region participates.** Nothing is clamped to `0`
or `1`, no shadows or highlights are dropped, no absolute value is taken, no
epsilon is added, and there is no percentile or outlier rejection. Finite
negatives are real black-subtracted noise and lower a mean, as they should. A
NaN or infinite sample raises `nonFiniteInputValue` with its coordinate rather
than being skipped.

A required plane's mean must be finite and strictly positive; zero, negative
and non-finite means raise `invalidPlaneMean`. A ratio that is not a finite
positive `Float32` raises `nonFiniteEstimatedGain` rather than being clamped,
and there is no arbitrary maximum gain — a very small positive mean may
legitimately produce a very large one.

Guarantees of `.preserveStrongestMeasuredPlane`, all tested: every measured
plane gets a finite positive gain, at least one measured gain is exactly `1`,
none is below `1`, applying them equalises the patch means to Float32
precision, unused slots are `1`, and nothing renormalises afterwards. The
policy exists so the estimator does not attenuate the plane carrying the most
signal, which is what dividing through by green or by the weakest plane would
do.

Provenance is `RAWWhiteBalanceSource.neutralPatch`, carrying the region, the
policy, the per-plane sample counts and means, and the target mean. It does not
repeat the gains — those already live on `RAWWhiteBalanceProcessing.gains`, and
two copies could disagree.

That gains and provenance describe the same measurement is enforced by the
public API, not by call-site discipline. `RAWWhiteBalancer` exposes exactly two
operations, and each determines its own provenance:

```text
apply(to:gains:)      → the caller's literal numbers → .explicit
apply(to:estimate:)   → an estimate, whole           → that estimate's own provenance
```

No public method accepts a `RAWWhiteBalanceSource` beside a set of gains; the
one helper that pairs them is private. `RAWWhiteBalanceEstimate` holds `let`
properties behind a module-internal initialiser, as do
`RAWNeutralPatchWhiteBalanceSource`, `RAWNeutralPatchStatistics` and
`RAWColorPlaneStatistics` — all four are readable in full from anywhere, and
mintable only by the estimator that measured them. So gains carrying a
neutral-patch measurement that did not produce them are unrepresentable rather
than merely discouraged.

Cost is `O(samples in the region)` with constant auxiliary memory: four
`Double` sums and four counters. See
`docs/decisions/0004-neutral-patch-white-balance-estimation.md`.

### Demosaicing

`RAWDemosaicer` reconstructs three values per pixel from one value per CFA
location. It is application-owned: it imports no `CLibRaw`, receives no LibRaw
context, and never routes the mosaic back through `dcraw_process`. It is
**not** `RAWDecodeOptions.Demosaic`, which selects LibRaw's own algorithms on
the separate legacy processed-RGB path.

Its input is `WhiteBalancedRAWMosaic`, not `LinearRAWMosaic`, and there is no
overload taking the latter. White balance therefore structurally precedes
interpolation: averaging neighbours whose relative scaling is not yet correct
would mix mismatched quantities, and on this camera the two green planes can
carry different gains. Identity gains remain a valid way to reach this input
unchanged.

#### Supported layouts

Only a genuine repeating 2×2 Bayer RGB mosaic. `pattern == .bayer` is not the
check — that flag says a CFA code was packed, not that the code describes
something a 2×2 algorithm may run on. `RAWBayerCellPattern.resolve` walks the
**complete 8-row × 2-column packed cell** and requires:

| Requirement | Failure |
| --- | --- |
| `.bayer` pattern | `.xTrans`, `.foveon`, `.none`, `.unknown` refused by name |
| `filters != 1` | LibRaw's 16×16 layout refused |
| every position names a colour plane | refused |
| every plane index addressable in `colorDescription` | refused |
| every letter is `R`, `G` or `B` | `E`, `C`, `M`, `Y` refused, never folded onto RGB |
| rows 2…7 restate rows 0…1's **colours** | a taller repeat refused |
| the 2×2 cell is one R, one B, two G | refused |

All failures raise `RAWProcessingError.unsupportedSensorLayoutForDemosaicing`,
carrying the pattern, the algorithm that refused it, and a reason.

The repeat check compares colours, not plane indices. A cell whose lower rows
swap which green *plane* sits in which corner is still a 2×2 mosaic here: the
two green planes were already told apart by white balance, upstream.

`RGGB`, `BGGR`, `GRBG` and `GBRG` are all supported, and the phase is
**discovered** from the layout's own `colorPlaneIndex(row:column:)` and
`colorDescription` — never hardcoded, and never re-deriving LibRaw's CFA
decoding. A three-plane Bayer layout, whose greens share plane `1`, and a
four-plane `RGBG` layout, whose greens are planes `1` and `3`, resolve to the
same `R/G/G/B` cell.

X-Trans is recognised and explicitly unsupported by this algorithm. It is not
treated as Bayer, not demosaiced from a 2×2 subset, not downsampled and not
routed through LibRaw. A future X-Trans algorithm would be a new
`RAWDemosaicAlgorithm` case producing the same `DemosaicedRAWRGBImage`.

#### The interpolation

```text
at a red location:    R = the native sample, copied exactly
                      G = mean of the in-bounds AXIAL   green neighbours (N S W E)
                      B = mean of the in-bounds DIAGONAL blue  neighbours (NW NE SW SE)

at a blue location:   B = the native sample, copied exactly
                      G = mean of the in-bounds AXIAL   green neighbours
                      R = mean of the in-bounds DIAGONAL red   neighbours

at a green location:  G = the native sample, copied exactly
                      R = mean of the in-bounds AXIAL   red   neighbours
                      B = mean of the in-bounds AXIAL   blue  neighbours
```

A contributor counts only if it is in bounds **and** its own CFA location
carries the wanted colour. For a green location that resolves to one horizontal
pair and one vertical pair; which is which follows from the discovered phase,
since the two green positions in a cell have opposite orientations.

Borders average **only their available contributors**. A corner red location
has two axial greens and one diagonal blue, and divides by two and by one
accordingly. Nothing is reflected, wrapped or duplicated, no out-of-bounds
sample is invented, and the image is never cropped: every CFA location produces
exactly one pixel. A channel with no contributor at all — a 1×1 mosaic, a
single row, a single column — raises `missingDemosaicNeighbors` with the
coordinate and the channel rather than being filled with zero.

Native samples are copied straight across, never through `Double`, so their
`Float32` bit patterns survive exactly, negative zero included. Interpolated
means accumulate their at most four contributors in `Double` and narrow once,
because `Float.greatestFiniteMagnitude + Float.greatestFiniteMagnitude`
overflows while the average does not — an artefact of the summation, not of the
data. Storage is `Float32` throughout; there is no `Double` buffer.

Nothing is clamped. Finite negatives stay negative and values above `1` stay
above `1`, for interpolated values as much as native ones. A non-finite sample,
native or contributor, raises `nonFiniteInputValue` with its own coordinate
rather than being skipped; skipping would silently change a mean's denominator.

#### G1 and G2

Both green CFA positions become the single output green channel. They are never
merged, averaged or reconciled as planes:

| Location | Output green |
| --- | --- |
| G1 | its own G1 white-balanced sample, exactly |
| G2 | its own G2 white-balanced sample, exactly |
| red or blue | spatial mean of its in-bounds green neighbours, normally both kinds |

There is no global G1/G2 reconciliation stage. Adding one would undo the
per-plane gains the white-balance stage deliberately keeps separate.

#### Output

`DemosaicedRAWRGBImage` stores tightly packed, row-major, interleaved RGB —
exactly three `Float32` per pixel:

```text
base = (row * width + column) * 3
```

`[SIMD3<Float>]` is deliberately not the storage type: its 16-byte stride would
turn the E-PL3's 148 MB buffer into 197 MB, a third of it padding.

**The values are linear camera-native sensor responses, not colour-space
coordinates.** They are not sRGB, not linear sRGB, not Display P3, not Adobe
RGB, not ProPhoto RGB, not XYZ and not ACES. `R`, `G` and `B` identify which
filter on *this* sensor produced the value, so two cameras' values are not
comparable. No camera colour matrix, gamma or orientation has been applied, and
the enforcement is structural: the demosaicer receives no `RAWMetadata` at all,
so `cam_mul`, `pre_mul`, `rgb_cam` and `cam_xyz` have nothing to arrive
through.

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
applied and their `RAWWhiteBalanceSource` (`.explicit`, or `.neutralPatch`
carrying the measurement that produced them). The
gains are recorded as numbers, not as a label: given the same
`LinearRAWMosaic`, the recorded provenance contains the exact gains required to
reproduce the white-balance transformation. The provenance does not contain the
source pixels, so it reproduces the *transformation*, not the image on its own.

### What the demosaicing stage does not do

| Stage | Applied? |
| --- | --- |
| Bilinear Bayer interpolation | **yes** |
| Clamping / clipping | no |
| Range normalisation of any kind | no |
| G1/G2 reconciliation | no |
| White balance | no — upstream |
| Camera colour matrix | no |
| Colour-space conversion | no |
| Gamma / transfer function | no |
| Exposure / tone | no |
| Highlight reconstruction | no |
| Sharpening / noise reduction / false-colour suppression | no |
| Orientation | no |

Each is recorded on `RAWDemosaicProcessing`, alongside the algorithm and the
discovered Bayer phase. Upstream facts — black subtraction, normalisation, the
white level, the gains and their source — are read through the
`RAWWhiteBalanceProcessing` it carries rather than copied, so two records of
the same history cannot disagree.

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
| **Linear camera-native RGB** | Three `Float32` per pixel — the sensor's own filter responses, interpolated. No camera matrix, no gamma, no colour space. Not clamped. | `DemosaicedRAWRGBImage.values` |
| **Decoder-processed RGB** | LibRaw's own full pipeline output: its demosaic, its black/white handling, a camera matrix and gamma. | `RAWImage` (legacy reference path only) |
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

### Neutral-patch estimate for a central diagnostic region

> These numbers are **diagnostic only**. The region is a geometrically central
> rectangle, chosen because it is deterministic and contains all four CFA
> positions. No claim is made that it is visually neutral, that this frame is a
> grey card, or that these gains are an E-PL3 calibration, an infrared filter
> profile or a recommended starting point. They are a measurement of one
> rectangle in one file.

Region: origin row 1488, column 1996, size 64 × 64 — 4096 samples, 1024 of each
CFA plane. Policy `.preserveStrongestMeasuredPlane`.

| Plane | Samples | Mean before WB | Estimated gain | Mean after WB |
| --- | --- | --- | --- | --- |
| 0 (R) | 1024 | 0.05718087 | 1.0 | 0.05718087 |
| 1 (G1) | 1024 | 0.03957828 | 1.4447539 | 0.05718087 |
| 2 (B) | 1024 | 0.00840750 | 6.8011756 | 0.05718087 |
| 3 (G2) | 1024 | 0.03979002 | 1.4370658 | 0.05718087 |

Target mean 0.05718087, which is plane 0's — the largest, so plane 0's gain is
exactly `1` and no plane is attenuated. The four post-balance means agree to
better than 2 parts in 10⁸, which is Float32 multiply noise.

Planes 1 and 3 measured 0.03957828 and 0.03979002 and received different gains,
confirming the two greens are measured independently on real data and not
merely representable independently.

Estimating over this patch takes about 0.6 ms in a **debug** build. No
optimised-build measurement has been taken, and no performance claim is made
from this number.

### After bilinear Bayer demosaicing

> These numbers are **diagnostic**. No camera colour matrix has been applied at
> this stage, so they are linear camera-native sensor responses and say nothing
> about whether the image is colour-correct. The gains they were produced under
> are the diagnostic estimate above, not a calibration.

Input: the white-balanced 4056 × 3040 mosaic above, balanced with the estimated
gains. Discovered Bayer phase: `RGGB`, resolved from the file's own
`colorDescription "RGBG"` and `colorCount 3`.

| | |
| --- | --- |
| Output dimensions | 4056 × 3040, unchanged — every CFA location yields one pixel |
| Output values | 36 990 720 `Float32` (12 330 240 pixels × 3) |
| Owned payload | 147 962 880 bytes ≈ 148 MB, 4 bytes per `Float` |
| Non-finite values | 0 |

| Channel | Minimum | Maximum | Mean | < 0 | > 1 |
| --- | --- | --- | --- | --- | --- |
| R | 0.010667 | 0.526172 | 0.130020 | 0 | 0 |
| G | 0.008960 | 0.760906 | 0.130518 | 0 | 0 |
| B | −0.005062 | 0.658015 | 0.123163 | 11 | 0 |

The 11 negative values are the same 11 sub-black samples the earlier tables
track, still negative and still unclamped. No value exceeds 1 in this frame
because the largest balanced sample does not — a fact about this exposure and
these gains, not a clamp; the synthetic suite proves values above 1 survive.

Demosaicing the full frame takes roughly 25 s in a **debug** build (`-Onone`,
bounds checks on, up to eight neighbour lookups per pixel through a throwing
nested function). No optimised-build measurement has been taken, and no
performance claim is made from this number.

Memory, stated precisely: 148 MB is this buffer's **own payload**, not process
RSS. The pipeline additionally retains the white-balanced and normalised
mosaics — about 49 MB each — so gains, estimates and algorithm can be changed
without decoding the file again. That retention is a deliberate tradeoff at
this architecture stage, to be revisited by measurement once interactive
editing exists, not by dropping buffers to make a number smaller.

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

Demosaicing itself is no longer on this list. One application-owned reference
algorithm is decided and implemented, and the representation it produces is
stable enough for a second algorithm to target. What remains open is
everything downstream of it, plus image quality:

- The **working colour space**, which is downstream of demosaicing. Nothing
  converts `DemosaicedRAWRGBImage` into one yet, and it must not be treated as
  sRGB or anything else in the meantime.
- The **camera colour transform** — including whether a visible-light matrix is
  ever valid for infrared capture.
- **Tone mapping, exposure and display encoding.**
- The **final production-quality Bayer algorithm**. `.bilinearBayer` is a
  correctness reference, not an image-quality answer.
- An **X-Trans algorithm**. The layout is recognised and explicitly refused
  today.
- Whether any of this belongs on the **GPU**. The current implementation is a
  CPU reference and no optimised-build measurement has been taken.
- How infrared white-balance gains should be chosen *without* a user-selected
  region. ADR 0003 records how gains are applied and ADR 0004 how they are
  estimated from a selected patch; automatic estimation, robust statistics and
  filter profiles remain open.
- Whether the mosaic path should ever expose the masked border, e.g. for
  measuring the black level from the optical-black region instead of trusting
  LibRaw's own estimate (see "Masked pixels and who owns black estimation").
