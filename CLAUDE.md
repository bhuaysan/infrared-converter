# CLAUDE.md — Infrared Converter

## Project Overview

**Infrared Converter** is a native macOS application for developing and converting RAW photographs captured for infrared photography.

It is not intended to become a general-purpose Lightroom replacement. Its primary purpose is to make infrared RAW processing fast, reproducible, technically well-defined, predictable, and accessible.

The key problems are:

- extreme/custom infrared white balance
- channel mixing and channel swapping
- camera/filter/capture-specific color behavior
- false-color rendering
- repeatable infrared recipes
- batch conversion
- older RAW formats and converted cameras

The current and exclusive target platform is **macOS**.

Do not introduce cross-platform abstractions unless explicitly requested.

---

# Product Goals

Infrared Converter should allow a photographer to:

1. Open a RAW file from a supported camera.
2. Decode sensor data with high precision.
3. Apply an infrared-appropriate white balance.
4. Select or define the physical capture/filter configuration.
5. Apply camera/capture/filter-specific processing.
6. Perform channel swaps and other infrared-specific transforms.
7. Fine-tune the result with a focused set of standard development controls.
8. Preview changes interactively.
9. Export high-quality TIFF, JPEG, or PNG files.
10. Reuse the same versioned infrared recipe across multiple images.

Conceptual workflow:

```text
RAW
 ↓
Camera / Capture Configuration
 ↓
IR Filter Profile
 ↓
IR White Balance
 ↓
IR Color Transform
 ↓
Creative Look
 ↓
Basic Develop
 ↓
Export
```

The application should produce a useful, reproducible infrared result with only a few deliberate choices.

---

# Non-Goals

Unless explicitly requested, do NOT implement:

- Lightroom-style catalog management
- DAM functionality
- cloud sync
- photo hosting
- social features
- albums or collections
- face recognition
- geolocation databases
- AI image generation
- Photoshop-style layer editing
- compositing
- vector graphics
- video support
- Linux or Windows support
- plugin systems
- account systems
- subscriptions or licensing infrastructure

Do not expand scope merely because a feature is common in other photo applications.

The main differentiator is **infrared RAW development**, not generic photo management.

---

# Target Platform and Technology

Use native Apple technologies by default:

- Swift
- SwiftUI
- AppKit where SwiftUI is insufficient
- Metal / Metal Performance Shaders where justified
- Accelerate / vDSP where useful
- Core Image only where it provides a clear advantage without compromising pipeline correctness
- LibRaw for RAW decoding unless an alternative is explicitly justified

Do not introduce without explicit approval:

- Electron
- Qt
- Flutter
- React Native
- Catalyst
- browser-based application shells

Before adding any third-party dependency, document:

1. the capability it provides
2. why Apple frameworks or existing dependencies are insufficient
3. maintenance risk
4. license
5. whether it is required at runtime

Avoid dependency proliferation.

---

# Supported RAW Formats

The architecture must support common RAW formats including, but not limited to:

- Olympus / OM System ORF
- Sony ARW
- Nikon NEF / NRW
- Canon CR2 / CR3
- Fujifilm RAF
- Panasonic RW2

Older RAW formats are important.

The initial reference camera is:

- **Olympus PEN E-PL3**

Do not assume the macOS system RAW decoder supports every camera we care about.

RAW decoding must live behind a dedicated decoder boundary.

Do not design the RAW core around a Bayer-only or fixed-RGGB assumption. The decoder abstraction must be able to describe the actual sensor color layout, including non-Bayer layouts such as Fujifilm X-Trans where supported.

---

# RAWDecoder Contract

`RAWDecoder` must make the state of its output explicit.

Callers must be able to determine which operations, if any, have already been applied by the underlying decoder.

The preferred raw-stage decoder output exposes, where available:

- sensor or mosaic samples at useful source precision
- sensor dimensions
- active image area
- CFA / color-layout description
- black levels
- white / saturation levels
- camera make and model
- orientation
- embedded white-balance metadata
- camera color metadata
- decoder warnings or limitations relevant to interpretation

Unless explicitly requested by the caller, the RAW boundary must not silently apply:

- display gamma
- output/display color-space conversion
- creative processing
- sharpening
- noise reduction
- undocumented highlight reconstruction

If LibRaw or another decoder applies any material processing before the application receives the buffer, that behavior must be explicit at the decoder boundary.

This includes, where applicable:

- black-level correction
- scaling or normalization
- white balance
- demosaicing
- camera color conversion
- highlight handling

Do not allow application processing stages to be applied twice because decoder-side processing was implicit.

---

# Core Architecture Principles

## UI and processing are separate

SwiftUI views may present state, collect user input, and modify processing parameters.

Views must not:

- decode RAW files
- perform color transforms
- own Metal resources
- parse profiles
- write exports directly

Conceptual boundary:

```text
UI
 ↓
Application / View Model
 ↓
Processing API
 ↓
RAW / IR / Render Engines
```

## Processing is non-destructive

Never permanently mutate original RAW files.

All edits are represented as parameters.

Conceptually:

```text
ImageDocument
 ├── source
 ├── metadata
 └── adjustments
```

Rendered output is derived from:

```text
source + adjustments
```

This architecture must make undo/redo, presets, recipes, batch processing, parameter comparison, and sidecars possible without modifying source data.

The sidecar is the first of those to exist. It holds the photograph's complete application-owned processing state — the **capture-profile reference** and the adjustments together, today the white-balance choice, the orientation correction, the creative channel mix and the exposure — and it is written and read as a whole, never field by field. A RAW file is an immutable input — never rewritten, appended to, re-tagged or replaced — and a user's decisions live in one application-owned JSON file beside it, named by one rule in one place. It is read **before** the file is decoded, so the first render is already the saved state; it is written only after a state has rendered successfully and is still the current one; and a record it cannot understand stops the open rather than becoming a default state. See `docs/decisions/0013-adjustment-sidecar.md` and `docs/decisions/0020-ir-capture-profile-foundation.md`.

Two kinds of state live there, and keeping them apart is the point:

```text
PhotographProcessingState
 ├── captureProfile   a reference to a reusable capture configuration
 └── adjustments      this photograph's own editing decisions
```

A capture profile describes how the photograph was **captured** — camera, sensor conversion, filter — and is shared by every frame shot that way. An adjustment describes what the user decided about **this one frame**. A neutral patch at `(0.42, 0.31)` is a place in one picture, so it can never belong to a profile; a filter's nominal wavelength is true of a configuration, so it can never be an adjustment.

## Processing stages have explicit boundaries

Do not create one giant `ImageProcessor`.

Preferred conceptual responsibilities:

```text
RAWDecoder
RAWProcessor
CameraProfileEngine
InfraredWhiteBalanceEngine
InfraredCaptureProfileEngine
InfraredColorEngine
DevelopEngine
RenderEngine
ExportEngine
```

Each unit must have one clear responsibility.

## Profiles are data

Camera profiles, capture configurations, IR filter profiles, and creative recipes are data structures.

Do not hard-code filter-specific or camera-specific values inside SwiftUI views or rendering control flow.

Prefer stable identifiers and `Codable` value types where appropriate.

---

# Suggested Module Structure

Create structure incrementally. Do not create empty directories merely to match this tree.

```text
InfraredConverter/
├── App/
├── Documents/
├── RAW/
│   ├── RAWDecoder.swift
│   ├── LibRawDecoder/
│   ├── RAWMetadata.swift
│   ├── RAWImage.swift
│   ├── CameraProfile.swift
│   └── CaptureConfiguration.swift
├── Infrared/
│   ├── Calibration/
│   ├── InfraredWhiteBalance.swift
│   ├── InfraredFilterProfile.swift
│   ├── InfraredColorTransform.swift
│   ├── ChannelMixer.swift
│   └── InfraredRecipe.swift
├── Develop/
├── Rendering/
├── Export/
├── UI/
└── Shared/
```

---

# RAW Processing Pipeline

The RAW pipeline is one of the most important parts of this project.

Do not casually change processing order.

The starting pipeline is a **design hypothesis**, not a claim that every camera or IR capture requires the same sequence:

```text
RAW Sensor Values
        ↓
Metadata / CFA Interpretation
        ↓
Black-Level Correction
        ↓
White-Level Normalization
        ↓
Defective Pixel Handling (if needed)
        ↓
RAW-domain White Balance
        ↓
Demosaicing
        ↓
Camera / Sensor Interpretation
        ↓
Defined Working Representation
        ↓
IR Capture-Profile Adjustment
        ↓
Infrared Channel / Color Transform
        ↓
Develop Adjustments
        ↓
Display or Export Transform
        ↓
Preview / Export
```

Individual stages must remain independently testable and movable where technically necessary.

Infrared white balance is a **user adjustment**, not a fixed application choice — but it stays where it is, in the mosaic domain, before demosaicing. It is the one adjustment upstream of the preview reduction, so changing it re-prepares that preview from a retained normalised mosaic rather than being applied to it. The user's decision is persisted as the **neutral region they chose**, in normalised active-area coordinates, and the gains are re-derived from the RAW file every time, by one resolver and one estimator, for the preview and the export alike. See `docs/decisions/0019-interactive-white-balance.md`.

The camera/sensor interpretation stage — the camera-to-working transform — is no longer a fixed application constant. It is chosen by the photograph's resolved **capture profile**, through its `IRCaptureProcessingBasis`, and handed to the shared RAW front half as a parameter. For the built-in `builtin.uncalibrated` profile that is exactly `.sensorRGBIdentityFalseColor`, which is what every earlier build applied, so migrated photographs render identically. Preview and export are handed the same resolved profile value. See `docs/decisions/0020-ir-capture-profile-foundation.md`.

The working representation is established **before** the infrared channel/color transform, not after it. That ordering was originally hypothesised the other way round; implementation showed that a creative channel mix is only meaningful once the RGB axes it remixes are defined, so the stage operates inside the working representation and leaves it unchanged. See `docs/decisions/0006-working-color-space.md` and `docs/decisions/0007-infrared-channel-mixing.md`.

The pipeline's "Display or Export Transform" step is implemented as **two separate boundaries**, and no tone stage exists at either. The display boundary — exposure, hard display-range clipping, the sRGB transfer function, 8-bit quantisation — is `docs/decisions/0008-display-preview-rendering.md`. The export boundary — hard export-range clipping, the same transfer function, 16-bit quantisation — is `docs/decisions/0018-full-resolution-tiff-export.md`. They share the arithmetic that is genuinely one rule (`SceneLinearExposure`, `SRGBTransferFunction`) and each owns its own range policy, bit depth and destination. Neither may reuse the other's buffer, and an export must never start from the 8-bit preview.

Between the working representation and the creative channel mix there is now one more boundary, and it is the only stage in the pipeline that changes how many pixels there are: the **preview reduction**. It produces the reduced scene-linear rendition the interactive workspace holds, leaves the colour space, the linearity and the numeric range unchanged, and is deliberately absent from any full-resolution path. See `docs/decisions/0015-reduced-resolution-preview.md`.

The creative channel mix that follows it is a **user adjustment**, not a fixed application choice. It is applied in the interactive half of the pipeline, to the retained **pre-mix** reduced preview — never composed onto a previous mix, and never baked into what a document holds open — and it forms one complete render state with the user's orientation correction and exposure. See `docs/decisions/0016-interactive-channel-mixer.md`.

Exposure is the third user adjustment. Its arithmetic is `SceneLinearExposure` — `× 2^EV`, in the linear domain, before whichever range policy follows — and that one primitive is the only place it is written. The interactive path applies it inside the display boundary, where it has always lived; the full-resolution export applies it as a stage of its own, `SceneLinearExposer`, so the adjusted scene-linear image exists before anything clips or quantises it. It is not tone mapping. See `docs/decisions/0017-interactive-exposure.md` and its amendment.

Image orientation is a stage of its own, between the infrared channel/color transform and the display or export transform. It is **discrete geometry**: the eight standard orientations, applied as an exact permutation of whole pixels, lossless and with every component's bit pattern preserved. It is the only stage that changes where a pixel is, or that can exchange the image's width and height. See `docs/decisions/0009-application-owned-orientation.md`.

The orientation applied is **derived**, not read: the file's recorded orientation composed with a user-owned adjustment. Keep the three apart — source metadata is an immutable fact about the input, the adjustment is an editing decision, and the effective orientation is derived from both. A user correction must never be written back into `RAWMetadata`. See `docs/decisions/0010-user-owned-orientation-adjustment.md`.

Keep that apart from arbitrary-angle rotation, straightening, crop and perspective correction. Those are continuous editing operations, they require resampling, and none of them is implemented. Do not fold either kind of geometry into demosaicing — a CFA layout is defined in sensor coordinates — or into the display encoder, whose per-component, geometry-preserving claim is what makes it auditable.

Whenever processing order changes, document:

1. old order
2. new order
3. technical reason
4. expected visual impact
5. test evidence

Detailed and experimentally evolving pipeline information belongs in `docs/raw-pipeline.md` and `docs/infrared-pipeline.md`.

---

# Visible-Light vs Infrared Color Calibration

Do not assume that standard camera or DNG color matrices calibrated for visible-light photography remain valid for infrared data.

Visible-light camera transforms and IR-specific calibration transforms are separate concepts.

Do not use a standard camera matrix merely because LibRaw or metadata exposes one. Its calibration domain must be understood before applying it to IR data.

A capture profile naming a camera, a conversion vendor and a nominal filter wavelength is **not** a calibration either. Those fields are context that lets a person tell two configurations apart and lets the application refuse a profile applied to the wrong body. Only measured, documented data makes a transform calibrated, and none exists in this project.

What such data has to consist of is now defined. A calibration is an artefact carrying three things together — the measurement evidence, the reference dataset it was fitted against, and the fitted transform with its per-patch residuals — plus the capture context it was measured against, **by value**, so that editing a profile afterwards cannot falsify it. Validation status is derived from that evidence and from acceptance criteria; it is never a stored flag. This project establishes no acceptance criteria, so nothing reaches `validated` and `isValidatedInfraredCalibration` is `false` everywhere. The objective is a **defined infrared false-colour calibration**, never a recovery of human-visible scene colour from infrared photons. See `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md` and `docs/calibration-protocol.md`.

When adding any color matrix or transform, document:

- source representation / space
- destination representation / space
- whether it is visible-light calibrated, IR-specific, empirical, or creative
- matrix orientation
- normalization assumptions
- expected numeric range

Do not hide uncertainty behind plausible-looking matrices.

---

# Physical IR Filters and Capture Profiles

A physical infrared filter acts **during capture**, before sensor sampling.

Digital processing after capture must not treat a filter profile as an exact physical simulation or inverse of the filter's spectral transmission unless such a model is explicitly implemented and validated.

Use the concept of an **IR Capture-Profile Adjustment** for processing that is appropriate for a known physical capture configuration.

A wavelength label such as `720 nm` identifies a filter family. It does not fully characterize the recorded image.

This holds wherever such a label appears, and it now appears in two places for two different reasons: a **capture profile**'s filter records what was physically on the lens, and a **creative preset**'s filter note records what its author suggests the look for. Neither is a measurement, neither makes anything calibrated, and nothing in this project selects a profile, a preset or a transform by comparing wavelengths. This build ships no wavelength-specific creative matrices, because no measured or otherwise established basis for one exists here.

Different manufacturers, conversion types, cameras, lenses, and illumination can produce different behavior.

Filter profiles may eventually contain:

- schema version
- metadata
- manufacturer / product identity
- nominal wavelength or family
- default IR white balance
- empirical IR transform
- channel transform
- hue remapping
- tone defaults
- recommended recipe
- camera or capture-configuration overrides

Avoid overdesigning V1.

Version serialized profile formats from the first persisted format onward.

---

# Camera Profiles and Capture Configuration

Keep these concepts separate:

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

A camera model profile may contain:

- black-level behavior
- white-level behavior
- CFA details
- visible-light camera color metadata, clearly identified as such
- sensor quirks
- validated IR-specific calibration data where available
- model aliases

The first of these now exists, as `IRCaptureProfile`: a reusable, stably identified description of the camera, the sensor conversion and the filter, plus the one field that reaches a pixel — its `IRCaptureProcessingBasis`. A photograph references it by `IRCaptureProfileID`; the definition lives in a registry, never copied into a sidecar. Camera matching is exact, validates a selection a person already made, and never makes one. An unresolvable or mismatched profile refuses the photograph rather than being replaced by another. See `docs/decisions/0020-ir-capture-profile-foundation.md`.

Those definitions are now **persisted**, so a person can record a real capture configuration once and assign it to many photographs. One JSON file per profile, named by its validated identifier, in an application-owned Application Support folder, at a profile schema version of its own — independent of the photograph sidecar's. The registry is a composition of the built-in profiles and the loaded user ones, refusing a duplicate identity rather than resolving it; it is replaced, never mutated, through one owner, `IRCaptureProfileLibrary`, which is the only thing in the project that reads that folder. A corrupt file costs one profile and is reported; the built-in profile is a value and always exists. See `docs/decisions/0021-user-capture-profile-library.md`.

**A user-defined profile is not a calibrated profile.** `isValidatedInfraredCalibration` is derived from the transform's own provenance rather than asserted by the profile, and it is `false` for every profile this project ships and every profile a user can create. Only `uncalibratedSensorRGB` has a wire format at all: `IRCaptureProcessingBasis` is deliberately not `Codable`, `.explicitMatrix` stays runtime-only, and attempting to persist one is a typed refusal rather than a silent downgrade — the alternative would turn an internal escape hatch into a public infrared-calibration interchange format that nothing validates.

Identity is generated (`user.<uuid>`) and never derived from the display name, so renaming a profile breaks no photograph. `builtin.` is reserved: a user profile may neither save nor load under it. Editing a profile is an immutable replacement under the same identity, and it changes what every referencing photograph resolves to the next time it is opened — but it never touches any photograph's adjustments, and it never rewrites a sidecar, because the canonical state did not change.

A `CaptureConfiguration` describes the physical camera state relevant to the photograph, for example:

- stock camera
- full-spectrum conversion
- dedicated IR conversion
- conversion vendor / calibration identifier where known
- unknown/custom conversion

Do not assume two bodies of the same camera model have identical IR behavior after physical conversion.

Version serialized camera, capture-configuration, and calibration profile schemas from the beginning.

---

# Precision and Numeric Ranges

Avoid unnecessary precision loss.

## RAW stage

Keep RAW values at their original useful precision.

Never convert RAW data to 8-bit for processing.

## Processing stage

Default internal processing target:

```text
Float32 per channel
```

Use higher precision only where justified.

Do not introduce half-float merely for memory savings without measurement.

Intermediate floating-point values are **not inherently restricted to `0...1`**.

White balance, channel mixing, color matrices, highlight headroom, and tone operations may legitimately produce values below `0` or above `1`.

Do not clamp intermediate values unless a specific processing stage explicitly requires clipping and that behavior is documented and tested.

Keep these concepts separate:

- RAW sensor saturation
- processing-domain clipping
- display clipping
- export clipping

---

# Highlight Handling

Do not silently reconstruct clipped RAW channels.

Highlight reconstruction, if introduced, must be an explicit and independently testable processing stage with documented assumptions.

Do not rely on undocumented LibRaw highlight behavior.

---

# Color Management

Color management must be explicit.

Conceptually distinguish:

```text
Sensor / Camera Representation
        ↓
Working Representation
        ↓
Display Space
        ↓
Export Space
```

Do not assume the working representation is automatically a conventional visible-light photographic RGB space.

The working representation must be deliberately defined before production IR color transforms depend on it.

That decision is recorded in:

```text
docs/decisions/0006-working-color-space.md
```

The working representation is **extended linear sRGB**: sRGB primaries, the sRGB D65 white point, a linear transfer function, Float32 storage, and no clipping to `0...1`.

Choosing that space defines only the coordinate system. How camera-native sensor RGB is mapped into it is a separate decision, carried explicitly by a camera/IR color transform with its own provenance. Do not conflate the two, and do not treat a defined working space as a claim of colorimetric accuracy for an infrared capture.

Creative infrared channel mixing is a **third** decision, distinct from both. It operates inside the working representation, leaves the color space unchanged, and carries its own provenance as creative intent — never as camera calibration, white balance, working-space establishment or filter calibration. That decision is recorded in `docs/decisions/0007-infrared-channel-mixing.md`, and that it is a **user adjustment** rather than a fixed application choice in `docs/decisions/0016-interactive-channel-mixer.md`.

Arranging the pixels for viewing is a **fourth** decision, and it is not a colour decision at all: orientation moves whole pixels and changes no value, so it is kept out of every colour stage. That decision is recorded in `docs/decisions/0009-application-owned-orientation.md`, and the user-owned correction composed onto it in `docs/decisions/0010-user-owned-orientation-adjustment.md`.

Encoding the result for a display is a **fifth** decision, distinct from all four. It is the first point in the pipeline where a value stops being proportional to light, and it is deliberately minimal: exposure in the linear domain, an explicitly named hard clip to `0...1`, the piecewise sRGB transfer function, and deterministic 8-bit quantisation. That decision is recorded in `docs/decisions/0008-display-preview-rendering.md`.

Keep these apart in code and in language:

```text
extended linear sRGB    scene-linear, unclamped Float32, light-proportional
display-encoded sRGB    display-referred, clipped, transfer function applied
```

Scene-linear values must never be tagged as ordinary sRGB, and display-encoded values must never be tagged linear. Display encoding is not tone mapping, and a displayable image is not a color-validated one.

Never rely on accidental/default ColorSync or framework behavior for major processing decisions.

---

# Infrared White Balance

Infrared white balance is a core feature, not merely a Temperature/Tint slider.

The architecture must support RAW-domain color-plane multipliers where the sensor layout and decoder make that meaningful.

A simple RGB conceptual example is:

```text
R' = R × rMultiplier
G' = G × gMultiplier
B' = B × bMultiplier
```

This is an example, not a RAW layout assumption.

The RAW core must not assume:

- fixed RGGB Bayer layout
- exactly three independently addressable RAW planes
- identical green positions

White balance must operate against CFA/color-plane metadata supplied by the decoder.

The neutral-patch picker exists. A user clicks a neutral part of the displayed photograph; the click is mapped back through the aspect-fit layout and the effective orientation into **normalised active-area coordinates**, and that region is what the sidecar records. Never the gains, never view coordinates, never preview pixels. A file with no saved decision gets `.defaultNeutralPatch` — the deterministic centred square this project has always measured — which is a placeholder and is deliberately not called an automatic white balance.

Potential further modes:

- Camera WB
- Auto IR
- Foliage
- Manual multipliers
- Saved camera/filter/capture-configuration WB

Do not artificially clamp IR white balance to a conventional Kelvin range.

If Kelvin/Tint is offered, it is a UI convenience representation, not the only underlying representation.

Sampling algorithms must document whether sampling occurs in RAW-domain, demosaiced, or later rendered data.

---

# Infrared Color Engine

Infrared-specific color processing is its own subsystem.

Likely operations include:

- channel swap
- channel mixer
- empirical IR color transforms
- false-color mapping
- hue remapping
- Aerochrome-inspired rendering
- CandyChrome-style transformations
- blue-sky 720 nm rendering
- monochrome conversion
- LUT-based creative finishing

Represent channel mixing as a matrix where practical.

Example:

```text
[ R' ]   [ a b c ] [ R ]
[ G' ] = [ d e f ] [ G ]
[ B' ]   [ g h i ] [ B ]
```

Separate technical/capture transforms from creative looks.

Do not special-case channel swaps or filter names in UI code.

---

# Infrared Recipes

A recipe combines reusable processing choices.

Example:

```text
Olympus E-PL3
Full Spectrum
720 nm
Foliage White Balance
Red/Blue Channel Swap
Blue-Sky Color Transform
Default Contrast Curve
```

Recipes reference profiles and parameters rather than duplicate implementation logic.

Persisted recipes must be serializable and versioned.

The **first reusable fragment** of this exists, and it is deliberately one
fragment rather than a recipe: `IRCreativePreset` is a named, persisted,
reusable creative channel mix with an optional filter note. It carries the
existing `UserChannelMixAdjustment` rather than a matrix of its own, so applying
one is a single assignment into `DocumentState.setChannelMix` and nothing below
the menu is preset-aware. It carries **only** the mix — a neutral patch is a
place in one photograph, and an exposure and an orientation are equally
photograph-local. A photograph's sidecar stores the **resolved** mix, never a
preset reference, so renaming or deleting a preset cannot change an image
developed with it. See `docs/decisions/0024-reusable-creative-presets.md`.

Conceptually:

```swift
struct InfraredRecipe: Codable {
    let schemaVersion: Int
    // stable profile IDs + adjustment parameters
}
```

Do not use UI display names as the only persistent identity for referenced profiles.

---

# Focused Develop Controls

General photo editing is secondary.

Initial useful controls may include:

- exposure
- contrast
- highlights
- shadows
- white point
- black point
- tone curve
- saturation
- vibrance
- crop
- rotate
- sharpening
- noise reduction

Do not build generic editor features ahead of infrared functionality.

A feature enters the core roadmap only when it materially improves the infrared workflow.

---

# Rendering

Start with a correct implementation.

Measure before optimizing.

CPU implementations are acceptable when they are:

- easier to validate
- easier to test
- fast enough during early development
- useful as reference implementations

Metal is appropriate when measurement shows meaningful benefit.

Potential Metal candidates include:

- channel matrices
- color matrices
- curves
- LUTs
- exposure
- saturation
- preview compositing

Do not move code to GPU merely because GPU code appears desirable.

When Metal is introduced:

1. keep shader interfaces explicit
2. avoid hidden global state
3. validate CPU vs GPU output where practical
4. use consistent numeric ranges
5. document texture formats
6. avoid repeated CPU ↔ GPU transfers
7. keep business logic out of shaders
8. never couple SwiftUI directly to shader calls

---

# Preview Rendering

Interactive preview must prioritize responsiveness while preserving processing semantics.

Do not require full-resolution decode merely to create the first useful preview.

Valid strategies may include:

```text
RAW
 ├── fast / reduced-resolution preview path
 └── full-quality render path for export or detailed inspection
```

A cached full-resolution decode is also acceptable if measurement shows it is appropriate.

That strategy is now decided, and it is the first of the two branches. The interactive workspace holds a **reduced-resolution scene-linear working representation** and re-renders only that; the RAW file plus `ImageAdjustments` remains the source of truth, and the reduced preview is a disposable cache derived from the pair. The reduction happens once, immediately after the camera-to-working transform and before the first creative stage, by exact area-weighted averaging of scene-linear Float32 values. The size rule lives in one value type, `PreviewResolutionPolicy`, and caps the longest edge of the unoriented image. See `docs/decisions/0015-reduced-resolution-preview.md`.

The retained reduced preview is **pre-creative**: the reduction is the last thing that has happened to it. That is what makes a creative mix adjustable at all — a mix is applied to those values, never composed onto a previous mix — and it is enforced by the types rather than by a runtime check. The reduced domain has two image types, one for each side of the creative stage, so `M2 × (M1 × preview)` does not compile.

What a document retains is therefore **two** buffers, not one: the full-resolution normalised mosaic — the input to the white-balance chain, and the only full-resolution thing anything keeps — and the reduced pre-mix preview. That is a deliberate, stated exception to "nothing full-resolution survives preparation", and its justification is the alternative: re-reading and re-normalising a twelve-megapixel file on every neutral-patch click, for two stages that do not depend on the patch at all. The mosaic is retained only after an open has actually produced an image.

A CFA mosaic is never resized by a general image filter. Neighbouring mosaic samples are different colours, so an ordinary downscale averages across colour filters and destroys the pattern semantics a demosaicer depends on. Reduce only after the representation has become ordinary multi-channel image data, unless a deliberately CFA-aware algorithm with a proven invariant and tests exists — and none does.

The invariant is:

> preview and final rendering represent the same adjustments even when resolution, demosaicing quality, caching, or implementation strategy differs

Avoid decoding the RAW file again after every slider movement.

Any material preview-vs-export differences must be documented and tested. The resolution is one such difference and is now permanent: preview pixels are never export truth, and a full-resolution render re-runs from the RAW file rather than from a retained preview buffer. That path exists — `FullResolutionExportPipeline` — and takes a `URL` plus one `ImageAdjustments` and nothing else, so no preview, preview policy or `CGImage` can reach it. The differences that remain are named in `docs/decisions/0018-full-resolution-tiff-export.md`: resolution, range policy, bit depth and destination. Everything else is the same code.

The architecture should not prevent future before/after or split-preview modes.

---

# Concurrency and Memory

RAW decoding and image processing must not freeze the main thread.

Use Swift Concurrency and prefer structured concurrency.

Do not annotate entire processing engines with `@MainActor`.

Avoid unnecessary detached tasks.

Obsolete preview renders must be genuinely cancellable when users change
parameters rapidly, not merely discardable. A full-frame stage is one
synchronous pass with no suspension point, so `Task.cancel()` alone stops
nothing: a stage that can be superseded takes an explicit
`ProcessingCancellation`, polls it at a documented granularity, and throws
`CancellationError` rather than returning a partially written buffer.
Cancellation is not a processing failure and must never be reported as one.

There are two expensive costs per document, and each has its own coalescing
slot of the same generic type: the **fast** one re-renders the retained reduced
preview, and the **heavy** one re-prepares that preview from the retained
normalised mosaic when the white balance changes. Two slots, because "at most
one at a time" is a claim each has to make about itself. A heavy preparation
that lands is followed by a render of the **latest** complete state, so an
exposure changed while a patch was being prepared is in the result rather than
a stop behind it. See `docs/decisions/0019-interactive-white-balance.md`.

Rapid parameter changes coalesce. At most one expensive render works at a
time **per document**, a burst collapses to the newest requested state, and no
historical state is rendered on the way there — the scheduling counterpart of
adjustments being canonical state rather than command history. See
`docs/decisions/0011-coalesced-preview-rendering.md`.

Opening another file does not cancel a render whose result a user's decision
depends on. A document the workspace leaves keeps its render slot until the
state it was asked for has settled, and may then do one thing only: write its
own sidecar. For that interval, and only that interval, two documents' renders
can overlap.

Two generations of one RAW file share one sidecar, so they are serialised: an
older generation of a file must never write after a newer generation of that
same file has read or written it. Reopening a file therefore waits for that
file's older generation to finish writing, and only that case waits — two
different files have two different destinations and race over nothing. Prefer
removing such an overlap to arbitrating it with a written-generation
comparison. See `docs/decisions/0014-adjustment-lifecycle.md`.

An open document holds one reduced scene-linear buffer, not a chain. Nothing full-resolution may be reachable from what the workspace retains: the mosaics, the camera-native image and the full-resolution working-colour image go out of scope when preparation returns, which is why an ADR 0014 file-switch overlap of two retained sources is affordable. Use the bare-image stage overloads after the reduction; the wrapper overloads exist to keep a whole upstream chain reachable, and that is exactly what must not survive into a retained value.

Treat memory usage as a first-class engineering constraint.

Avoid:

- unnecessary full-resolution copies
- repeated RGB buffer conversions
- unbounded preview caches
- accidental retention of intermediate buffers

When adding a new full-frame buffer, be able to explain why it is necessary.

Measure before introducing complex pooling or cache systems.

---

# Export

Initial export targets:

- TIFF 16-bit
- JPEG
- PNG

High-quality export must never reuse an 8-bit display preview as its source.

Preview and export may use different performance strategies while preserving processing semantics.

Every export path must choose an explicit output color space and embed an appropriate color profile where supported.

Do not overwrite an existing file without explicit user intent.

RAW source files must never be modified.

The first of those targets exists. **16-bit TIFF export restarts from the RAW
file**: an export is a `URL` plus one complete `ImageAdjustments`, rendered
again at the sensor's own resolution through the same primitives the preview
uses, and there is no API through which a preview, a preview policy or a
`CGImage` could reach it. The export path shares the RAW front half
(`RAWWorkingImagePipeline`), the three adjustment stages, the exposure
arithmetic (`SceneLinearExposure`) and the transfer function
(`SRGBTransferFunction`) with the preview; it differs only in resolution, in
its own range policy, and in quantising to 16 bits rather than 8. Bit depth is
not range: a normalised integer TIFF still needs an explicitly decided, counted
clip. The pixels are physically oriented and the file's orientation tag is
therefore `1`. Nothing is written to the destination until a complete file has
been encoded somewhere disposable. An export is an artefact, never an edit: it
does not write the sidecar, and a failed save does not block it. See
`docs/decisions/0018-full-resolution-tiff-export.md`.

---

# Error Handling and Logging

Use typed errors where reasonable, for example:

```text
unsupportedRAWFormat
corruptRAWFile
decoderFailure
unsupportedCamera
renderFailure
exportFailure
invalidProfile
```

Do not silently ignore processing failures.

Use `OSLog` instead of scattered `print()` statements.

Useful categories:

- RAW
- infrared
- rendering
- export
- UI

Never log image buffers.

Be cautious with potentially sensitive file paths.

---

# Testing Strategy

Image-processing code must be testable independently of the UI.

## Verification tiers

Two settings, answering two questions that do not imply each other:

```text
INFRARED_TEST_ORF            where the RAW fixture is
INFRARED_RUN_RAW_FIXTURES    whether the expensive real-RAW suites run
```

**The presence of a RAW fixture is not consent to decode it.** A file sitting
at `RAW/OLYMPUS.ORF` must never change what `swift test` costs or what it runs.
That rule lives in exactly one place, `RAWFixtureMode`, and every fixture-backed
suite gates on it.

```text
Tier 1   swift test                                    seconds
Tier 2   INFRARED_RUN_RAW_FIXTURES=1 swift test --filter <suite>
Tier 3   INFRARED_RUN_RAW_FIXTURES=1 swift test        minutes
```

Tier 1 is the standard milestone verification command. Reach for Tier 2 only
when the change touched RAW decoding, normalisation, white balance,
demosaicing, working-colour conversion, channel mixing, orientation, display
encoding or export — and then run the one suite that covers it. Tier 3 is for
major pipeline work and release validation.

Do not spend fifteen minutes decoding an ORF to verify a change that cannot
reach the RAW path.

Requesting Tier 2 or 3 with no fixture to be found is a **failure**, not a
skip: silent skips must never add up to a passing extended run.

See `docs/testing.md`.

## Unit tests

Important examples:

- white-balance multiplier math
- CFA/color-plane multiplier mapping
- channel swap
- channel matrix
- matrix composition
- numeric-range handling
- clipping rules
- profile decoding
- schema-version handling
- recipe serialization and migration

## RAW decoder tests

For known RAW samples verify:

- dimensions and active area
- camera model
- useful precision / bit depth
- CFA or color-layout information
- black levels
- white levels
- metadata extraction
- decoder-side operation state
- decoded numeric sanity

## Stage-by-stage fixtures

For selected RAW files or synthetic mosaics, validate intermediate stages where practical:

```text
raw samples
→ normalized mosaic
→ white-balanced mosaic
→ demosaiced representation
→ camera / sensor interpretation
→ IR capture-profile adjustment
→ IR color transform
→ final working representation
```

The purpose is to localize failures to a stage rather than merely discovering that the final image looks wrong.

Synthetic CFA fixtures are encouraged for deterministic tests.

## Reference rendering tests

Where practical, maintain deterministic reference outputs.

Prefer measurable tolerances such as:

- maximum absolute error
- mean absolute error
- PSNR
- per-channel error

Do not require bit-identical GPU output unless the algorithm guarantees it.

Avoid tests that require launching the entire application when the processing unit can be tested directly.

---

# Test Assets

RAW files can be large.

Do not casually commit personal photo archives to Git.

Possible strategies:

- small curated test set
- Git LFS
- externally stored optional test assets
- generated synthetic CFA data

The reference dataset should eventually include multiple brands and especially:

- Olympus E-PL3 ORF

Avoid copyrighted or privacy-sensitive sample images unless their use is clearly permitted.

---

# Development Strategy

Build vertically in small, reviewable steps.

Do not build the entire architecture before proving the RAW path.

Recommended sequence:

## Phase 1 — App shell

- native macOS SwiftUI app
- open file
- drag and drop
- basic workspace
- metadata display

## Phase 2 — RAW decoder

- LibRaw integration
- Olympus E-PL3 ORF
- metadata
- sensor dimensions
- CFA / color-layout description
- decoded buffer
- explicit decoder-operation state

## Phase 3 — Minimal RAW render

- black level
- white level
- white balance
- demosaic
- useful RGB/working preview

## Phase 4 — IR white balance

- direct multipliers
- foliage/custom sampling
- reproducible settings

## Phase 5 — IR transformations

- capture/filter profile
- channel swap
- channel mixer
- basic IR color transform

## Phase 6 — Interactive rendering

- responsive preview
- Metal only where justified

## Phase 7 — Export

- TIFF 16-bit
- JPEG
- PNG
- explicit output color handling

## Phase 8 — Focused develop tools

Only after the infrared path works end-to-end.

---

# Version 1 Definition

Version 1 does not need to compete with Lightroom.

A successful early version should:

1. launch as a native macOS application
2. open an Olympus E-PL3 ORF
3. decode it with explicit RAW pipeline semantics
4. render a useful preview
5. apply IR-capable white balance without conventional Kelvin limitations
6. apply a channel transform
7. provide at least one useful IR filter/capture-profile workflow
8. adjust basic exposure
9. export a high-quality TIFF/JPEG with explicit output color handling
10. reproduce the same versioned settings on another image

Everything else is secondary until this works reliably.

---

# Documentation and ADRs

`CLAUDE.md` defines project invariants and agent behavior.

Detailed and experimentally changing technical design belongs in `/docs`.

Create documentation only when it has content; do not create empty files merely to match a tree.

Likely documents:

```text
docs/
├── architecture.md
├── raw-pipeline.md
├── infrared-pipeline.md
├── color-management.md
├── camera-profiles.md
├── filter-profiles.md
├── calibration-protocol.md
├── testing.md
└── decisions/
```

Use lightweight ADRs for decisions that would be expensive to reverse.

Examples:

```text
docs/decisions/0001-use-libraw.md
docs/decisions/0006-working-color-space.md
docs/decisions/0025-metal-render-pipeline.md
```

The working-representation decision must be recorded before production IR color transforms depend on it. It is, in `docs/decisions/0006-working-color-space.md`. The creative channel-mix stage that depends on it is `docs/decisions/0007-infrared-channel-mixing.md`, the display boundary that turns its result into pixels is `docs/decisions/0008-display-preview-rendering.md`, the geometry stage between them is `docs/decisions/0009-application-owned-orientation.md`, and the user-owned orientation adjustment composed onto that is `docs/decisions/0010-user-owned-orientation-adjustment.md`.

How those re-renders are scheduled and cancelled is `docs/decisions/0011-coalesced-preview-rendering.md`. That the application-owned pipeline and the LibRaw processed-RGB reference are independent paths, neither gating nor substituting for the other, is `docs/decisions/0012-independent-raw-paths.md` — whose amendment defines the open boundary: a file is open when a path produced an **image**, and a prepared scene-linear state is not one.

Where the user's adjustments are kept between sessions, how an open reads them before it renders, and when a state earns the right to be written, is `docs/decisions/0013-adjustment-sidecar.md`. How one adjustment is tracked from the button press to the disk — pending, saved, refused by the render, refused by the write — and what happens to it when the user leaves the photograph mid-render, is `docs/decisions/0014-adjustment-lifecycle.md`.

That the interactive workspace re-renders a **reduced** scene-linear rendition rather than the sensor's own, where in the pipeline it is reduced and why not a step either side of that, why a CFA mosaic is never resized, and what the RAW file plus its canonical adjustments still are, is `docs/decisions/0015-reduced-resolution-preview.md`.

That the creative channel mix is a canonical **user adjustment**, that the retained preview is therefore pre-mix, that the mix moved from `prepare` to `render` and forms one complete render state with the orientation, that the reduced domain has two image types so mixes cannot compose, and that the sidecar schema is at version 2 with a tested version 1 migration, is `docs/decisions/0016-interactive-channel-mixer.md` — whose amendment makes schema dispatch exhaustive and refuses a built-in mix that carries a matrix.

That exposure is the third canonical user adjustment and the first continuous one, that it is applied by the existing display-stage primitive as `× 2^EV` before the range policy, that its persisted range is `−10…+10 EV` while the slider offers `−4…+4`, that a slider drag is handled by the existing coalescing renderer with no debounce, and that the sidecar schema is at version 3 with tested version 1 and 2 migrations, is `docs/decisions/0017-interactive-exposure.md`.

That the full-resolution export restarts from the RAW file with the same canonical adjustments, that preview and export share the RAW front half and every adjustment stage and diverge only at resolution, range policy, bit depth and destination, why the exposure arithmetic and the sRGB transfer function each became one shared primitive, why a 16-bit integer TIFF still needs an explicit counted clip, why the pixels are oriented and the orientation tag is `1`, and why an export is a snapshot that neither waits for a preview nor writes a sidecar, is `docs/decisions/0018-full-resolution-tiff-export.md`.

That a reusable capture profile is a different kind of state from a photograph-local adjustment, that a photograph's canonical state became the pair `capture-profile reference + ImageAdjustments`, that identity is a validated namespaced string rather than a display name or a path, that a profile's camera, conversion and filter are metadata while only its processing basis reaches a pixel, that an unresolvable or mismatched profile refuses the open rather than being substituted, that the registry holds definitions while the sidecar holds a reference, that the sidecar schema is at version 5 with a nested payload and tested version 1 to 4 migrations to `builtin.uncalibrated` proven pixel-neutral, that schema ownership moved off `ImageAdjustments`, that preview and export are handed the same resolved profile, and that a profile change costs a re-preparation only when its processing basis differs, is `docs/decisions/0020-ir-capture-profile-foundation.md`.

That those definitions are now persisted — one JSON file per profile, named by its validated identifier, under an application-owned Application Support folder, at a profile schema version of its own that is independent of the sidecar's — that the registry became a composition of built-in and user profiles which refuses a duplicate identity rather than resolving it, that it is replaced rather than mutated through one owner (`IRCaptureProfileLibrary`) which is the only thing that reads that folder, that only `uncalibratedSensorRGB` has a wire format so `.explicitMatrix` stays runtime-only and a persistence attempt is a typed refusal rather than a silent downgrade, that identity is generated and never derived from the display name while `builtin.` is reserved in both directions, that a corrupt profile costs one profile and is reported rather than swallowed, that editing a definition is an immutable replacement which changes what every referencing photograph resolves to but touches no adjustment and rewrites no sidecar, that a render writes the sidecar only when it settles a pending decision, and that a missing or mismatched profile still refuses the open and now offers an explicit recovery to the built-in uncalibrated profile, is `docs/decisions/0021-user-capture-profile-library.md`.

That the infrared white balance is a canonical **user adjustment** recorded as the neutral region a person picked rather than as the gains it produced, that the workspace retains the normalised mosaic so a new patch costs no decode, that the heavy re-preparation and the fast render are separate coalescing slots whose landing order is resolved in favour of the newest complete state, that the export resolves the same intent from the file rather than from any workspace cache, that the coordinate road from a click to a sensor coordinate depends on the layout and the orientation and on nothing else, that `isIdentity` is retired in favour of `isDefault`, and that the sidecar schema is at version 4 with tested version 1, 2 and 3 migrations to the historical centred patch, is `docs/decisions/0019-interactive-white-balance.md`.

That calibration evidence is a first-class artefact rather than a matrix, that measurement evidence and the fitted result are separate things with separate identities so a refit rewrites no history, that the camera, conversion and filter a calibration was measured against are snapshotted by value rather than referenced through a mutable profile, that responses are measured as per-colour-plane means of the normalised mosaic before demosaicing and the two green planes are collapsed by a named reversible rule, that a calibration session has its own neutral reference which is never a photograph's white balance, that clipped patches are excluded rather than averaged in, that the solver refuses degenerate data instead of emitting coefficients and applies no offset, no regularisation and no weighting, that per-patch residuals are stored while every other metric is derived from them, that validation status is derived and this project establishes no acceptance criteria so nothing is validated, that calibrations persist as one file each in their own folder at a schema version independent of the profile and sidecar schemas, and that no capture profile becomes calibrated and `.explicitMatrix` is not promoted, is `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`. Its amendment makes the artefact verify its own matrix: constructing a calibration — from a fresh fit or from a file, which is one code path — re-derives the transform from the stored evidence and reference dataset through the one fitter, refuses it unless the stored matrix, residuals, conditioning and sample count agree under one central tolerance, refuses a fit method this build cannot reproduce rather than carrying it unverified, requires one residual per fitted patch rather than a matching set of patch identities, and refuses a neutral reference the evidence excluded — which the evidence may still record, because a measurement is a fact and an exclusion is a judgement about it. Its second amendment closes two rules that were stated against the wrong quantity: a neutral reference may contain **no** clipped sample at all, independent of the general clipping tolerance, because that tolerance bounds what a patch *contributes* while the neutral reference *decides* the white balance of every fitted patch; and calibration evidence now records the sensor's **colour-plane signature** — the ordered `plane -> channel` list read once from the layout at the moment of measurement — so a plane absent from every patch can no longer be invisible, every included patch is complete against it, an incomplete patch may exist only as explicitly excluded evidence that names exactly the planes it lacks, and the calibration schema is at version 2 with version 1 refused rather than migrated, since every source for the missing signature would be an invention. Self-verification is stated more carefully there too: material changes to fit-determining values without recomputing the fit are refused, which proves internal consistency and is not cryptographic tamper protection, provenance or authorship. Its third amendment closes the two rules the arithmetic cannot state: reference values are defined **under** an illuminant, so a fit and a calibration artefact both refuse a pair whose two recorded illuminant identities are not exactly the same — one authority, `IRCalibrationIlluminantCompatibility`, asked by the fitter, by `IRCalibration` and defensively by the verifier, each throwing its own typed refusal from one shared explanation — and no spectral equivalence is inferred in either direction, because this project reads no SPD and a measured SPD is an identifier rather than a spectrum; `.unknown` matched against `.unknown` stays constructible and stays `experimental` through the existing evidence gap, and nothing derives a standard illuminant from it. An illuminant identity must also say something: `namedOther` and `measuredSPD` are trimmed and refused when empty — an empty measured SPD would report `isMeasured` while pointing at no measurement — and after trimming the identity is exact and case-sensitive, validated once in `IRCalibrationIlluminant.validated(field:)` and called by the two boundaries that create evidence, which is the path persistence decodes through. And a reference dataset identity is produced by one pair only: `@` is refused inside `identifier` and `version`, so `a@b`+`c` and `a`+`b@c` can no longer both name `a@b@c`; the grammar, the wire shape and calibration schema version 2 are unchanged. Its human-executable companion is `docs/calibration-protocol.md`.

That a person can now author the creative 3×3 mix, that the editor produces `UserChannelMixAdjustment.explicit` through `RAWColorMatrix3x3` and hands it to the same `setChannelMix` the built-ins use so there is no second matrix type, no second persisted representation and no second mixer, that the editing state is nine strings in `ChannelMixMatrixDraft` because half-typed text is not a coefficient and a field bound to a `Double` would write a zero over the canonical mix, that non-finiteness is refused by the matrix primitive's own typed error rather than by a rule restated in the editor, that nothing clamps a coefficient, normalises a row, preserves luminance or refuses a singular matrix, that rows stay output channels and columns stay input channels with the three equations printed rather than transposed for convenience, that an authored matrix stays `.explicit` even when its nine numbers equal a built-in's because provenance is what the person did, that no schema version, pipeline order or scheduling changed and a second authored matrix replaces the first from the retained pre-mix preview, and that the white-balance gains are now labelled per colour plane by `RAWWhiteBalanceGainListing` — planes from `RAWWhiteBalanceEstimator.colorPlanes(in:)` so a listing cannot describe a set the estimate did not measure, identities from the layout's `colorDescription` so nothing assumes RGGB, both greens of an `RGBG` sensor kept separate, and the layout carried on `WorkspacePreview` as the provenance the labels are read from — is `docs/decisions/0023-authoring-a-creative-channel-mix.md`.

That a creative channel mix authored for one photograph is now reusable, that a preset is a named `UserChannelMixAdjustment` and never a second mixer, matrix type or persisted mix representation, that applying one is a single assignment into the existing `DocumentState.setChannelMix` so no code below the menu is preset-aware, that `IRChannelMixSource` gains no `.preset` case because where a person found a matrix is not a property of the matrix, that the photograph sidecar is unchanged at schema version 5 and stores the **resolved** decision rather than a reference — so renaming, editing or deleting a preset cannot change an image already developed with it, and an unreadable preset library leaves every photograph rendering exactly as it was — that applying is always explicit and nothing is ever applied because a capture profile names the same nominal wavelength as a preset's filter note, that the filter note is the same `IRFilterDescriptor` used for capture context and takes part in no arithmetic or selection, that this build ships **no** presets because no measured basis for a 590/665/720/830 nm matrix exists here while `builtin.` is reserved against one appearing dishonestly, that presets live in their own Application Support folder under their own schema version with the capture-profile library's file rules — one file per preset, the filename is the identity, a corrupt file costs one preset and is reported, and a duplicate identity is refused rather than resolved by load order — that there is no registry type because nothing resolves a preset reference, that a capture profile's filter is a save-form **prefill** copied once and never a binding, and that a preset carries the mix alone because a neutral patch, an exposure and an orientation are photograph-local, is `docs/decisions/0024-reusable-creative-presets.md`.

The verification tiers, the two fixture environment variables and why having a
RAW file is not consent to decode it are in `docs/testing.md`.

ADR numbers are assigned in the order decisions are actually made; do not reuse a number that is already taken.

If implementation evidence invalidates a design hypothesis in this file, do not silently work around the contradiction. Update the relevant documentation and deliberately update `CLAUDE.md` if an invariant itself changes.

---

# Git and Pull Request Rules

Work in small branches.

Prefer one coherent feature or fix per branch.

Examples:

```text
feat/raw-decoder
feat/orf-epl3-support
feat/ir-white-balance
feat/channel-mixer
feat/metal-preview
fix/raw-black-level
```

Commits should describe meaningful changes and leave the project buildable where practical.

Do not rewrite unrelated files.

PRs should be small enough to review.

Every non-trivial PR should explain:

```markdown
## What changed

## Why

## Architecture impact

## Testing

## Known limitations

## Screenshots / visual evidence
```

Include screenshots for UI changes where appropriate.

Processing changes should include numeric or reference-image evidence where practical.

---

# Coding Style

Prefer straightforward, idiomatic Swift.

Favor:

- value types where appropriate
- explicit types at architectural boundaries
- small focused functions
- immutable data where practical
- dependency injection where testing requires it
- protocols only where they provide real value

Avoid:

- premature abstraction
- giant service objects
- singleton-heavy architecture
- global mutable state
- deeply nested callbacks
- excessive generics
- unnecessary third-party libraries

YAGNI applies.

---

# Instructions for Claude Code

## Agent Orchestration and Token Efficiency

The primary Claude Code session should use **Opus 5 as the orchestrator** and delegate well-scoped implementation work to **Sonnet 5 subagents** where this reduces cost or preserves the main context.

The goal is not to maximize delegation. The goal is to minimize expensive reasoning, duplicated context, and unnecessary agent turns while preserving correctness.

### Opus 5 responsibilities

Use the main Opus 5 session for:

- architecture and system-design decisions
- task decomposition and sequencing
- RAW-pipeline and color-science reasoning
- decisions involving uncertain image-processing semantics
- changes that would be expensive to reverse
- review of technically sensitive diffs
- integration decisions across multiple modules
- deciding whether a task should be delegated at all

Opus should act as the technical lead and orchestrator rather than implementing every routine change itself.

### Sonnet 5 implementation subagents

Prefer Sonnet 5 subagents for coherent, well-defined work such as:

- routine Swift implementation
- localized bug fixes
- focused refactoring with an already-decided design
- unit and integration tests
- profile or serialization code
- straightforward UI implementation that does not define processing semantics

An implementation subagent should normally own the complete small work package:

```text
inspect relevant code
        ↓
implement requested change
        ↓
add or update tests
        ↓
run relevant build/tests
        ↓
return concise result
```

Do not split one coherent task into separate agents for inspection, implementation, testing, and reporting unless those parts are genuinely independent.

### Do not delegate trivial work

Do not spawn a subagent when:

- one or two direct repository/tool operations are sufficient
- the task is a very small edit
- only a filename, symbol, or text occurrence must be located
- delegation would require copying substantial context into the subagent
- the next task depends immediately on an unresolved decision in the current task

Prefer direct tools or lightweight repository exploration for simple searches and inspection.

### Keep the hierarchy flat

Use the main Opus session as the single orchestrator.

Subagents should execute assigned work, not act as secondary project managers. Do not create unnecessary chains of delegation.

### Parallelism

Do not maximize parallelism.

Run Sonnet subagents in parallel only when their tasks are genuinely independent and do not require shared, evolving design decisions.

Good parallel candidates:

- separate test modules
- independent profile parsers
- unrelated localized fixes

Bad parallel candidates:

- defining a new API in one task while another task simultaneously implements against that undecided API
- two agents editing the same subsystem without a stable boundary
- multiple agents independently exploring the same problem

When tasks are sequentially dependent, execute them sequentially.

### Context discipline

Pass a subagent only the context required for its task.

A delegated task should state:

- objective
- allowed scope
- relevant files or modules when known
- important architectural constraints
- acceptance criteria
- required tests

Do not paste large sections of repository documentation into every subagent prompt when the agent can read the authoritative file directly.

### Subagent result format

Subagents must return concise implementation summaries rather than narrative work logs.

Preferred format:

```text
Changed:
- ...

Tests:
- ...

Decisions:
- none | ...

Issues:
- none | ...
```

The main Opus session should inspect the actual diff and relevant test output directly instead of asking the subagent to restate the implementation in detail.

### Review model selection

Routine code-quality review may be delegated to Sonnet 5.

Use Opus 5 for final review when a change affects any of the following:

- RAW decoding semantics
- black/white-level handling
- CFA interpretation or demosaicing assumptions
- infrared white balance
- camera or IR calibration transforms
- working-space or color-management decisions
- clipping/highlight behavior
- render-pipeline ordering
- concurrency architecture
- public interfaces that would be expensive to change later

### Effort and turn limits

Use the lowest reasoning effort and turn budget that is appropriate for the task.

Do not give a routine implementation agent an unnecessarily large reasoning budget. Increase effort only for work that has demonstrated complexity or ambiguity.

A task that cannot be clearly scoped for Sonnet should remain with Opus until the architectural uncertainty has been resolved.

## Before coding

1. Read this `CLAUDE.md`.
2. Read relevant files under `docs/`.
3. Inspect the current implementation before proposing changes.
4. Check existing tests.
5. Do not assume a subsystem exists merely because this document describes it.

## Before implementing a substantial feature

State:

- proposed approach
- affected modules
- important assumptions
- expected tests

Keep the approach as small as possible.

## While coding

- stay within requested scope
- do not refactor unrelated code
- preserve architectural boundaries
- add or update tests
- keep processing logic outside UI
- avoid unnecessary dependencies
- prefer correctness over cleverness

## When image-processing math is uncertain

Do not invent constants.

Do not silently approximate undocumented color transforms.

Do not rely on undocumented decoder defaults for processing semantics.

Instead:

- state the uncertainty
- isolate the assumption
- document it
- keep the implementation replaceable
- add a test or diagnostic path
- verify with a reference image or measurable data where possible

## Before declaring work complete

Run the relevant build and tests:

```text
1. swift build
2. focused tests for the components changed
3. swift test                                     (Tier 1)
4. if RAW-sensitive code changed, the relevant targeted real-RAW suite:
   INFRARED_RUN_RAW_FIXTURES=1 swift test --filter <suite>
5. the extended real-RAW suite only for major pipeline work or release
   validation
```

Report:

```text
Build:
Tests:
Warnings:
Known limitations:
Files changed:
```

Do not claim tests pass unless they were actually executed. Say which tier was
run: a Tier 1 result is not evidence about real-camera integration, and
reporting it as though it were is the failure mode the tiers exist to prevent.

---

# Scope Guard

If a task asks for one feature, do not opportunistically implement several adjacent features.

For example, if asked to add E-PL3 ORF metadata decoding, do not also redesign the UI, add export, build a preset system, or rewrite the renderer.

If broader restructuring appears genuinely necessary, explain why before making the change.

---

# Architectural Red Flags

Pause and reconsider when code begins to show any of these patterns:

- RAW logic inside SwiftUI
- filter-specific `if` statements scattered through UI
- duplicate color math
- 8-bit intermediate processing
- implicit color spaces or working representations
- unconditional clamping of intermediate floats to `0...1`
- visible-light camera matrices treated as automatically valid for IR
- hidden LibRaw processing that duplicates application stages
- Bayer/RGGB assumptions leaking into general RAW abstractions
- large mutable global image state
- one class controlling decode, edit, preview, and export
- camera/filter presets hard-coded into rendering functions
- a cancellation check placed after the work it was meant to prevent
- a processing stage returning a partially written buffer when cancelled, or
  reporting cancellation as a processing failure
- a queue of pending renders, or any structure that replays superseded
  adjustment states
- the LibRaw processed-RGB path gating, or standing in for, the
  application-owned pipeline
- a diagnostic reference whose failure closes the workspace
- an open reported as successful when no path produced a displayable image
- a successful expensive preparation mistaken for a successful render
- adjustability derived from a retained buffer rather than from a render that
  actually succeeded
- a control offered for an adjustment that is known to refuse
- an error flattened to a string where the typed value could have survived
- a persisted record whose publicly constructible values do not round-trip
- a schema version that is settable application state rather than wire-format
  metadata
- an image-affecting persisted field added without a schema-version bump, or
  an older client reading around a newer version
- orientation applied inside a colour stage, corrected by a view transform, or not applied at all
- a decoder's orientation integer travelling through the pipeline instead of an application-owned type
- an unreadable orientation value silently treated as upright
- a user's orientation correction written back into `RAWMetadata`, or metadata and user intent sharing one field
- an orientation applied on top of an already-oriented buffer instead of re-derived from the unoriented source
- a user adjustment stored as a list of button presses rather than one canonical state
- unreadable persisted adjustment state silently recovered as "no adjustment"
- a RAW file opened for writing, or a user decision recorded anywhere but the sidecar
- a sidecar name built by string concatenation somewhere other than the one place that owns the rule
- an identity render performed on open and then replaced by the saved state
- an adjustment persisted before it is known to render, or a superseded render writing one
- an unreadable sidecar recovered as "no adjustments", repaired, or deleted
- a sidecar failure reported as a RAW decoding failure
- a successful render withdrawn because saving it failed
- a persistence state that describes the last write rather than the adjustment on screen
- a state reported as saved while its render is still running
- several booleans standing in for one closed state enum
- a user's decision discarded because they opened another file, with nothing said
- a delivery routed to a document by its path rather than by which open it belongs to
- two generations of one RAW file able to write its sidecar in either order
- a newly opened file reading a sidecar an older generation of it is about to change
- a queue of deferred opens, or a superseded open still able to install a preview
- generic resizing of a CFA mosaic, or any reduction of mosaic samples that mixes colour-filter positions
- an 8-bit or display-encoded image used as an editing source, or a display `CGImage` resized and edited from
- the full-resolution scene-linear image kept alive only because the UI may rotate again
- an interactive adjustment that reruns RAW decode, normalisation, white balance, demosaicing or the reduction
- preview pixels treated as export truth, or an export path that starts from a retained preview buffer
- exporting from a `WorkspacePreview`, its `CGImage`, or anything else the interactive path retains
- upscaling the reduced preview for final output
- an export path with its own independent channel-mix, exposure or transfer-function arithmetic
- passing a `PreviewResolutionPolicy`, a preview image or a preview `Source` into full-resolution export
- double-applying orientation through permuted pixels plus a TIFF orientation tag that is not `1`
- quantising to 8 bit, or through a display buffer, anywhere on the way to a 16-bit export
- writing directly into the final destination before the encode has succeeded, so a failure leaves a plausible-looking file
- an export using the last durable sidecar state instead of the current canonical adjustments
- an export that waits for a preview render in order to reuse its pixels
- an export that writes the sidecar, or a save failure that blocks an export
- a bit depth treated as a range, so that "16-bit" is taken to mean scene-linear values need no range policy
- a reduced buffer wearing a full-resolution type, so that only `width < sensorWidth` distinguishes them
- a preview size chosen inside a processing stage, or hard-coded anywhere but the size policy
- a reduction performed after the creative channel mix, baking one mix into the retained buffer
- retaining an already-mixed preview as the source for an adjustable mixer
- composing a new IR mix onto a previously mixed preview
- saving orientation and channel mix independently, or a render request naming one adjustment rather than the complete state
- first rendering identity and then applying a saved channel mix
- rerunning decode, demosaicing or the reduction for a channel-mix change
- automatically assuming an opened RAW is infrared, or choosing the red/blue swap without a person asking
- an interactive stage that does not poll cancellation at the documented granularity on every one of its paths
- an image-affecting persisted field slipped into an existing schema version, or a migration that guesses rather than stating what the absent field meant
- schema-version decoding through a `default` or other catch-all case, rather than an exhaustive switch over a closed version type
- a built-in persisted channel mix carrying matrix coefficients that are silently ignored
- an image-affecting field added to an existing schema version with `decodeIfPresent` and a default
- an exposure slider directly manipulating rendered pixels, a display buffer or a `CGImage`
- a continuous adjustment bypassing the complete-state coalescing renderer, or given its own timer, debounce or queue
- clamping scene-linear exposure results before the display stage's explicit range policy
- first rendering `0 EV` and then restoring a saved exposure
- a second exposure primitive beside `SceneLinearExposure`, or exposure arithmetic in a view, in `DocumentState`, or copied into an encoder
- a saved exposure outside the slider's range silently changed because a control displayed it
- full RAW decode on every slider move without measurement or caching rationale
- applying interactive white balance as downstream RGB gains on the reduced preview, just to avoid re-preparing — a single green multiplier cannot reproduce a demosaic that averaged two independently balanced green planes
- per-channel white-balance gains composed onto a preview that already carries the previous gains
- persisting preview, view or window coordinates for a neutral patch, or persisting the estimated gains as the record of the decision
- re-decoding the RAW file for every white-balance picker change when the normalised mosaic is already retained
- retaining the normalised mosaic for a file whose open never produced an image
- a normalised mosaic retained alongside the decoded `UInt16` buffer it replaced
- a hidden default neutral patch inside a shared pipeline or a processing stage, rather than an explicit resolved region
- a second white-balance resolver or estimator on the export path
- saving a white-balance adjustment before its complete preview renders successfully
- letting a superseded white-balance preparation replace the current reduced source, install a preview or write a sidecar
- re-requesting an in-flight preparation for a state that is already being prepared, so a second control restarts it
- rendering the state a patch was picked with rather than the latest complete state once the preparation lands
- export using workspace cached pixels or a retained mosaic instead of RAW plus the canonical white-balance intent
- a saved white-balance patch first rendering with the default centred patch
- mixing transient picker-drag or picker-armed state into `ImageAdjustments`
- mapping a click onto the whole SwiftUI frame rather than through the aspect-fitted image rectangle
- clamping a click outside the displayed image to the nearest edge instead of ignoring it
- a picker mapping that consults the channel mix, the exposure or the preview resolution
- a whole-record `isIdentity` that claims "no net effect on the image" once a default stage has a visible effect
- putting `captureProfile` inside `ImageAdjustments`, or a neutral patch, a rotation or an exposure inside a capture profile
- calling a camera/filter profile calibrated merely because it has a nominal wavelength, a camera name or a conversion vendor
- treating a nominal 720 nm filter label as a measured spectral response, or matching profiles by wavelength
- inventing an IR camera-to-working matrix without measured evidence, or labelling any matrix calibrated without it
- persisting an entire reusable profile definition in every photograph's sidecar instead of a stable reference
- silently falling back to another profile when a referenced profile is missing, or opening a photograph under a profile the user did not choose
- auto-selecting a profile from a filename, a camera model or EXIF metadata without user intent
- letting preview and export resolve different capture profiles, or an export resolving one from a registry after it has started
- applying profile recommendations continuously, so a later user edit is overwritten by a profile selection
- allowing a preview prepared under profile A to install after the document switched to profile B
- deciding what a profile change costs from a UI assumption rather than from its processing basis
- a capture-processing decision that is a static constant inside a processing type rather than a resolved profile's choice
- a schema version, or any persistence metadata, living on `ImageAdjustments` rather than on the record the sidecar holds
- a sidecar record with two authorities for one field — adjustments both nested and at the top level
- persisting a user capture-profile definition into every photograph sidecar instead of a stable reference
- allowing user profiles to claim or overwrite `builtin.*` identities
- making `IRCaptureProcessingBasis` `Codable` wholesale, and thereby giving `explicitMatrix` a file format by accident
- silently downgrading an unpersistable processing basis to `uncalibratedSensorRGB` instead of refusing it
- labelling a user-created profile calibrated because a person named a filter, a wavelength, a camera or a conversion vendor
- deriving a stable profile identifier from a mutable display name, a file path, or anything else a rename can change
- silently choosing one definition when two profile files claim the same identity, or discarding a whole library because one file is corrupt
- reporting a corrupt or unreadable profile file as nothing at all, so a profile a person created vanishes without a word
- silently falling back to `builtin.uncalibrated` when a photograph references a missing user profile, rather than refusing and offering an explicit recovery
- editing a reusable profile and copying its metadata into `ImageAdjustments`, or letting any profile operation change a white balance, orientation, mix or exposure
- rewriting a photograph's sidecar because a profile's *definition* changed, when its canonical state did not
- reading the profile directory from `DocumentState`, or holding more than one registry per process
- replacing the in-memory registry before the write that caused it has returned, so memory and disk disagree after a reported success
- using the real Application Support directory from tests, or resolving it by building a path from the home directory
- writing a profile file non-atomically, or creating the profile directory merely to read an empty library
- a profile filename and payload that may disagree, so one definition can be stored at another profile's address
- a "Calibrated" checkbox, a matrix field, or any control by which a user asserts a validation the project has not performed
- calling a 3×3 matrix a validated calibration without stored measurement evidence
- making `explicitMatrix` the persisted calibrated case, or giving it a wire format so that a measured transform has somewhere to go
- storing only a matrix and discarding the target, the illuminant and the residuals
- using 8-bit, sRGB-encoded, clipped or preview pixels for calibration fitting
- fitting from clipped calibration patches, or tolerating a clipped sample because re-photographing the chart was inconvenient
- baking a photograph-local neutral patch into a reusable profile calibration
- treating a nominal 720 nm label as a measured spectral response, or matching a calibration to a profile by wavelength
- using mutable profile metadata as the only description of what a calibration was measured against
- a boolean `isValidated` flag that can disagree with the evidence, or a status stored rather than derived
- silently falling back to uncalibrated processing when a referenced calibration artefact is missing
- fitting measurement evidence recorded under one illuminant against reference values defined for another, or a calibration artefact assembled in memory carrying such a pair
- inferring that a measured SPD reference "is" a standard illuminant because its file name says so, or matching two lamp names by lowercasing, trimming inside, or any other fuzzy rule
- deriving a standard illuminant from `.unknown`, or refusing `.unknown` against `.unknown` instead of letting the existing evidence gap keep it experimental
- an illuminant compatibility rule written as an `==` at each call site rather than asked of the one authority, or a second definition of it inside the verifier
- a calibration illuminant identity that is empty or whitespace, especially a `measuredSPD` reference that reports `isMeasured` while pointing at no measurement
- a second, parallel illuminant representation, or illuminant validation on the persistence path separate from the domain boundary that creates the evidence
- a reference dataset identifier or version containing the `@` that joins them, so two different pairs can name one identity
- escaping or silently rewriting a person's dataset identifier instead of refusing it
- a calibration neutral reference carrying a clipped sample that the general clipping tolerance happened to include, so a censored value sets the white balance of the whole transform
- a clipping policy whose threshold or tolerance cannot describe a decision about samples, so "nothing clipped" and "nothing measurable" look alike
- calibration evidence that never states which colour planes the sensor produced, so a plane missing from every patch is invisible and a four-plane layout fits as three
- a colour-plane expectation inferred from the patches, from the first patch, or from an assumption that four planes mean RGGB
- an included calibration patch missing a plane the recorded signature expects, or a patch plane relabelled to another channel
- an incomplete calibration patch carried as included evidence, or an exclusion naming planes other than the ones actually absent
- a calibration schema version read around, migrated by reconstructing evidence it never carried, or accepted as equivalently verified
- a claim that self-verification makes a calibration tamper-proof, authentic or attributable, rather than internally consistent
- a calibration whose residual list does not correspond to the patches it claims to have fitted
- comparing residual patches to fitted patches as *sets*, so one patch carrying two residuals passes while doubling its weight in every derived metric
- a stored matrix, residual list or conditioning figure accepted without being re-derived from the evidence stored beside it
- a second implementation of the fit arithmetic written to check the first, so that when the two disagree nothing can say which is right
- a persisted fit whose algorithm or version this build cannot reproduce, accepted under an "unverified" status invented to hold it
- a float comparison tolerance for calibration numbers invented at a call site, or one wide enough to admit an edit a person could make and mean
- a calibration session's neutral reference used for the gains after the evidence excluded it, so unusable data sets the white balance of the whole transform
- `gains[plane] ?? 1`, or any silent identity gain, where an active white-balance policy defines no gain for a plane
- an error metric stored beside the residuals it is derivable from, so the two can disagree
- a solver that stabilises ill-conditioned data with an undocumented prior instead of refusing it
- an acceptance threshold invented because it sounded small, rather than justified by measurements and recorded in an ADR
- automatic chart detection, or any calibration input a person did not deliberately mark
- calibration evidence written into a photograph sidecar, or a calibration and a profile sharing one schema, one folder or one counter
- a second matrix type, persisted representation or mixer introduced for the sake of a mixer UI
- a coefficient field bound directly to a number, so clearing a cell writes a zero over the canonical mix
- a half-typed coefficient resolved to zero, or a partially valid draft committed as an adjustment
- a non-finite coefficient filtered out in the editor instead of being refused by `RAWColorMatrix3x3`
- normalising a row, preserving luminance, clamping a coefficient or refusing a singular matrix a person deliberately typed
- transposing the matrix convention for the editor, so the sidecar and the grid disagree about which cell is `m01`
- collapsing an authored matrix into `.identity` or `.redBlueSwap` because its nine numbers happen to match
- a reusable preset that carries its own matrix type or persisted mix representation, rather than the `UserChannelMixAdjustment` the sidecar already stores
- a preset applied anywhere but through `DocumentState.setChannelMix`, or composed onto the mix already in force
- an `IRChannelMixSource` case, or any other provenance, invented to record that a matrix came from a preset
- a photograph sidecar storing a preset identifier, name or reference instead of the resolved channel mix
- a preset rename, edit or deletion that reaches a photograph, rewrites a sidecar, or leaves an image unable to open
- a preset applied automatically — on open, from a filename, from EXIF, or because a capture profile names the same nominal wavelength as its filter note
- a creative matrix shipped under a wavelength name without stated provenance for its nine coefficients, or a menu populated so that it does not look empty
- a preset treated as calibrated, or `isValidatedInfraredCalibration` asserted rather than derived, because a preset names a filter
- a white-balance gain, a neutral-patch region, an exposure or an orientation persisted into a reusable preset
- a preset library and a capture-profile library sharing a folder, a suffix, a schema counter or a loader
- a preset identity derived from its display name, or a user preset claiming `builtin.`
- a save form's filter field bound to a capture profile's filter, so that editing the profile later rewrites a saved preset
- a second matrix editor, or a second filter-draft parser, added for the preset form
- a white-balance gain labelled from a hard-coded `R G B G` table, or from any assumption that four planes mean RGGB
- a gain listing that walks the CFA cell itself, so it can describe a different set of planes than the estimator measured
- an unused gain slot shown as `×1.000`, so a plane the sensor never fills reads as a measured plane needing no correction
- plane labels read from the open document's metadata rather than from the preview whose gains they describe
- an expensive real-RAW suite enabling itself because a fixture happens to exist, so `swift test` costs minutes on one machine and seconds on another
- fixture *location* and fixture *execution* decided by one setting, or by seventeen independent `ProcessInfo` lookups instead of one authority
- an explicit request for the real-RAW suites answered with silent skips and a green run, so a misconfiguration reads as successful integration coverage
- an unrecognised value for the fixture-mode flag folded into "off" rather than reported
- a Tier 1 result reported as evidence about real-camera integration
- raising an asynchronous test's timeout to absorb contention caused by fixture work running beside it
- the same twelve-megapixel frame decoded once per test in a suite whose tests all consume the identical immutable value
- a shared fixture cache that a test can mutate, or one that replaces isolation in a suite whose claim is about the filesystem
- the binary RAW fixture committed to Git, or CI made dependent on private local fixture data
- every feature depending directly on LibRaw
- direct Metal shader calls from UI views
- tests requiring the entire app to run

Fix the boundary rather than normalizing the smell.

---

# Guiding Product Principle

When choosing between:

> building another generic photo-editor feature

and

> making infrared RAW processing significantly easier, more predictable, or better defined

choose the infrared workflow.

Infrared Converter succeeds by being exceptionally good at one specialized task.
