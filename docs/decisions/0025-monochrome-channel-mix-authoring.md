# 0025 — Monochrome channel-mix authoring

Status: accepted
Date: 2026-09-16

> Numbering note: `CLAUDE.md` uses `0025-metal-render-pipeline.md` as an
> illustrative future filename. This decision took `0025`; no ADR was renamed,
> and that example now reads `0026-metal-render-pipeline.md`.

## Context

Infrared monochrome is one of the two results a photographer actually wants
from an infrared capture. The other is false colour, which
[ADR 0007](0007-infrared-channel-mixing.md),
[ADR 0016](0016-interactive-channel-mixer.md),
[ADR 0023](0023-authoring-a-creative-channel-mix.md) and
[ADR 0024](0024-reusable-creative-presets.md) have already built out. Black and
white is not a fallback from colour here — for many 720 nm and 830 nm captures
it is the point of the exposure.

The obvious way to add it is the wrong one. A "Monochrome" toggle, a
`UserMonochromeAdjustment`, a sidecar field, a desaturation stage after the
channel mixer — every one of those is a second way to decide the same thing,
and two authorities over one pixel is the failure mode this project's
architecture is arranged against. It would also be arithmetically redundant:
the pipeline already applies a 3×3 matrix to working RGB, and a matrix whose
three rows are identical *is* monochrome.

```text
         ⎡ r g b ⎤   ⎡ R ⎤       Rout = r·R + g·G + b·B
output = ⎢ r g b ⎥ × ⎢ G ⎥  so   Gout = r·R + g·G + b·B
         ⎣ r g b ⎦   ⎣ B ⎦       Bout = r·R + g·G + b·B
```

Every output channel receives the same scene-linear value, so the result is
achromatic. Nothing had to be added to the renderer to make that true; it was
already true, and ADR 0007 said so in as many words when it decided not to
refuse singular matrices:

> a deliberately singular monochrome collapse and negative mixing coefficients
> are all legitimate

What was missing was not a capability. It was a way to reach it without typing
nine numbers, six of which repeat.

There is a second temptation to refuse, and it is the colour-science one. The
familiar monochrome control offers a luminance weighting — Rec. 709's
`0.2126 / 0.7152 / 0.0722`, or Rec. 601's — and calls the result "brightness"
or "natural". Those coefficients are derived from the spectral sensitivity of
human vision to *visible* light, and they are defined against RGB channels that
carry visible-light meanings. Neither holds here. This application develops
infrared false colour: the red channel of a 720 nm capture is not red, the
photons were never seen by an eye, and a weighting fitted to human photopic
response describes nothing about them. Shipping one under the word "luminance"
would be exactly the kind of plausible-looking, unfounded colour claim
[ADR 0022](0022-calibration-evidence-and-measurement-protocol.md) exists to
keep out of this project.

## Decision

### 1. Monochrome is authored as an existing explicit channel mix

There is no monochrome stage, no monochrome image type, no monochrome
adjustment, no monochrome provenance and no monochrome persisted field. The
monochrome editor produces

```swift
UserChannelMixAdjustment.explicit(RAWColorMatrix3x3)
```

and hands it to `DocumentState.setChannelMix`, the same entry point the two
built-in mixes, the 3×3 matrix editor and every creative preset already use.

The consequence is stated as a requirement rather than an observation: **a
photograph developed through the monochrome editor is indistinguishable, in
everything that is stored or rendered, from one where the same nine
coefficients were typed into the matrix editor.** The sidecar bytes are
identical, the provenance is `.explicit` in both cases, and the exported pixels
are bit-for-bit equal. A test asserts each of those three.

### 2. Three identical rows define this editor's monochrome shape

A matrix is monochrome, for this editor, when its three rows are exactly
identical. `IRMonochromeMix` is the one place that translation lives, in both
directions:

```text
matrix()                 (r, g, b)             → three identical rows
init?(recognising:)      three identical rows  → (r, g, b)
```

It is a small value type in `Infrared/`, internal to the module, and it is
deliberately not a persisted model, a pipeline value or a public interface. Its
whole responsibility is the translation, the recognition and the four starting
points.

Recognition reads the coefficients and nothing else, so a matrix typed into the
3×3 editor, restored from a sidecar or applied from a creative preset all
recognise the same way. There is no monochrome provenance to consult, which is
the point — see §5.

### 3. Equality is exact; there is no epsilon

Recognition uses `Double` equality on the stored coefficients, exactly as
`RAWColorMatrix3x3.isIdentity` compares. `-0.0` and `+0.0` compare equal, which
is the treatment every other coefficient comparison in the project gives them.

An epsilon was rejected. A tolerance wide enough to be useful is wide enough to
call a colour transform monochrome, and the editor's job when it opens is to
*seed itself from the matrix in force*. Mis-recognising a near-monochrome
colour matrix would put three numbers in front of a person that describe
something they did not author, and applying them would silently discard the
six coefficients that differed. When the rows are not exactly equal the editor
seeds `Equal RGB` instead, and the person can open **Custom Matrix…** to
inspect or edit the real coefficients.

### 4. Not monochrome means Equal RGB, inferring nothing

When the mix in force is not monochrome — a colour matrix, the identity, the
red/blue swap — the editor opens at `Equal RGB`.

Nothing attempts to derive three monochrome contributions from an arbitrary
colour matrix. There is no defensible derivation: the row a person would want
depends on what they are trying to see, and any projection this code chose
would be an invention presented as a reading of their work. Nothing composes
the new monochrome matrix with the existing one either, for the reason §6
gives.

### 5. `IRChannelMixSource` gains no case

Where a person found a matrix is not a property of the matrix. A `.monochrome`
provenance case would have to be persisted, migrated, and then kept in
agreement with nine coefficients that could contradict it — the same argument
ADR 0024 made when it refused a `.preset` case, and the same one the persisted
format already enforces by refusing a built-in token that carries coefficients.

The compiler holds this: the switch over `IRChannelMixSource` in
`MonochromeChannelMixReuseTests` is exhaustive with no `default`, so a fourth
case would stop that file compiling.

### 6. Applying replaces; it never composes

A channel mix is canonical state rather than command history (ADR 0016), so

```text
current mix M1
apply monochrome M2
result                 M2, never M2 × M1
```

The mechanism is the one that already existed: the workspace retains a
**pre-mix** reduced preview, and a render applies one mix to it. There is no
composition to suppress, because there is nowhere to compose. The editor says
so in words — *Applying replaces the current channel mix* — because a person
who has just authored a colour mix would otherwise have to guess.

A test states this against the pixels, not only the state: after `M1` then a
monochrome `M2`, the rendered image equals one pass of `M2` over the retained
buffer, and differs from both `M1`'s result and a hand-computed `M2 × M1`. A
second test applies the identity after a monochrome mix and gets the original
pixels back byte for byte, which would be impossible if a collapse had been
retained.

### 7. Editing state is three strings

`MonochromeMixDraft` holds the three fields as text, for the reason
`ChannelMixMatrixDraft` does (ADR 0023): `-`, `.`, `1e` and an empty field are
all states a person passes through on the way to a number, and a `TextField`
bound to a `Double` would resolve each of them to something — most likely zero
— and write it over the canonical mix. The draft is UI state, is never
persisted, and produces an adjustment only when there is one to produce.

It reuses the matrix editor's number formatter, so a coefficient that
round-trips through one editor round-trips through the other.

### 8. Nothing is normalised, clamped or repaired

`r + g + b` need not be `1`. Negative contributions are valid. Contributions
above `1` are valid. Three zeroes are valid. Nothing preserves luminance,
rescales a row or refuses a singular matrix — the collapse *is* the feature.

The only numeric rule is `RAWColorMatrix3x3`'s own — every coefficient finite —
and it is enforced there rather than restated in the editor. A complete draft
holding `inf` or `nan` is committed and **refused** by the matrix's own typed
error, rather than sitting behind a greyed-out button with no explanation.

### 9. Equal RGB is an arithmetic mean, and is named as one

The four starting points are authoring shortcuts and nothing else:

```text
Equal RGB     1/3  1/3  1/3      the arithmetic mean (R + G + B) ÷ 3
Red Only      1    0    0
Green Only    0    1    0
Blue Only     0    0    1
```

`Equal RGB` is **not** called luminance, perceptual luminance, Rec. 709
luminance, brightness-corrected or natural monochrome, and no visible-light
weighting appears anywhere in this milestone. The reason is in the Context: this
is infrared false colour, whose channels do not carry the meanings such a
formula is defined against. The editor says what the mean is, in the interface,
beside the buttons.

### 10. No wavelength determines a coefficient

Nothing here reads a capture profile, a filter descriptor or a nominal
wavelength. No 590/665/720/830 nm coefficient table exists, nothing is applied
automatically on open, and no starting point is selected because a filter is
named. This is the same rule ADR 0024 established for presets, and it is
unchanged: a wavelength label identifies a filter family and does not
characterise the recorded image.

### 11. No schema changes anywhere

The photograph sidecar stays at **schema version 5**. The creative-preset
schema stays at **version 1**. Neither needed a change, because monochrome was
already representable by `UserChannelMixAdjustment.explicit`:

```json
{ "kind": "matrix",
  "matrix": [0.3333333333333333, 0.3333333333333333, 0.3333333333333333,
             0.3333333333333333, 0.3333333333333333, 0.3333333333333333,
             0.3333333333333333, 0.3333333333333333, 0.3333333333333333] }
```

Bumping a schema version because a new interface can author an
already-supported value would make every older client refuse files it can read
perfectly well. A schema version is wire-format metadata, not a changelog.

### 12. Presets, export and the pipeline reuse themselves

Nothing below the menu is monochrome-aware, so nothing below the menu changed:

```text
IRCreativePreset          carries the mix it already carried
FullResolutionExportPipeline   runs the adjustment it was already handed
IRChannelMixer            applies the matrix it already applied
WorkspacePreviewPipeline  renders from the pre-mix buffer it already retained
```

A monochrome edit costs exactly what any channel-mix edit costs: one render of
the retained reduced preview. No decode, no normalisation, no white-balance
estimation, no demosaicing and no preview reduction runs again, and a test
counts each of those.

### 13. The UI extends the mix control

One menu item, `Monochrome…`, beside `Custom Matrix…` in the existing
channel-mix menu, opening a small sheet. No new top-level editing subsystem, no
panel and no mode.

Both `Monochrome…` and `Custom Matrix…` are marked when an authored monochrome
matrix is in force. That is deliberate and it is truthful: one state, two true
statements about it. The alternative — making them mutually exclusive — would
imply monochrome is a separate state, which is precisely what this decision
says it is not.

## Consequences

- A photographer can author an infrared monochrome rendering in three fields,
  and reuse it on every other frame through the existing preset mechanism with
  no preset change at all.
- `IRMonochromeMix` and `MonochromeMixDraft` are the only new types, and
  neither is persisted, public or reachable from a processing stage.
- The recognition rule is now load-bearing for the editor's seeding, so a
  future change to matrix equality semantics would be felt here.
- Nothing in the pipeline, the sidecar, the preset library, the export path or
  the scheduling changed. This milestone adds no code below the menu.

## Known limitations

- **No monochrome preview or comparison.** There is no split view, no before
  and after, and no indication in the workspace that the mix in force happens
  to be monochrome beyond the menu's checkmark.
- **No visible-light luminance option.** Deliberately, per §9. If a defensible
  weighting for infrared data is ever established — measured, not borrowed — it
  would arrive as a starting point with stated provenance, not as a formula
  copied from a broadcast standard.
- **No wavelength-specific starting points.** Same reason as ADR 0024's empty
  preset library: no measured basis for such coefficients exists here.
- **Recognition is exact.** A matrix whose rows differ in the last bit is not
  monochrome and seeds Equal RGB. That is the intended trade (§3), and a person
  who hits it has `Custom Matrix…`.
- **No channel-specific contrast, filtering or toning.** A monochrome result is
  a scene-linear achromatic image; contrast, curves, split toning and grain are
  all absent from this project and remain so.
- **The result is achromatic, not "black and white" in any output sense.** No
  grayscale colour space, no single-channel export and no ICC gray profile: the
  exported TIFF is still RGB, with three equal components per pixel.

## Non-goals

Wavelength-specific monochrome recipes, 590/665/720/830 nm coefficient tables,
automatic filter detection, automatic monochrome application, visible-light
luminance claims, Rec. 709 or Rec. 601 conversion, saturation, contrast,
curves, highlight recovery, histograms, tone mapping, grain, colourisation,
split toning, a second channel-mixing stage, matrix composition, a recipe
format, calibration changes and GPU acceleration. Monochrome remains creative:
nothing here makes any transform in this project a validated infrared
calibration.
