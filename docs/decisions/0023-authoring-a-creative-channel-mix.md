# 0023 — Authoring a creative channel mix, and reading the infrared gains

Status: accepted
Date: 2026-09-15

> Numbering note: `CLAUDE.md` uses `0023-metal-render-pipeline.md` as an
> illustrative future filename. This decision took `0023`; no ADR was renamed,
> and that example now reads `0024-metal-render-pipeline.md`.

## Context

Two things existed in the model and not in the product.

**A creative 3×3 matrix could be rendered and not authored.**
[ADR 0016](0016-interactive-channel-mixer.md) made the channel mix a user
adjustment with three states, and said so plainly in its Decision 3:

> `.explicit` exists in the model and has no editor. It is what makes the
> persisted format able to express the mix the processing stage can already
> apply, and adding it later would have cost another schema version.

and again in its non-goals:

> **A matrix editor.** `.explicit` is persistable, applicable and testable, and
> there is no user interface that produces one.

So a photograph could only acquire a matrix from a sidecar written by something
else — a test, or a hand-edited JSON file. Everything downstream of the
decision was finished: `IRChannelMix.explicit`, `IRChannelMixer`,
`UserChannelMixAdjustment.explicit`, the persisted `matrix` record, the
coalescing renderer, the export. The missing part was nine text fields.

That gap mattered more than it sounds. Channel mixing is one of the reasons
this project exists: a red/blue swap is the *classic* infrared move, and it is
also only one point in a space. Aerochrome-like renderings, partial swaps,
channel-borrowing to recover contrast in foliage, and a deliberate monochrome
collapse are all 3×3 matrices, and none of them is expressible by a two-item
menu.

**The infrared gains could be seen and not read.** The inspector showed the
estimator's output as four bare numbers in colour-plane order:

```text
Gains    1.000  2.143  4.827  2.097
```

Every number in that row is correct and none of it is legible. Which one is the
blue plane that was lifted nearly five stops? Are there four planes or is the
fourth a slot the sensor never fills? Why are two of them nearly the same, and
are those the two greens? On a converted camera with a deep long-pass filter
those are the questions a photographer actually has, and the row answered none
of them.

## Decision

### 1. The editor authors `UserChannelMixAdjustment.explicit` and nothing else

There is no new type for a creative matrix, no second persisted
representation, no second mixer and no UI-side matrix. The chain is the one
that already existed:

```text
ChannelMixEditorView        nine text fields
        ↓
ChannelMixMatrixDraft       text → numbers, or nothing yet
        ↓
RAWColorMatrix3x3           the one matrix; refuses a non-finite coefficient
        ↓
UserChannelMixAdjustment    .explicit(matrix) — canonical user state
        ↓  derived, computed, never stored
IRChannelMix                working space + matrix + provenance .explicit
        ↓
IRChannelMixer              one pass over the retained pre-mix preview
```

`DocumentState.setChannelMix` is the entry point, unchanged, and it is the same
one the two built-in choices use. An authored matrix is therefore a complete
render state exactly as a chosen swap is: one request, one coalescing slot, one
sidecar write after it renders.

### 2. The editing state is text, and it is a type of its own

`ChannelMixMatrixDraft` holds nine `String`s. That is not an implementation
detail; it is the decision.

A coefficient is a finite `Double`. Half-typed text is not one:

```text
""      not a number        the field was cleared to retype it
"-"     not a number        a negative coefficient, first keystroke
"1e"    not a number        an exponent, half typed
"1.5"   a coefficient
"inf"   a number, not finite
```

A `TextField` bound to a `Double` resolves every one of the first three to
something — zero, in practice — and writes it into the canonical adjustment. A
user clearing a cell to retype it would render, and save, a matrix with a zero
in it. So the draft parses on demand and produces an adjustment **only when
there is one to produce**: `adjustment()` returns `nil` while any cell is not
yet a number, and the canonical state is untouched until every cell is.

The draft stores no coefficients, performs no colour arithmetic and does not
know what the working colour space is. It is a keyboard, not a fourth
authority.

### 3. Non-finiteness is refused by the existing contract, not restated

`Double("inf")`, `Double("nan")` and `Double("1e400")` all succeed. A draft
holding one of those is *complete* — every cell is a number — and is committed
and refused by `RAWColorMatrix3x3`'s own initialiser, which throws
`RAWProcessingError.invalidColorMatrix3x3(row:column:value:)` naming the cell.

Two alternatives were rejected:

- **Filtering non-finite text in the draft.** It would put a copy of the
  matrix's numeric contract in the editor, and the two could then disagree.
- **Disabling Apply until every cell is finite.** A person who typed `inf`
  would be left looking at a greyed-out button with no statement of why.

The cell is marked as soon as it stops being a finite number, *and* pressing
Apply reports the primitive's refusal. The marking says which cell; the refusal
says what the matrix would not accept.

### 4. Nine coefficients, and no repair of any of them

The editor clamps nothing, normalises no row, preserves no luminance and
refuses no singular matrix. Legitimate creative mixes include:

```text
negative coefficients          channel subtraction
coefficients above 1           channel amplification
rows that do not sum to 1      a brightness decision
determinant 0                  a monochrome collapse, or a two-channel mix
```

ADR 0007 already says an IR channel mix carries no luminance, gamut or
energy-preservation claim. An editor that quietly repaired a row would be
authoring a matrix the user did not type, and would make the sidecar disagree
with what was entered.

The one numeric requirement is the primitive's: every coefficient is finite.

### 5. Rows are outputs, and the convention is shown rather than translated

`RAWColorMatrix3x3` is row-major with rows as output channels, and the editor
prints the three equations it performs above the grid:

```text
Rout = m00·R + m01·G + m02·B                 input R   input G   input B
Gout = m10·R + m11·G + m12·B    output R       m00       m01       m02
Bout = m20·R + m21·G + m22·B    output G       m10       m11       m12
                                output B       m20       m21       m22
```

Transposing it for typing convenience was rejected: the nine numbers in the
sidecar, the nine coefficients in the matrix and the nine cells on screen must
be the same nine numbers in the same nine places, or a person reading a saved
recipe cannot check it against the editor.

Cells are addressed as `draft[output:input:]` rather than by a flat index, so
the view cannot transpose the grid by getting a loop the wrong way round.

### 6. An authored matrix is `.explicit`, whatever its numbers are

Typing the identity's nine numbers produces `.explicit`, not `.identity`.
Typing the swap's produces `.explicit`, not `.redBlueSwap`.

Provenance is what the person did, not what the numbers happen to equal. The
persisted format already enforces the converse — a built-in token carrying a
matrix is refused, whatever the coefficients are (ADR 0016, amendment) — and
collapsing an authored matrix into a built-in would be the same modelling error
from the other side: the record would say a person chose the red/blue swap when
they typed nine numbers, and editing one of them afterwards would be a
different kind of decision than editing the other eight.

Selecting the Identity or Red/Blue Swap menu items still persists those
built-in cases, unchanged. `UserChannelMixAdjustment.selectableCases` stays
`[.identity, .redBlueSwap]`: it is the list of mixes a menu can offer *by
name*, and a matrix is authored rather than chosen.

### 7. Nothing about the pipeline, the schema or the scheduling changed

- **No composition.** The mix is applied to the retained pre-mix reduced
  preview, which is where ADR 0016 put it, so `new output = NewMix × pre-mix
  image` and never `NewMix × OldMix × image`. Authoring a second matrix is an
  ordinary re-render: no decode, no normalisation, no white balance, no
  demosaic, no reduction.
- **No schema change.** The sidecar's `channelMix` record already had a
  `matrix` kind carrying nine coefficients. The photograph sidecar stays at
  schema version 5.
- **No export path change.** An export takes one `ImageAdjustments` from the
  RAW file; an authored matrix reaches it the way every adjustment does.
- **No new scheduling.** A matrix is committed once, on Apply, so there is no
  continuous stream of states to coalesce — and if there were, it would use the
  existing complete-state renderer, as the exposure slider does.

### 8. The gains are labelled from the layout, by one derived type

`RAWWhiteBalanceGainListing` pairs each gain with the colour plane it
multiplies and with what the sensor's own layout says that plane is:

```text
Gain P0 R    ×1.000
Gain P1 G    ×2.143
Gain P2 B    ×4.827
Gain P3 G    ×2.097
```

Two facts come from `RAWMetadata.SensorColorLayout` and nowhere else:

```text
which planes exist      RAWWhiteBalanceEstimator.colorPlanes(in:)
what each plane is      layout.colorDescription, indexed by plane
```

Plane enumeration is **delegated to the estimator's own helper** rather than
reimplemented. A second walk of the CFA cell could disagree with the one that
produced the gains, and a listing that described a different set of planes than
the estimate measured would be worse than the unlabelled row it replaced.

Plane identity comes from `colorDescription` — the file's own statement of what
its planes are. `RGBG`, `RGBE`, `GBTG` and `GMCY` all occur, so a hard-coded
`["R", "G", "B", "G"]` would mislabel three of them. A letter that names no
linear RGB channel keeps its letter and gets no channel:
`RAWLinearRGBChannel.init(colorDescriptionLetter:)` already refuses to invent an
RGB channel for an emerald or a CMY filter, and the label can still say what
the file said.

Consequences of reading the layout rather than assuming a shape:

- **A three-plane layout lists three rows.** The gain model has four slots
  because `colorPlaneIndex` can return `3` even when `colorCount` is `3`; a
  layout that never reaches plane 3 has no fourth gain, and showing its unused
  slot as `×1.000` would read as a measured plane that needed no correction.
- **Both greens stay visible.** An `RGBG` layout has two green planes, the
  pipeline balanced them independently, and they are two rows.
- **A plane the description does not name keeps its index.** `P3`, not `P3 G`.

The caption states the scale policy, read from the estimate's own
`scalePolicy`, so `×1.000` reads as "the strongest measured plane" rather than
as "no correction here".

### 9. `WorkspacePreview` carries the layout its gains are indexed by

One new field, `sensorColorLayout`, set from the preparation's own
`RAWMetadata` where the preview is built.

The alternative was to read the layout from the open document. It is the same
layout today, and it was rejected anyway: `DocumentState.Loaded.metadata` is
whichever path read the file, which in some cases is the LibRaw diagnostic
reference (ADR 0012), and the inspector's rule is that every line in the owned
preview panel is read back from that preview's own provenance. A panel that
sourced the gains from one place and their labels from another could label one
read of a file with another's planes.

The field says nothing about the *rendering*: the pixels are demosaiced, mixed
and oriented, and no CFA plane survives into them. It records where the gains
came from.

## Consequences

- A photographer can author any finite 3×3 creative mix, save it with the
  photograph and export it, and the built-in Identity and Red/Blue Swap choices
  are unchanged.
- The inspector's gain rows say which plane is which, for any CFA layout the
  estimator can measure, without assuming RGGB.
- ADR 0016's statement that `.explicit` has no editor is superseded. Its
  amendment records that; nothing in it is rewritten.
- One more public type in the RAW processing surface
  (`RAWWhiteBalanceGainListing`) and one more field on `WorkspacePreview`.
  Neither is reachable from a processing stage, and neither multiplies a pixel.

## Known limitations

- **Decimal separators are `.`** — `Double`'s own parsing, on the trimmed
  text. `1,5` is not a number here. Guessing a locale's separator would make
  one string mean a value on one machine and nothing on another; a deliberate
  locale-aware parse is a later decision, not an accident of the first one.
- **No presets.** An authored matrix is not saveable as a named recipe. That is
  the recipe feature, which references profiles by stable identity and does not
  exist yet.
- **No per-channel sliders and no live drag.** Nine numeric cells, committed on
  Apply. Sliders are a separate design question — they need a sensible range
  per coefficient, and the answer for infrared is not obviously `0…1`.
- **No visual aid.** No determinant readout, no "this collapses colour"
  warning, no before/after. A singular matrix is applied silently because it is
  legitimate.
- **The gain listing is presentation.** Nothing reads it back; it cannot affect
  a render.

## Non-goals

Filter-family presets (590/665/720/830 nm), a filter database, hue remapping,
false-colour LUTs, Aerochrome and CandyChrome renderings, monochrome UI,
hotspot correction, tone curves, histograms, Kelvin/tint white balance, manual
white-balance gain entry, automatic scene analysis, and any automatic detection
that a photograph is infrared. A creative matrix remains creative: none of this
makes any transform in the project a validated infrared calibration.
