# 0021 — User capture-profile library

Status: accepted
Date: 2026-09-14

> Numbering note: `CLAUDE.md` used `0021-metal-render-pipeline.md` as an
> illustrative future filename, after [ADR 0020](0020-ir-capture-profile-foundation.md)
> took the number the previous example used. This decision took `0021`, so that
> example now reads `0022-metal-render-pipeline.md`. No ADR was renamed.

## Context

[ADR 0020](0020-ir-capture-profile-foundation.md) built the capture-profile
domain: a stable identity, an immutable definition, a registry, a photograph
state that is `capture-profile reference + ImageAdjustments`, and a sidecar at
schema version 5 that stores the reference rather than the definition.

What it deliberately did not build was a way for a person to *have* a profile.
The registry was an immutable value over one literal list:

```swift
public static let builtin = IRCaptureProfileRegistry(
    uncheckedProfiles: [.builtinUncalibrated]
)
```

so the architecture's central claim — that a profile is **reusable**, shared by
every frame shot that way — was true of exactly one profile that describes no
camera, no conversion and no filter. A photographer with a converted E-PL3 and a
Hoya R72 had nowhere to write that down, and the `user.` namespace named nothing.

That milestone's own list of limitations said so:

> **One production profile.** User-created profile definitions are not
> persisted, so the registry is built-in only and the picker shows one entry.

This decision persists them.

It is emphatically **not** the calibration milestone either. Nothing measured
exists for any camera, any conversion or any filter in this project, and nothing
here invents any. The danger a profile *library* introduces is precisely that it
looks like one: a folder of files describing cameras and wavelengths, shared
between photographers, is one careless design choice away from becoming an
infrared-calibration interchange format that nobody validated.

## Decision

**User-defined capture profiles are persisted as one JSON file each, under an
application-owned Application Support folder, at their own schema version;
the registry becomes a composition of built-in and user definitions, replaced
through one owner; and only the uncalibrated sensor-RGB processing basis has a
wire format at all.**

```text
~/Library/Application Support/Infrared Converter/Profiles/
  user.550e8400-e29b-41d4-a716-446655440000.irprofile.json

IRCaptureProfileStore        load all / save one / delete one
IRCaptureProfileLibrary      store + registry + load failures, one per process
IRCaptureProfileRegistry     builtins + loaded user profiles, immutable
DocumentState                consumes the registry; never reads the folder
```

### 1. A second store, not a second use of the first

```text
PhotographProcessingStore    one photograph's state, beside its RAW file
IRCaptureProfileStore        reusable definitions, application-owned
```

Two artefacts with two lifetimes, two schemas and two locations, so two stores.
The sidecar keeps storing a **reference**; the definition never enters it. That
invariant is the difference between a reusable profile and a preset baked into
each file: if a sidecar carried the definition, editing a profile would leave a
stale copy beside every photograph ever adjusted under it, with no way to tell
the copies apart.

The store has three operations and must not grow more. There are as many
profiles as a photographer has cameras and filters, each a few hundred bytes,
and every question worth asking is answered by loading them all.

### 2. Application Support, resolved through `FileManager`

```text
beside the RAW files   would tie a reusable profile to one folder of photographs
Documents              the user's own space; application state does not go there
the repository         developer state, not user state
a temporary directory  deleted without warning — and a photograph referencing a
                       vanished profile stops opening
```

The location comes from `FileManager.url(for: .applicationSupportDirectory, …)`
with `create: false`, never from a path built out of the home directory, so a
sandboxed build gets its container's folder from the same call. The folder is
created **lazily, by the first save**: reading an empty library must leave the
file system exactly as it found it, because a first launch that never creates a
profile has not asked for anything to be written.

Tests inject a temporary directory. No test touches the real Application Support
folder — a suite that did would leave profiles on the machine it ran on, and
would pass or fail depending on what somebody had created there earlier.

### 3. One file per profile, named by identity

```text
<profile id>.irprofile.json
```

Rather than one library file holding them all, which would make every write a
rewrite of everything, every delete a rewrite of everything, and one corrupt byte
the loss of the whole library. Per-file replacement is atomic, deletion is
removing one file, and corruption isolates.

`profileURL(for:)` is the only place the naming rule is expressed. The identifier
is filesystem-safe by construction: `IRCaptureProfileID` admits only lowercase
`a–z`, `0–9`, `-` and `.` separators, so a name contains no path separator, and
`.` and `..` are unrepresentable because every segment must be non-empty and
dot-free.

Identity therefore appears twice — in the name and in the payload — and **the two
must agree**. A mismatch is refused rather than reconciled: if they may differ,
one profile's definition can live at another profile's address, and the next save
of the second silently destroys the first.

### 4. The profile schema is version 1, and it is not the sidecar's version 5

```json
{
  "schemaVersion": 1,
  "id": "user.550e8400-e29b-41d4-a716-446655440000",
  "name": "My Olympus E-PL3 — R72",
  "cameraMatch": { "kind": "camera", "make": "OLYMPUS IMAGING CORP.", "model": "E-PL3" },
  "sensorConversion": { "kind": "fullSpectrum", "vendor": "Some Converter" },
  "filter": { "kind": "longPass", "nominalCutoffNanometers": 720 },
  "processingBasis": { "kind": "uncalibratedSensorRGB" }
}
```

A photograph's record gains a version whenever a new **adjustment** can change
its pixels; a profile's gains one whenever a new **capture-configuration** field
can. Neither event implies the other, and one shared counter would force every
reader of one artefact to be re-released because the other changed.

The forward-compatibility rule is the sidecar's, restated because it is the rule
and not the file that matters: a non-semantic field may be added within a
version and ignored; an image-affecting field requires a bump, and an older
client refuses the newer version rather than reading around it.
`processingBasis` is the image-affecting field here.

Every kind is a tagged object that refuses the fields belonging to the other
kinds — a camera match calling itself `any` may not also carry a make — for the
same reason version 5 refuses a record with two authorities for one value: there
is no reading of it that is not a guess. Values are re-validated on the way in,
so a file cannot create a filter cutoff a person could not have typed.

### 5. `.explicitMatrix` has no wire format, and that is the point

This is the most important boundary in the milestone.

```text
IRCaptureProcessingBasis          runtime      uncalibratedSensorRGB, explicitMatrix
PersistedIRCaptureProcessingBasis persisted    uncalibratedSensorRGB
```

`IRCaptureProcessingBasis` is deliberately **not** `Codable`. A synthesised
conformance would have given `.explicitMatrix` a file format by accident, and an
internal escape hatch whose only contract is "the coefficients are finite" —
present since [ADR 0006](0006-working-color-space.md), and existing today so
that ADR 0020's invalidation rule has a branch to exercise — would have become a
public infrared-calibration interchange format overnight. Files of coefficients
nobody measured, passed between photographers as characterisation data.

So the conversion from the runtime basis to the persisted one **throws**, at the
point a profile is turned into a record, before any file is opened or any folder
created. And it throws rather than downgrading: a profile that quietly lost its
matrix on the way to disk would render differently after a restart.

A measured calibration would arrive as a second persisted case, carrying its
evidence, under a new schema version. None exists.

### 6. Identity is generated, never derived from the name

```text
user.<uuid>
```

A name is rewritten — "720 nm", then "720 nm (Hoya R72)", then "Summer 720" — and
an identity derived from it would change with it, silently taking every
photograph's profile away. Two profiles a person calls the same thing are also
two profiles, and a name-derived identity would make them one. A UUID's canonical
spelling is a subset of what a segment already allows, so the generated value
validates by construction.

`builtin.` is **reserved**. A user profile may not claim it, in either direction:
such a profile cannot be saved, and one already on disk is not admitted to the
library. It would otherwise shadow a built-in definition, and a photograph
resolving to it would be rendered under a definition the application did not
author while reporting the identity that it did. No other namespace is
restricted: a future build's `vendor.` profiles must not be unreadable by this
one for syntactic reasons.

### 7. The registry composes; duplicates are refused, never resolved

```swift
IRCaptureProfileRegistry(builtins: …, userProfiles: …)
```

An identity claimed twice — across the two sources or within either — is refused
at construction rather than settled by "last one wins". Which of two definitions
a photograph meant would otherwise depend on an ordering nobody chose, that can
differ between machines, and that changes what the photograph looks like.

On disk the ambiguous pair is **both excluded and reported**, rather than one
being chosen or the whole library being discarded. It is the same judgement as
the corrupt-file rule below, applied to a different fault.

The registry keeps two orders. `allProfiles` is sorted by identity and is what
anything mechanical uses, because a rename cannot disturb it. `profilesForDisplay`
puts the built-in profiles first and then sorts by display name, which is right
for a menu and wrong for anything that has to be reproducible.

### 8. A corrupt profile is one missing profile, not a missing library

```text
IRCaptureProfileLibraryLoad
 ├── profiles    definitions that loaded
 └── failures    per-file typed refusals
```

Both halves, always, and `loadAll()` does not throw. The two alternatives are
each worse in their own way: throwing on the first bad file would let one corrupt
profile hide an entire library, and ignoring bad files would let a profile
somebody spent time creating vanish without a word — taking every photograph
that references it with it.

Only files ending in `.irprofile.json` are scanned at all. A folder may perfectly
reasonably contain `.DS_Store`, a note, or a file a future version writes; none of
those is a broken profile and none is reported as one.

The built-in profile is not part of any of this. It is a value this build holds
rather than a file it reads, so a library that is entirely unreadable — or a
machine where the storage location cannot be determined at all — still leaves an
application that opens and renders photographs.

### 9. One library owner, and the registry is replaced rather than mutated

`IRCaptureProfileLibrary` owns the store, holds the composed registry, and is the
only thing that replaces it. The alternative is every `DocumentState` reading the
folder for itself: two documents would then hold two registries built at two
moments, a profile created in one window would be invisible in the other until a
restart, and "which definition does this photograph resolve to?" would have as
many answers as there are windows.

It is `@MainActor`, and its file operations are synchronous. Three things have to
stay in step — the folder, the registry, and the interface showing both — and one
actor makes that a guarantee rather than an arrangement. It is the same judgement
`DocumentState.write` makes about a sidecar, about the same quantity of data, and
it would have to be revisited if a library ever grew large enough to measure.

The rule that follows: **the registry is replaced only after the write has
returned.** A profile whose file could not be deleted is still installed, and the
library still says so. The registry and the disk may not disagree after a
reported success.

Editing is a **replacement**: a new immutable value with the same identity,
written whole. There is no partially mutated shared object anywhere, and no
moment at which a half-updated definition is visible.

### 10. A write reaches the sidecar only for a decision

`DocumentState` gained one entry point, `updateCaptureProfiles(_:)`, and one
consequence worth stating: re-resolving a photograph against an edited definition
**does not write its sidecar**. The canonical state — the profile *reference* and
the adjustments — has not changed, so there is nothing new to make durable.

That is enforced rather than assumed: a render now writes the sidecar only when
it settles a `.pending` decision. Every path that existed before this milestone
sets `.pending` before requesting work, so the behaviour of all of them is
unchanged; the new path does not, and therefore writes nothing. Renaming a
profile does not rewrite a single sidecar, and a test compares the bytes.

The same guard applies to a refusal. A render that fails for a reason the user
did not cause does not make a state that was already saved look unsaved.

### 11. What a profile change costs is still asked of its processing basis

Unchanged from ADR 0020, Decision 10, and now reached by two callers instead of
one: a change of *selection*, and a change of *definition*. A definition edit
whose processing basis is unchanged costs one reduced-resolution render, for
provenance, because the preview carries the profile it was rendered under and the
inspector reads it from there. In this milestone every persisted profile shares
one basis, so every persisted edit is of that kind.

### 12. A missing profile still refuses — and now has a remedy

ADR 0020, Decision 5, is unchanged: a sidecar naming a profile this machine does
not have, or one made for another camera, stops the open in
`Status.captureProfileUnusable`, and nothing is substituted, repaired or
rewritten.

What a library makes possible is a way out that is still not a fallback. The
refusal screen offers **"Use Uncalibrated / Generic Instead"**, and pressing it
is an explicit user edit: the photograph is reopened under `builtin.uncalibrated`
with **every saved adjustment untouched**, the owned pipeline renders it, and the
sidecar is written once that render has succeeded — the ordinary lifecycle, with
nothing special about it. A render that refuses writes nothing.

It is offered for a camera mismatch as well as a missing profile, which removes
ADR 0020's "a camera mismatch is a dead end in the UI" limitation.

### 13. Deleting a profile is permitted, warned about, and never repaired

Photograph sidecars may still reference a deleted identity. Nothing scans for
them: they are wherever the photographs are, on whatever volumes, and a library
operation that went looking would be slow, incomplete, and wrong the moment a
disk was unplugged. So the interface says, before the deletion:

> Photographs that reference this profile will no longer open with their saved
> processing state until another profile is assigned.

and afterwards nothing is rewritten. Such a photograph refuses to open and offers
the recovery above — a refusal with a remedy, which is better than silently
rendering it under a profile nobody chose.

Two deletions are refused outright. The built-in profile is a value, not a file,
and there is nothing to remove. And a profile **the open photograph is currently
using** cannot be deleted while it is using it: the alternative leaves a document
rendering under a definition that is no longer installed, a state whose only
symptom appears the next time that file is opened. Reassigning first is one
click, and it makes the consequence visible while the person is still thinking
about it.

A profile deleted from another window, while a photograph is open under it, is
the case that remains: the document keeps the definition it resolved, keeps
rendering exactly what is on screen, and the consequence appears on the next
open.

### 14. The editor edits a draft, and the draft is the only gate

```text
IRCaptureProfileDraft    mutable, possibly invalid, what a form holds
IRCaptureProfile         immutable, valid, what the library stores
```

A form has a half-typed model in it and a wavelength field containing `"72"` on
the way to `"720"`. `IRCaptureProfile` has none of those states and must not
learn them, so the interface edits a draft and `makeProfile(id:)` is the single
gate between the two.

Invalid input is **refused, never normalised**. A blank camera model does not
quietly become "any camera"; a cutoff of `0` does not quietly become "unknown".
Either would save a profile describing a different capture configuration from the
one a person was describing, and they would not be told. Everything is trimmed,
because surrounding whitespace is a typing artefact rather than a decision, and
nothing else is changed.

The identity is a parameter of `makeProfile(id:)` rather than a field of the
draft: creation is given a freshly generated one and editing is given the one
being replaced, and there is no path by which a person could move a definition to
another profile's address.

### 15. The processing basis is not on the form, and neither is a checkbox

Every profile this milestone creates is `uncalibratedSensorRGB`, and it is not
offered as a choice. A form that let a person pick a camera transform would be a
calibration editor wearing a profile editor's clothes.

There is deliberately no "Calibrated" checkbox. Validation is something this
project performs and reports, never something a user asserts. The editor shows
`Calibration — No` as a **fact**, read from the basis's own transform provenance
rather than written into the view, so the day a source is genuinely validated the
form says so because it is true.

### 16. Prefill is convenience; selection is always a person's

Creating a profile while a photograph is open can copy the camera's make and
model into the form. That is two strings a person can see and change, and it
happens because they pressed something.

Nothing reads a file's make and model, or its filename, and creates or selects a
profile. A camera name says nothing about which filter was on the lens or what
was done to the sensor, and a profile invented from it would be a guess presented
as a record. Saving a profile does not assign it either: that is a second button,
labelled as a second thing.

A profile that does not describe the open photograph's camera is **listed and
disabled**, with the reason in its help text, rather than hidden. Hiding it would
leave somebody who had just created it staring at a menu that does not contain
it, wondering whether it saved — and the honest answer is that it saved and does
not apply here.

## Shared-definition semantics

Stated plainly, because the interface says it too:

> A capture profile is a shared object. Editing one changes what **every**
> photograph referencing it resolves to, the next time each one is opened.

In this milestone that is bounded: only `uncalibratedSensorRGB` can be persisted,
so a persisted edit changes metadata and cannot change a pixel. The rule is
recorded now because the day a second basis can be persisted it will not be
bounded, and the place to have decided is before that, not after.

## Calibration honesty

**User-defined does not mean calibrated.** Every profile this milestone can
create renders camera-native sensor values straight into the working space
through `RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor`. A profile
that names an E-PL3, a full-spectrum conversion, a vendor and a 720 nm filter is
describing a capture configuration in a person's own words. It is not a
measurement, and `isValidatedInfraredCalibration` is `false` for it — derived
from the transform's provenance, not asserted by the profile.

A nominal wavelength is a family label. A marketed 720 nm long-pass filter has a
transition band tens of nanometres wide and per-batch variation, two
manufacturers' "720 nm" filters are not interchangeable, and nothing here matches
profiles by wavelength.

## Consequences

- The `user.` namespace names something. A photographer can record a real
  capture configuration once and assign it to any number of photographs.
- A photograph's sidecar still holds a reference of a few dozen bytes; profile
  definitions live in one place and are edited in one place.
- The registry is composed and replaced through one owner, so every window sees
  the same profiles without a restart.
- An internal experimental matrix cannot become a file, in either direction.
- One corrupt profile costs one profile.
- A photograph whose profile is missing has a remedy that is still an explicit
  edit.

## Known limitations

- **No calibration, still.** Nothing in this milestone measures anything.
- **A filter is a nominal cutoff or a product name, not both.** "Hoya R72" and
  "720 nm nominal" cannot be recorded at once, because `IRFilterDescriptor` has
  one case for each. Redesigning it was out of scope for a library milestone; the
  workaround is to put the product name in the profile's own name.
- **No import, export, sharing or sync.** Profiles are files a person can copy by
  hand; nothing in the application helps.
- **No filesystem watcher.** The library is loaded once at launch and refreshed
  by its own writes. A profile added to the folder by another process appears at
  the next launch.
- **One window at a time is the tested case.** The library is shared by every
  window and its registry reaches each open document, but the application has no
  multi-document lifecycle to speak of and none is claimed.
- **Deletion is refused while the open photograph uses the profile.** The
  simpler, coherent policy; it means reassigning first rather than being warned
  afterwards.
- **A profile deleted from another window while a photograph is open** leaves
  that document rendering under the definition it resolved. The consequence
  appears on the next open.
- **No recommendations.** A profile describes capture context and suggests no
  white balance, mix, exposure or orientation.

## Non-goals

Calibration matrices, a matrix editor, measured-calibration schemas, spectral
response curves, DNG matrices, ICC generation, cloud or iCloud sync, profile
import/export or sharing, a profile marketplace, automatic profile selection or
detection, recommendations, presets and recipes, batch application,
temperature/tint, GPU or Metal work, CFA-aware reduction, and new export formats.
