# 0019 — Interactive infrared white balance and the neutral-patch picker

Status: accepted
Date: 2026-09-13

> Numbering note: `CLAUDE.md` used `0019-metal-render-pipeline.md` as an
> illustrative future filename, after [ADR 0018](0018-full-resolution-tiff-export.md)
> took the number that example previously used. This decision took `0019`, so
> that example now reads `0020-metal-render-pipeline.md`. No ADR was renamed.

## Context

Infrared white balance is, by [CLAUDE.md](../../CLAUDE.md)'s own account, *the*
core feature of this project — "not merely a Temperature/Tint slider". Until
this milestone it was the only stage in the pipeline that a user had no say in
at all.

[ADR 0003](0003-infrared-white-balance.md) established the representation:
per-CFA-colour-plane multipliers, applied literally, in the mosaic domain,
before demosaicing. [ADR 0004](0004-neutral-patch-white-balance-estimation.md)
established how the multipliers are obtained: measure a rectangular patch the
caller claims is neutral, equalise the per-plane means. Both said, in as many
words, that the rectangle would eventually come from a person:

> A future UI "neutral point picker" will therefore turn a click into a small
> rectangle and call this estimator with it; the picker is presentation, this
> is the measurement.

What the application actually did was hard-code a centred square — a sixteenth
of the shorter active-area edge — inside the shared RAW front half, where every
caller silently got it. The comment on it said what it was:

> A deterministic placeholder, not a scene analysis. Nothing verifies that what
> is in the middle of the frame is neutral; the user will choose the patch when
> there is a UI for it.

Three canonical adjustments existed by then — orientation
([ADR 0010](0010-user-owned-orientation-adjustment.md)), the creative channel
mix ([ADR 0016](0016-interactive-channel-mixer.md)) and exposure
([ADR 0017](0017-interactive-exposure.md)) — and all three shared one shape:
apply the adjustment to the **retained reduced preview**
([ADR 0015](0015-reduced-resolution-preview.md)), which is why a rotation or a
slider drag costs one pass over 3.1 megapixels and no decode.

The white balance does not fit that shape, and the reason is not a detail:

```text
normalised RAW mosaic  →  WB gains  →  balanced mosaic  →  demosaic  →  working RGB
                          ↑
                          here, upstream of three stages the preview is downstream of
```

So this milestone had to answer two questions at once. What is the user's
white-balance decision, as data? And how is it applied interactively without
either faking the arithmetic or re-reading the RAW file on every click?

## Decision

**The user's white balance is a canonical adjustment that records *where they
pointed*, in normalised active-area coordinates; the workspace retains the
normalised mosaic and re-prepares the reduced preview from it; and the export
resolves the same region through the same estimator, from the file.**

```text
prepareBase     decode → normalise            once per open; RETAINED
prepareSource   resolve the patch → estimate → balance → demosaic
                → camera → working → reduce   once per open, once per patch
render          mix → orientation → exposure/display   every adjustment
```

### 1. The white balance is not moved downstream, and the reason is arithmetic

The tempting shortcut was to apply per-channel gains to the retained reduced
RGB preview. It is one multiply per sample, it is instantaneous, and it is not
the same operation.

```text
what the pipeline does    gain[plane] × sample, per CFA colour plane, BEFORE
                          demosaicing — so interpolation happens between
                          samples that have already been balanced

what the shortcut does    gain[channel] × value, per RGB channel, AFTER
                          bilinear interpolation of UNBALANCED samples, and
                          after a 4:1 area-average reduction
```

It is worth being exact about where they differ, because for most of the image
they do **not**. A gain is linear and so is bilinear interpolation, so scaling
before averaging and scaling after it agree whenever every sample being averaged
carries the same multiplier — which is true of red interpolated from red
neighbours and of blue interpolated from blue neighbours.

The green channel is the exception, and it is not a small one. The CFA has
**two independent green planes**, and `RAWWhiteBalanceGains` keeps them
independent on purpose ([ADR 0003](0003-infrared-white-balance.md)):

```text
RGGB:   plane 0 = R    plane 1 = G1    plane 2 = B    plane 3 = G2
        gains are four numbers, and G1 and G2 are never forced to agree
```

Bilinear green at a red or blue site is the mean of its four axial neighbours,
**two from G1 and two from G2**. Where `gain[G1] ≠ gain[G2]`, no single green
multiplier applied afterwards can reproduce that mean — and after demosaicing
there is no G1 and no G2 left to apply two to. The native green at a G1 site and
at a G2 site are likewise scaled by different numbers upstream and by one number
downstream.

So a downstream gain is not the same operation, it has no correct choice of
green multiplier, and the difference is a per-pixel one rather than a rounding
error. On an infrared capture, where a plane gain can be 4 or 8 rather than 1.2,
it is not academic.

A downstream estimator would also be measuring something else: this one measures
the **mosaic**, per CFA plane, which is where the four numbers come from at all.

There is a further, independent problem. Downstream gains **compound**. The
retained preview would carry the previous gains, so the second patch a user
picked would render `G2 × (G1 × preview)` — exactly the failure
[ADR 0007](0007-infrared-channel-mixing.md) and
[ADR 0016](0016-interactive-channel-mixer.md) designed the type system to
prevent for mixes.

So the canonical processing truth is unchanged, and it is where it always was:

```text
normalised RAW mosaic → WB gains → balanced mosaic → demosaic → working RGB
```

Interactivity is bought by **retaining the input to that chain**, not by moving
the chain.

### 2. The adjustment records intent, not gains

`UserWhiteBalanceAdjustment` has two cases:

```swift
case defaultNeutralPatch
case neutralPatch(NormalizedActiveAreaRegion)
```

and the gains are derived from the RAW file every time, by the estimator, at
preparation and at export.

The alternative — persisting `{red, green, blue}` multipliers — was rejected on
two grounds. A gain is an answer and the patch is the question: `[3.81, 1.0,
2.07, 1.0]` cannot be reviewed, reproduced or reconsidered, while "the grey card
just left of centre" can. And persisting the numbers freezes today's estimator
into every sidecar ever written, so a better scale policy or a fixed measurement
would leave every previously saved photograph rendering by arithmetic that no
longer exists, with nothing saying so.

Explicit multipliers remain a legitimate future case and the enum can gain one.
It deliberately has not: there is no manual-gain editor, no temperature and no
tint in this version, and adding a case no UI can produce would put a wire
format into the world ahead of the decision it describes.

### 3. The default is a named case, not a centred rectangle

`.defaultNeutralPatch` resolves through `UserWhiteBalanceAdjustment.defaultRegion(width:height:)`
— the rule this project has always used, `max(2, (shorter / 16) rounded down to
even)`, centred — moved out of `RAWWorkingImagePipeline` and into the case whose
meaning it is.

It is **not** modelled as a centred `.neutralPatch(...)`, and that is deliberate.
The rule is expressed in sensor samples and does not survive a round trip
through fractions exactly; only a case that resolves through the rule itself can
promise a version 1, 2 or 3 sidecar the rendering it was saved with. A test
pins the equivalence: for the reference geometry and for a spread of others, the
default case resolves to the identical `RAWActiveAreaRegion` the old hard-coded
helper produced.

It is also **not** called "auto white balance", anywhere, and the UI does not
either. Nothing examines the photograph. The middle of the frame is a
placeholder a person can replace, and the inspector says so in those words.

### 4. Normalised active-area coordinates, and why not pixels

A `NormalizedActiveAreaRegion` is four `Double`s in the unit square, in
**sensor** axes — origin top-left, `y` downwards, matching `RAWActiveAreaRegion`
and `LinearRAWMosaic`.

The four things the persisted region has to survive are exactly the four that
pixel coordinates do not:

```text
the preview reduction   the workspace edits a 2048-pixel rendition of a
                        4056-pixel photograph
orientation             the displayed image may be a quarter turn from the
                        sensor's own layout, and the user can change that
the display             a click lands in view points inside an aspect-fitted
                        rectangle
the export              which runs at sensor resolution, from the file, with
                        no preview anywhere
```

Integer active-area pixels were considered and would be exact rather than
rounded. They were rejected because they silently assume every decode of one
file reports the same active area: a LibRaw upgrade that changed a crop by two
rows would move every saved patch by two rows and nothing would say so. A
fraction describes the same part of the picture either way.

The conversion has **one** home,
`UserWhiteBalanceAdjustment.resolvedRegion(activeAreaWidth:activeAreaHeight:)`,
and the rule is written out:

```text
left   = floor(originX × width)
top    = floor(originY × height)
extent = round(fraction × dimension), then rounded DOWN to even,
         and at least minimumPatchExtent (2)
origin = shifted back inside the area if the even extent pushed it out
```

The even extent is the CFA-alignment rule. It is applied in the **conversion**,
not in the persisted value, because it is a fact about a sensor layout and the
persisted value is a fact about a photograph — so a record written on one camera
stays meaningful on another. It is a Bayer-shaped minimum and is honest about
being one: a 6×6 X-Trans cell is not guaranteed complete coverage by it, and is
protected instead by the estimator's own refusal to invent a gain for a plane it
did not measure ([ADR 0004](0004-neutral-patch-white-balance-estimation.md)).

The shift is the only adjustment made to a valid region, it moves the origin by
at most one sample, and it exists so a patch touching an edge keeps its size
instead of being trimmed to an odd one. Malformed persisted data is **refused**,
never clamped: non-finite coordinates, a non-positive extent, and a rectangle
outside the unit square each have their own typed error.

### 5. The workspace retains the normalised mosaic

`RAWBasePreparationPipeline` is a new type with one job — decode and normalise
— and its result, `NormalizedRAWSource`, is what a document holds:

```text
retained per open document
    NormalizedRAWSource   full-resolution Float32 CFA mosaic     49 MB on E-PL3
    Source.preview        reduced pre-mix scene-linear RGB       37 MB on E-PL3

transient during a white-balance re-preparation, released when it returns
    WhiteBalancedRAWMosaic                                       49 MB
    DemosaicedRAWRGBImage                                       147 MB
    WorkingColorRGBImage                                        147 MB

released when the file finishes opening, and never retained
    DecodedRAWMosaic (UInt16 samples)                            24 MB
```

Measured, by element count times `MemoryLayout<Float>.size`, not estimated.
These are the **application-owned image buffers** and nothing else: a document
also holds the LibRaw diagnostic reference, the display `CGImage`s and the
metadata, and no claim is made here about their size. This is not a statement
about process RSS.

It stores the **bare** `LinearRAWMosaic`, not the normaliser's
`ProcessedRAWMosaic` wrapper, precisely so the decoded `UInt16` samples — a
further 24 MB — are unreachable from it. Nothing else full-resolution survives
a preparation: the three transient buffers above go out of scope when
`prepareSource` returns, as they always did.

This is a deliberate exception to the rule [ADR 0015](0015-reduced-resolution-preview.md)
otherwise keeps, and the justification is the alternative: without it, moving
the neutral patch re-reads and re-normalises a twelve-megapixel file on every
click, when **neither stage depends on the patch at all**.

The trade was measured rather than asserted. Release build, Apple silicon, the
E-PL3 fixture (4056 × 3040), warm file cache, one run each — engineering
figures, not a benchmark:

```text
decodeMosaic (LibRaw, blocking C++)   173 ms   ┐ removed from every pick
RAWMosaicNormalizer                    18 ms   ┘ by retaining the mosaic

white-balance estimate                  0.1 ms ┐
RAWWhiteBalancer                       14 ms   │
RAWDemosaicer                         233 ms   ├ what a pick actually costs
RAWWorkingColorConverter                9 ms   │
SceneLinearPreviewReducer              44 ms   │
prepareSource, end to end             297 ms   ┘

fast render (mix + orientation + display)        73 ms
fast render (swap + quarter turn + 1 EV)         85 ms
```

So a pick costs about 300 ms rather than about 490 ms: 49 MB buys roughly
190 ms and, more to the point, removes a blocking decode and a 24 MB `UInt16`
allocation from an interactive path — and the 173 ms is a warm-cache figure,
which a cold read is not. It is a worthwhile trade rather than an overwhelming
one, and it is stated here with its numbers so it can be revisited honestly.
The demosaic dominates what remains, which is where a later optimisation
belongs.

Note that the same measurements in a **debug** build are 40–50× slower
(prepareSource 14.6 s), which is why they were taken in release. Neither set is
a guarantee.

The mosaic is retained **only after a successful open**: `OwnedOutcome.rendered`
is the one case that carries it, so a file that prepared and then refused at the
geometry stage holds its reduced buffer for diagnosis and releases the largest
retained cost in the application, which it has no controls to spend.

### 6. Two coalescing slots, one canonical state

```text
FAST    PreviewRenderSlot            request = (source, ImageAdjustments)
                                     → WorkspacePreview
HEAVY   WhiteBalancePreparationSlot  request = UserWhiteBalanceAdjustment
                                     → a new reduced pre-mix Source
```

Both are `CoalescingRenderSlot<Request, Output>`, which is
`CoalescingPreviewRenderer` ([ADR 0011](0011-coalesced-preview-rendering.md))
made generic — the same algorithm, the same three invariants, proved once
instead of twice: at most one pass working, a burst collapses to its newest
member, a superseded result is never delivered.

They are **two** slots rather than one because "at most one at a time" is a
claim each has to make about itself. A patch being prepared must not stop the
exposure from re-rendering once it lands, and a render must not stop a newer
patch from starting.

The routing in `DocumentState.adjust` is one question:

```swift
if source.whiteBalance != updated.whiteBalance {
    preparer.request(updated.whiteBalance)   // heavy; no render yet
} else {
    preparer.cancelAll()
    renderer.request(PreviewRenderRequest(source: source, adjustments: updated))
}
```

It is asked of the **source**, not of the previous adjustments, because those
two disagree exactly when it matters: picking patch B while patch A is still
being prepared leaves the source at the original balance, and both patches need
the heavy path.

The source moved into the render **request** rather than staying captured in
the slot's closure. Rebuilding the slot whenever the source changed was the
other answer and a worse one — it discards a slot that may still be unwinding a
cancelled pass, which is the state the one-at-a-time guarantee depends on.

### 7. A preparation lands, and then the *latest* state renders

`applyPreparedSource` installs the new source and then requests a render with
`loaded.adjustments` — the latest complete state — not with a state captured
when the patch was picked.

That is the whole answer to the race this milestone had to get right:

```text
patch A picked      heavy preparation starts
exposure → +1 EV    no render requested: the source is still the old balance
A lands             source installed, render requested for (patch A, +1 EV)
```

The result is patch A **and** the current exposure, because the result is a
render of what the user currently wants, from the source that now describes
their patch. And the harder one:

```text
A starts → B starts → exposure changes → A finishes late → B finishes
```

A's delivery fails the guard `loaded.adjustments.whiteBalance == whiteBalance`,
so it installs nothing, renders nothing and saves nothing. Only B installs, and
the render that follows carries the latest exposure.

### 8. Persistence is unchanged, and the guard is still the render

Nothing is written when a preparation succeeds. `.pending` survives it and ends
where it always has — where a render succeeds and is installed — because a
white balance that estimated cleanly and then failed to demosaic, orient or
encode is not a state worth restoring on the next launch
([ADR 0013](0013-adjustment-sidecar.md), [ADR 0014](0014-adjustment-lifecycle.md)).

### 9. Settling is generalised from one pass to the whole adjustment

[ADR 0014](0014-adjustment-lifecycle.md) let a document the user leaves keep its
render slot long enough to write its own sidecar. An adjustment can now cost two
passes, so a document left mid-preparation still has both to make.

`SettlingDocument` therefore holds **both** slots and a mutable `source`, and
`settlePreparedSource` installs the new source and requests the render of the
document's *frozen* requested state — the frozen one, because a settling
document has no UI and nothing can change what it was asked for. That render's
delivery reaches the existing `settle`, which writes the sidecar and releases
the document.

One concept, generalised, rather than a second lifecycle beside it. The
same-URL reopen ordering ([ADR 0014](0014-adjustment-lifecycle.md)) is unchanged
and now covers the longer wait: a reopen of a file whose older generation is
mid-preparation still waits for that generation to finish writing.

### 10. The picker: click-based, committed on mouse-up, mode state stays in the view

A click, not a rubber-band drag. The selection is built by
`UserWhiteBalanceAdjustment.pickedRegion(atX:y:activeAreaWidth:activeAreaHeight:)`,
which centres a patch of **the same size the default patch is** — a sixteenth
of the shorter active-area edge, square in sensor samples — on the point, and
shifts it (never trims it) to stay inside the frame. So picking the exact
centre of a frame measures the same samples the default does.

Rectangle dragging was rejected for this milestone as scope: it needs a
transient rubber-band, a minimum-size rule, a drag-versus-click distinction and
its own geometry, and none of it changes what this milestone is about.

The commit is on mouse **up**, once. Nothing is requested while the pointer
moves: re-estimating and re-demosaicing per pointer-move is work nobody asked
for, and the coalescing would merely hide it.

Armed-or-not is `@State` in the view and never reaches `ImageAdjustments`.
Being about to pick is not an editing decision: it renders nothing, persists
nothing, and means nothing to an export.

### 11. The coordinate road, and what it is not allowed to depend on

```text
a click, in view points
    ↓  PreviewPatchGeometry.fittedImage       undo the aspect-fit letterboxing
a unit point on the displayed image
    ↓  PreviewPatchGeometry.sourcePoint       undo the effective orientation
a unit point on the active image area          ← sensor axes
    ↓  UserWhiteBalanceAdjustment.pickedRegion
a NormalizedActiveAreaRegion                   ← persisted
```

and the same road backwards for the overlay, which is derived from the
canonical region and the current layout every time it is laid out. **No view
coordinate is ever stored, and none is ever persisted.**

The mapping depends on the displayed pixel dimensions, the aspect-fitted
rectangle, and the effective orientation — and on nothing else. Not the channel
mix, not the exposure (both change every pixel's value and no pixel's position),
and not the preview's resolution, which normalised coordinates cancel out.

SwiftUI will not say where it put an aspect-fitted image, so the layout rule is
reproduced once in `PreviewPatchGeometry` and pinned by tests. Clicks outside
the picture are **refused**, not clamped to the nearest edge: an aspect-fit
layout letterboxes generously, and snapping a margin click to an edge would move
a user's patch somewhere they did not point.

### 12. The export resolves the same intent, from the file

`FullResolutionExportPipeline` passes `request.adjustments.whiteBalance` into
`RAWWorkingImagePipeline`, which resolves it through the one resolver and
measures it with the one estimator. There is no export white balance, no export
patch and no export default.

It still decodes the file itself, and deliberately does **not** consume the
workspace's retained normalised mosaic even when a document is holding one for
exactly that photograph. An export that read a workspace cache would depend on
what happened to be open, which is precisely the reproducibility
[ADR 0018](0018-full-resolution-tiff-export.md) exists to guarantee.

A consequence worth stating, because it is the sharpest demonstration of
"canonical state, not displayed state": an export started while a new patch is
still being prepared renders the **new** patch, not the one on screen.

### 13. `isIdentity` is retired; `isDefault` replaces it

`ImageAdjustments.isIdentity` meant "no net effect on the image". The white
balance killed that reading: the default patch estimates real multipliers from
real samples, so **every** record changes the photograph, and the property would
have been false for every value in the application.

The honest split is between two questions, and only one is answerable from a
record:

```text
isDefault        "has the user departed from the defaults?"  — a fact about
                 this record
has no effect    "would rendering with these adjustments change the pixels?"
                 — not answerable here at all: whether the default patch's
                 gains come out as 1,1,1,1 depends on the photograph
```

So `isDefault` is a question about **decisions**, and the per-field
`isIdentity`s that remain true statements about pixels — the orientation's, the
mix's, the exposure's — are kept. `UserWhiteBalanceAdjustment.isDefault` is
named for what it is and makes no claim about gains.

### 14. Cancellation reaches the mosaic-domain stages

The heavy path is now user-triggered and repeatable, so non-cancellable
multi-second work stopped being acceptable. `RAWWhiteBalanceEstimator`,
`RAWWhiteBalancer`, `RAWDemosaicer` and `RAWWorkingColorConverter` each take a
`ProcessingCancellation` and poll it **once per row** — per region row for the
estimator — in addition to a check before any buffer is allocated. Each leaves
`initializedCount` at exactly the elements written, so no half-written image
escapes.

The decode and the normalisation deliberately still do not poll. They run once,
on open, in response to an action a user cannot repeat by holding a control
down, and the new interactive path begins *after* them
(`RAWBasePreparationPipeline` states this and why).

## Consequences

- A user can point at a grey card, a cloud or a patch of foliage and get a
  reproducible infrared white balance from it, on the preview and in the
  exported file.
- Moving the patch costs a balance, a demosaic, a conversion and a reduction —
  and **no decode**. A counting decoder proves it: an open plus two picks plus
  a reset is one `decodeMosaic`.
- A document costs roughly 49 MB more, retained. During an
  [ADR 0014](0014-adjustment-lifecycle.md) file-switch overlap, two documents
  hold one each.
- The sidecar is at schema version 4. Versions 1, 2 and 3 migrate to
  `.defaultNeutralPatch` — the same centred patch they were rendered with, not
  identity gains — and are rewritten as version 4 only when the user's next
  decision renders and saves.
- Rotate, mix and exposure are unchanged in cost and in behaviour. They do not
  touch the heavy slot, and a test proves no preparation runs for them.
- A refused white balance behaves exactly as a refused rotation does: the typed
  failure replaces the preview, the requested intent stays in the controls, the
  sidecar keeps the last state that rendered, and the user can pick elsewhere.
  This is a **deliberate uniformity** rather than the "keep the previous preview
  visible" behaviour the milestone brief preferred: introducing a
  white-balance-only exception would mean two rules for what a refused
  adjustment does, and the existing rule is the one three adjustments already
  follow. Changing it should be changed for all four at once, and is listed as
  a known limitation rather than done here.

## Non-goals

Not implemented, and not partially implemented:

- temperature and tint controls, in any form;
- manual per-channel or per-plane gain entry;
- automatic white balance of any kind — grey-world, white-patch, scene
  analysis, subject detection;
- rectangle-drag patch selection, or any transient rubber-band;
- per-camera, per-conversion or per-filter white-balance profiles, and recipes
  of any kind — the patch belongs to *this* photograph's sidecar;
- batch white balance;
- a histogram, tone controls, crop or undo;
- any GPU path;
- consuming the workspace's retained mosaic from the export;
- caching anything to disk.

## Alternatives considered

**Per-channel gains on the reduced preview.** Rejected: a different operation
from the one the pipeline performs (§1), and it compounds.

**Re-decode the RAW file per patch.** Correct, and unusable: a blocking
twelve-megapixel decode per click, for two stages that do not depend on the
patch.

**Persist the gains.** Rejected: freezes the estimator into every sidecar and
records an answer nobody can review (§2).

**Persist integer active-area pixels.** Reasonable, and rejected for one
reason: it assumes every decode of a file reports the same active area (§4).

**One coalescing slot for both costs.** Rejected: ownership and cancellation
become unclear, and a heavy pass would block a cheap re-render that is ready to
go.

**Keep the previous preview visible when a patch refuses.** Preferred by the
milestone brief and deferred: it is a change to what a refused adjustment does,
and doing it for one of four would be worse than doing it for none. See
Consequences.
