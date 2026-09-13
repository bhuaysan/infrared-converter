# 0018 — Full-resolution render and 16-bit TIFF export

Status: accepted
Date: 2026-09-13

> Numbering note: `CLAUDE.md` used `0018-metal-render-pipeline.md` as an
> illustrative future filename, after [ADR 0017](0017-interactive-exposure.md)
> took the number that example previously used. This decision took `0018`, so
> that example now reads `0019-metal-render-pipeline.md`. No ADR was renamed.

## Context

Since [ADR 0015](0015-reduced-resolution-preview.md) the workspace has held a
**reduced** scene-linear rendition — 2048 pixels on its longest edge where the
reference camera records 4056 — and since [ADR 0008](0008-display-preview-rendering.md)
it has shown an **8-bit, display-encoded, hard-clipped** version of that. Both
documents state the same thing in different words:

> Preview pixels are disposable. The RAW file plus canonical adjustments are
> the source of truth.

Until now that was a claim with nothing to test it. There was no second
consumer of the canonical state, so nothing proved that the state was enough to
reproduce the photograph, and nothing would have noticed if the preview had
quietly become the only representation that existed.

Three canonical adjustments now exist — orientation
([ADR 0010](0010-user-owned-orientation-adjustment.md)), the creative channel
mix ([ADR 0016](0016-interactive-channel-mixer.md)) and exposure
([ADR 0017](0017-interactive-exposure.md)) — and a user can do real work with
them and then have no way to get the result out of the application.

## Decision

**A full-resolution export restarts from the RAW file, applies the same
canonical `ImageAdjustments` through the same processing primitives, and
writes a 16-bit unsigned integer RGB TIFF tagged sRGB.**

```text
ExportRequest = RAW URL + ImageAdjustments
    ↓  RAWWorkingImagePipeline      ← the SHARED front half
WorkingColorRGBImage                full resolution, scene-linear, pre-creative
    ↓  IRChannelMixer               adjustments.channelMix
IRChannelMixedRGBImage
    ↓  ImageOrienter                file orientation + adjustments.orientation
OrientedSceneLinearRGBImage
    ↓  SceneLinearExposer           adjustments.exposure
ExposedSceneLinearRGBImage          ← the full-resolution render
    ↓  ExportImageEncoder           clip, sRGB, 16-bit quantisation
ExportEncodedImage
    ↓  TIFFExporter                 temp file → finalise → move
a 16-bit RGB TIFF
```

### 1. The export takes a URL, and there is no other way to give it pixels

`FullResolutionExportPipeline.render(_:using:cancellation:)` takes an
`ExportRequest`, which has exactly two stored properties: a `URL` and an
`ImageAdjustments`. It has no initialiser taking a preview, a
`WorkspacePreviewPipeline.Source`, a `CGImage`, a `SceneLinearPreviewImage` or
a `PreviewResolutionPolicy`.

That is the structural half of the invariant, and it is the half that matters:
exporting from preview pixels is not a mistake anyone can make, because there
is no parameter through which preview pixels could arrive.

The behavioural half is tested too — a document prepared at a 2048-pixel
preview policy and the same document prepared at 512 produce **byte-identical**
exports, on the synthetic frame and on the E-PL3 fixture.

### 2. One front half, not two

Everything from the file to the working representation now lives in
`RAWWorkingImagePipeline`, which both end paths call:

```text
decodeMosaic → RAWMosaicNormalizer → neutral-patch estimate → RAWWhiteBalancer
→ RAWDemosaicer → RAWWorkingColorConverter
```

It was extracted from `WorkspacePreviewPipeline.prepare`, where it had lived
while the preview was the only consumer. Writing those seven calls again in the
export path was the obvious alternative and was rejected: two RAW pipelines
that start identical drift silently. A different neutral patch, a different
camera-to-working transform or a different demosaic would make an export
disagree with the preview it is supposed to be the full-resolution version of,
and nothing in the application would say so.

The split is at the **working representation**, because that is exactly where
the two paths genuinely diverge: the preview reduces, and the export does not.

`WorkspacePreviewPipeline` keeps its named choices — `initialTransform`,
`centredNeutralPatch`, `orientation(for:)`, `effectiveOrientation(for:adjustments:)`
— as forwarding declarations rather than second literals, so there is still one
place each decision is made.

### 3. The adjustable stages are the same three, in the same order

```text
colour   IRChannelMixer      adjustments.channelMix
geometry ImageOrienter       source orientation composed with the user's
light    exposure            adjustments.exposure
```

Same stages, same order, same values, both paths. The export runs them at
sensor resolution and the preview runs them on the reduced buffer; nothing else
about them differs.

### 4. Exposure stops being display-only arithmetic

ADR 0017 named `DisplayPreviewRenderer` the mathematical authority on what
`exposureEV` does to a pixel. That was accurate while the display was the only
consumer and stopped being accurate here. The arithmetic is now
`SceneLinearExposure`:

```text
UserExposureAdjustment     the person's intent, validated and persisted
SceneLinearExposure        the mathematics: scale = 2^EV, exposed = v × scale
DisplayPreviewRenderer     display clipping and 8-bit sRGB encoding
ExportImageEncoder         export clipping and 16-bit sRGB encoding
```

The alternative was four copied lines. Two copies of a numeric rule drift, and
this drift would be invisible: an export one rounding step, one narrowing order
or one `pow`-versus-`exp2` away from the preview looks entirely plausible. A
test compares the two paths' exposed values bit pattern by bit pattern.

The same argument applied to the sRGB transfer function, which is now
`SRGBTransferFunction` and is called by both encoders.

The preview applies exposure **inside** its display pass, as it always has; the
export applies it as a stage of its own, `SceneLinearExposer`, because its
result has to exist as an inspectable scene-linear value before anything clips
or quantises it. That is the state a test checks for a red/blue swap, a quarter
turn and a doubling, all at once, with the evidence still intact.

See the [amendment to ADR 0017](0017-interactive-exposure.md#amendment-2026-09-13--the-exposure-primitive-is-shared).

### 5. The export range policy: an explicit hard clip

```text
x < 0   → 0        counted in clippedLowSampleCount
x > 1   → 1        counted in clippedHighSampleCount
else    → x
```

> **16 bits does not mean unlimited scene-linear range.** A normalised integer
> TIFF still needs a finite encoded range: its samples run `0…65535` and mean
> `0…1`. More bits buy finer steps inside that range, not a larger one.

The working representation is deliberately unbounded — black-subtracted noise
straddles zero, and a creative mix with negative coefficients produces negative
values on purpose — so bringing it into an encodable range is a decision, not a
technicality. The decision is the same one the display path made, for the same
reasons, with the same counting of what it destroyed.

No tone mapping, no highlight recovery, no automatic rescaling. Each would be
its own decision with its own ADR.

Clipping happens **after** exposure, so a value a negative exposure brings back
into range is rendered rather than already lost. Tested on both paths.

#### Floating-point TIFF was considered and rejected

A 32-bit float TIFF (`SampleFormat = 3`) would preserve the extended range
exactly. It is a real part of the TIFF specification, and ImageIO can write it.
It was rejected for this milestone because interoperability is the point of
choosing TIFF at all: float TIFFs are read unevenly, are frequently
misinterpreted as display-referred, and would hand users a file that looks
wrong in the applications they already use. A scene-linear interchange format
is worth having and is a separate decision — OpenEXR is the better candidate
when it is made.

### 6. The colour encoding

```text
16-bit unsigned integer RGB, 3 channels, no alpha
sRGB primaries, D65 white point       — unchanged from the working space
piecewise sRGB transfer function      — applied exactly once, by the shared function
tagged sRGB                           — an ICC profile is embedded in the file
```

The primaries and the white point are the working space's own
([ADR 0006](0006-working-color-space.md)), so the only thing that changes at
this boundary is the transfer function. The file is tagged so that no reader
applies it a second time: an untagged file and a mis-tagged file both produce a
doubled or missing transfer function, which looks like a contrast error rather
than a colour-management one.

**This is not a colour claim.** The camera-to-working transform is still
`.sensorRGBIdentityFalseColor`, which is not a validated infrared calibration.
An exported file is *displayable and interoperable*, which is strictly weaker
than *colour-correct*, and the provenance on every stage continues to say so.

### 7. Quantisation

```text
sample = round(encoded × 65535)        half away from zero
```

The display path's rule with `65535` where it has `255`. The endpoints are
exact:

```text
0    → 0 × 65535 = 0                                   → 0
0.5  → 32767.5                                         → 32768
1    → 1.055 × 1^(1/2.4) − 0.055 = 1 − 1 ULP, × 65535  → 65535
```

The last is worth stating carefully: the sRGB OETF evaluates in `Double` to one
ULP below `1`, so rounding to nearest is exactly what recovers `65535`.
Truncation would give `65534` — a white that is not quite white — and would
bias every sample downward by up to one level. Two quantisers with two
different rules would also make a preview and an export disagree in a way that
reads as a colour difference rather than a rounding one.

### 8. Processing and file encoding are separate

```text
FullResolutionExportPipeline   RAW → adjusted scene-linear → encoded samples
TIFFExporter                   encoded samples → a file
```

`TIFFExporter` does not decode RAW, does not know what an adjustment is, and
makes no processing decision. `ExportEncodedImage` stores `[UInt16]` rather
than `Data`, so byte order exists in exactly one place — `ExportCGImageAdapter`
— and is declared to CoreGraphics rather than assumed.

The encoder refuses an image whose provenance says it was reduced for preview,
with `ExportEncodingError.previewReducedSource`. The export pipeline cannot
produce one; the guard is for the case where someone later hands the encoder an
image from the interactive path. Upscaling a preview into a final file is the
worst failure this milestone could have, and it would look entirely plausible
in every way except sharpness.

### 9. The snapshot: a URL and an adjustment state, taken once

```text
let exportRequest = RAW URL + current canonical ImageAdjustments
```

Both are captured when the export starts and never consulted again.

- **Pending renders do not matter.** The canonical truth is
  `DocumentState`'s adjustments, not the last preview that managed to appear.
  An export requested while a render is in flight uses the state the user has
  asked for, at full resolution, rendered itself. It does not wait for the
  preview, because it has no use for the preview's pixels.
- **Persistence does not matter either.** A failed sidecar write is a
  persistence failure, not an editing failure. An export while
  `.saveFailed` stands uses the current adjustments and does not repair, retry
  or hide the save failure.
- **An export never writes a sidecar.** Exporting produces an artefact; it is
  not an edit, and coupling the two would mean a user could not export without
  also committing.

Each of these three is tested.

### 10. One export at a time

The control is unavailable while an export runs. No queue, and no cancelling
the first with the second: both are more mechanism than a single-file export
needs. A second request while one is running does nothing — enforced in
`exportTIFF(to:)`, not only displayed by `canExport`.

Cancelling the save panel does nothing at all: no task, no file, no error, no
status to dismiss.

### 11. Opening another file leaves a running export alone

`open(_:)` does not cancel `exportTask`. A user who starts a twelve-megapixel
render and then looks at the next photograph has not changed their mind about
the file they asked for. The export completes against its snapshot, and its
receipt names the RAW file and the adjustments it used — which are the first
document's, however the second has been adjusted since.

This is a **different** rule from the preview renderer's, deliberately. A
superseded preview is worthless, so ADR 0011 cancels it; a requested file is
not, so this does not.

### 12. Orientation is applied to the pixels and declared as upright

```text
pixels      permuted by ImageOrienter, into viewing order
TIFF tag    Orientation = 1
```

Copying the RAW file's orientation tag across would tell every reader to rotate
the pixels again. A doubly rotated export is the classic form of this bug, and
it reads as a pipeline error rather than a metadata one. The orientation is
stated as `1` in both the top-level property and the TIFF dictionary, because
readers disagree about which they consult and "absent means 1" is a convention
rather than a guarantee.

Exported dimensions are therefore the oriented ones:

```text
4056 × 3040   upright
3040 × 4056   after a quarter turn
```

### 13. Metadata: pixels, dimensions, colour, camera — and nothing else

```text
written        pixels, dimensions, 16-bit RGB, the sRGB ICC profile,
               Orientation = 1, TIFF Make and Model
not written    adjustment JSON, XMP, private tags, recipes, a thumbnail,
               the RAW file's EXIF, the capture date
```

The **capture date** is left out rather than guessed. `RAWMetadata` carries it
as an instant; a TIFF `DateTime` is a wall-clock string with no time zone, so
writing one would mean inventing the zone the photograph was taken in. An
absent field is honest; a wrong one is not. A test greps the written bytes for
`schemaVersion`, `channelMix`, `iradjustments` and `xmpmeta` and requires none
of them.

### 14. File safety

ImageIO has no commit semantics of its own — `CGImageDestinationFinalize`
returning `false` can leave a partial file behind — so the destination is never
written to directly:

```text
1. ask the file system for a replacement directory on the destination's volume
2. write and finalise the whole TIFF there
3. move it onto the destination, replacing an existing file if there is one
4. remove the replacement directory
```

If anything before step 3 fails, the destination is untouched: a user who
exported over yesterday's file still has yesterday's file. Step 3 uses
`replaceItemAt` when something is already there — the file system's own
atomic-where-possible replacement — and a plain move otherwise.

Overwriting is not decided in the writer. A destination exists only because the
user chose it in a save panel, and the panel is where the overwrite was agreed
to. The RAW file is opened for reading and nothing else, as always.

### 15. Errors say which step failed

```text
FullResolutionExportError
├── rawPreparationFailed(url:underlying:)          decode, normalise, WB, demosaic, convert
├── adjustmentProcessingFailed(stage:underlying:)  channelMix | orientation | exposure
├── encodingFailed(underlying:)                    ExportEncodingError
└── writingFailed(underlying:)                     TIFFExportError

TIFFExportError
├── invalidExportImage(reason:)
├── imageUnavailable(reason:)
├── destinationUnavailable(url:reason:)
├── encodingFailed(url:reason:)
└── finalizationFailed(destination:underlying:)
```

Five distinguishable problems rather than one "export failed", because they
call for different responses and only some of them are ours. `CancellationError`
is deliberately none of them: nobody wanting the result is not the same as
being unable to produce it, and a cancelled export reports nothing at all.

The typed error survives to `DocumentState.ExportFailure`, which keeps
`any Error` and offers `exportError` rather than flattening it to a sentence.

### 16. Concurrency

The export runs in a detached task at user-initiated priority; nothing about it
computes on the main actor. The three adjustment stages and the encoder poll
cancellation once per row. The RAW front half does not — none of its stages
does, which is unchanged from the preview path — so an export cancelled during
decoding stops at the task boundary rather than inside the pass.

## Preview and export, side by side

| | interactive preview | full-resolution export |
|---|---|---|
| starts from | the retained reduced buffer | the RAW file, decoded again |
| RAW front half | `RAWWorkingImagePipeline` | `RAWWorkingImagePipeline` — the same code |
| resolution | reduced by `PreviewResolutionPolicy` | the sensor's own active area |
| channel mix | `IRChannelMixer`, `adjustments.channelMix` | the same |
| orientation | `ImageOrienter`, file + user | the same |
| exposure arithmetic | `SceneLinearExposure` | `SceneLinearExposure` — the same |
| where exposure is applied | inside the display pass | as `SceneLinearExposer`, its own stage |
| range policy | `.hardClipToDisplayRange` | `.hardClipToExportRange` |
| transfer function | `SRGBTransferFunction` | `SRGBTransferFunction` — the same |
| quantisation | `round(x × 255)` | `round(x × 65535)` |
| bit depth | 8 per component | 16 per component |
| destination | a `CGImage` on screen | a TIFF file on disk |
| cancelled by a newer request | yes (ADR 0011) | no — it is bound to its snapshot |
| writes the sidecar | yes, after a successful render | never |

Everything above the resolution row is identical code. Everything below it is
each path's own, and each difference is named.

## Memory

Stated structurally, not measured. For the 4056 × 3040 reference frame:

```text
pixels                                 12,330,240
Float32 RGB buffer                    147,962,880 bytes  (~148 MB)
UInt16 RGB export samples              73,981,440 bytes  (~74 MB)
the reduced preview, for comparison     37,724,160 bytes  (~36 MB)
```

The export path's largest simultaneous buffers are the four scene-linear
`Float32` images the adjustment stages produce:

```text
working   the shared front half's result
mixed     IRChannelMixer
oriented  ImageOrienter
exposed   SceneLinearExposer
```

They are all in scope inside one function, so the conservative bound is **four
× 148 MB ≈ 592 MB** while the last of them is being written. ARC may release
earlier than the end of scope; nothing here depends on that, and no measurement
of peak RSS is claimed. Once `render` returns, only the exposed image survives,
and the encoder's 74 MB `UInt16` buffer is allocated beside that one alone.

The RAW front half's own intermediates — the decoded, normalised and
white-balanced mosaics and the camera-native image — go out of scope when
`prepare` returns, because it uses the bare-image overloads rather than the
chain-retaining wrappers. Retaining that chain would have added roughly another
270 MB for no purpose — the same 270 MB the preview path's existing figures
account for, since its retained 36 MB buffer replaced a ~420 MB chain.

An **identity mix and an upright orientation share their input's buffer** rather
than copying it, and so does a `0 EV` exposure, so a neutral export allocates
one full-resolution `Float32` image and the `UInt16` result — not four and a
result.

None of these figures is a measurement of peak RSS, and none is presented as
one: they are the sizes the geometry and the element types imply, checked
against the real frame by a test.

## Consequences

- The central architectural claim is now load-bearing rather than asserted: a
  2048-pixel preview and a 4056-pixel export of the same RAW file and the same
  `ImageAdjustments` are two renderings of one state, and the export is derived
  from the file.
- Preview and export cannot become two colour pipelines without deleting shared
  code, which is a visible change rather than a quiet one.
- Exposure arithmetic and the sRGB transfer function each have exactly one
  implementation.
- Version 1's export requirement is met for TIFF.
- `Develop/` and `Export/` exist as modules for the first time.

## Known limitations

- One format. JPEG and PNG are named in `CLAUDE.md` as V1 targets and are not
  implemented.
- No progress reporting beyond "Exporting…". A twelve-megapixel export on the
  CPU takes seconds, and there is no per-stage percentage.
- Cancelling a running export is not offered in the UI. The pipeline is
  cooperatively cancellable from the adjustment stages onwards; only the
  control is missing.
- Exports are not reduced, sharpened or resized, and there is no option to.
- The capture date is not carried across; see Decision 13.
- No batch export. One file at a time, chosen in a save panel.
- The colour is still not validated for infrared. A 16-bit file is a more
  precise record of the same unvalidated rendering.

## Non-goals

JPEG, PNG, DNG, OpenEXR, floating-point TIFF, batch export, export presets,
resizing, output sharpening, print profiles, an ICC profile chooser,
watermarks, a metadata editor, an EXIF round-trip engine, recipes, undo/redo, a
histogram, white-balance controls, and any GPU path.
