# 0017 — Interactive exposure

Status: accepted
Date: 2026-09-13

> Numbering note: `CLAUDE.md` used `0017-metal-render-pipeline.md` as an
> illustrative future filename. This decision took number `0017`, so that
> example now reads `0018-metal-render-pipeline.md`. No ADR was renamed.

## Context

The exposure primitive has existed since [ADR 0008](0008-display-preview-rendering.md):
`DisplayRenderSettings.exposureEV`, applied by `DisplayPreviewRenderer` as
`linear × 2^EV` before hard display-range clipping. The application always
passed a constant:

```swift
static let initialSettings = DisplayRenderSettings(
    exposureEV: 0, rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
)
```

So an underexposed infrared frame — the ordinary case for a filtered capture —
could not be lifted, and the only stage between the working representation and
the screen that a user might reasonably want to change had no control.

[ADR 0016](0016-interactive-channel-mixer.md) had already done the structural
work: the retained source is pre-creative, render requests are complete
`ImageAdjustments` states, and one coalescing renderer serves every control.
What was missing was an adjustment, a persisted field, and a continuous
control — the first one — to prove that the scheduler handles a real burst.

Before any of that, two schema-v2 defects were fixed and recorded in the
[ADR 0016 amendment](0016-interactive-channel-mixer.md#amendment-2026-09-13--schema-v2-hardening):
schema dispatch is now exhaustive over a closed version type, and a built-in
channel mix carrying matrix coefficients is refused. Version 3 is built on that.

## Decision

**Exposure becomes the third canonical user adjustment, persisted at schema
version 3, applied in the interactive render half by the existing display-stage
primitive, and driven by a slider through the existing coalescing renderer.**

```text
ImageAdjustments
├── orientation     UserOrientationAdjustment
├── channelMix      UserChannelMixAdjustment
└── exposure        UserExposureAdjustment        ← new
```

```text
prepare   decode → normalise → white balance → demosaic → camera → working
          → preview reduction → RETAIN the pre-mix source

render    retained pre-mix preview
          → IRChannelMixer          adjustments.channelMix
          → ImageOrienter           file orientation + adjustments.orientation
          → DisplayPreviewRenderer  exposureEV = adjustments.exposure.ev
                                    range policy and encoding unchanged
```

### 1. The adjustment is a value type

`UserExposureAdjustment` holds one `Double`, `ev`, and states what it means and
which values are allowed:

```text
meaning     exposure compensation in stops
neutral     0 EV (.neutral)
allowed     finite, and within supportedRange = −10 … +10 EV
identity    ev == 0
```

A bare `Double` on `ImageAdjustments` was rejected because every reader —
sidecar, control, render — would have had to know the range and the meaning
separately.

It performs **no arithmetic**. There is no `scale` property on it.
`DisplayPreviewRenderer` multiplied by `2^EV` before exposure was a user
decision, and it remains the single authority on what `exposureEV` does to a
pixel; `WorkspacePreviewPipeline.displaySettings(for:)` passes `ev` to it
unchanged.

### 2. The supported range

`−10 … +10 EV`, chosen from the pipeline rather than copied:

```text
+10 EV   ×1024   lifts a value ten stops below white level to display white.
                 The reference camera records 12 bits, so that is a sample of
                 about 4 in 4095; further up is lifting quantisation noise.
−10 EV   ÷1024   brings a value a thousand times white level to display white —
                 far beyond the headroom white balance and a mix leave above 1.
```

The endpoints are exact binary values, and no realistic scene-linear value
overflows `Float32` at either. The renderer still refuses a non-finite result
itself; this bound is a validity rule for a persisted decision, not what protects
the renderer.

A value outside it is **refused**, never clamped — at construction and when a
sidecar is read — with `ImageAdjustmentError.exposureAdjustmentOutOfRange(ev:supported:)`.
NaN and infinities are refused with `.nonFiniteExposureAdjustment(ev:)`. Both
name the refused value.

### 3. Mathematics

```text
scale    = 2^EV
exposed  = linear RGB × scale          per component, in Double, narrowed once
clipped  = hard clip to 0…1            the existing range policy, counted
encoded  = sRGB OETF → 8 bits          unchanged
```

Exposure acts on **scene-linear, unclamped** values. Nothing in the workspace
clamps the mixed, oriented image before the display stage, so a value exposure
lifts above `1` is clipped — and counted in `clippedHighSampleCount` — by the
policy that owns clipping, and a value above `1` that negative exposure brings
back into range is rendered, not lost. The retained source is never modified.

It is not tone mapping, highlight recovery or automatic exposure, and the
preview's provenance continues to say so.

### 4. Schema version 3

```text
v1    orientation
v2    orientation, channelMix
v3    orientation, channelMix, exposureEV
```

```swift
enum PersistedSchemaVersion: Int, CaseIterable {
    case orientationOnly = 1
    case channelMix = 2
    case exposure = 3
}
```

Adding `case exposure` was a compile error in the migration until its branch was
written, which is what the ADR 0016 amendment set out to guarantee.

Migrations — each stating what the absent field meant, not guessing:

```text
v1 → orientation as persisted, channelMix = .identity, exposure = 0 EV
v2 → orientation, channelMix as persisted,             exposure = 0 EV
v3 → all three as persisted
```

Versions 1 and 2 predate the control, and the workspace always rendered them at
`0 EV`; that is the state those records were saved in. A migrated record is
written as version 3 the next time a render of it succeeds and is saved.
Reading never rewrites the file.

Strictness, per version:

```text
v1 + channelMix         refused   unexpectedAdjustment
v1 + exposureEV         refused   unexpectedAdjustment
v2 + exposureEV         refused   unexpectedAdjustment
v3 without exposureEV   refused   missingAdjustment     (null too)
v3 without channelMix   refused   missingAdjustment
```

The wire format is a bare number; the unit is in the key alone.

```json
{
  "channelMix" : { "kind" : "redBlueSwap" },
  "exposureEV" : 1.25,
  "orientation" : "none",
  "schemaVersion" : 3
}
```

`1.25` always means `+1.25 EV`. The value is not rounded on the way to disk or
back; a test round-trips bit patterns.

### 5. `isIdentity`

```text
orientation has no effect  AND  channelMix has no effect  AND  exposure == 0 EV
```

Still "no net effect on the image", not "the user never edited" (ADR 0014,
Decision 6). An explicit identity matrix at `0 EV` is the identity and is still
recorded as explicit.

### 6. Provenance: requested and rendered

`WorkspacePreview` carries `exposureAdjustment` — what the person chose — beside
`processing.exposureEV`, exposed as `renderedExposureEV` — what the display stage
applied. The pipeline passes one to the other unchanged, and tests assert that
they agree for every rendered value. They are two facts for the same reason
`channelMixAdjustment` and `processing.mix` are: a control reads intent, an audit
reads processing.

### 7. `DocumentState`: the same path, no scheduler of its own

```swift
func setExposure(_ exposure: UserExposureAdjustment) { adjust { $0.exposure = exposure } }
func resetExposure() { setExposure(.neutral) }
```

`adjust` updates the complete record, sets `.pending` in the same assignment,
and makes one request to the document's `CoalescingPreviewRenderer`. There is no
timer, no Combine debounce, no delay and no exposure queue. Resetting exposure
changes only exposure; the orientation and mix resets leave it alone.

### 8. Continuous changes

A slider drag is a burst of complete states. The coalescing renderer from
[ADR 0011](0011-coalesced-preview-rendering.md) needed no change:

```text
+0.1   in flight → cancelled inside its pass, never delivered
+0.2 … +1.4       each overwrites the one pending slot, never started
+1.5              the only state rendered, installed and written
```

The test holds the first render at a gate so fifteen requests arrive while a
render is genuinely in flight. Its render log is exactly `[open, +1.5]` and its
save log exactly `[+1.5]`. An ungated burst, where an early render may complete
before it is superseded, shows `DocumentState`'s own guard refusing to install
or save the stale result.

No debounce was added because no measurement asked for one. If one ever is,
it is recorded here, not added quietly.

### 9. The control

```text
Exposure   −4 ────●──── +4    +0.70 EV   ⟲
```

- The slider shows the **requested** exposure from `DocumentState`, never the
  last delivered preview's. A drag that outruns rendering does not snap back.
- The inspector's Exposure row reads the preview's provenance and therefore
  describes the image on screen. While a render is pending the two differ, and
  that is correct: controls describe the newest request, the inspector
  describes the displayed preview.
- Reset returns exposure to `0 EV` and nothing else.

Two ranges, deliberately different:

```text
slider      −4 … +4 EV, quantised to 1/20 stop
persisted   −10 … +10 EV, not quantised
```

Quantisation is `round(v × 20) / 20`, so a written value is the shortest decimal
(`0.3`, not `0.30000000000000004`). A saved value beyond the slider — from a
hand-edited sidecar or a future recipe — pins the thumb to its end stop, shows
its real value in orange, and is **not written back** because it was displayed:
`ExposureControlScale` ignores a slider write that merely echoes the displayed
position. Only a real move writes.

### 10. Persistence and lifecycle are unchanged

ADR 0013 and ADR 0014 apply as written, now over three fields:

- a state is written only after exactly that state has rendered;
- a burst writes its newest delivered state and nothing in between;
- a refused render keeps the requested exposure in memory, leaves the previous
  sidecar, and reports `.renderRefused`;
- a refused write keeps the preview and reports `.saveFailed`;
- a document left mid-render settles and writes its own complete state, and
  never installs into the next document;
- reopening the same file waits for its older generation to write.

Each is tested through exposure.

## What an exposure change costs

```text
does NOT rerun    decode, normalisation, white balance, demosaic,
                  camera → working, preview reduction
does rerun        channel mix, orientation, display encode
```

A counting decoder across open, four exposure changes, a mix and a rotation
reads the file once and performs the LibRaw diagnostic decode once.

## Consequences

- An underexposed infrared frame can be lifted, interactively, without
  re-decoding, and the lift survives the session.
- The coalescing renderer has handled a genuine continuous burst without
  change.
- The schema has a third version and two tested migrations, and adding it
  exercised the exhaustive dispatch the amendment introduced.
- Scene-linear values reach the range policy unclamped, and the preview's clip
  counts now vary with a user decision.

## Known limitations

- During a fast drag, each new request cancels the render in flight, so the
  preview may not update until the drag pauses for longer than one render.
  That is ADR 0011's newest-state-wins contract, not a defect; whether
  intermediate feedback is wanted is a measurement question, not settled here.
- The slider step and range are UI choices without user research.
- No keyboard entry of an exact EV value.

## Non-goals

Tone mapping, curves, contrast, highlights/shadows, highlight recovery,
automatic exposure, a histogram, white-balance controls, export, undo/redo,
presets and recipes, and any GPU path.
