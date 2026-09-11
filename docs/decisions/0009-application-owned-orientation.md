# 0009 — Application-owned image orientation

Status: accepted
Date: 2026-09-11

> Numbering note: `CLAUDE.md` uses `0009-metal-render-pipeline.md` as an
> illustrative example of a future ADR filename. This milestone is the decision
> that actually took number `0009`, so that illustrative example now reads
> `0010-metal-render-pipeline.md`. ADR numbers follow the order decisions are
> made; no ADR was renamed. This is the third time that example has moved, for
> the same reason it moved the first two times.

## Context

Seven application-owned stages exist:

```text
RAWMosaic
    ↓
LinearRAWMosaic              black subtracted, normalised, unclamped Float32
    ↓
WhiteBalancedRAWMosaic       per-CFA-plane infrared gains
    ↓
DemosaicedRAWRGBImage        linear camera-native sensor RGB
    ↓
WorkingColorRGBImage         extended linear sRGB — ADR 0006
    ↓
IRChannelMixedRGBImage       the same space, creatively remixed — ADR 0007
    ↓
DisplayEncodedPreviewImage   exposure, clip, sRGB, 8 bit — ADR 0008
```

Every one of them is geometry-preserving, and every one of them records
`orientationApplied` as `false`. [ADR 0008](0008-display-preview-rendering.md)
Decision 13 made that explicit and deferred the question: a file that asks for
a rotation is displayed unrotated, because rotating inside the display encoder
would put a geometry operation inside a colour stage.

This is that deferred decision.

## What this ADR is, and is not

It is **discrete, metadata-driven geometry**: the eight standard orientations,
applied as an exact permutation of whole pixels.

It is **not** an editing feature. Arbitrary-angle rotation, straightening,
crop, perspective correction and any form of resampling are outside it, and
nothing here interpolates or invents a pixel. The distinction matters enough to
be stated in two words:

```text
Orientation          discrete file geometry, read from metadata, lossless
Rotation / crop      continuous editing operations, chosen by a person,
                     requiring resampling — not in this milestone
```

## Decision 1 — Orientation is its own stage

`ImageOrienter` sits between the creative channel mix and the display boundary:

```text
IRChannelMixedRGBImage        extended linear sRGB, in SENSOR order
      │
      │  explicit RAWImageOrientation
      ↓
ImageOrienter                 ← this stage
      ↓
OrientedSceneLinearRGBImage   the same values, in VIEWING order
      │
      │  explicit DisplayRenderSettings
      ↓
DisplayPreviewRenderer
```

It is the only stage in the pipeline that changes *where* a pixel is, and the
only one that can change the image's width and height. That is the whole reason
it is separate: a geometry operation folded into a neighbour is invisible in the
one record that is supposed to describe the pipeline.

## Decision 2 — It is not part of demosaicing

Here the objection is not only architectural; it is arithmetic.

A CFA layout is defined in **sensor** coordinates. `RAWDemosaicer` discovers a
Bayer phase from `RAWMetadata.SensorColorLayout` and interpolates according to
it. Orienting before or during that step would move samples out from under the
pattern that describes them, and the interpolation would then read the wrong
colour plane at every position. The result would not be a rotated image with
correct colour; it would be a rotated image with wrong colour, in a way that
looks like a demosaic bug.

Orientation therefore happens long after the mosaic domain has closed, when
there are no colour planes left to invalidate.

## Decision 3 — It is not part of the display encoder

`DisplayPreviewRenderer` claims to be strictly per-component and
geometry-preserving, and that claim is load-bearing: it is what makes the stage
auditable as a clip and an encode. A rotation smuggled in beside the transfer
function would falsify it.

The renderer does not read `RAWMetadata.geometry.flip` and never will. It
consumes `OrientedSceneLinearRGBImage`, which is already arranged for viewing,
and forwards the orientation as a fact in provenance — `orientationApplied`,
`appliedOrientation`, `orientationSwappedDimensions` — so one record still
answers "is this arranged for viewing?" without a reader having to know which
stage did it.

## Decision 4 — It operates on scene-linear RGB, and changes no value

The stage consumes and produces extended-linear-sRGB `Float32` coordinates.
Orientation is geometry; it cannot change what a coordinate means, so:

```text
sceneLinear        stays true
clamped            stays false
gammaApplied       stays false
toneMappingApplied stays false
displayEncoding    stays false
```

Values below `0` and above `1` are moved, not limited. The colour space is
unchanged, the channel order is unchanged, and no matrix, gain or curve is
involved.

## Decision 5 — Component bit patterns are preserved exactly

Each destination pixel's three `Float` components are **copied** from exactly
one source pixel. No arithmetic touches them, so every bit survives: signed
zeros, subnormals, the largest and smallest finite magnitudes — and non-finite
values too.

That last one is deliberate. The stage reads no component as a number and
therefore has no standing to refuse one: a NaN is `DisplayPreviewRenderer`'s
boundary, at the stage that genuinely cannot proceed with it. Refusing here
would make the preservation guarantee conditional for no benefit.

The `.upright` path goes further and allocates nothing at all: it hands the
same immutable `[Float]` back, which `Array`'s copy-on-write makes free and
exactly as faithful as a `memcpy` would be.

## Decision 6 — All eight orientations, with reflections distinguished

`RAWImageOrientation` models eight cases, not four rotations:

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

Four of the eight are **reflections**: they reverse handedness, and no rotation
can produce them. Collapsing `.transposed` onto `.rotated90Clockwise` would
mirror the photograph — invisible on a symmetrical subject, glaring on text.
`isMirrored` is a property of the type rather than something callers infer from
a case list.

The names describe the operation a viewer **performs**, not where the stored
image's first row ends up, which is what EXIF's own names describe. That is the
direction the code works in, and naming it the other way round is the single
most common orientation bug there is.

## Decision 7 — The decoder's integer is mapped once, at the metadata boundary

`RAWMetadata.Geometry.flip` is LibRaw's own value. It is a dcraw-derived
**bitfield**, not an EXIF orientation code, and the two disagree for six of the
eight values — `flip 2` is EXIF 4, `flip 3` is EXIF 3, `flip 5` is EXIF 8. That
is exactly the kind of near-miss that survives review.

So it is mapped exactly once, by `RAWImageOrientation.init?(decoderFlip:)`, and
no stage downstream ever sees the integer again.

The mapping was read from the vendored LibRaw 0.22.2 sources in this
repository, not assumed:

- `LibRaw::flip_index` (`src/write/file_write.cpp`) defines the bits, applied
  in this order to a **destination** coordinate to find its source:

  ```text
  bit 2 (4)   swap row and column
  bit 1 (2)   row    = sourceHeight - 1 - row
  bit 0 (1)   column = sourceWidth  - 1 - column
  ```

- `src/metadata/tiff.cpp` maps EXIF tag 274 with the string index
  `"50132467"[exif & 7]`, which is where the EXIF column above comes from.

## Decision 8 — Unmodelled orientation is a typed failure, never `.upright`

`init?(decoderFlip:)` returns `nil` for anything outside `0...7`, and
`RAWMetadata.Geometry.orientation` is therefore `RAWImageOrientation?`.

Values outside that range are reachable. Several LibRaw format parsers assign
`flip` straight from a file field — `flip = get4()` in `src/metadata/ciff.cpp`,
`flip = get2()` in `src/metadata/nikon.cpp` — and `identify()` normalises only
exact 90/180/270-degree values into the bitfield.

The policy is that nobody guesses. `WorkspacePreviewPipeline` refuses with
`OrientationError.unsupportedDecoderOrientation(flip:)`, reporting the value
verbatim, and `DocumentState` surfaces that as the preview's failure reason.
Reading an unmodelled code as upright would turn a field we could not parse
into a silent claim about the photograph.

### What this cannot distinguish

LibRaw's `identify()` finishes by substituting `0` when neither a makernote nor
EXIF tag 274 supplied an orientation (`src/metadata/identify.cpp`). So "the file
recorded upright" and "nothing in the file recorded anything" arrive at this
boundary as the same number and are genuinely indistinguishable here.

That is a fact about the decoder, not a defect in the mapping, and it has a
visible consequence recorded in Decision 12.

## Decision 9 — Width and height are exchanged for exactly four orientations

The four whose `swapsDimensions` is `true` — `.transposed`,
`.rotated90Clockwise`, `.transverse`, `.rotated270Clockwise` — are exactly the
four whose coordinate mapping transposes. For them the oriented image is
`sourceHeight × sourceWidth`; for the other four it is `sourceWidth ×
sourceHeight`.

The pixel count is invariant in every case. Nothing is scaled, padded or
cropped, so the output element count always equals the input's, which is
checked rather than assumed.

## Decision 10 — The coordinate mapping is a gather, written out

The loop runs over **destination** coordinates and asks each one where its
pixel comes from. Every output element is therefore written exactly once by
construction rather than by argument: no output can be left uninitialised and
none can be written twice. A scatter would make both properties something to
prove.

With `w = sourceWidth`, `h = sourceHeight`, and a destination coordinate
`(r, c)`:

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

The four transposing cases take their destination row from a source *column*
and vice versa, which is why the `w − 1` and `h − 1` terms attach to the
opposite axis from the one a reader expects. That crossover is the easiest
thing here to get wrong, so the table is written out as an explicit switch
rather than derived from a 2×3 affine abstraction. Auditability beats
generality at this size.

## Decision 11 — Changing an orientation restarts from the unoriented image

```text
new result = orient(the channel-mixed image, O2)
       NOT   orient(orient(the channel-mixed image, O1), O2)
```

`OrientedProcessedRAWImage` keeps the `IRChannelMixedProcessedRAWImage` it was
produced from, and `ImageOrienter.apply(orientation:replacing:)` reaches
through it, exactly as `IRChannelMixer` and `DisplayPreviewRenderer` do for
their own stages.

The failure mode this prevents is unusually quiet. The eight orientations are
closed under composition, so a chained result is always *some* valid
orientation and never looks malformed — it is simply not the one that was asked
for, while provenance records the one that was. Setting `.upright` after
`.rotated90Clockwise` would leave the image rotated and every record claiming
it upright.

## Decision 12 — The workspace reads the file's orientation, and corrects nothing

`WorkspacePreviewPipeline` derives the orientation from
`RAWMetadata.Geometry.orientation` and nothing else. There is no camera-model
table, no filename heuristic, no per-body override and no automatic
straightening.

This has a consequence worth stating plainly, because it is the opposite of
what a milestone about orientation might be expected to produce.

**The Olympus E-PL3 reference fixture is stored sideways and records EXIF
orientation 1.** Its TIFF tag 274 is `1`; LibRaw reports `flip 0`; macOS's own
metadata agrees. The photograph was taken with the camera turned, and the body
recorded nothing about it. The application therefore maps it to `.upright` and
displays it exactly as captured — sideways — which is the correct response to
the metadata that exists.

A camera-model special case that rotated E-PL3 files would make this one file
look right and every correctly tagged E-PL3 file look wrong. Making that
photograph upright is a **manual editing** operation, and it belongs with
arbitrary rotation and crop, not here.

Files that do record a non-identity orientation are oriented by this stage, and
the synthetic and unit test suites cover all eight arrangements exhaustively.

## Decision 13 — Typed failures, no fatal errors

`OrientationError` has three cases:

```text
invalidGeometry                    dimensions and buffer disagree, or overflow
unrepresentableOrientedGeometry    the oriented extent is not representable
unsupportedDecoderOrientation      a flip value we do not model, reported
```

There is deliberately **no** case for a value problem, for the reason Decision 5
gives. Nothing in this stage traps, and no input the public initialisers accept
can make it.

## Decision 14 — The platform adapter learns nothing

`DisplayPreviewCGImageAdapter` is unchanged. It receives already-oriented
dimensions and already-oriented bytes and describes them to CoreGraphics; the
`CGImage`'s width and height are the oriented preview's, because the buffer
itself is oriented.

No SwiftUI `.rotationEffect`, no `CGAffineTransform`, no `CGImagePropertyOrientation`
and no view-layer correction of any kind is used. A view transform would orient
the picture on screen while leaving every buffer, every test and every future
export in sensor order.

## What this ADR does not decide

- **Arbitrary-angle rotation and straightening**, and therefore any
  resampling, interpolation or filtering.
- **Crop, perspective correction, lens corrections** and every other geometric
  editing feature.
- **A user-facing orientation control.** The workspace reads metadata; nothing
  lets a person override it yet. That is the natural home for making an
  untagged sideways photograph upright.
- **Orientation for export.** Export has no stage at all yet and will need its
  own decisions.
- **Whether orientation should move earlier for performance.** The four
  transposing cases read down columns while writing along rows and are
  cache-hostile on a large frame. No measurement has been taken and no tiled
  variant is written.
- **Reduced-resolution previews, caching, cancellation** and GPU execution.

## Consequences

- The pipeline has an orientation stage, in one auditable place, with all eight
  standard orientations and reflections distinguished from rotations.
- A displayed pixel's chain back to a decoded sample now names the orientation
  alongside the settings, mix, camera transform, demosaic, gains and
  normalisation.
- The display encoder's claim to be per-component and geometry-preserving is
  intact, and now provably so: it consumes geometry it did not produce.
- A file recording a rotation is shown rotated. A file recording none is shown
  as captured, including when the camera was plainly turned — and the reason is
  a named, testable fact about the file rather than a missing feature.
- Orientation is lossless. Nothing downstream has to treat an oriented image as
  degraded, which matters for the export path that does not exist yet.
