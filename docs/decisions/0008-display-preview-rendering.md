# 0008 — The first display preview rendering boundary

Status: accepted
Date: 2026-09-11

> Numbering note: `CLAUDE.md` used `0008-metal-render-pipeline.md` as an
> illustrative example of a future ADR filename. This milestone is the decision
> that actually took number `0008`, so that illustrative example now reads
> `0009-metal-render-pipeline.md`. ADR numbers follow the order decisions are
> made; no ADR was renamed. This is the second time the example has moved, for
> the same reason it moved the first time.

## Context

Six application-owned stages exist:

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
```

Everything in that chain is **scene-linear**, extended-range and unclamped.
None of it can be shown to a person. [ADR 0006](0006-working-color-space.md)
Decision 27 and [ADR 0007](0007-infrared-channel-mixing.md) Decision 31 both
deferred the encoding of those values for a monitor to a later, separate stage.
This is that stage.

Until now the only pixels the workspace has ever displayed came from LibRaw's
processed-RGB path — the path that applies a camera colour matrix, gamma and
its own black and white handling, and which for exactly that reason was never
the foundation of the owned pipeline. The product consequence of this ADR is
that the pixels on screen become the ones the application computed.

## What this ADR is, and is not

It is a **display boundary**: a defined, auditable, deliberately primitive way
to turn scene-linear coordinates into bytes a monitor can be handed correctly.

It is **not** a photographic tone pipeline. There is no tone mapping, no
highlight recovery, no automatic exposure, no contrast, no saturation and no
curve. A first display boundary that pretends to be a rendering pipeline is
worse than one that is honest about being a clip and an encode.

## Decision 1 — The input is the post-creative-stage representation

The renderer consumes `IRChannelMixedRGBImage`, or the
`IRChannelMixedProcessedRAWImage` that wraps it.

It does **not** consume, and has no entry point that could accept:

```text
RAWMosaic                    the sensor mosaic
LinearRAWMosaic              the normalised mosaic
WhiteBalancedRAWMosaic       the white-balanced mosaic
DemosaicedRAWRGBImage        camera-native RGB
WorkingColorRGBImage         the PRE-mix working image
RAWImage                     LibRaw's processed RGB
```

The creative channel mix therefore stays strictly upstream of display
rendering. A rendering that reached the screen went through the creative stage,
even when the mix asked for nothing — which is exactly the fact
`IRChannelMix.identity` exists to record.

Excluding `WorkingColorRGBImage` is deliberate rather than incidental. The two
types hold coordinates in the same space and the same layout; if the renderer
accepted both, a caller could skip the creative stage without the provenance
chain ever saying so.

## Decision 2 — The input's coordinates are taken at their word

The renderer assumes, and requires, that its input is:

```text
space        extended linear sRGB (sRGB primaries, D65, linear transfer)
storage      Float32, interleaved R G B, tightly packed
range        any finite value: below 0 and above 1 are both normal
finiteness   finite — NaN and infinity are refused, not encoded
```

It must never treat those numbers as though they were already sRGB-encoded.
That mistake is invisible in code and obvious on screen, and it is the single
most likely way a display stage silently invalidates everything upstream of it.

The one assumption the renderer does not make is that the values are *good*.
Whether they represent anything colourimetrically meaningful for an infrared
capture is decided by the camera-to-working transform's provenance, and no
transform in this project is a validated infrared calibration.

## Decision 3 — Exposure is an explicit stage, in the linear domain

```text
linearExposed = linearInput × 2^EV
```

Photographic EV semantics: `+1 EV` doubles, `−1 EV` halves, `0 EV` is exactly
`×1` and is the mathematically neutral choice.

It happens **before** clipping and **before** the transfer function, because
that is the only place the arithmetic means what its name says. Multiplying an
already-clipped or already-encoded value by `2^EV` is not exposure.

## Decision 4 — There is no automatic exposure and no default EV

No histogram is read. No mean, median or percentile is computed. Nothing is
normalised to a maximum. No brightness factor is applied anywhere else in the
stage under another name.

There is no defaulted exposure parameter on any renderer entry point. A caller
that wants neutral exposure writes `0 EV` and that choice appears at the call
site, exactly as `IRChannelMixer` requires a mix to be named rather than
assumed. The reason is the same: a default hides a decision that a reader of
the code would otherwise be able to audit.

## Decision 5 — Exposure arithmetic is `Double`, narrowed once, and can fail

The scale factor is computed once per image as `exp2(exposureEV)` in `Double`.
Each sample is widened to `Double`, multiplied, and narrowed back to `Float32`
exactly once — the same convention `RAWWorkingColorConverter` and
`IRChannelMixer` use, for the same reason.

A non-finite result is a **typed failure**, never an infinity written into an
image and never a value clamped to something plausible. Three things are
refused:

```text
a non-finite EV                     NaN, ±infinity
a finite EV whose 2^EV is infinite  e.g. 5000 EV
a product that overflows Float32    finite input, finite scale, infinite result
```

The first two share one case, because both mean "this exposure cannot be
applied" and both are fully diagnosed by reporting the EV and the scale it
produced.

Both the EV **and** its scale are checked, not just the scale. `exp2(−infinity)`
is `0` — a perfectly finite-looking multiplier that would render a black frame
from a nonsense exposure without a word. A scale-only check would let exactly
that through.

Refusing the third rather than letting the clip absorb it is the point. A
sample that overflowed to infinity would clip to `1` and reach the screen as a
perfectly ordinary white pixel, and nothing downstream could ever tell it apart
from a legitimately bright one.

## Decision 6 — Values outside `0...1` are hard clipped, and it is named that

After exposure, each component is clipped to the unit range:

```text
x < 0   → 0
x > 1   → 1
else    → x unchanged
```

That is the whole policy. It is called **hard display-range clipping**, it is
carried as a named `DisplayRangePolicy` value rather than being implicit in the
code, and it is recorded in provenance.

It is **not** tone mapping. Nothing is compressed, rolled off, shouldered,
toed, adapted or recovered. Highlights above `1` are *destroyed*, not
"handled"; shadows below `0` are *destroyed*, not "lifted". Saying anything
softer than that would misdescribe what the code does.

It is also this path's **entire gamut and range handling**. Clipping extended
linear sRGB to the unit cube is a primitive gamut operation as well as a range
one: a coordinate outside the cube may be outside sRGB's gamut, and clipping
each component independently moves it to a different colour rather than to the
nearest in-gamut one. Values below zero are common in this pipeline — they come
from black-subtracted noise straddling the black point and from creative mixes
with negative coefficients — so this is a real operation on real data, not a
theoretical edge case. A real gamut-mapping decision is a later ADR.

## Decision 7 — Clipping happens only in the display representation

The upstream `IRChannelMixedRGBImage` is never mutated, replaced, clamped or
rewritten. Rendering it reads it and produces a separate buffer of a different
type; afterwards the scene-linear image is bit-identical to what it was before,
and every value below `0` and above `1` is still there.

That is asserted directly, on synthetic data and on the real fixture. It is the
invariant that keeps "the preview clips" from quietly becoming "the pipeline
clips".

## Decision 8 — How much was destroyed is recorded

The renderer counts the samples it clipped low and the samples it clipped high,
and both counts are part of the stage's provenance record.

Provenance elsewhere in this project records *what a stage did*. Here the stage
discards information, so what it did is not fully described by naming the
policy — the honest record includes how much of the image the policy consumed.
The counts are per component, not per pixel, cost two increments in a loop that
already branches, and turn "the highlights clipped" from an impression into a
number.

## Decision 9 — The transfer function is the piecewise sRGB encoding

After exposure and clipping, each component is encoded with the standard sRGB
opto-electronic transfer function:

```text
if x <= 0.0031308:  encoded = 12.92 × x
else:               encoded = 1.055 × x^(1 / 2.4) − 0.055
```

evaluated in `Double`.

**`pow(x, 1/2.2)` is not an acceptable substitute.** It is a different curve; it
differs most in the shadows, which is where infrared work most often lives, and
it would make the pixels disagree with the sRGB profile they are about to be
tagged with. The two-branch definition, including the linear segment near
black, is the encoding sRGB actually specifies.

The comparison is `<=` at exactly `0.0031308`, so the threshold itself takes
the linear branch. The published constants are very slightly inconsistent —
the two branches differ by about `3 × 10⁻⁸` there — and picking a branch by
fiat is the only way to make the boundary deterministic.

This is where the representation changes name:

```text
upstream     extended linear sRGB    scene-linear, unclamped, Float32
downstream   display-encoded sRGB    display-referred, 0...1, then quantised
```

## Decision 10 — The output is 8-bit, three bytes per pixel, R G B

```text
bits per component   8
components           3
alpha                none — there is no alpha channel
bytes per pixel      3
bytes per row        width × 3, tightly packed, no padding
layout               row-major, interleaved, R G B R G B ...
byte order           not applicable: one byte per component
```

There is no alpha channel rather than an ignored or invented one. The image is
opaque by construction, a fourth byte would be a value with no meaning, and a
third of the buffer would be padding. `CGImage` accepts 24-bit-per-pixel RGB
with `kCGImageAlphaNone` directly, so nothing is gained by paying for it.

The layout mirrors the Float32 RGB images upstream, which makes the whole
pipeline one storage convention with one thing changed: the element type.

Nothing here depends on unspecified memory layout. The buffer is a flat byte
sequence with a stated index formula:

```text
index = (row × width + column) × 3 + channelOffset
```

## Decision 11 — Quantisation rounds to nearest, half away from zero

```text
sample = round(encoded × 255)
```

with `round` being round-half-away-from-zero. Every encoded value is in
`0...1`, so all values are non-negative and this is plainly "round half up".

The endpoints are exact:

```text
encoded 0 → 0 × 255 = 0        → 0
encoded 1 → 1 × 255 ≈ 255      → 255
```

The second is worth stating precisely. `1.055 × 1^(1/2.4) − 0.055` evaluates in
`Double` to one ULP below `1`, so the product is `254.999999999999971…` — and
rounding to nearest is exactly what recovers `255`. The mapping is exact
*because* of the rounding step, not in spite of it, and a test pins it.

Truncation was rejected: it biases every sample downward by up to one level and
would map `1` to `254`.

The conversion to `UInt8` is bounded by the range already proven — `0...255` —
rather than by invented limits, because a trapping integer conversion is not an
acceptable failure mode on a publicly reachable path.

## Decision 12 — The platform image is tagged sRGB, at an adapter boundary

The `CGImage` is built with `CGColorSpace(name: CGColorSpace.sRGB)` — the
ordinary, non-linear sRGB space — because that is what the bytes now are.

Tagging these bytes as linear sRGB, or leaving ColorSync to infer something,
would double-apply or skip a transfer function. The existing legacy preview
tags LibRaw's *linear* 16-bit samples as `linearSRGB`, which is correct for
*those* bytes and wrong for these; the two must not be confused, which is one
more reason the display buffer is its own type.

Platform image construction lives in a small adapter, separate from the
renderer. The mathematics has no reason to import CoreGraphics, and the pixel
representation was chosen so the adapter can hand the buffer over directly
rather than convert it a second time.

Core Image is deliberately absent. A `CIFilter` chain would be an undocumented
tone and colour pipeline hidden behind a display call, which is the opposite of
what this ADR is for.

## Decision 13 — Orientation is not applied, and says so

The application-owned pipeline has recorded orientation as unapplied at every
stage since the mosaic, and there is no application-owned orientation stage.
This milestone does not add one, and the display renderer does not read
`RAWMetadata.geometry.flip`.

The renderer is geometry-preserving: same width, same height, same pixel order,
no rotation, no flip, no crop, no resampling. `orientationApplied` stays
`false` in provenance, where it is visible rather than merely absent.

Rotating inside the display encoder as an incidental side effect of "making the
preview look right" would put a geometry stage in a colour stage and hide it
from the one record that is supposed to describe the pipeline. A camera whose
file asks for a flip therefore shows unrotated in the workspace. That is a
known limitation with a named cause, which is better than a correct-looking
image produced by an unnamed stage.

## Decision 14 — Rendering intent is one immutable value

`DisplayRenderSettings` carries exactly the three choices this stage requires:

```text
exposureEV          Double, photographic EV
rangePolicy         DisplayRangePolicy  — .hardClipToDisplayRange
encoding            DisplayEncoding     — .sRGB
```

All three are `let`. There is no default, no `.standard`, no zero-argument
initialiser, and no defaulted parameter anywhere that would let one appear.

`DisplayRangePolicy` and `DisplayEncoding` each have exactly one case, for the
same reason `RAWWorkingColorSpace` has one: a case is a claim that the pipeline
can produce and interpret that behaviour. There is no `.reinhard`, no
`.filmic`, no `.displayP3` and no `.rec709`, because none of them exists. They
arrive when they are implemented.

Unlike `IRChannelMix` and `RAWCameraToWorkingColorTransform`, this type's
initialiser is public and its properties are plain data. Those two pair a
matrix with a provenance claim, and a mismatched pairing would be a lie about
where a transform came from. Settings pair three independent choices, none of
which is a claim about anything's origin, so there is nothing to forge — and
the value is validated where it is used, once, rather than in two places.

## Decision 15 — The output is a distinct semantic type

`DisplayEncodedPreviewImage` is not `WorkingColorRGBImage`, not
`IRChannelMixedRGBImage` and not `RAWImage`. Its documentation says what its
pixels are:

```text
display referred     not scene-linear
sRGB encoded         the piecewise transfer function has been applied
clipped              per the named display-range policy
quantised            8 bits per component
```

Its storage shape (`Data` of bytes, as `RAWMosaic` already uses) is not a reason
to merge it with anything, and its being an image is not a reason to reuse a
scene-linear type whose element count happens to match. Every geometry
accessor validates and returns `nil` rather than trapping, exactly as the
upstream image types do.

## Decision 16 — Provenance retains the whole chain, by reference

`DisplayPreviewProcessing` holds the settings, the two clip counts and the
`IRChannelMixProcessing` it consumed. Everything else is read *through* that:
the mix and its source, the camera-to-working transform and its source, the
demosaic algorithm, the white-balance gains and their provenance, the white
level, the black subtraction. Nothing upstream is copied, so two records of one
history cannot disagree.

`DisplayPreviewProcessedRAWImage` retains the `IRChannelMixedProcessedRAWImage`
it was produced from, and through it the working image, the camera-native
image, both mosaics, the decoded `UInt16` mosaic, the metadata and the source
URL. Its initialiser is module-internal, as every wrapper in the chain is: the
pairing can be read in full from outside the module but not minted there.

## Decision 17 — Changing display settings re-renders from the same mixed image

```text
new preview = render(the IRChannelMixedRGBImage, newSettings)
       NOT   render(the previous 8-bit preview, newSettings)
```

`render(settings:replacing:)` reaches through `previous.source` and never reads
`previous.image`. Changing exposure therefore costs one pass over the mixed
image and must not rerun the channel mix, the camera conversion, the demosaic
or the white balance, and must never decode again.

Structurally this is the same protection every stage above has. Practically it
matters more here than anywhere else: re-rendering from an 8-bit clipped
preview would compound quantisation and could not recover a single clipped
highlight, and the result would look plausible.

## Decision 18 — Typed failures, no fatal errors

`DisplayRenderingError` is a separate type from `RAWProcessingError` and
`IRProcessingError` for the reason those two are separate from each other: it
describes a different boundary. Nothing here interprets sensor data, and
nothing here is a creative colour decision; what can go wrong is geometry, an
unusable exposure, a value that is not a number, and the platform refusing to
build an image.

```text
invalidGeometry              dimensions and buffer disagree, either side
nonFiniteExposure            the EV, or the 2^EV it produces, is not finite
nonFiniteSceneLinearInput    a NaN or infinite input coordinate
nonFiniteExposedValue        exposure produced a value Float32 cannot hold
displayImageUnavailable      CoreGraphics would not build the image
```

The bare image types are publicly constructible, so every one of these is a
real boundary rather than an internal assertion, and none of them is a
precondition failure. Output storage arithmetic is checked too, and reports
`invalidGeometry` naming the output rather than gaining a second case that
means the same thing.

## Decision 19 — The workspace's initial state chooses `.identity`, at the UI layer

The application layer has to pick something for a freshly opened file, and this
is a product decision rather than a rendering one, so it is made in
`DocumentState` where it is visible — not as a default inside any core API.

The choices are stated at that call site:

```text
white balance   neutral-patch estimate over a centred region of the active area
camera→working  .sensorRGBIdentityFalseColor
channel mix     .identity
exposure        0 EV
range policy    .hardClipToDisplayRange
encoding        .sRGB
```

The mix is `.identity` rather than `.redBlueSwap` because the application
cannot know that a given file is an infrared capture. A red/blue swap applied
to a visible-light frame is simply wrong, and applying the canonical infrared
operation by default would make the app assert something about the photograph
that it has no basis for. `.identity` traverses the creative stage and asks for
nothing, which is a fact the provenance chain records honestly. When a filter
or capture profile exists, it — not the renderer, and not this default —
decides the mix.

The white-balance patch is a centred rectangle of the active area, chosen at
the application layer for the same reason. It is a deterministic placeholder,
not a scene analysis: nothing verifies that whatever is in the middle of the
frame is neutral.

## Decision 20 — The legacy LibRaw preview stays, and stops being the picture

`decode(at:options:)` and `PreviewImageRenderer` are not deleted. They remain
as a diagnostic reference, and the workspace still shows what the decoder
reported.

What changes is which pixels are on screen. After the owned pipeline succeeds,
the image the user sees is the owned pipeline's. If the owned pipeline fails,
the failure is reported — the workspace does not fall back to the LibRaw image,
because a visually plausible picture produced by a different pipeline is the
worst possible response to our own pipeline being broken.

## What this ADR does not decide

- **Tone mapping** of any kind: Reinhard, filmic, ACES, shoulder/toe curves,
  local operators.
- **Highlight reconstruction or recovery.**
- **Automatic exposure** or histogram-derived anything.
- **Contrast, saturation, vibrance, HSL, curves and LUTs.**
- **Real gamut mapping.** Component-wise clipping is the primitive stand-in.
- **Colour spaces other than sRGB** for display, including Display P3 and any
  wide-gamut or HDR handling.
- **Bit depths other than 8** for preview.
- **Dithering.** None is applied; 8-bit banding in smooth gradients is a known
  consequence.
- **Orientation**, which needs its own application-owned stage.
- **Export.** A file is not a preview: it will need its own colour decisions,
  its own bit depth and its own ADR, and it must not reuse this 8-bit buffer.
- **Preview resolution strategy, caching and cancellation.** The current
  implementation renders the full frame.
- **A Metal or Accelerate implementation.** This is a CPU reference; only
  debug-build timings have been taken and no performance claim is made.

## Consequences

- The application-owned pipeline reaches the screen. For the first time the
  workspace shows pixels this project computed, from the sensor mosaic upward,
  with every stage named and recorded.
- The chain from a displayed pixel back to a decoded sample is readable from
  one value: settings, mix, camera transform, demosaic, gains, normalisation,
  metadata, URL.
- The stage destroys information, and says how much. A preview with 3 million
  clipped samples is now a number rather than a feeling, which is the argument
  for the tone stage that comes next.
- Scene-linear data remains intact and recoverable behind the preview, so
  exposure, tone and export can all be built without re-deriving anything.
- Nothing about this makes the image *correct*. It is displayable, which is a
  strictly weaker claim: no transform in the pipeline is a validated infrared
  calibration, and a defined display encoding does not become one.
