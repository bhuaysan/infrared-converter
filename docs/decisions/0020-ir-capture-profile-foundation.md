# 0020 — IR capture/filter profile foundation

Status: accepted
Date: 2026-09-13

> Numbering note: `CLAUDE.md` used `0020-metal-render-pipeline.md` as an
> illustrative future filename, after [ADR 0019](0019-interactive-white-balance.md)
> took the number that example previously used. This decision took `0020`, so
> that example now reads `0021-metal-render-pipeline.md`. No ADR was renamed.

## Context

Four canonical user adjustments now exist — the infrared white balance
([ADR 0019](0019-interactive-white-balance.md)), the orientation correction
([ADR 0010](0010-user-owned-orientation-adjustment.md)), the creative channel
mix ([ADR 0016](0016-interactive-channel-mixer.md)) and exposure
([ADR 0017](0017-interactive-exposure.md)) — and every one of them is a
decision about **one photograph**. They are persisted as one record
([ADR 0013](0013-adjustment-sidecar.md)) and rendered by two paths that share
their processing ([ADR 0018](0018-full-resolution-tiff-export.md)).

What does not exist is the other kind of state, the kind `CLAUDE.md` has
described from the beginning:

```text
Camera Model Profile
+
Capture Configuration
+
Filter Profile
+
Creative Recipe
=
Rendered Result
```

Only the last of those is modelled. The first three were **one hard-coded
constant**:

```swift
// RAWWorkingImagePipeline, before this milestone
static let cameraToWorkingTransform = RAWCameraToWorkingColorTransform
    .sensorRGBIdentityFalseColor
```

That constant is the application's entire answer to "which camera, which
conversion, which filter produced this file, and what processing does that
call for?" — and it was invisible: no photograph recorded that it had been
used, no user could see it, and nothing could ever select anything else. The
transform itself is honest (it claims nothing; see
[ADR 0006](0006-working-color-space.md)), but its *placement* was not: a global
policy in a processing type, where a product decision cannot be argued with.

The distinction this milestone exists to draw:

```text
photograph-local editing state   ≠   reusable capture configuration
```

A neutral patch at `(0.42, 0.31)` is the clearest case. It is a place in *this*
picture. A reusable profile that carried it would be asserting that the same
rectangle is neutral in every photograph ever taken with that camera.

This is deliberately **not** the calibration milestone. No measured data exists
for any camera, any conversion or any filter in this project, and none is
invented here.

## Decision

**A capture profile is a reusable, identified description of how a photograph
was captured and what processing that configuration requires. A photograph's
canonical state becomes the pair `capture-profile reference + ImageAdjustments`,
persisted together in the existing sidecar at schema version 5, resolved before
the first owned render, and shared by preview and export.**

```text
PhotographProcessingState
 ├── captureProfile   IRCaptureProfileID     reusable, by stable identity
 └── adjustments      ImageAdjustments       this photograph's own decisions

IRCaptureProfileRegistry     id → IRCaptureProfile      one per application
```

### 1. The capture profile is not an `ImageAdjustments` field

The two have different lifetimes, different owners and different meanings.

```text
capture profile   describes how the photograph was CAPTURED — camera, sensor
                  conversion, filter — and is shared by every frame shot that
                  way. Renaming it must not change any photograph.

adjustments       describes what the user DECIDED about this one frame. The
                  patch they clicked. Meaningless for any other photograph.
```

Putting the profile inside `ImageAdjustments` would have been the smaller
diff and the wrong model: `ImageAdjustments` is the seed of the eventual
`InfraredRecipe`, which *references* profiles rather than containing them, and
a record that mixed "what I decided" with "what the camera was" could never be
reused across photographs without dragging one into the other.

So a new value sits above both. It is `PhotographProcessingState` — not
`DocumentState`, which is the runtime workspace controller, and not
`ImageDocument`, which in `CLAUDE.md` also includes the source and the metadata.
It is `Equatable`, `Sendable`, immutable by convention, free of anything that
runs, and it is what a sidecar holds, what an export is rendered from, and what
a render request names.

### 2. Identity is a namespaced string, and it is not the name

```text
builtin.uncalibrated
user.olympus-epl3-720nm
```

A profile's display name is something a person writes and later rewrites.
Every photograph that referenced it by name would lose its profile the moment
the name changed, silently, with a different rendering as the only symptom.

It is equally not a file path: a path is a location, it changes when a library
moves between machines, it leaks a user's directory layout into every sidecar,
and two profiles copied to one place would collide.

`IRCaptureProfileID` validates at the boundary — at least two dot-separated
segments, lowercase `a–z`, `0–9` and `-`, bounded lengths — so that no later
code has to wonder whether an identifier it holds is well formed, and so that
`Builtin.Uncalibrated` and `builtin.uncalibrated` cannot be two spellings of one
identity. The **namespace is not restricted to a known set**: a future build's
`vendor.` profiles must not be unreadable by this one for syntactic reasons.

### 3. Metadata and processing are separate fields, and only one reaches a pixel

```text
IRCaptureProfile
 ├── id, name                  identity
 ├── cameraMatch               context, and a validity check
 ├── sensorConversion          context — unknown / factory / full-spectrum / internal IR
 ├── filter                    context — unknown / nominal long-pass / named product
 └── processingBasis           ← the ONLY field that changes an image
```

The sensor conversion and the filter are two fields rather than one because
they are two facts:

```text
full-spectrum body + 720 nm filter on the lens   720 nm capture, filter removable
body converted internally to 720 nm              720 nm capture, filter permanent
full-spectrum body, no filter                    not a 720 nm capture at all
```

The first two record similar light and are different cameras; the third shares
a conversion with the first and records something else entirely.

The filter's wavelength field is `nominalCutoffNanometers`, and the name is the
decision. A marketed 720 nm long-pass filter is not a step function at 720 nm:
it has a transition band tens of nanometres wide, a passband that is not flat,
and per-batch variation, and two manufacturers' "720 nm" filters are not
interchangeable. The number is what the box says. Two consequences follow, and
both are enforced: **nothing matches profiles by wavelength**, and **carrying a
wavelength does not make a profile calibrated**.

### 4. Camera matching is exact, and it validates rather than selects

`IRCameraMatch` is `.any` or `.camera(make:model:)`. Comparison is exact after
trimming whitespace and folding case, and nothing more: `E-PL3` and `EPL3` are
different spellings, and deciding they are the same is the beginning of
guessing. `IRCaptureProfileApplicability` has three answers rather than a
`Bool`, because "no" has two meanings a user needs told apart:

```text
matches           the profile claims no camera, or names this one
cameraMismatch    the profile names a camera and the file names another
cameraUnknown     the profile names a camera and the file names none
```

Matching **validates a selection a person already made**. Nothing in this
milestone reads a file's make and model, or its filename, and picks a profile
from them. A future UX may suggest; it may not choose.

### 5. An unusable profile refuses the photograph; it never substitutes another

A sidecar may name `user.my-profile` on a machine that does not have it, or a
profile made for another camera. Both stop the open, in a status case of their
own:

```text
Status.captureProfileUnusable(URL, DocumentCaptureProfileError)
```

The alternative — opening the photograph under some other profile that happens
to be installed — would change the rendering and report success, which is the
failure mode this whole milestone exists to prevent. It is the same policy
[ADR 0013](0013-adjustment-sidecar.md) applies to an unreadable sidecar, for the
same reason, and with the same guarantee: nothing is repaired, deleted or
rewritten.

The unresolvable case is detected **before** the decode, because the registry
lookup needs no pixels. The camera mismatch is detected **after** the decode and
**before** the first processing stage, because it needs the file's make and
model and nothing may be processed under the profile until it has passed.

### 6. The sidecar stores a reference; the registry stores the definition

```text
registry    id → definition          one per application
sidecar     "this photograph uses id" one per photograph
```

If a sidecar carried the whole definition, editing a profile would leave every
photograph already adjusted under it holding a stale copy, and the same profile
would be duplicated once per frame with no way to tell the copies apart. That is
the difference between a *reusable* profile and a preset baked into each file.

`IRCaptureProfileRegistry` is an immutable value built from a fixed list, with
exact lookup, deterministic listing sorted by identity, and duplicate
identities refused at construction. **Built-in only in this milestone**: there
is no user-profile directory, no profile JSON schema and no profile editor.
That is a deliberate scope choice — the milestone's purpose is the architecture
and the photograph-level selection, and a profile manager would have dwarfed
both — and the domain model assumes nothing about the set being fixed. When
user profiles are persisted they get their **own** schema version, independent
of the photograph sidecar's.

> **Amended by [ADR 0021](0021-user-capture-profile-library.md) (2026-09-14).**
> The registry is no longer built-in only. It is now a **composition**:
>
> ```text
> IRCaptureProfileRegistry(builtins: …, userProfiles: …)
> ```
>
> of the profiles this build ships and the definitions loaded from a persisted
> user library, and profile identifiers in sidecars can therefore genuinely
> reference reusable definitions a person created.
>
> Everything above survives unchanged, and is what made the composition cheap:
> the registry is still an **immutable value** with exact lookup, deterministic
> listing by identity, and duplicate identities refused at construction rather
> than resolved by load order. It is replaced, never mutated, through one owner
> (`IRCaptureProfileLibrary`), so nothing resolves against a definition that
> changed underneath it.
>
> The user library gets its own schema version — profile schema **1**, beside
> the photograph sidecar's **5** — exactly as this decision anticipated, and
> only the `uncalibratedSensorRGB` processing basis has a wire format at all:
> `.explicitMatrix` remains runtime-only, and attempting to persist one is a
> typed refusal rather than a silent downgrade.

One simplification follows and is recorded rather than relied on: the set of
profiles cannot change while an export runs. The export defends anyway, by
carrying the resolved profile rather than an identifier to look up later, which
is the behaviour a mutable registry would require.

> **Amended by [ADR 0021](0021-user-capture-profile-library.md).** The
> simplification is gone and the defence is now load-bearing: a person can edit
> a profile while an export runs. Because the export carries the **resolved**
> `IRCaptureProfile`, an edit affects the next export and not the running one,
> and no registry lookup happens while an export is in flight.

### 7. The sidecar schema becomes version 5, and it nests

```text
v1   orientation
v2   + channelMix
v3   + exposureEV
v4   + whiteBalance
v5   + captureProfileID, adjustments nested
```

```json
{
  "schemaVersion": 5,
  "captureProfileID": "builtin.uncalibrated",
  "adjustments": {
    "orientation": "rotate90Clockwise",
    "channelMix": { "kind": "identity" },
    "exposureEV": 0,
    "whiteBalance": { "kind": "defaultNeutralPatch" }
  }
}
```

The nesting is the wire format catching up with the model. Once the record
holds two different kinds of thing, a flat object says they are the same kind,
and every future field would have to be read to find out which half it belongs
to. Staying flat and appending `captureProfileID` would have made this migration
shorter and every later one worse.

**There is exactly one authority for each field.** A version 5 record that also
carries `orientation` at the top level is refused, and a version 1–4 record that
carries `adjustments` or `captureProfileID` is refused. Neither is read
leniently: a record with two places to look for one value has no reading that is
not a guess.

The **filename did not change**. `<RAW name>.iradjustments.json` is what every
sidecar already written is called; a filename is an address, not a schema, and
the payload's shape is versioned inside the file where a reader looks.

`captureProfileID` earns a version bump for the general reason even though every
profile this build ships happens to share one processing basis: the field's
purpose is to select which camera-to-working transform runs, so a build that
ignored it would eventually render somebody's photograph through the wrong one
and say nothing.

### 8. Schema ownership moved off `ImageAdjustments`

`PersistedSchemaVersion`, `currentSchemaVersion` and the version-aware `Codable`
conformance now belong to `PhotographProcessingState`. `ImageAdjustments` is no
longer `Codable` at all: the record that owns the version owns the whole wire
format, including the four adjustment fields, in one place.

A schema version belongs to the record it describes. Leaving it on the
adjustments would have meant a version number claiming to describe a file it
only half covered. And `ImageAdjustments` went back to being editing data: a
test about an exposure builds `ImageAdjustments(exposure:)` and nothing else —
no record, no version, no profile — which is what
[§26 of the milestone](../../CLAUDE.md) asked for and what the old shape made
progressively harder.

`ImageAdjustmentError` lost `unsupportedSchemaVersion`, `missingAdjustment` and
`unexpectedAdjustment` to a new `PhotographProcessingStateError`, for the same
reason: those are the **record's** shape refusing, not an adjustment's value.

### 9. Preview and export are handed the same resolved profile

```text
preview   prepareSource(base, whiteBalance:, captureProfile:, …)
export    ExportRequest(rawURL:, captureProfile:, adjustments:)
              → RAWWorkingImagePipeline.prepare(… cameraToWorkingTransform: …)
```

`RAWWorkingImagePipeline.cameraToWorkingTransform` is gone as a constant. The
transform is a parameter of the one shared RAW front half, and both end paths
supply it from `profile.processingBasis.cameraToWorkingTransform`. There is no
export profile, no export default and no second resolver — the same shape
[ADR 0019](0019-interactive-white-balance.md) established for the neutral patch,
applied to the other thing that was hidden.

The export carries the profile **resolved**, as a whole `IRCaptureProfile`,
rather than an identifier to look up while running. A registry lookup from
inside a running export would be the "look up mutable UI state after it starts"
that an immutable snapshot exists to prevent.

### 10. What a profile change costs is asked of its processing basis

```text
basis unchanged   the pixels cannot differ — re-render, for provenance
basis changed     the camera-to-working transform differs — re-prepare
```

The question is asked of `IRCaptureProcessingBasis`, the only part of a profile
that reaches a pixel, and it is asked of the **source** rather than of the
previous selection — the two disagree exactly when it matters, which is while
an earlier preparation is still in flight.

A metadata-only change therefore costs one reduced-resolution render and no
re-preparation, and the inspector still updates, because a preview carries the
profile it was rendered under. A change of basis joins the **existing** heavy
slot, the one a new neutral patch uses, because it needs exactly that pass:
re-balance, re-demosaic, re-convert, re-reduce, from the retained normalised
mosaic. No third cache and no third slot.

The slot's request became `SourcePreparationRequest { whiteBalance,
captureProfile }`, and every lifecycle guarantee of
[ADR 0014](0014-adjustment-lifecycle.md) and ADR 0019 now compares the whole
request: a source prepared under one profile cannot install into a document that
has moved to another, and a control moved during a preparation does not restart
a pass that is already producing the right answer.

### 11. No recommendations, in this milestone

A profile may eventually recommend a channel mix — a creative choice, and safe
to copy into `ImageAdjustments` by an explicit action. None is implemented, and
the built-in profile carries none. The rule, recorded now so the first one
obeys it: a recommendation is **copied once, by an explicit user action**, and
never applied continuously. Selecting a profile must never overwrite an exposure
the user set afterwards.

Profile-level white balance is refused outright rather than deferred. A reusable
profile cannot meaningfully contain a neutral patch, because a patch is a place
in one photograph.

### 12. Two processing bases exist, and neither is a calibration

`.uncalibratedSensorRGB` is the identity false-colour axis assignment — exactly
what every build of this application has done, which is what makes the migration
pixel-neutral.

`.explicitMatrix` is the existing
`RAWCameraToWorkingColorTransform.explicit(matrix:)` escape hatch, present since
ADR 0006 and carrying no claim beyond finite coefficients, surfaced where a
profile can name it. It earns its place for one reason: without a second basis,
Decision 10 would be a branch nothing could ever exercise, and an untested
invalidation rule is worse than an unused enum case. Nothing in the application
produces one — no UI, no built-in profile, and no persisted profile format that
could carry it.

A **validated infrared calibration** would be a third case carrying a measured
matrix and its evidence. It is deliberately absent.
`isValidatedInfraredCalibration` is derived from the transform's own provenance
rather than asserted by the profile, so the day a source is genuinely validated,
a profile reports it because it *is* true rather than because someone edited a
constant. Today it is `false` everywhere.

### 13. The UI shows the profile and does not pretend to offer a choice

Production ships one profile. A menu with a single item is not a choice; it is
a control implying the application has capture configurations to offer when it
has not.

> **Amended by [ADR 0021](0021-user-capture-profile-library.md).** There is now
> more than one profile to offer, so the control is a menu: every profile, the
> built-in ones first and then user profiles by display name, with a way into
> the library. The reasoning is preserved rather than reversed — a profile that
> does not describe this camera is listed and **disabled**, with the reason in
> its help text, and there is still no free-text profile field and nothing that
> picks a profile for the user. So the selection machinery exists in production —
`DocumentState.setCaptureProfile`, the registry, the invalidation rule — and the
control shows the current profile honestly until there is a second. Tests
exercise selection with injected profiles rather than production growing fake
ones.

There is no free-text profile field either. An identifier a user typed would
name nothing, and a photograph pointing at nothing is the unresolvable state
Decision 5 refuses to create on purpose.

The inspector separates the two kinds of state, which is the product-visible
half of this whole document:

```text
Capture
  Profile       Uncalibrated / Generic
  Profile ID    builtin.uncalibrated
  Intended camera  Any camera
  Conversion    Unknown
  Filter        Unknown
  Processing    Uncalibrated sensor RGB
  Calibration   No

Owned preview
  …  White balance, Channel mix, Exposure, Orientation
```

The calibration row says "No" in words rather than being omitted. An absent row
reads as "not applicable"; this one has to read as "we have not characterised
your camera".

## Migration, and the pixel-neutrality proof

Every historical record migrates to `builtin.uncalibrated`, and that is a
**migration rather than a default**: it is not a guess about a missing field, it
is what the absent field meant. Every build that wrote versions 1 to 4 rendered
through `sensorRGBIdentityFalseColor`, and `builtin.uncalibrated` is the profile
whose basis is exactly that.

The claim is tested rather than asserted, on synthetic data and on the E-PL3
fixture: the same RAW file rendered from a version 4 state and from the migrated
version 5 state produces **bit-identical** reduced preview values and
bit-identical full-resolution pre-encoding export values.

Reading rewrites nothing. An older record is upgraded on disk only when the
user's next decision renders and is saved.

## Consequences

- The application's one capture-processing assumption is visible, selectable,
  recorded per photograph and stated in the inspector, where before it was a
  static constant in a processing type.
- There is a defined place for camera, conversion and filter context that is
  not an adjustment, and a defined place for adjustments that is not a profile.
- Preview and export cannot resolve different profiles: they are handed the
  same resolved value.
- The sidecar's payload is the photograph's complete application-owned state,
  written as one record.
- `ImageAdjustments` is editing data again, with no persistence metadata on it.
- The processing basis makes "does this change cost a re-preparation?" a
  question about data rather than a UI assumption.

## Known limitations

> Two of these were lifted by [ADR 0021](0021-user-capture-profile-library.md),
> and are marked below. The rest still stand.

- **No calibration.** Every profile this build ships renders through the
  identity false-colour axis assignment. A named filter is context, not colour
  science. *(Still true. ADR 0021 persists user profiles and does not measure
  anything: a user-defined profile is not a calibrated one.)*
- **One production profile.** User-created profile definitions are not
  persisted, so the registry is built-in only and the picker shows one entry.
  *(Lifted by ADR 0021: profiles are persisted, one JSON file each, under
  Application Support.)*
- **A camera mismatch is a dead end in the UI.** The document refuses to open,
  and the profile can only be changed by editing the sidecar. It is unreachable
  in production, where the only profile matches everything, and a deliberate
  override is left to the milestone that ships user profiles. *(Lifted by
  ADR 0021: the refusal screen offers an explicit "Use Uncalibrated / Generic
  Instead", for a mismatch as well as for a missing profile. It reopens the
  photograph with every adjustment intact and is still an explicit user edit,
  never a fallback.)*
- **No recommendations, no "Apply Profile Recommendations" action.**
- **No suggestion, no detection.** Nothing proposes a profile from a filename,
  a camera model or EXIF.
- The camera match is make and model only. Serial numbers, conversion vendors
  and lens identities are recorded where known but take no part in matching.
- A profile change re-prepares rather than reusing anything; profile switching
  is not optimised, and deliberately so.

## Non-goals

Measured camera matrices, DNG `ColorMatrix` generation, spectral response
modelling, automatic filter or camera detection, automatic profile assignment,
profile sync or sharing, a profile marketplace, recipes, batch apply,
temperature/tint, manual white-balance gains, tone curves, a histogram, GPU or
Metal work, CFA-aware reduction, and new export formats.
