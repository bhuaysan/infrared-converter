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

This architecture must make undo/redo, presets, recipes, batch processing, parameter comparison, and future sidecars possible without modifying source data.

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

The working representation is established **before** the infrared channel/color transform, not after it. That ordering was originally hypothesised the other way round; implementation showed that a creative channel mix is only meaningful once the RGB axes it remixes are defined, so the stage operates inside the working representation and leaves it unchanged. See `docs/decisions/0006-working-color-space.md` and `docs/decisions/0007-infrared-channel-mixing.md`.

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

Creative infrared channel mixing is a **third** decision, distinct from both. It operates inside the working representation, leaves the color space unchanged, and carries its own provenance as creative intent — never as camera calibration, white balance, working-space establishment or filter calibration. That decision is recorded in `docs/decisions/0007-infrared-channel-mixing.md`.

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

Potential modes:

- Camera WB
- Auto IR
- Foliage
- Neutral target picker
- Custom sampled point
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

The invariant is:

> preview and final rendering represent the same adjustments even when resolution, demosaicing quality, caching, or implementation strategy differs

Avoid decoding the RAW file again after every slider movement.

Any material preview-vs-export differences must be documented and tested.

The architecture should not prevent future before/after or split-preview modes.

---

# Concurrency and Memory

RAW decoding and image processing must not freeze the main thread.

Use Swift Concurrency and prefer structured concurrency.

Do not annotate entire processing engines with `@MainActor`.

Avoid unnecessary detached tasks.

Obsolete preview renders should be cancellable when users change parameters rapidly.

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
├── testing.md
└── decisions/
```

Use lightweight ADRs for decisions that would be expensive to reverse.

Examples:

```text
docs/decisions/0001-use-libraw.md
docs/decisions/0006-working-color-space.md
docs/decisions/0009-metal-render-pipeline.md
```

The working-representation decision must be recorded before production IR color transforms depend on it. It is, in `docs/decisions/0006-working-color-space.md`. The creative channel-mix stage that depends on it is `docs/decisions/0007-infrared-channel-mixing.md`, and the display boundary that turns its result into pixels is `docs/decisions/0008-display-preview-rendering.md`.

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

Run the relevant build and tests.

Report:

```text
Build:
Tests:
Warnings:
Known limitations:
Files changed:
```

Do not claim tests pass unless they were actually executed.

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
- full RAW decode on every slider move without measurement or caching rationale
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
