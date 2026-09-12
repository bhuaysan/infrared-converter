# 0015 — A reduced-resolution interactive preview

Status: accepted
Date: 2026-09-12

> Numbering note: `CLAUDE.md` used `0013-metal-render-pipeline.md` as an
> illustrative example of a future ADR filename, a number ADR 0013 has since
> taken. This milestone takes `0015`, and that illustrative example now reads
> `0016-metal-render-pipeline.md`. ADR numbers follow the order decisions are
> made; no ADR was renamed.

## Context

ADR 0010 split the workspace pipeline in two so that a user's orientation
correction reruns only the cheap half, and ADR 0011 made that half coalescing
and cancellable. Both took the resolution for granted.

```text
prepare(decoding:using:)    decode → normalise → balance → demosaic → convert → mix
render(_:adjustments:)      orient → display-encode
```

On the E-PL3 fixture — a 4056 × 3040 active area — the retained state after
`prepare` was an `IRChannelMixedProcessedRAWImage`, which reaches the
working-colour image, the camera-native image, both mosaics and the decoded
mosaic through its `source` chain. Measured on the fixture:

| retained buffer | bytes | MiB |
| --- | ---: | ---: |
| decoded mosaic, `UInt16` | 24,660,480 | 23.5 |
| normalised mosaic, `Float32` | 49,320,960 | 47.0 |
| white-balanced mosaic, `Float32` | 49,320,960 | 47.0 |
| camera-native RGB, `Float32` | 147,962,880 | 141.1 |
| working-colour RGB, `Float32` | 147,962,880 | 141.1 |
| **total, application-owned scene-linear chain** | **419,228,160** | **399.8** |

The channel-mixed image itself added nothing: the initial mix is `.identity`,
whose exact path hands the same immutable array back, so copy-on-write shares
the working-colour buffer.

**What that total is, and is not.** Every figure in this ADR describes the
**application-owned scene-linear buffers** reachable from the retained
processing state. It is not a measurement of an open `DocumentState`, which
also holds the LibRaw processed-RGB diagnostic reference, the display
`CGImage`s for both paths, the decoder metadata and a little small state. Those
are held beside the scene-linear buffer and are not counted here, in either
column. The claim is "the retained scene-linear chain fell from ~400 MB to
~36 MB", never "an open document costs 36 MB".

Two costs followed from that, and both were named in the code as things nobody
had measured.

**Every interactive re-render worked on 12.3 megapixels.** An orientation
change permutes the whole frame and then applies exposure, clipping, the sRGB
transfer function and quantisation to all of it — 37 million `Float32` in and
37 million `UInt8` out, for a picture that is then drawn into a window a
fraction of that size.

**A file switch briefly held two of those chains.** ADR 0014 deliberately lets
a document the workspace has left keep its render slot until the state it was
asked for has settled, because that render is what makes the user's decision
eligible to be written. The cost was stated there as "briefly retains two of
them" — which, at 400 MB each, is a cost worth removing rather than defending.

## Decision

**Full-resolution upstream processing stays the processing truth. The
interactive workspace is given a reduced-resolution scene-linear working
representation, and retains that and nothing else.**

```text
RAW mosaic
  → normalisation                       full resolution
  → IR white balance                    full resolution
  → demosaic / RGB formation            full resolution
  → camera → working colour             full resolution
  ────────────────────────────────────  ← the reduction point
  → reduce to preview resolution        SceneLinearPreviewReducer
  → IR channel mix                      preview resolution
  → RETAINED: SceneLinearPreviewImage   preview resolution
  → user orientation                    preview resolution
  → display preview                     preview resolution
```

Four parts, each decided separately.

### 1. The reduction point: immediately after the camera-to-working transform

The working representation has just been established (ADR 0006) and no
creative stage has run yet.

### 2. The size policy: `PreviewResolutionPolicy`, 2048 px on the longest edge

One rule, stated once, in a value type with no view, no screen and no scale
factor in it:

```text
longest edge <= maximumLongestEdge
aspect ratio preserved
never enlarged
never zero
```

The longer edge is set to the limit exactly and the shorter is derived from it
by the same factor, rounded to nearest and floored at 1 — so `longest edge ==
limit` is an exact equality for every input rather than an approximate one.

The size is decided on the **unoriented** image, in sensor coordinates, before
`ImageOrienter` runs. That is safe rather than merely convenient: the eight
orientations are exact permutations of whole pixels, so they may exchange width
and height but cannot change which of the two is larger. A limit imposed before
orientation is still exactly satisfied after it.

```text
source 4056 × 3040  →  preview 2048 × 1535  →  quarter turn  →  1535 × 2048
```

**Why 2048.** `ContentView` has a 720 × 520 point floor with an inspector
taking 280–420 points of it, and a comfortably large workspace on a laptop
display is on the order of 1000–1400 points wide. At a 2× backing scale that is
2000–2800 device pixels, so 2048 is a 1:1 match for the common case and a mild
upscale for a window maximised on a large display. It retains 36 MB instead of
141 MB for the scene-linear buffer alone, and it cuts the per-interaction work
by 3.9×. A 2560 limit would cover a maximised 16-inch window exactly, at 56 MB
retained and only a 2.5× reduction in work; a 1600 limit would save more still
and be visibly soft in an ordinary window. The right answer to "I need more
pixels here" is a future zoom or 1:1 inspection path, not a permanently larger
interactive buffer. 2048 is also a power of two, which costs nothing and is a
convenient size for a future GPU path with texture limits.

The policy is injected — into `WorkspacePreviewPipeline.prepare` and through
`DocumentState.init` — so a test can exercise the reduction on a 64 × 48 image
instead of paying for a multi-megapixel one.

### 3. The resampling method: exact area-weighted averaging

Each destination pixel's footprint is the exact rectangle of source pixels it
maps to; each source pixel contributes in proportion to how much of that
rectangle it covers; the sum is divided by the total weight.

```text
destination column d covers source x in [d·sw/dw, (d+1)·sw/dw)
```

Computed **in the scene-linear domain, on `Float32` values, with `Double`
accumulators, per channel**. No 8-bit round trip, no `CGImage`, no ColorSync,
no implicit colour management, no clamping. Channels are accumulated separately
and never read each other.

Nearest-neighbour is deliberately excluded: point sampling throws away every
sample it does not land on, so fine detail aliases into coarse artefacts —
foliage in particular, which is what infrared photography is full of. An area
average answers "what was the average light over this patch", which is the only
question a smaller rendition of a photograph can honestly answer. A one-pixel
checkerboard reduces to a flat 0.5 rather than to a plaid.

Apple's `vImage` was considered and not used. Its scaling entry points want a
planar or four-channel layout and their own buffer ownership; this project's
storage is three interleaved `Float32` per pixel, the conversions would cost
more than the arithmetic they replace, and an unauditable resampling kernel in
the middle of the one stage whose exactness this milestone has to demonstrate
is the wrong trade. A correct, measured reference implementation comes first,
exactly as ADR 0005 and ADR 0007 chose for their stages.

Cancellation follows the ADR 0011 contract unchanged: one poll before anything
is allocated, one per destination row, `CancellationError` on refusal, and
never a partially written buffer.

### 4. Full-resolution rendering stays a separate, future path

No export and no full-resolution render command is built here. What is
established is that one remains possible: the canonical editing state is
unchanged and is not these pixels.

```text
the RAW file  +  ImageAdjustments        the document
SceneLinearPreviewImage                  a cache derived from the pair
```

An eventual export re-runs from the file. It does not, and must not, start from
the preview buffer.

## Why this point, and not an earlier or later one

All three candidate points produce the same picture. Every transformation
between demosaicing and orientation is a per-pixel linear map with no offset —
a 3×3 matrix for the camera-to-working transform, another for the channel mix —
and an area-weighted mean is a weighted sum, so matrix multiplication
distributes over it:

```text
reduce(M · image)  ==  M · reduce(image)
```

exactly in real arithmetic, and to within floating-point rounding in the
implementation. That is checked rather than asserted, on the actual matrix and
mix representations, in `SceneLinearPreviewEquivalenceTests` — including a
negative control showing that reduction does **not** commute with the display
transfer function, which is why the interactive source stays scene-linear and
the display encode stays last.

So the choice was made on cost and on what a future adjustment can still
change, not on colour.

Peaks below are the sum of the buffers alive at the moment of reduction, from
the measured fixture sizes in the table above, plus the reduced output.

| | peak during `prepare` | retained | future adjustments served |
| --- | ---: | ---: | --- |
| A. after demosaic | ~309 MB | ~36 MB | camera transform, mix, exposure, tone |
| **B. after camera → working** | **~457 MB** | **~36 MB** | **mix, exposure, tone** |
| C. after channel mix | ~457 MB, ~605 MB with a non-identity mix | ~36 MB | exposure, tone |

**Not later than this.** The channel mix is the first creative stage and the
next control the workspace will offer — it is the project's stated
differentiator. Reducing after it would bake one mix into the retained buffer,
so changing the mix would have to re-decode, re-normalise, re-balance,
re-demosaic and re-convert the whole file. Reducing before it costs nothing and
keeps that door open: a future interactive mixer runs on 3.1 megapixels.

> That door was walked through in the next milestone, and it needed one thing
> this ADR did not provide. Reducing *before* the mix is where the reduction
> happens; this milestone nonetheless applied `.identity` immediately
> afterwards and retained the **mixed** result, which is exactly the value a
> new mix cannot be applied to. [ADR 0016](0016-interactive-channel-mixer.md)
> moves the mix out of `prepare` and into `render`, so the retained buffer is
> pre-creative. It also splits the one reduced image type in two — see the
> amendment at the end of this file.

**Not earlier than this.** Reducing one stage earlier, in camera-native RGB,
has a genuinely lower transient peak — the full-resolution working-colour
buffer is never allocated — and it was the closest call in this decision. It
was rejected because the retained representation would then be in a space the
project deliberately refuses to call a colour space (`DemosaicedRAWRGBImage` is
"this sensor's filter responses", ADR 0006), every downstream consumer would
have to carry the camera transform along, and the camera transform would rerun
on every interactive render for a choice that changes with a camera profile
rather than with a slider. The peak is transient and the retained size is not;
the milestone is about what a document holds open, and both options hold open
the same thing.

**And not before demosaicing at all.** See below.

## The CFA rule

A RAW mosaic is not an image, and it must never be handed to a general image
resize.

```text
FORBIDDEN
CFA mosaic → generic 2×2 or bilinear resize → demosaic as if still a CFA
```

Neighbouring mosaic samples are different colours: red, green and blue sit at
different positions of the same 2×2 cell, and a non-Bayer layout such as
X-Trans has a larger and less regular period still. Averaging neighbouring
samples averages *across colour filters*. The result is a smaller buffer whose
pattern semantics have been destroyed, and demosaicing it as though the pattern
survived produces colours that came from nowhere and look entirely plausible.

A CFA-aware reduction is a real technique and is not ruled out forever. It
would need its own invariant, its own per-layout handling and its own tests,
and it is not needed here, because a correct point exists downstream: once
demosaicing has run, every pixel carries all three channels and an ordinary
image filter means what it says. This is also the reason white balance cannot
be made interactive by this milestone — it is a mosaic-domain operation,
upstream of every candidate reduction point, and changing it re-prepares from
the file.

## Memory consequence

Measured structurally on the E-PL3 fixture, 4056 × 3040 active area, three
`Float32` per pixel.

| | dimensions | samples | retained bytes |
| --- | --- | ---: | ---: |
| before, scene-linear buffer | 4056 × 3040 | 36,990,720 | 147,962,880 |
| before, whole retained scene-linear chain | — | — | 419,228,160 |
| after | 2048 × 1535 | 9,431,040 | 37,724,160 |

Both "before" rows and the "after" row are application-owned scene-linear
buffers only. See the note under the table in the Context above: an open
document holds other things, and no claim is made about their size.

```text
scene-linear samples   3.92× fewer          74.5% fewer
retained bytes        11.11× fewer          91.0% less
```

The per-interaction work falls by the same 3.92×: an orientation change now
permutes and display-encodes 3,143,680 pixels instead of 12,330,240. No
wall-clock speedup is claimed here; the sample counts are exact and a timing on
one machine would not be.

The ADR 0014 overlap improves in the same proportion. A file switch made
mid-render briefly retains two scene-linear sources; that is now roughly 72 MB
rather than roughly 840 MB, which turns an overlap worth arguing about into one
worth allowing. Nothing about the settling rules changes — `handOverCurrentDocument`,
the generation routing, the same-URL serialisation and the sidecar invariants
are untouched.

The saving is real only because nothing full-resolution is reachable from what
the workspace keeps. `prepare` uses the **bare-image** overloads after the
reduction, deliberately: the wrapper overloads exist to keep a stage's whole
upstream chain reachable through `source`, and that is exactly what must not
survive. `WorkspacePreviewPipeline.Source` holds one buffer, the metadata, the
URL and the neutral-patch region, and a test pins that shape so a future change
cannot quietly reattach a chain.

## Types and provenance

The reduced domain gets **one** image type, not one per stage.

```swift
SceneLinearPreviewImage        width, height, values, processing
SceneLinearPreviewProcessing   resolution, workingColorProcessing, mix: IRChannelMix?
PreviewResolution              source dims, preview dims, policy, method, scales, factor
PreviewResolutionPolicy        maximumLongestEdge, reducedSize(width:height:)
PreviewReductionMethod         .areaAverage | .unreduced
```

It is a separate type from `WorkingColorRGBImage` because that type's contract
says its dimensions are those of the image it was demosaiced from and that no
resampling has happened — both of which stop being true. A reduced buffer
wearing the full-resolution type would be distinguishable from the real thing
only by comparing its width against the sensor's, which is the guess the type
exists to remove.

It is *one* type rather than a preview twin for every stage because forking the
whole pipeline into full-resolution and preview-resolution variants is the
general image engine this milestone is not building. The cost of that choice is
the one optional: `mix` is `nil` until the creative stage has run. The
invariant it protects is the one the full-resolution wrapper protects
structurally — **mixes never compose** — and `IRChannelMixer` refuses an
already-mixed preview rather than quietly composing two matrices.

`ImageOrientationProcessing` gains `previewResolution: PreviewResolution?`,
which is the one fact the upstream stage records cannot carry: they describe
stages that are exactly as true of a reduced image as of a full one, and the
reduction happened between two of them. `WorkspacePreview` carries the same
record to the application layer and the inspector shows it, so a reader who is
looking at a 2048-pixel rendition of a 4056-pixel photograph is told so.

`method` distinguishes `.areaAverage` from `.unreduced`, because an image
already within the limit is copied rather than filtered — every bit pattern
survives, signed zeros included — and calling that an area average would be
false.

## Future consequence

```text
runs on the reduced preview        orientation (today)
                                   channel mix, channel swap, false colour
                                   exposure, contrast, tone curve, saturation
                                   anything per-pixel in the working space

re-prepares from the RAW file      white balance (mosaic domain)
                                   demosaic algorithm
                                   camera / IR colour transform
                                   defective-pixel handling, highlight work

runs at full resolution, later     export
                                   1:1 inspection and zoom
                                   sharpening and noise reduction, whose
                                   results are meaningless at preview scale
```

The middle column is not a regression: those stages were never interactive.
What this ADR fixes is where they will have to run *from* — the file, through
the canonical adjustments — rather than from a retained chain.

## Non-goals

Not in this milestone, deliberately:

- export of any kind, and no full-resolution render command
- a CFA-aware mosaic reduction
- GPU or Metal rendering
- a preview cache, a disk cache, or eviction
- zoom, pan, crop, arbitrary-angle rotation
- thumbnails or a RAW browser
- any change to the sidecar schema, the persisted fields, or the ADR 0013 and
  0014 lifecycle rules
- any UI for exposure, white balance or the channel mixer (the mixer arrived in
  [ADR 0016](0016-interactive-channel-mixer.md), with a schema version of its
  own)

## Consequences

- One document open holds roughly 36 MB of application-owned scene-linear
  buffer rather than roughly 400 MB of chain. That is the scene-linear state
  alone; the LibRaw reference, the display images and the metadata are held
  beside it.
- Every interactive adjustment does 3.92× less work on the fixture, and does it
  on a buffer that never reaches back to a full-resolution one.
- The interactive preview is explicitly disposable. The RAW file plus
  `ImageAdjustments` remains the source of truth, and this ADR is the place
  that says so.
- The E-PL3 reference values for display clipping changed: the reduced frame
  has 0 clipped-low samples where the full frame had 11. Nothing was clamped —
  the reduction clamps nothing — those few slightly negative samples averaged
  back into range with their neighbours. The reference test now pins the
  reduced frame's values and says why.

---

## Amendment (2026-09-13) — the reduced domain has two types, not one

The "Types and provenance" section above chose **one** reduced image type with
one optional field:

```swift
SceneLinearPreviewProcessing   resolution, workingColorProcessing, mix: IRChannelMix?
```

and said the invariant it protected — mixes never compose — was enforced by
`IRChannelMixer` refusing an already-mixed preview. That reasoning held for
exactly as long as the mix ran once, inside `prepare`, and was never replaced.

[ADR 0016](0016-interactive-channel-mixer.md) makes the mix a user adjustment,
so the pre-mix and post-mix states are both live in one call graph on every
interaction. The optional is gone and there are two types:

```text
SceneLinearPreviewImage        reduced, pre-mix    retained by a document
IRChannelMixedPreviewImage     reduced, post-mix   one render long
```

Nothing about the reduction, the reduction point, the size policy, the
resampling method, the CFA rule or the memory figures changes. What changes is
that `M2 × (M1 × preview)` no longer has an overload to be written in, and that
the two `PreviewReductionError` cases which used to refuse it at runtime no
longer exist.

The cost this ADR named — "the one optional" — turned out to be the right thing
to pay for one milestone and the wrong thing to keep for the next. It is
recorded here rather than quietly reversed.
