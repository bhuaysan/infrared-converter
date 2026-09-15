# 0024 — Reusable creative presets

Status: accepted
Date: 2026-09-15

> Numbering note: `CLAUDE.md` uses `0024-metal-render-pipeline.md` as an
> illustrative future filename. This decision took `0024`; no ADR was renamed,
> and that example now reads `0025-metal-render-pipeline.md`.

## Context

[ADR 0023](0023-authoring-a-creative-channel-mix.md) gave a photographer nine
text fields and a matrix. It also recorded, in its own limitations, the thing
it did not finish:

> **No presets.** An authored matrix is not saveable as a named recipe.

That is a sharper gap than it sounds, because of where the matrix lives. An
authored mix is written into **one photograph's sidecar**. A person who spends
twenty minutes finding the channel mix that makes their 720 nm foliage work has
produced a result that applies to exactly one frame, and the only way to reuse
it on the next frame is to read nine numbers out of a JSON file and type them
back in.

Infrared photography makes this worse than it would be for a general editor.
An infrared photographer does not shoot one look: they own a filter, or three,
and everything shot through one filter on one converted body wants
approximately the same creative starting point. The reuse is the workflow.

The obvious temptation is the one this decision exists to refuse. It would be
easy to ship a menu reading

```text
590 nm    665 nm    720 nm    830 nm
```

with a matrix behind each. There is no measured, documented or otherwise
established basis in this repository for any of those four matrices, and
inventing nine plausible-looking coefficients and labelling them with a
wavelength would be exactly the false filter science
[ADR 0020](0020-ir-capture-profile-foundation.md) and
[ADR 0022](0022-calibration-evidence-and-measurement-protocol.md) were written
to prevent. `IRFilterDescriptor` already states the rule this milestone had to
keep:

> A wavelength label such as `720 nm` identifies a filter family. It does not
> fully characterize the recorded image.

So this milestone builds the **mechanism** by which such starting points could
later exist honestly, and populates it with nothing.

## Decision

### 1. A preset is a named `UserChannelMixAdjustment`, and nothing more

`IRCreativePreset` carries four things:

```text
id            IRCreativePresetID          stable, generated, never the name
name          String                      what a person recognises it by
channelMix    UserChannelMixAdjustment    the decision it applies
filter        IRFilterDescriptor          context; consulted by nothing
```

The third field is the whole architecture. A preset does **not** carry a
matrix of its own. It carries the existing user adjustment, so there is no
second persisted representation of a channel mix that could come to disagree
with the first about what `redBlueSwap` means, and applying one is a single
assignment into a path that already exists:

```text
preset.channelMix
        ↓
DocumentState.setChannelMix(_:)      the same entry point Identity and
        ↓                            Red/Blue Swap and the matrix editor use
existing coalescing render path
        ↓
IRChannelMix  →  IRChannelMixer
```

Nothing new renders. No preset-aware code exists anywhere below the menu item.

### 2. A preset is not a new provenance

`IRChannelMixSource` gains no `.preset` case. The pixel operation is whatever
the preset resolves to — `.identity`, `.redBlueSwap` or `.explicit` — and a
photograph developed from a preset is indistinguishable, in its sidecar and in
its pixels, from one where the same nine numbers were typed by hand.

That is correct rather than merely convenient. Provenance records **what the
matrix is**: a creative choice, a built-in swap, a measured calibration. Where
a person got the idea from is not a property of the matrix, and a `.preset`
case would be a fourth answer to a question that has three.

### 3. The photograph sidecar does not change, and stores no preset reference

Schema version 5, unchanged. A photograph stores the **resolved**
`UserChannelMixAdjustment`, exactly as it did before presets existed.

This is the opposite of the capture-profile decision, deliberately:

```text
capture profile   sidecar stores a REFERENCE      the definition is shared,
                  (ADR 0020)                      and a missing one refuses the open
creative preset   sidecar stores the RESOLVED     the decision is the photograph's,
                  decision                        and the library is only a shortcut
```

A capture profile describes a fact about the capture that many photographs
share, and a stale copy in every sidecar would be a lie the moment the profile
was corrected. A preset is a **starting point a person took**. Once taken, it
is theirs; it is not a continuing relationship with a library entry.

The consequences are worth stating plainly, because they are the point:

- Renaming a preset changes no photograph.
- Editing a preset's matrix changes no photograph already developed with it.
- Deleting a preset changes no photograph, and no photograph fails to open.
- A preset library that is entirely unreadable leaves every photograph
  rendering exactly as it was.

A photograph does not remember which button was clicked. It remembers the
processing decision that resulted from the click, which is the only part that
has a defined meaning.

### 4. Applying is always explicit

No preset is ever applied automatically. Not on open, not from a filename, not
from EXIF, and — the one that matters here — **not because a photograph's
capture profile names the same nominal wavelength as a preset's filter note.**

Matching a preset to a photograph by wavelength would assert that all filters
sold as "720 nm" call for the same creative mix on every converted body. That
is false, it is unmeasured, and it is precisely the claim
`IRFilterDescriptor` refuses to let a profile make.

The interface may show a person what a preset is noted for. It never acts on
it.

### 5. The filter hint is metadata, and it is `IRFilterDescriptor`

Not a second notion of "720 nm". The same enum the capture profile uses, with
the same three cases, the same validation, and the same wording — a nominal
cutoff is what the box says, and `shortDescription` renders it as
`720 nm nominal long-pass` so that it cannot be read as a measurement.

`.unknown` is an ordinary, complete state: a preset with no filter note is a
preset about a look rather than about equipment, and it is offered for every
photograph.

The hint takes part in no arithmetic, no selection, no enabling and no
disabling. `isValidatedInfraredCalibration` is `false` for every preset,
including one that names a wavelength, and it is derived rather than stored so
that it cannot come to disagree with anything.

### 6. No built-in presets, and `builtin.` reserved anyway

This build ships zero presets. Populating a menu with `590 nm`, `665 nm`,
`720 nm` and `830 nm` would require nine coefficients each, and there is no
provenance for any of them. The wavelength-specific starter library is a
follow-up whose first task is deciding where its coefficients come from and
saying so.

The `builtin.` namespace is reserved regardless, in one direction: a user
preset may neither save nor load under it. A stored preset shadowing a
definition a future build authored would apply a matrix nobody in this project
wrote, under a name the application would appear to vouch for.

What a preset *may* reuse is a transform that already has defined semantics —
`.identity` and `.redBlueSwap` are established creative operations in this
project, and a preset resolving to either is honest.

### 7. The capture profile's filter is a prefill, never a binding

When the open photograph's capture profile records a filter, the save sheet's
filter field starts there. It is a reasonable first guess at which family the
author would suggest the look for, and it saves retyping `720`.

It is copied **once**, when the sheet opens, and the copy is then the draft's
own. Editing that capture profile afterwards, renaming it or deleting it
changes nothing about the draft and nothing about any preset saved from it. The
sheet says the value was copied and from where, so that the copy is visible
rather than mysterious.

A preset that tracked a profile's filter would silently change what it claims
to be suggested for, long after its author stopped thinking about it.

### 8. A library of its own: own folder, own schema, own store

Modelled on [ADR 0021](0021-user-capture-profile-library.md), and deliberately
separate from it at every level.

```text
Application Support/Infrared Converter/
  Profiles/   <profile id>.irprofile.json   capture profiles   schema 1
  Presets/    <preset id>.irpreset.json     creative presets   schema 1
```

Siblings, not a shared folder. Two artefacts in one folder eventually share a
suffix, a counter or a loader, and these two must not: a capture profile gains
a schema version when a new capture-configuration field can change a pixel, a
preset gains one when what a preset carries changes, and neither event implies
the other. That both start at `1` is a coincidence of when each was introduced,
and a test pins that they are independent numbers.

The rules carried over from ADR 0021 without change:

- One file per preset, so replacement is atomic per preset and one corrupt file
  costs one preset.
- The filename **is** the identity, expressed in one place
  (`FileIRCreativePresetStore.presetURL(for:)`); a payload that disagrees with
  its name is refused rather than reconciled.
- Loading returns both halves — what loaded and what refused. A corrupt file is
  reported, never silently skipped, and never allowed to hide the rest.
- A file wearing our suffix whose name is not a valid identifier is
  `invalidPresetFilename`, distinct from a foreign file, which is ignored in
  silence.
- Two definitions claiming one identity are **both dropped** and the ambiguity
  reported. Resolving it by enumeration order would make which mix a menu entry
  applies depend on how a folder happened to be read.
- One owner per process, `IRCreativePresetLibrary`, the only thing that reads
  that folder; the list is replaced only after a write has returned.

### 9. No registry type, because nothing resolves a reference

A capture profile needs `IRCaptureProfileRegistry` because a sidecar holds a
reference that must be resolved at open, at render and at export. A preset is
read once, at the moment a person clicks it, and what leaves the library is an
ordinary adjustment. So there is a list and a display order, and no resolution
step anywhere in the pipeline.

Display order is by name case-insensitively, then by identity. Names are
deliberately not unique — a name is not an identity, and two presets may both
be called "720 sky" — so the identity is the tiebreak that makes the order
total and independent of the file system.

### 10. Identity is generated, and renaming is only a rename

`user.<uuid>`, never derived from the display name. The reasoning is
`IRCaptureProfileID`'s, and it survives even though no photograph references a
preset: two presets a person calls the same thing are two presets, and a
name-derived identity would silently make a rename into an overwrite of
somebody else's preset.

### 11. One filter draft, shared

Three forms now describe a filter — a capture profile's external filter, its
internal one, and a preset's note. Parsing text into a nominal cutoff is one
operation, and a second implementation of it would be a second notion of what
`720 nm` is. `IRCaptureProfileDraft.FilterDraft` was therefore promoted to
`IRFilterDraft`, with the nested name kept as an alias and the capture
profile's field-labelled refusals produced by a mapping extension.

`IRFilterDescriptor.commonNominalCutoffsNanometers` — 590, 665, 720, 830 —
exists as **typing shortcuts** for such a form. It is not a closed set, not a
calibration, and not a key anything matches on; any cutoff in the supported
range is equally valid and `.named` covers products with no single number.

### 12. The UI extends the mix control rather than adding a panel

```text
Channel Mix
    Identity
    Red/Blue Swap
    ──────────────
    Presets ▸
        <saved presets, name — filter note>
    Save Current Mix as Preset…
    Manage Presets…
    ──────────────
    Custom Matrix…
```

Inspecting a preset opens **the existing matrix editor** seeded with its
coefficients. There is no second matrix editor, and applying from there sets
the photograph's mix while leaving the stored preset alone.

The mix a preset records is the one on screen when the save sheet opens, not
whatever it has become by the time a name has been typed.

## Consequences

- A creative infrared look can be developed once and applied to any number of
  photographs, which is the reuse the product was missing.
- Nothing about a photograph's rendering depends on the preset library
  existing, being readable, or being unchanged.
- One more application-owned folder, one more schema version to maintain, and
  one more `@Observable` library per process.
- `IRChannelMixSource`, `UserChannelMixAdjustment`, `IRChannelMix`,
  `IRChannelMixer`, `DocumentState.setChannelMix`, the sidecar schema and the
  export path are all unchanged. The preset feature adds no code below the
  menu.
- ADR 0023's limitation "No presets" is superseded; its amendment records that
  and nothing in it is rewritten.

## Known limitations

- **No starter library.** The menu is empty until a person saves something.
  590/665/720/830 nm presets with real coefficients are a follow-up that must
  first decide where those coefficients come from.
- **A preset carries only the mix.** No white balance, because a neutral region
  is a place in one photograph and can never be reusable state. No exposure and
  no orientation, which are equally photograph-specific. A workflow that said
  "pick a neutral patch after applying this look" is a later idea and is not a
  persisted gain or region.
- **No import, export, sharing or sync.** A preset is a small JSON file in an
  application-owned folder; moving one between machines is a milestone of its
  own, not a button added on the way past.
- **No folders, tags, favourites, search or sort controls.** One deterministic
  order.
- **Editing a preset's matrix is not offered.** A preset can be renamed and its
  filter note changed; changing what it applies means applying it, editing the
  matrix in the mixer, and saving a new preset. Replacing a stored matrix in
  place is supported by the library (`update`) and is not surfaced, because the
  useful version of it needs a clearer answer about what a person expects to
  happen to the photograph they are looking at.
- **Comparison hints are absent.** The interface does not tell a person that a
  preset's filter note differs from their capture profile's. Such a hint would
  be informational only, and it was left out rather than shipped as the first
  step toward matching.

## Non-goals

Wavelength-specific creative coefficients invented without provenance,
automatic preset selection, automatic infrared or filter detection, monochrome
UI, Aerochrome and CandyChrome LUTs, hue remapping, hotspot correction, tone
curves, histograms, Kelvin/tint, manual white-balance gains, batch processing,
cloud sync, preset sharing or a marketplace, and any calibration work. A preset
remains creative: nothing here makes any transform in this project a validated
infrared calibration.
