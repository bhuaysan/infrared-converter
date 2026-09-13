# RAW pipeline — the RAW-stage contract

This document defines what a sample *is* at each stage of the RAW path, and
which stages have and have not run.

It now covers four domains.

```text
MOSAIC DOMAIN               one value per CFA location; colour only via the layout
    LinearRAWMosaic
    WhiteBalancedRAWMosaic

CAMERA-NATIVE RGB DOMAIN    three Float32 per pixel; linear; NOT a colour space
    DemosaicedRAWRGBImage

WORKING-COLOUR RGB DOMAIN   three Float32 per pixel; linear; extended linear sRGB
    WorkingColorRGBImage        full resolution; the processing truth
    SceneLinearPreviewImage     reduced for the interactive workspace
    IRChannelMixedRGBImage

DISPLAY-REFERRED DOMAIN     three UInt8 per pixel; sRGB-encoded; clipped
    DisplayEncodedPreviewImage
```

The **mosaic domain** runs from LibRaw's unpacked samples to a white-balanced
CFA mosaic. The **camera-native RGB domain** begins at demosaicing: three
values per pixel, still linear, still the sensor's own filter responses, and
still not in any colour space. The **working-colour RGB domain** begins at an
explicit camera-to-working transform: the same layout, the same linearity, but
the values are now coordinates in a defined space. The **display-referred
domain** begins at the display renderer, and is the first place in the whole
project where a number is no longer proportional to light.

The middle two are the pair most easily confused, so they are named apart
everywhere:

```text
linear camera-native RGB      what THIS SENSOR's filters responded with
extended linear sRGB working  coordinates in sRGB primaries at D65, linear
```

The last one is a different kind of thing again, and the distinction it turns
on is the one a display stage exists to make:

```text
extended linear sRGB    scene-linear, unclamped Float32, light-proportional
display-encoded sRGB    display-referred UInt8, clipped, transfer function applied
```

Demosaicing is decided — one application-owned reference algorithm, see
`docs/decisions/0005-application-owned-bayer-demosaicing.md` — so is the
working colour space, see `docs/decisions/0006-working-color-space.md`, so is
creative channel mixing, see
`docs/decisions/0007-infrared-channel-mixing.md`, and so is the first
display boundary, see `docs/decisions/0008-display-preview-rendering.md`. So
now is the resolution the interactive workspace works at, see
`docs/decisions/0015-reduced-resolution-preview.md`: the workspace holds a
**reduced** scene-linear rendition and re-renders only that, while the RAW file
plus its canonical adjustments remain the source of truth. What is still
undecided is a real tone pipeline: the display stage clips and encodes, and
nothing more.

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
       explicit RAWCameraToWorkingColorTransform   ┐
                  ↓                                ├ RAWWorkingColorConverter
       WorkingColorRGBImage                        ┘

═══════════ WORKING-COLOUR RGB DOMAIN ══════════════════
extended linear sRGB; unclamped Float32; still linear

                  ↓
       PreviewResolutionPolicy: cap the longest edge  ┐
                  ↓                                   ├ SceneLinearPreviewReducer
       exact area-weighted average, per channel       │
                  ↓                                   │
       SceneLinearPreviewImage (reduced)              ┘

═══════════ the full-resolution path ends here ═════════
everything above is transient and released when preparation
returns; the reduced PRE-MIX buffer is what the workspace
retains, and everything below it re-runs per adjustment

                  ↓
       adjustments.channelMix → IRChannelMix       ┐
                  ↓                                ├ IRChannelMixer
       IRChannelMixedPreviewImage                  ┘

═══════════ CREATIVE IR WORKING RGB DOMAIN ═════════════
the SAME extended linear sRGB; unclamped Float32; linear
a different PROCESSING STATE, not a different space
pixels are still in SENSOR reading order
resolution is now the preview's, not the sensor's

                  ↓
       recorded orientation (metadata)   ┐
                  +                      ├ EffectiveImageOrientation
       user orientation adjustment       ┘
                  ↓
       one explicit RAWImageOrientation            ┐
                  ↓                                ├ ImageOrienter
       OrientedSceneLinearRGBImage                 ┘

═══════════ ORIENTED SCENE-LINEAR DOMAIN ═══════════════
the same space, the same values, the same bit patterns
pixels are now in VIEWING order; width/height may be swapped

                  ↓
       explicit DisplayRenderSettings              ┐
                  ↓                                │
       exposure, in the linear domain              │
                  ↓                                ├ DisplayPreviewRenderer
       hard display-range clipping to 0...1        │
                  ↓                                │
       sRGB transfer function                      │
                  ↓                                │
       deterministic quantisation to 8 bits        ┘
                  ↓
       DisplayEncodedPreviewImage

═══════════ DISPLAY-REFERRED DOMAIN ════════════════════
sRGB-encoded UInt8; clipped; NOT scene-linear

                  ↓
       DisplayPreviewCGImageAdapter (tagged sRGB)
                  ↓
       CoreGraphics / SwiftUI

                  ↓
       [FUTURE: tone mapping / contrast / curves]
                  ↓
       [FUTURE: export]
```

The scene-linear representations are **not consumed** by the display stage,
only read. After a render, every one of them is bit-identical to what it was,
including every value below `0` and above `1` that the preview clipped away.

Five semantic states, in three colour situations:

```text
MOSAIC                     LinearRAWMosaic
                           WhiteBalancedRAWMosaic
                           one value per CFA location; no colour space

CAMERA-NATIVE RGB          DemosaicedRAWRGBImage
                           three channels; sensor responses; NOT a space

WORKING RGB                WorkingColorRGBImage
                           extended linear sRGB, before creative mixing

CREATIVE IR WORKING RGB    IRChannelMixedRGBImage
                           extended linear sRGB, after creative mixing

DISPLAY-ENCODED RGB        DisplayEncodedPreviewImage
                           sRGB-encoded UInt8; display-referred; clipped
```

The last two are in the **same colour space**. What separates them is
processing state, not colour-space identity: one holds coordinates as the
camera-to-working transform placed them, the other holds those coordinates
after a creative remix. They are two types so that a function signature can
tell them apart — a shared layout and a shared space are not a shared
meaning.

`DemosaicedRAWRGBImage` is **not** sRGB, and must not be labelled as such. No
camera colour matrix has been applied to it; see "Demosaicing" below.

`WorkingColorRGBImage` **is** in extended linear sRGB coordinates — and that is
a statement about the coordinate system, not about colour accuracy. How the
sensor responses were mapped into it is a separate fact carried by the
transform's provenance; see "Camera-native RGB → working colour space".

Estimation is **not** a stage downstream of white balance. It reads the
pre-white-balance `LinearRAWMosaic`, produces a `RAWWhiteBalanceGains`, and
that value is what `RAWWhiteBalancer` then applies to the same mosaic. The two
halves meet at the gains, not at the image.

All seven stages are application-owned and none imports `CLibRaw`.

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

`RAWWorkingColorConverter` takes a `DemosaicedProcessedRAWImage` (or a bare
`DemosaicedRAWRGBImage`) **and an explicit transform** and returns a
`WorkingColorProcessedRAWImage`, which keeps the camera-native image reachable
on `.source` so the transform can be changed without demosaicing again. It
receives no `RAWMetadata` and there is no default transform.

`IRChannelMixer` takes a `WorkingColorProcessedRAWImage` (or a bare
`WorkingColorRGBImage`) **and an explicit mix** and returns an
`IRChannelMixedProcessedRAWImage`, which keeps the pre-mix working image
reachable on `.source` so the mix can be changed without converting again. It
receives no `RAWMetadata` either, and there is no default mix.

It also has a **preview overload**, and that is the one the workspace uses:
`SceneLinearPreviewImage` → `IRChannelMixedPreviewImage`, reduced in and
reduced out. There is no wrapper chain in the reduced domain, deliberately —
nothing full-resolution may be reachable from what a document retains — so the
"mixes never compose" invariant is carried by the **types** instead: the input
is the pre-mix type, the output is not, and nothing accepts the output back.
See `docs/decisions/0016-interactive-channel-mixer.md`.

Exposure joined the render half the same way. The display stage's
`exposureEV` was always `0 EV` in the workspace; it is now the user's
`ImageAdjustments.exposure`, passed unchanged, so the `× 2^EV` described under
the display stage below acts on the unclamped mixed and oriented preview before
the range policy. No stage was added and none moved. The sidecar is at schema
version 3. See `docs/decisions/0017-interactive-exposure.md`.

`ImageOrienter` takes an `IRChannelMixedProcessedRAWImage` (or a bare
`IRChannelMixedRGBImage`, or a reduced `IRChannelMixedPreviewImage`) **and an
explicit orientation** and returns an `OrientedProcessedRAWImage`, which keeps
the unoriented image reachable on `.source` so the orientation can be changed
without mixing again. It receives no `RAWMetadata`: the orientation is chosen
by the caller, normally from `RAWMetadata.Geometry.orientation`, and there is
no default.

`DisplayPreviewRenderer` takes an `OrientedProcessedRAWImage` (or a bare
`OrientedSceneLinearRGBImage`) **and explicit settings** and returns a
`DisplayPreviewProcessedRAWImage`, which keeps the scene-linear image reachable
on `.source` so exposure can be changed without orienting again. It receives no
`RAWMetadata` — not even the orientation, which one stage upstream has already
applied — and there is no default exposure.

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

### Camera-native RGB → working colour space

`RAWWorkingColorConverter` is the second RGB-domain stage. It takes a
camera-native image and **one explicit transform**, and produces coordinates in
a defined space.

#### Two decisions, kept apart

```text
a working colour space   defines the COORDINATE SYSTEM the numbers live in
a camera / IR transform  decides HOW sensor-native RGB is MAPPED into it
```

Saying "the working space is extended linear sRGB" settles the first and says
nothing about the second. For an infrared-modified camera the second has no
conventional answer, which is why the mapping is always explicit and always
carries provenance. See `docs/decisions/0006-working-color-space.md`.

#### The working space

`.extendedLinearSRGB`: sRGB primaries, the sRGB D65 white point, a **linear**
transfer function, `Float32` storage, and no clipping. Finite values below `0`,
inside `0...1` and above `1` are all legal and all preserved. The nonlinear
sRGB transfer function is not applied, and neither is any gamma, tone mapping
or display encoding.

#### The transform

`RAWCameraToWorkingColorTransform` carries the space, a `RAWColorMatrix3x3` and
the provenance together, and its initialiser is module-internal so the matrix
and the source cannot be mismatched. Three origins exist:

| Factory | Provenance | What it is |
| --- | --- | --- |
| `.sensorRGBIdentityFalseColor` | `.sensorRGBIdentityFalseColor` | Sensor R, G and B assigned to the working axes unchanged. A **deliberate false-colour axis assignment**, not a camera calibration. |
| `.explicit(matrix:)` | `.explicit` | A matrix the caller decided on. The project makes no claim about it. |
| `.visibleLightMetadata(from:)` | `.visibleLightMetadataRGBFromCamera` | The file's own `rgbFromCamera`, which is **visible-light calibrated**. Opt-in, diagnostic. |

There is **no default transform** on any entry point, no API that discovers a
matrix for itself, and no fallback that reaches for metadata when something
else is missing. That policy does not exist.

#### Identity false colour

The matrix is exactly the identity, and the stage takes a dedicated path that
performs no arithmetic: every `Float` bit pattern survives, `-0.0` included,
and copy-on-write means the values are not copied at all. What changes is the
semantic state and the provenance, not a single number.

It is the assumption-minimal way to put an infrared capture into a defined
coordinate system. It is **not** a camera calibration, not "correct colour" and
not "accurate sRGB".

#### The visible-light metadata adapter, and why it is opt-in

`RAWMetadata.ColorMetadata.rgbFromCamera` is a Camera-RGB → sRGB matrix
calibrated by the vendor or decoder **for visible light**. An
infrared-converted body shooting through an IR filter is precisely the case it
does not describe, so every result derived from it is labelled a *visible-light
metadata transform, diagnostic only for this IR capture* — not an IR camera
calibration, not a camera-model IR profile, not a filter profile, not a
recommendation and not a claim of colourimetric accuracy.

Its matrix is 3×4 and the camera-native image has three input channels, so it
is representable only when the fourth column is exactly zero:

```text
⎡ r0 r1 r2 0 ⎤        ⎡ r0 r1 r2 ⎤
⎢ g0 g1 g2 0 ⎥   →    ⎢ g0 g1 g2 ⎥
⎣ b0 b1 b2 0 ⎦        ⎣ b0 b1 b2 ⎦
```

`+0.0` and `-0.0` both count as zero and there is no epsilon. A non-zero fourth
coefficient is refused, never dropped. A missing matrix, a wrong row count, a
row that is not four coefficients long and a non-finite coefficient are each
their own typed error.

The adapter reads `rgbFromCamera` and nothing else: `cameraMultipliers` and
`daylightMultipliers` are not reapplied — white balance already happened in the
mosaic domain — and `cameraFromXYZ` is neither read nor inverted.

#### The matrix convention

```text
             ⎡ m00 m01 m02 ⎤   ⎡ cameraR ⎤
workingRGB = ⎢ m10 m11 m12 ⎥ × ⎢ cameraG ⎥
             ⎣ m20 m21 m22 ⎦   ⎣ cameraB ⎦
```

Rows are output channels, columns are input camera channels. Coefficients are
nine `Double` values in a fixed shape; only non-finite ones are refused, so
zero, negative, greater-than-one, non-normalised and singular matrices are all
accepted — infrared false-colour work legitimately uses them.

#### Arithmetic

Each output channel is one dot product accumulated in `Double` and narrowed to
`Float` exactly once. `Float32` intermediates can overflow where the result
cannot: `2 × greatestFiniteMagnitude − greatestFiniteMagnitude` is infinity in
`Float` and exact in `Double`. There is no `Double` image buffer. Non-finite
inputs, and results that do not survive the narrowing, fail with the
coordinate and channel rather than being clamped.

#### Output

`WorkingColorRGBImage` uses the same storage contract as the camera-native
image — tightly packed, row-major, interleaved, three `Float32` per pixel —
and the same geometry. The shared layout is a coincidence of storage, not a
shared meaning, which is why the two are separate types.

#### Reprocessing

`WorkingColorProcessedRAWImage` retains the demosaiced source, and
`convert(using:replacing:)` reaches through it. Transforms never compose:
replacing `M1` with `M2` gives `M2 × cameraRGB`, not `M2 × (M1 × cameraRGB)`.

### Working RGB → creative infrared RGB

`IRChannelMixer` is the first explicitly **creative** stage, and the first the
user drives. It takes a working-colour image and **one explicit mix**, and
returns coordinates in the same space, remixed. In the interactive workspace
the mix comes from `ImageAdjustments.channelMix` — a canonical user decision,
persisted with the orientation as one record — and the image it is applied to
is the reduced, pre-mix buffer the document retains.

#### A different question from the camera transform

```text
RAWCameraToWorkingColorTransform
    How do camera-native sensor responses enter our working colour space?

IRChannelMix
    Once we are already in that space, how do we creatively remix RGB
    for infrared rendering?
```

Both are 3×3 matrices over the same `RAWColorMatrix3x3` primitive, and they are
still different operations with different provenance types. They are never
merged, and a future profile that decides both will carry them as two values,
not one composed matrix. See
`docs/decisions/0007-infrared-channel-mixing.md`.

#### What channel mixing does and does not do

```text
does:       a linear RGB remix inside one working colour space

does not:   camera calibration
            white balance
            colour-space conversion
            exposure / tone
            gamma / display encoding
```

#### The mix

`IRChannelMix` carries the working space, a `RAWColorMatrix3x3` and the
provenance together, and its initialiser is module-internal so the matrix and
the source cannot be mismatched. Three origins exist:

| Factory | Provenance | What it is |
| --- | --- | --- |
| `.identity` | `.identity` | A creative **no-op**: no remapping was requested and the stage was traversed anyway. Bit-preserving for accepted values. |
| `.redBlueSwap` | `.redBlueSwap` | `outputR = inputB`, `outputG = inputG`, `outputB = inputR`. The canonical first infrared creative operation. Bit-preserving for accepted values. |
| `.explicit(matrix:)` | `.explicit` | A matrix the caller decided on. The project makes no claim about it. |

There is **no default mix** on any entry point. An explicit matrix that happens
to equal a built-in's takes the same optimised path and keeps `.explicit`
provenance: the execution path is decided by the matrix's value, the provenance
by how the mix was constructed.

A mix records the working space it was authored for, because coefficients mean
something only relative to the RGB axes they were written for. A mismatch is
refused, never converted. Exactly one space exists today, so that check cannot
currently fire; it stays for the day a second one does.

#### Coefficients

Only non-finite ones are refused, so zero, negative, greater-than-one,
non-normalised and singular matrices are all accepted — infrared creative work
legitimately uses every one of them. Rows are not normalised, coefficients are
not percentages, and row sums need not be `1`. There is **no constant or offset
term**: the operation is `output = M × input`, never affine.

#### Arithmetic

Identity performs no arithmetic and hands the same immutable array back, so
copy-on-write means nothing is copied. The exact red/blue matrix copies
channels rather than computing three dot products — `0*R + 0*G + 1*B` is
mathematically right but can turn a `-0.0` positive, and a permutation should
not alter a bit. A general matrix accumulates each output channel in `Double`
and narrows to `Float` exactly once, for the reason the working-colour stage
gives. Non-finite inputs and results fail with the coordinate and channel,
reported as `IRProcessingError`. A result fails for any of three reasons — an
infinite accumulation, a NaN accumulation from terms of opposing sign, or a
finite `Double` that overflows the single narrowing to `Float32` — and they
share one case, named and worded for *finiteness* rather than magnitude,
because a NaN is not a number that is merely too large.

Those two facts sit together deliberately, and "bit-preserving" has to be read
against the second one:

```text
finite input value      identity / permutation preserve its bit pattern exactly
NaN or infinity         refused with its coordinate and channel — never copied
```

The identity and permutation paths validate before they preserve. What survives
untouched is every value the stage **accepts**; what does not survive is not
altered either, it is rejected.

#### Output

`IRChannelMixedRGBImage` uses the same storage contract as every RGB
representation upstream — tightly packed, row-major, interleaved, three
`Float32` per pixel — and the same geometry. Mixing is strictly per-pixel: no
crop, no resize, no orientation, no resampling.

#### Reprocessing

`IRChannelMixedProcessedRAWImage` retains the pre-mix working-colour state, and
`apply(mix:replacing:)` reaches through it. Mixes never compose: replacing `M1`
with `M2` gives `M2 × workingRGB`, not `M2 × (M1 × workingRGB)`. Two red/blue
swaps in a row would otherwise cancel.

In the reduced domain the same rule is enforced without a wrapper. The
workspace retains the **pre-mix** `SceneLinearPreviewImage` and re-mixes it
from scratch on every adjustment, and `IRChannelMixedPreviewImage` is accepted
by no `apply` overload, so `M2 × (M1 × preview)` cannot be written at all.

The mix is now on the **interactive** path, so it polls a
`ProcessingCancellation` on the ADR 0011 contract: once before anything is
allocated, once per row, `CancellationError` on refusal, and never a partially
written buffer. All three execution paths poll, the identity path's finiteness
sweep included.

### Creative infrared RGB → oriented scene-linear RGB

`ImageOrienter` is the only stage in the pipeline that changes **where** a
pixel is, and the only one that can change the image's width and height. It
takes a channel-mixed image and **one explicit `RAWImageOrientation`**, and
returns the same values arranged for viewing.

See `docs/decisions/0009-application-owned-orientation.md`.

#### Discrete geometry, not editing

```text
Orientation        eight standard arrangements, an exact permutation of
                   whole pixels, lossless — whether the file asked for it
                   or a person did

Rotation / crop    continuous editing operations chosen by a person,
                   requiring resampling — neither exists yet
```

Nothing here interpolates, resamples, scales, crops or invents a pixel.

#### The orientation type

`RAWImageOrientation` models all eight standard orientations, with reflections
distinguished from rotations — four of the eight reverse handedness, and no
rotation reproduces them.

| Case | EXIF | LibRaw `flip` | Swaps dimensions | Mirrored |
| --- | --- | --- | --- | --- |
| `upright` | 1 | 0 | no | no |
| `mirroredHorizontally` | 2 | 1 | no | yes |
| `rotated180` | 3 | 3 | no | no |
| `mirroredVertically` | 4 | 2 | no | yes |
| `transposed` | 5 | 4 | yes | yes |
| `rotated90Clockwise` | 6 | 6 | yes | no |
| `transverse` | 7 | 7 | yes | yes |
| `rotated270Clockwise` | 8 | 5 | yes | no |

The names describe the operation a **viewer performs**, not where the stored
image's first row ends up, which is what EXIF's own names describe.

`RAWMetadata.Geometry.flip` is LibRaw's dcraw-derived bitfield, and it
disagrees with the EXIF code for five of the eight values. It is mapped exactly
once, by `RAWImageOrientation.init?(decoderFlip:)`, and no stage downstream
sees the integer.

#### Unknown or unmodelled orientation

`init?(decoderFlip:)` returns `nil` outside `0...7`, and
`RAWMetadata.Geometry.orientation` is therefore optional. LibRaw does not
guarantee the range: several format parsers assign `flip` straight from a file
field.

An unmodelled value is **never** read as upright. `WorkspacePreviewPipeline`
refuses with `OrientationError.unsupportedDecoderOrientation(flip:)`, reporting
the value verbatim.

What this cannot distinguish is a file that recorded upright from a file that
recorded nothing. LibRaw maps EXIF `1` to `0`, copies a `t_flip` into
`tiff_flip` only when it is non-zero, and finally substitutes `0` when nothing
supplied an orientation — so both arrive as the same number. Telling the two
apart needs the file's own bytes, not the decoder.

#### The coordinate mapping

The loop runs over **destination** coordinates and gathers, so every output
pixel is written exactly once by construction. With `w = sourceWidth`,
`h = sourceHeight` and a destination coordinate `(r, c)`:

```text
upright                source(r,          c        )
mirroredHorizontally   source(r,          w − 1 − c)
rotated180             source(h − 1 − r,  w − 1 − c)
mirroredVertically     source(h − 1 − r,  c        )
transposed             source(c,          r        )
rotated90Clockwise     source(h − 1 − c,  r        )
transverse             source(h − 1 − c,  w − 1 − r)
rotated270Clockwise    source(c,          w − 1 − r)
```

The four transposing cases take their destination row from a source *column*,
which is why the `w − 1` and `h − 1` terms attach to the opposite axis from the
one a reader expects.

#### Values

Each destination pixel's three components are **copied**, never computed, so
every `Float` bit pattern survives: signed zeros, subnormals, the extremes, and
non-finite values too. The stage reads no component as a number and therefore
refuses none — a NaN is the display renderer's boundary.

`.upright` allocates nothing: it hands the same immutable array back.

#### Output

`OrientedSceneLinearRGBImage` uses the same storage contract as every RGB
representation upstream — tightly packed, row-major, interleaved, three
`Float32` per pixel. `(0, 0)` is the top-left **as viewed**. Width and height
are exchanged for exactly the four orientations whose `swapsDimensions` is
`true`; the pixel count is invariant in every case.

#### Reprocessing

`OrientedProcessedRAWImage` retains the unoriented channel-mixed state, and
`apply(orientation:replacing:)` reaches through it. Orientations never compose:
replacing `O1` with `O2` gives `orient(mixed, O2)`. The eight orientations are
closed under composition, so a chained result would always be *some* valid
orientation and would never look malformed — just not the one asked for.

#### Where the orientation comes from

The stage is handed one orientation and knows nothing about where it came
from. The application layer derives it from two separate facts:

```text
recorded / decoder orientation      RAWMetadata.Geometry.orientation — immutable
            +
user orientation adjustment         UserOrientationAdjustment — an edit
            =
effective orientation               EffectiveImageOrientation.applied
```

`effective = source.composed(with: userAdjustment.transform)` — **source
first, then the user**, because a person rotates what they are looking at.
The order is load-bearing: composition does not commute once reflections are
involved, so `transposed` then a quarter turn right is
`mirroredHorizontally`, while the reverse is `mirroredVertically`.

`composed(with:)` is integer arithmetic on the canonical mirror-then-rotate
decomposition of the dihedral group of order eight — no matrices, no floating
point. All 64 pairs are tested against two independent oracles: real pixel
permutations, and the destination-to-source mappings composed by hand.

The adjustment is a **canonical single state**, one of eight, never a history
of presses. Four rotate-rights reduce to the identity, and the image is
permuted exactly once, from `WorkspacePreviewPipeline.Source`'s unoriented
buffer, on every change. Reset sets the adjustment to the identity, which
restores the **file's** orientation — not upright.

See `docs/decisions/0010-user-owned-orientation-adjustment.md`.

### Oriented scene-linear RGB → display-encoded preview

`DisplayPreviewRenderer` is the first stage whose output is **not**
proportional to light. It takes an oriented scene-linear image and **one
explicit `DisplayRenderSettings`**, and returns bytes a monitor can be handed
correctly.

See `docs/decisions/0008-display-preview-rendering.md`.

#### What it is, and what it is not

```text
does:       exposure in the linear domain
            hard display-range clipping to 0...1
            the piecewise sRGB transfer function
            deterministic quantisation to 8 bits

does not:   tone mapping of any kind
            highlight reconstruction
            automatic exposure or any histogram
            contrast, saturation, curves, LUTs
            gamut mapping beyond the component-wise clip
            orientation, crop or resampling
```

It is a defined clip and encode. Calling it a tone pipeline would misdescribe
it.

#### The settings

`DisplayRenderSettings` carries exactly three choices, all `let`:

| Property | Today's values |
| --- | --- |
| `exposureEV` | any finite `Double`; `2^EV` must be finite too |
| `rangePolicy` | `.hardClipToDisplayRange` |
| `encoding` | `.sRGB` |

There is **no default** on any entry point. `0 EV` is written at the call site,
which is where a reader can audit it.

#### The arithmetic, per component

```text
1. exposure     exposed = Float(Double(sceneLinear) × exp2(EV))
2. clipping     clipped = exposed < 0 ? 0 : (exposed > 1 ? 1 : exposed)
3. encoding     encoded = clipped <= 0.0031308
                            ? 12.92 × clipped
                            : 1.055 × clipped^(1/2.4) − 0.055
4. quantisation sample  = round(encoded × 255)      half away from zero
```

The scale is computed once per image; the multiply widens to `Double` and
narrows to `Float32` exactly once, the convention the two stages above already
use. The encoding is evaluated in `Double`.

`pow(x, 1/2.2)` is **not** an acceptable substitute for step 3. It is a
different curve, it differs most in the shadows, and it would make the bytes
disagree with the sRGB profile they are then tagged with. The comparison in
step 3 is `<=`, so the threshold itself takes the linear branch; the two
branches differ by about `3e-8` there, and picking one by fiat is the only way
to make the boundary deterministic.

#### Clipping is destruction, and it is counted

Detail above `1` and below `0` is destroyed, not recovered, compressed or
rolled off. The stage therefore counts what it destroyed:
`clippedLowSampleCount` and `clippedHighSampleCount` are components, not
pixels, and are part of the provenance record.

Clipping the unit cube component-wise is also this path's **entire gamut
handling**: a coordinate outside the cube may be out of gamut, and clipping
each component independently moves it to a different colour rather than to the
nearest in-gamut one.

None of this touches the input. `IRChannelMixedRGBImage` is bit-identical after
a render, and every clipped value is still in it.

#### Exact failures rather than plausible numbers

```text
non-finite EV, or a finite EV whose 2^EV is not finite  → nonFiniteExposure
a NaN or infinite input coordinate                      → nonFiniteSceneLinearInput
exposure overflowing Float32                            → nonFiniteExposedValue
geometry that does not add up, on either side           → invalidGeometry
CoreGraphics declining to build an image                → displayImageUnavailable
```

Both the EV and its scale are checked: `exp2(−infinity)` is `0`, a
finite-looking multiplier that would render a black frame in silence.

An overflowing exposure is refused rather than left to the clip, because a
sample that reached infinity would clip to `1` and arrive on screen as an
ordinary white pixel that nothing downstream could distinguish from a
legitimately bright one.

#### Output

| | |
| --- | --- |
| Bits per component | 8 |
| Components | 3, interleaved `R G B` |
| Alpha | none — there is no alpha channel |
| Bytes per pixel | 3 |
| Bytes per row | `width × 3`, tightly packed |
| Byte order | not applicable: one byte per component |
| Endpoints | `0 → 0`, `1 → 255`, exactly |

`0 → 0` is arithmetic. `1 → 255` is arithmetic *plus rounding*: the `Double`
encoding of `1` is one ULP below `1`, so the product is `254.999999999999971…`
and rounding to nearest is what recovers `255`.

There is no alpha channel rather than an ignored one: the image is opaque by
construction, and `CGImage` accepts 24-bit-per-pixel RGB with
`kCGImageAlphaNone` directly.

#### The platform image

`DisplayPreviewCGImageAdapter` describes those bytes to CoreGraphics and tags
them `CGColorSpace.sRGB` — the ordinary, non-linear one, because that is what
they now are. It converts nothing and copies nothing.

The legacy `PreviewImageRenderer` tags LibRaw's **linear** 16-bit samples
`linearSRGB`, which is right for those bytes and wrong for these. Two paths,
two colour spaces, two types, and no way to confuse them in a signature.

#### Reprocessing

`DisplayPreviewProcessedRAWImage` retains the scene-linear state, and
`render(settings:replacing:)` reaches through it. Settings never compound:
changing exposure re-renders from the channel-mixed scene-linear image, never
from the 8-bit preview. Rendering an encoded buffer again would apply the transfer
function twice, compound quantisation, recover no clipped highlight — and look
entirely plausible.

### The second end path: full-resolution export

Everything above describes the interactive half. The application has a second
end path, and it does not branch off the first: it starts again from the RAW
file.

```text
ExportRequest = RAW URL + ImageAdjustments
    ↓  RAWWorkingImagePipeline      decode → normalise → WB → demosaic → convert
WorkingColorRGBImage                full resolution, scene-linear, pre-creative
    ↓  IRChannelMixer               adjustments.channelMix
    ↓  ImageOrienter                file orientation + adjustments.orientation
    ↓  SceneLinearExposer           adjustments.exposure
ExposedSceneLinearRGBImage          extended linear sRGB, still unclamped
    ↓  ExportImageEncoder           clip → sRGB → 16-bit quantisation
ExportEncodedImage
    ↓  TIFFExporter                 temp file → finalise → move
a 16-bit RGB TIFF
```

See [ADR 0018](decisions/0018-full-resolution-tiff-export.md).

#### What is shared, and what is not

| | interactive preview | full-resolution export |
| --- | --- | --- |
| RAW front half | `RAWWorkingImagePipeline` | the same code |
| preview reduction | yes, by `PreviewResolutionPolicy` | **never** |
| channel mix | `IRChannelMixer` | the same |
| orientation | `ImageOrienter` | the same |
| exposure arithmetic | `SceneLinearExposure` | the same |
| where exposure is applied | inside the display pass | `SceneLinearExposer`, its own stage |
| range policy | `.hardClipToDisplayRange` | `.hardClipToExportRange` |
| transfer function | `SRGBTransferFunction` | the same |
| quantisation | `round(x × 255)` | `round(x × 65535)` |
| destination | a `CGImage` on screen | a TIFF file on disk |

The export path takes a `URL` and an `ImageAdjustments`. It has no parameter
for a preview, a `WorkspacePreviewPipeline.Source`, a `CGImage` or a
`PreviewResolutionPolicy`, so preview pixels and preview *sizes* cannot reach
it — which is why two documents of one photograph at different preview
resolutions produce byte-identical exports.

#### The exposure stage

```text
scale    = 2^EV                     SceneLinearExposure, shared with the display path
exposed  = sceneLinear × scale      per component, in Double, narrowed once
```

Nothing is clipped here. A value this stage lifts above `1` reaches the export
range policy still above `1`, and a value a negative exposure brings back into
range is encoded rather than already destroyed. The identity (`0 EV`) hands the
same immutable array back, bit patterns intact, and still sweeps for non-finite
values so the output contract holds on both paths.

#### The export encoder

```text
clipped = min(max(x, 0), 1)         hard, named, counted in both directions
encoded = sRGB OETF(clipped)        the shared piecewise curve, in Double
sample  = round(encoded × 65535)    half away from zero
```

| | |
| --- | --- |
| Bits per component | 16 |
| Components | 3, interleaved `R G B` |
| Alpha | none — there is no alpha channel |
| Storage | `[UInt16]`, so no byte order exists before the file writer |
| Endpoints | `0 → 0`, `0.5 → 32768`, `1 → 65535`, exactly |

`1 → 65535` is arithmetic *plus rounding*, exactly as `1 → 255` is on the
display path: the `Double` encoding of `1` is one ULP below `1`, so the product
is `65534.999999999998…` and rounding to nearest recovers `65535`.

**Sixteen bits is not a range.** A normalised integer TIFF's samples run
`0…65535` and mean `0…1`; more bits buy finer steps inside that range, not a
larger one. So the unbounded working representation still needs an explicit,
counted clip, and the encoder records `clippedLowSampleCount` and
`clippedHighSampleCount` for the same reason the display stage does.

The encoder refuses an image whose provenance says it was reduced for preview,
with `ExportEncodingError.previewReducedSource`. The export pipeline cannot
produce one; the guard exists for anything that later hands it an image from
the interactive path.

#### The file

`ExportCGImageAdapter` is the one place samples become bytes, and it declares
the host byte order to CoreGraphics rather than assuming it. The image is
tagged `CGColorSpace.sRGB`, so the transfer function the encoder applied once
is not applied again by a reader.

`TIFFExporter` writes to a replacement directory on the destination's own
volume, finalises there, and only then moves the completed file into place —
ImageIO has no commit semantics of its own, and a failed
`CGImageDestinationFinalize` can leave a partial file behind. A failed export
therefore leaves the destination exactly as it was.

The pixels are already permuted into viewing order, so the file's orientation
tag is `1`, in both the top-level property and the TIFF dictionary. Copying the
RAW file's orientation across would rotate the photograph twice.

### What the export stage does not do

| Stage | Applied? |
| --- | --- |
| Hard export-range clipping to `0...1` | **yes** |
| sRGB transfer function | **yes** |
| Quantisation to 16 bits | **yes** |
| Exposure | no — upstream, by `SceneLinearExposer`, and not reapplied |
| Preview reduction | no — refused outright |
| Tone mapping of any kind | no |
| Highlight reconstruction | no |
| Automatic rescaling of out-of-range values | no |
| Contrast, saturation, curves, LUTs | no |
| Sharpening / noise reduction / resizing | no |
| Orientation / crop / resampling | no — orientation is upstream, and forwarded |
| Adjustment metadata, XMP, private tags, recipes | no — none is written to the file |
| The capture date | no — see ADR 0018, Decision 13 |

`isValidatedInfraredCalibration` is still `false`. A 16-bit file is a more
precise record of the same unvalidated rendering.

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

### What the working-colour stage does not do

| Stage | Applied? |
| --- | --- |
| Explicit camera → working 3×3 transform | **yes** |
| Working colour representation established | **yes** |
| Clamping / clipping | no |
| Gamma / transfer function | no |
| Tone mapping / auto exposure / gamut mapping | no |
| Display encoding / 8-bit quantisation | no |
| White balance | no — upstream, in the mosaic domain |
| Camera or daylight WB multipliers | no — never reapplied |
| `cameraFromXYZ` inversion | no |
| Automatic metadata transform selection | no — there is no such policy |
| Highlight reconstruction | no |
| Sharpening / noise reduction | no |
| Orientation | no |

Each is recorded on `RAWWorkingColorProcessing`. The working space, the matrix
and the transform source are read through the `RAWCameraToWorkingColorTransform`
it carries, and the upstream chain through the `RAWDemosaicProcessing`, rather
than copied — so no record of this history can disagree with another.

`isValidatedInfraredCalibration` is `false` for every transform source this
milestone can produce. A defined coordinate system is not a calibration claim.

### What the channel-mix stage does not do

| Stage | Applied? |
| --- | --- |
| Creative linear 3×3 RGB channel mix | **yes** |
| Clamping / clipping | no |
| Row normalisation of any kind | no |
| Constant / offset term | no |
| Colour-space conversion | no — the space is unchanged |
| Chromatic adaptation | no |
| Camera → working transform | no — upstream, and not reapplied |
| White balance | no — upstream, in the mosaic domain |
| Camera colour metadata of any kind | no — none reaches this stage |
| Gamma / transfer function | no |
| Tone mapping / exposure / gamut mapping | no |
| Display encoding / 8-bit quantisation | no |
| Highlight reconstruction | no |
| Sharpening / noise reduction | no |
| Orientation / crop / resampling | no |

Each is recorded on `IRChannelMixProcessing`. The working space, the matrix and
the mix source are read through the `IRChannelMix` it carries, and the whole
upstream chain through the `RAWWorkingColorProcessing`, rather than copied — so
no record of this history can disagree with another.

A creative mix never makes anything a calibration:
`isValidatedInfraredCalibration` is still `false`, and still forwarded from the
upstream transform rather than restated here.

### What the orientation stage does not do

| Stage | Applied? |
| --- | --- |
| One of the eight standard orientations | **yes** |
| Interpolation / resampling / filtering | no |
| Arbitrary-angle rotation or straightening | no |
| Crop / scale / padding | no |
| Change to any channel value | no — components are copied, bit for bit |
| Refusal of non-finite values | no — they are moved like any other |
| Clamping / clipping | no |
| Colour-space conversion | no — the space is unchanged |
| Channel mixing | no — upstream, and not reapplied |
| Camera → working transform | no — upstream, and not reapplied |
| White balance | no — upstream, in the mosaic domain |
| Gamma / transfer function | no |
| Tone mapping / exposure / gamut mapping | no |
| Display encoding / 8-bit quantisation | no |
| Reading `RAWMetadata` | no — the caller passes the orientation in |
| Composing the recorded orientation with a user adjustment | no — that happens above the stage |
| Knowing about buttons, documents or persistence | no |

Each is recorded on `ImageOrientationProcessing`. The orientation is its own
field; the whole upstream chain is read through the `IRChannelMixProcessing` it
carries rather than copied.

Rearranging pixels never makes anything a calibration:
`isValidatedInfraredCalibration` is still `false`, forwarded from the upstream
transform rather than restated here.

### What the display stage does not do

| Stage | Applied? |
| --- | --- |
| Exposure, in the linear domain | **yes** |
| Hard display-range clipping to `0...1` | **yes** |
| sRGB transfer function | **yes** |
| Quantisation to 8 bits | **yes** |
| Tone mapping of any kind | no |
| Automatic exposure / histogram / auto-levels | no |
| Highlight reconstruction | no |
| Contrast, saturation, vibrance, HSL, curves, LUTs | no |
| Gamut mapping beyond the component-wise clip | no |
| Channel mixing | no — upstream, and not reapplied |
| Camera → working transform | no — upstream, and not reapplied |
| White balance | no — upstream, in the mosaic domain |
| Camera colour metadata of any kind | no — none reaches this stage |
| Sharpening / noise reduction | no |
| Orientation / crop / resampling | no — orientation is upstream, and forwarded |
| Mutation of the scene-linear input | no |

Each is recorded on `DisplayPreviewProcessing`, alongside the settings and the
two clip counts. The orientation, the mix, the camera transform, the demosaic
algorithm and the gains are read through the `ImageOrientationProcessing` it
carries rather than copied — so no record of this history can disagree with
another.

`orientationApplied` is `true` on this record and `false` on every record
upstream of `ImageOrientationProcessing`, and both are correct: the flag is
forwarded so one record answers "is this arranged for viewing?" without a
reader having to know which stage did it. The display stage itself reads no
orientation metadata and moves no pixel.

`isValidatedInfraredCalibration` is still `false`. Making an image displayable
never makes it correct.

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
| **Extended linear sRGB working RGB** | Three `Float32` per pixel — coordinates in sRGB primaries at D65 with a linear transfer function, after one explicit camera → working transform. Not clamped, not gamma encoded. **Not the same thing as the row above.** | `WorkingColorRGBImage.values` |
| **Decoder-processed RGB** | LibRaw's own full pipeline output: its demosaic, its black/white handling, a camera matrix and gamma. | `RAWImage` (legacy reference path only) |
| **Working representation** | The project's defined internal processing space. | Extended linear sRGB; see ADR 0006. |

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

### After working-colour conversion

> These numbers are **diagnostic**. The identity transform is a deliberate
> false-colour axis assignment into extended linear sRGB, not a camera
> calibration of this infrared-converted body, and nothing here validates
> colour.

Input: the demosaiced camera-native image above.

**Identity false colour** (`.sensorRGBIdentityFalseColor`):

| | |
| --- | --- |
| Output dimensions | 4056 × 3040, unchanged |
| Output values | 36 990 720 `Float32` |
| Logical payload | 147 962 880 bytes ≈ 148 MB |
| Whole-buffer bit identity with the camera-native source | yes, 0 mismatches |
| Non-finite values | 0 |

Every per-channel statistic is identical to the camera-native table above,
because the identity path changes no numbers — R minimum 0.010667, G maximum
0.760906, B 11 values below zero, and so on.

Memory, stated precisely: the 148 MB is the buffer's **logical payload**. For
the identity path it is *not* incremental physical allocation — `Array`'s
copy-on-write means the working image shares its immutable source's storage.
Neither figure is process RSS. A non-identity matrix does allocate one new
output buffer of that size.

In a **debug** build the identity conversion takes roughly 1.4 s and a general
3×3 matrix roughly 1.6 s over the full frame (`-Onone`, bounds checks on). No
optimised-build measurement has been taken and no performance claim is made.

**The file's own `rgbFromCamera`**, read rather than assumed:

```text
row 0:  1.7544682   -0.5938559   -0.16061233   0.0
row 1: -0.25168633   1.8621225   -0.61043614   0.0
row 2:  0.05752118  -0.69685745   1.6393362    0.0
```

The fourth column is exactly zero, so this matrix **is** representable as a 3×3
camera-native transform, and the adapter derives its first three columns
unchanged (determinant ≈ 4.374). Running it gives:

| Channel | Minimum | Maximum | Mean | < 0 | > 1 |
| --- | --- | --- | --- | --- | --- |
| R | −0.071603 | 0.543874 | 0.130825 | 2 | 0 |
| G | −0.247599 | 1.135580 | 0.135133 | 28 | 2 |
| B | −0.037440 | 0.932444 | 0.118433 | 592 | 0 |

The negative and above-one coordinates are retained, not clamped — which is
what the extended range is for, and exactly what a matrix with negative
coefficients produces.

> This result is a **visible-light metadata transform, diagnostic only for this
> IR capture**. It is not an IR camera calibration, not an E-PL3 IR profile,
> not a filter profile, not a recommendation, and not a claim of colourimetric
> accuracy. That the matrix maps into the chosen working space does not
> establish that it is physically appropriate after infrared conversion.

### After infrared channel mixing

> These numbers are **diagnostic**. A channel mix is creative intent, not a
> measurement: a red/blue-swapped frame is the exact red/blue swap of its
> input, and calling it "correct infrared colour" would be a claim nothing in
> this project supports.

Input: the identity false-colour `WorkingColorRGBImage` above — deliberately,
so the creative stage's numbers do not depend on the file's visible-light
matrix.

**Identity** (`IRChannelMix.identity`):

| | |
| --- | --- |
| Output dimensions | 4056 × 3040, unchanged |
| Output values | 36 990 720 `Float32` |
| Logical payload | 147 962 880 bytes ≈ 148 MB |
| Whole-buffer bit identity with the pre-mix image | yes, 0 mismatches |
| Non-finite values | 0 |

Every per-channel statistic is identical to the working-colour table above,
because the identity path changes no numbers. As there, the 148 MB is the
buffer's **logical payload** and not incremental physical allocation: the
identity path shares its source's storage by copy-on-write.

**Red/blue swap** (`IRChannelMix.redBlueSwap`), checked over the whole frame
rather than sampled, since the expected result is trivial and independent:

| | |
| --- | --- |
| Output R bit-identical to input B | yes, 0 mismatches |
| Output G bit-identical to input G | yes, 0 mismatches |
| Output B bit-identical to input R | yes, 0 mismatches |
| Non-finite values | 0 |

| Channel | Minimum | Maximum | Mean | < 0 | > 1 | equals |
| --- | --- | --- | --- | --- | --- | --- |
| R | −0.005062 | 0.658015 | 0.123163 | 11 | 0 | input B |
| G | 0.008960 | 0.760906 | 0.130518 | 0 | 0 | input G |
| B | 0.010667 | 0.526172 | 0.130020 | 0 | 0 | input R |

The 11 sub-black values the earlier tables track are now in the red channel,
still negative and still unclamped. This is a strong check on channel order:
a swap that lost or reordered a channel could not reproduce the input's
statistics exactly, counts included. One new output buffer is allocated here —
the values are reordered, so copy-on-write cannot help.

**One explicit general matrix**, for coverage of the arithmetic path:

```text
 0.25  -0.5    1.75
 1.125  0.375 -0.25
-0.625  2.0    0.5
```

> Deterministic **test** coefficients, chosen so a transposition, a
> channel-order mistake, the wrong source buffer or an accidental clamp would
> change the answer. Not a recommended look and not a colour recommendation.

| Channel | Minimum | Maximum | Mean | < 0 | > 1 |
| --- | --- | --- | --- | --- | --- |
| R | −0.014558 | 1.082239 | 0.182782 | 51 | 2 |
| G | −0.032571 | 0.697013 | 0.164425 | 2 | 0 |
| B | 0.016206 | 1.479655 | 0.241355 | 0 | 10 |

Coordinates below zero and above one are retained, not clamped — which is what
the extended range is for. Five fixed pixel coordinates are additionally
checked against arithmetic written out in the test, within one `Float` ULP.

In a **debug** build (`-Onone`, bounds checks on), with this suite run on its
own, the three paths take roughly 1.0 s, 1.1 s and 1.2 s respectively over the
full frame — validate-and-share, validate-and-reorder, and nine multiplications
with six additions per pixel. Inside the fully parallel test run they are
roughly twice that, which is contention rather than cost. No optimised-build
measurement has been taken and no performance claim is made.

### After orientation

Same chain again, then `ImageOrienter` with the effective orientation — here
the file's own, because no user adjustment has been made.

| | |
| --- | --- |
| EXIF tag 274 in the file | present in IFD0 — `SHORT`, count 1, value `1`, at file offset `118` |
| LibRaw `flip` | `0` |
| Application-owned orientation | `.upright` |
| Swaps dimensions / mirrored | no / no |
| Geometry before → after | 4056 × 3040 → 4056 × 3040 |
| Values | 36 990 720, bit-identical to the channel-mixed buffer |
| Allocation | none — the `.upright` path shares the input array |

**The fixture is stored sideways and records upright.** The photograph was
taken with the camera turned and the body wrote tag 274 as `1` anyway — the tag
is present, not missing, which a test asserts from the file's bytes rather than
inferring from `flip == 0`. The correct response to that metadata is to display
the frame as captured. Making it upright is a manual editing operation; a
camera-model special case would make this one file look right and every
correctly tagged E-PL3 file look wrong.

That makes the fixture a strong test of the metadata path and a weak one for
the coordinate arithmetic, so the same real 12-megapixel frame is also put
through non-identity orientations. Under `.rotated90Clockwise` the geometry
becomes 3040 × 4056 and named destination coordinates are checked against the
source coordinates the written-out formula gives, by `Float` bit pattern:

| Destination | Source |
| --- | --- |
| (0, 0) — top-left | (3039, 0) — the source's bottom-left |
| (0, 3039) — top-right | (0, 0) — the source's top-left |
| (4055, 0) — bottom-left | (3039, 4055) |
| (4055, 3039) — bottom-right | (0, 4055) |
| (2000, 1500) | (1539, 2000) |
| (1024, 2048) | (991, 1024) |

Under `.transposed` the geometry is 3040 × 4056 as well, and the two are
distinguished numerically rather than visually: the reflection's fixed points
lie on the main diagonal and the rotation's do not.

Whole-frame sums, extremes and element counts are identical before and after,
which a dropped or duplicated pixel would break. The sum is compared with a
relative tolerance of `1e-9` rather than claimed exact, because floating-point
addition over the same multiset in a different order is not associative.

### After a user orientation correction

The same fixture, corrected by hand. The sky runs along the right edge of the
stored frame, so a quarter turn **left** puts it at the top. That choice is a
person's; no code path consults the camera model.

| | |
| --- | --- |
| Recorded orientation | EXIF 1 → LibRaw `flip 0` → `.upright` (unchanged) |
| User adjustment | `.quarterTurnLeft`, persisted as `"rotate270Clockwise"` |
| Effective orientation | `.rotated270Clockwise` |
| Swaps dimensions / mirrored | yes / no |
| Geometry before → after | 4056 × 3040 → 3040 × 4056 |
| `RAWMetadata.Geometry.flip` after | `0` — a user correction never writes metadata |

For `.rotated270Clockwise` on a `w × h` source, destination `(r, c)` comes from
source `(c, w − 1 − r)`, with `w − 1 = 4055`. Six named coordinates, compared
by `Float` bit pattern:

| Destination | Source |
| --- | --- |
| (0, 0) — top-left | (0, 4055) — the source's top-right |
| (0, 3039) — top-right | (3039, 4055) |
| (4055, 0) — bottom-left | (0, 0) — the source's top-left |
| (4055, 3039) — bottom-right | (3039, 0) |
| (2000, 1500) | (1500, 2055) |
| (1024, 2048) | (2048, 3031) |

`.transposed` gives the same 3040 × 4056 geometry and different pixels, which
is checked numerically — a reflection and a quarter turn are
indistinguishable by eye on a photograph.

Reprocessing is non-destructive, and proved rather than asserted. Two
rotate-rights followed by a reset return display bytes **bit-identical** to
the first render, the retained channel-mixed buffer is bit-identical element
by element throughout, and a sequence of presses matches reaching the same
canonical state in one step.

### After display preview rendering

Same chain again — identity false-colour transform, identity channel mix,
`.upright` orientation — then `DisplayPreviewRenderer` at `0 EV`, hard
display-range clipping and sRGB encoding.

| | |
| --- | --- |
| Preview geometry | 4056 × 3040, unchanged by this stage (orientation is upstream) |
| Buffer | 36 990 720 bytes |
| Bytes per row | 12 168 |
| Layout | 8 bits per component, three components `R G B`, no alpha |
| Exposure | `0 EV` (×1) |
| Range policy | hard display-range clipping to `0...1` |
| Encoding | standard sRGB, tagged `CGColorSpace.sRGB` on the `CGImage` |
| Non-finite intermediates | 0 |

The clip counts, at `0 EV`, against the scene-linear input's own out-of-range
counts:

| | Source values | Clipped by the display stage |
| --- | --- | --- |
| Below `0` | 11 | 11 |
| Above `1` | 0 | 0 |

They match exactly, and must: at `0 EV` nothing can move a value across a
boundary, so any difference would mean the stage clipped something it was not
asked to. The 11 sub-black values are the same 11 the normalisation and
white-balance tables track — they are still in the scene-linear buffer
afterwards, unchanged.

At `+1 EV` on the same frame: 39 components clip high, and the low count stays
at 11, because a positive exposure cannot push a value below zero.

Sample distribution at `0 EV`: 17 bytes are `0`, none is `255`. The frame is
not near the top of the display range at neutral exposure — which is a fact
about this photograph and this white balance, not a property of the stage.

Eight fixed pixel coordinates, spread over the frame and both parities of both
axes, are additionally checked against arithmetic written out step by step in
the test — linear, exposed, clipped, encoded, quantised — at `0 EV` and again
at `+1 EV`.

LibRaw's processed RGB is **not** consulted anywhere in this. The fixture
proves this pipeline is internally consistent on real data; it does not, and
could not, prove that the rendering is colourimetrically right.

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

Demosaicing, the working colour space, creative channel mixing, the first
display boundary and metadata-driven orientation are no longer on this list.
One application-owned reference demosaic algorithm is decided and implemented,
the working representation is extended linear sRGB (ADR 0006) reached through
an explicit provenance-carrying transform, a linear 3×3 creative channel mix
sits after that boundary (ADR 0007), the eight standard orientations are
applied as their own lossless geometry stage (ADR 0009), the result reaches a
monitor through an explicit exposure, a named clip, the sRGB transfer function
and 8-bit quantisation (ADR 0008), and it reaches a **file** through the same
adjustments at full resolution, its own named clip, the same transfer function
and 16-bit quantisation (ADR 0018). What remains open is everything downstream
of *those*, plus image quality:

- **The rest of the infrared creative colour transform** — false-colour
  mapping, hue remapping, LUT-based finishing. Channel mixing is decided; these
  are separate operations that ADR 0007 does not cover.
- **Filter and capture profiles, and recipes** — what would decide a mix and a
  transform for a given camera, conversion and filter, and how that is
  persisted and versioned.
- Whether a **visible-light matrix is ever appropriate for infrared capture**.
  The adapter exists as an opt-in diagnostic; that is not an endorsement, and
  no IR calibration methodology has been decided.
- **A real tone pipeline.** ADR 0008 decided a clip and an encode, and
  explicitly not Reinhard, filmic curves, shoulder/toe curves, local operators,
  highlight reconstruction or automatic exposure. Those remain open, and the
  fixture's clip counts are the argument for taking them on.
- **Real gamut mapping.** Component-wise clipping to the unit cube is the
  primitive stand-in.
- **Arbitrary-angle rotation, straightening, crop and perspective
  correction**, and therefore any resampling. Orientation is decided and
  implemented (ADR 0009, ADR 0010), but only as the eight discrete
  arrangements — whether a file names one or a person does; the continuous
  editing operations are a different problem and need interpolation.
- **Anything about persistence beyond one photograph's own state.** The
  orientation adjustment is saved in a JSON sidecar beside the RAW file and
  restored before the first render (ADR 0013). What does not exist: recipes and
  presets, any reuse of a record across images, a document format, watching a
  sidecar for external edits, and undo/redo.
- **Any adjustment beyond the three that exist.** Orientation (ADR 0010), the
  creative channel mix (ADR 0016) and exposure (ADR 0017) are user decisions
  with controls and a sidecar. The white-balance patch and the camera transform
  are still fixed application-layer choices with no controls, and the recipe
  format that would hold any of it is deliberately undefined.
- **Preview caching and eviction.** Preview *resolution* is decided (ADR 0015):
  the workspace reduces once, immediately after the camera-to-working
  transform, and retains only that reduced scene-linear buffer. Cancellation is
  decided too (ADR 0011). What remains open is keeping a reduced preview across
  opens, evicting one, or persisting one to disk — none of which exists.
- **A CFA-aware mosaic reduction.** Reducing before demosaicing would let the
  white-balance and demosaic stages run on fewer samples, which is the only way
  to make white balance interactive. It needs its own invariant and per-layout
  handling, and until it exists a CFA mosaic is never resized at all (ADR
  0015).
- **Export beyond one 16-bit TIFF.** The full-resolution render path and a
  16-bit sRGB TIFF exist (ADR 0018) and restart from the RAW file. JPEG, PNG,
  DNG, OpenEXR, floating-point TIFF, batch export, export presets, resizing and
  output sharpening do not.
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
