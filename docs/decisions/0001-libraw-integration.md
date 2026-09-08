# 0001 — LibRaw integration, C++ interoperability, and decoder configuration

Status: accepted
Date: 2026-09-08
Amended: 2026-09-08 — LibRaw 0.21.4 → 0.22.2, vendor/shim target split, and
three corrections to what this ADR claimed the boundary guaranteed. The three
decisions themselves are unchanged; see "Amendments" at the end.

## Context

Infrared Converter needs to decode RAW files from cameras that the macOS system
RAW decoder does not necessarily support, including older bodies such as the
reference camera (Olympus PEN E-PL3, `.ORF`). LibRaw is the obvious choice, but
three decisions have to be made explicitly because they are expensive to reverse:

1. how LibRaw enters the build,
2. how its C++ API reaches Swift,
3. what LibRaw is allowed to do to the pixels before we see them.

The third is the one that matters most for this project: infrared work needs
extreme white balance and non-standard colour transforms, so the decoder must
not bake in colour decisions calibrated for visible light.

## Decision 1 — Vendor LibRaw source into the package

LibRaw sources are vendored under `Sources/CLibRawVendor/` and built as an
ordinary SwiftPM C++ target. (Originally LibRaw 0.21.4 under
`Sources/CLibRaw/vendor/`; now 0.22.2 — see Amendments.)

Alternatives considered:

- **Homebrew `libraw` via a `systemLibrary` target.** Rejected. It needs a
  manual install step, hardcodes an architecture-specific prefix
  (`/opt/homebrew` vs `/usr/local`), requires `pkg-config` (not present on a
  Command Line Tools-only machine), and cannot be shipped in an app bundle
  without a separate bundling step.
- **A binary XCFramework.** Rejected for now. It would need its own build and
  release process before we have a reason for one.
- **A third-party SwiftPM wrapper package.** Rejected. LibRaw publishes no
  official SwiftPM package, and depending on an unofficial one adds maintenance
  risk to the single most load-bearing dependency in the project.

Vendoring gives reproducible builds, no manual setup, plain `swift build`
compatibility, no architecture-specific paths, and a CI setup that is just
`swift build && swift test`.

Cost: LibRaw updates are a deliberate vendor refresh. The procedure and the
exact deviations from the upstream tarball are recorded in
`Sources/CLibRaw/VENDOR.md`.

Licensing: LibRaw is dual-licensed LGPL-2.1 / CDDL-1.0; both licence files are
kept alongside the vendored source. Static linking under LGPL-2.1 obliges us to
let recipients relink against a modified LibRaw. Publishing this repository,
including the unmodified vendored source, satisfies that today. **Before
distributing a binary outside this repository**, confirm the chosen licence
(CDDL-1.0 has no relinking obligation) and state it in the application's
about/licence surface.

## Decision 2 — A plain-C shim, not Swift/C++ interoperability

Swift talks to LibRaw through one hand-written C header,
`Sources/CLibRaw/include/libraw_shim.h`, implemented by
`Sources/CLibRaw/shim/libraw_shim.cpp`. That `.cpp` file is the only place in
the project that includes `libraw/libraw.h`.

Swift/C++ interoperability was rejected because it would require
`-cxx-interoperability-mode=default` on the application target, exposing
LibRaw's class hierarchy, `std::` types and iostreams-based datastreams to every
Swift file in the module, and tying the build to a toolchain feature that is
still evolving. The shim is roughly 300 lines and gives a stable, POD-only
surface: an opaque context, a status struct, an options struct, a metadata
struct and an image descriptor.

The shim also translates LibRaw's integer error codes into a small classified
enum while preserving the original code and message, so the application's error
model never carries an opaque integer to the UI. (The Swift side did leak the
code into user-facing text despite this; corrected — see Amendments.)

## Decision 3 — Decoder configuration makes no irreversible colour decision

LibRaw's defaults are tuned for producing a finished visible-light JPEG. Almost
all of them are wrong for us. `ir_libraw_default_options` sets, explicitly:

| LibRaw parameter | Value | Reason |
| --- | --- | --- |
| `output_bps` | 16 | never process at 8 bit |
| `output_color` | 0 (raw) | **no** colour-matrix conversion; camera-native RGB |
| `gamm[0]`, `gamm[1]` | 1.0, 1.0 | linear output, no transfer function |
| `use_camera_wb` | 0 | do not bake in as-shot white balance |
| `use_auto_wb` | 0 | do not bake in an automatic white balance |
| `user_mul` | 1, 1, 1, 1 | **unity** multipliers, so LibRaw's daylight pre-multipliers are not applied either |
| `use_camera_matrix` | 0 | no embedded camera matrix |
| `no_auto_bright` | 1 | no automatic exposure scaling |
| `bright` | 1.0 | no brightness scaling |
| `highlight` | 0 (clip) | no undocumented highlight reconstruction |
| `adjust_maximum_thr` | 0.0 | disable LibRaw's automatic saturation-level tweak |
| `threshold`, `fbdd_noiserd`, `med_passes` | 0 | no noise reduction or median filtering |
| `four_color_rgb`, `green_matching`, `exp_correc` | 0 | no channel manipulation |
| `user_black`, `user_sat` | -1 | use the camera's own levels, do not override |
| `user_qual` | 3 (AHD) | demosaicing, see below |
| `user_flip` | -1 | honour the camera's recorded orientation (geometric only) |

Setting `user_mul` to unity is the subtle one. With `use_camera_wb` and
`use_auto_wb` both off but `user_mul` left at zero, LibRaw falls back to its own
`pre_mul` daylight multipliers — a visible-light colour decision, silently
applied. Unity multipliers prevent that.

What LibRaw still does, and what the boundary therefore reports in
`RAWDecoderProcessing`:

- **Black-level subtraction** and a **linear scale** so the camera's saturation
  level maps to 65535. Both are documented, reversible from metadata, and must
  not be repeated by our pipeline.
- **Demosaicing** (AHD by default), because this milestone hands back an RGB
  buffer. This is the one operation we would rather own. A later milestone that
  consumes the mosaic directly will replace it; the decoder already reports the
  CFA layout needed for that.
- **Camera orientation**, applied geometrically when requested.

`RAWDecoderProcessing` states each of these as a fact about the returned buffer,
so no application stage is ever applied twice.

## Consequences for infrared work

- The buffer is camera-native linear RGB. No visible-light matrix has touched
  it, so the infrared colour engine can define its own transform from a known
  starting point.
- Camera and daylight white-balance multipliers are exposed as *metadata only*.
  `RAWMetadata.ColorMetadata` documents `rgbFromCamera` and `cameraFromXYZ` as
  visible-light calibrated; they must not be assumed valid for infrared capture.
- White balance is unconstrained. Nothing at this boundary clamps multipliers to
  a conventional Kelvin range, and nothing clamps intermediate values.
- The remaining obstacle to fully custom infrared processing is decoder-side
  demosaicing. Removing it means consuming `imgdata.rawdata` instead of
  `dcraw_process`, which the shim can grow without changing the Swift API.


## Amendments

### A1 — LibRaw 0.22.2, and a two-target build

The vendored tree is now **LibRaw 0.22.2** under `Sources/CLibRawVendor/`, and
the single `CLibRaw` target has been split in two:

```text
InfraredConverter (Swift)  →  CLibRaw (our shim)  →  CLibRawVendor (upstream)
```

The original target applied `-w` to upstream *and* to `libraw_shim.cpp`, so
warnings in code we own were invisible. The vendor target keeps `-w`; the shim
target builds with `-Wall -Wextra` and compiles clean. Swift still sees only the
shim's plain-C surface.

Upgrading required no source changes and no new defines. The 0.22.2 tree only
adds files relative to 0.21.4, so the exclusion list carried over after being
re-checked. One define was *removed*: `NO_LCMS`, which 0.22 derives itself and
which now warns if defined explicitly.

The E-PL3 fixture reproduces every recorded 0.21.4 value exactly (see the
README table). Decision 3's parameter table is unaffected.

### A2 — What the boundary preserves was overstated

Three claims in this ADR were stronger than the implementation:

- **Black levels.** The boundary preserved `black`, `cblack[0...3]` and the
  black pattern's *dimensions*, but discarded the pattern *values* in
  `cblack[6...]`. It now carries the complete model. Note that our metadata is
  read straight after `open_file()`, i.e. before `LibRaw::adjust_bl()` folds
  `black` into the per-plane offsets — so the terms are kept separate and
  combined explicitly by `Levels.blackLevel(row:column:colorPlane:)`. A
  consumer that pre-sums them differently will be wrong.
- **User-facing decoder codes.** Decision 2 claims the error model "never
  carries an opaque integer to the UI". It did: `DecoderDiagnostic.description`
  embedded the code and the failure view rendered it. Every user-facing string
  surface is now code-free; `logDescription` is the loggable form.
- **Warnings.** `RAWDecoderProcessing.warnings` existed but was never
  populated, which is worse than absent — it implied a capture that was not
  happening. It is now a typed set decoded from `process_warnings`, mapping
  only flags this build can raise.

### A3 — CFA coordinates are active-image coordinates

`SensorColorLayout.colorPlaneIndex(row:column:)` documented its coordinates as
raw-readout coordinates. That was wrong, and would have produced a
margin-sized origin error the moment a camera with non-zero margins met the
mosaic pipeline.

The convention is **active-image coordinates**, chosen because the processing
pipeline will operate on the active-area mosaic, and because it is what LibRaw
itself uses: `fcol()` adds `top_margin`/`left_margin` before indexing the 16×16
table, and `identify.cpp` builds the exposed `xtrans` table from the
sensor-absolute `xtrans_abs` with those margins already folded in.

The consequence worth stating plainly: **margins are accounted for exactly once,
by LibRaw, before we see `filters` or `xtrans`.** This API must not add them
again. Tests with non-zero margins exist specifically to fail if it ever does.

### A4 — What `dcraw_process` actually does

Decision 3 lists what LibRaw still performs. Two refinements:

- **Orientation** is applied only when requested *and* when the camera recorded
  a non-zero flip. The provenance record now separates the request from the
  outcome; previously it reported a transform whenever handling was enabled,
  including for the E-PL3, whose flip is 0.
- **Black subtraction and scaling** happen inside `dcraw_process` via
  `adjust_bl()` and `subtract_black_internal()`, which also *mutate*
  `imgdata.color` (zeroing `cblack` and `black`). Our metadata snapshot is
  taken before that, so `RAWMetadata.Levels` describes the file, not the
  post-process state. This matters for the mosaic milestone, which will want
  the pre-process values.
