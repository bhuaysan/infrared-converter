# 0002 — RAW black subtraction and normalisation to Float32

Status: accepted
Date: 2026-09-09

> Numbering note: `CLAUDE.md` names `0002-working-color-space.md` as an
> expected ADR. That decision is downstream of demosaicing and is still
> undecided; it will take the next free number when it is made. This ADR took
> `0002` because it is the decision that actually had to be recorded first.

## Context

Until now the project's application-owned pipeline had no processing stages at
all. `LibRawDecoder.decodeMosaic(at:)` produces a `RAWMosaic`: LibRaw-unpacked
`UInt16` samples, active area only, with nothing subtracted, normalised,
balanced or interpolated. Every later stage — infrared white balance,
demosaicing, channel transforms — needs a defined numeric domain to operate in,
and that domain does not exist yet.

This ADR records the first two application-owned stages, and the three choices
inside them that would be expensive to reverse: what "1.0" means, what happens
to values outside `0...1`, and where the black level comes from.

## Decision 1 — Float32 is the first application-owned representation

`LinearRAWMosaic` holds one `Float32` per CFA location, black-subtracted and
normalised. It is still a mosaic: one value per sensor position, the same
width, height, active-area origin and CFA mapping as the `RAWMosaic` it came
from. It is not an RGB image and must never be described as one.

Storage is `[Float]`, tightly packed and row-major. `Data` was the right
container for `RAWMosaic` because that type wraps bytes copied out of a C
buffer; here the element type is ours, so `[Float]` puts it in the type,
gets bounds-checked indexing from the standard library instead of hand-written
byte arithmetic, removes any byte-order reinterpretation, and still hands a
contiguous buffer to a future Metal upload.

`Double` is deliberately not used for image buffers. The reference frame is
12.3 million samples; `Float32` is 49 MB, `Double` would be 99 MB for no
demonstrated accuracy benefit at this stage.

The source `RAWMosaic` is never mutated. It stays reachable on
`ProcessedRAWMosaic.source`, so the unpacked `UInt16` values remain available
for diagnostics and for reprocessing under a different policy without decoding
the file again.

## Decision 2 — The default white level is `RAWMetadata.Levels.maximum`

`RAWWhiteLevelPolicy.metadataMaximum` is the only policy, and it reads
`Levels.maximum` from the same post-unpack RAW state the samples came from.

Two plausible alternatives were rejected:

- **`2 ^ sourceRawBitDepth - 1`.** The source bit depth is file-format
  information: how wide a sample was before LibRaw touched it. `unpack()` may
  apply a format-specific linearisation curve that moves samples out of that
  nominal range, and LibRaw updates `maximum` when it does. Deriving a white
  level from the bit depth would silently mis-scale any such camera. It is
  also not universally a literal bit depth — see "Consequences".
- **`Levels.linearMaximum`.** Per-plane linearity / specular / calibration
  limits, whose meaning depends on the camera's own metadata. It is not
  universally the saturation white point. For the E-PL3 it is `3680` against a
  `maximum` of `4095`; normalising against it would push everything above
  `3680` past 1.0 and misrepresent the frame's actual headroom.

`linearMaximum` stays available as metadata. It may later inform linearity
warnings, highlight diagnostics, or an explicit alternative white-level policy.
None of that is in scope here, and it is never read by this stage.

The policy is a typed enum rather than a hardcoded read precisely so that
adding an alternative later is a visible change at the call site, not a silent
change of meaning for every image already processed.

## Decision 3 — Nothing is clamped

For each sample, with `black` the effective black level at that coordinate and
colour plane and `white` the policy's white level:

```text
value = (Float(sample) - Float(black)) / Float(white - black)
```

Values below `0` and above `1` are produced and preserved exactly.

- **Negatives are real data.** Sensor noise straddles the black point. The
  E-PL3 reference frame contains 11 samples below the effective black level;
  after normalisation they are 11 negative values, the smallest
  `(61 - 64) / 4031 ≈ -0.000744`. Clamping them to zero would bias every
  statistic computed around black, which is exactly the region an infrared
  white-balance stage has to reason about.
- **Values above 1 are highlight information.** Clipping them here would make
  highlight handling impossible later. Highlight reconstruction, if it is ever
  built, is its own explicit and independently testable stage.

This stage performs normalisation, not tone mapping. `RAWLinearProcessing`
records `clamped = false` as a `let` constant, so the fact is a property of the
type rather than a claim in a comment.

## Decision 4 — Effective black comes from `Levels.blackLevel(row:column:colorPlane:)`

The black model is never reconstructed by this stage. It calls the accessor,
which sums the global `black`, the per-plane offset for the sample's colour
plane, and any repeating black-pattern contribution.

The consequence that matters: **how the effective black is split between those
terms is irrelevant to the output.** LibRaw's `unpack()` canonicalises the
common component of `cblack[0...3]` into `black`, so the E-PL3 reads as
`black 0, perPlane [64, 64, 64, 64]` before unpack and
`black 64, perPlane [0, 0, 0, 0]` after. Both describe an effective black of
64, and both produce bit-identical output from this stage. That is tested, not
assumed.

The colour plane comes from the mosaic's own `SensorColorLayout`. A layout that
cannot name a plane for a coordinate is a typed error, not a fallback to global
black.

## Decision 5 — Processing failures are their own error type

`RAWProcessingError` is separate from `RAWDecodingError`. The decoder boundary
describes what LibRaw could do with a file; these describe our own arithmetic
refusing to run on decoded input. Sharing one type would blur the boundary the
pipeline is built around and would make a processing bug read like a file
problem in the UI.

Decoded metadata is treated as untrusted. A white level that is not above the
effective black level has no normalisation denominator, and is reported as
`invalidNormalizationRange` with the white level, the black level, and the
coordinate and plane where it was found. It is never silently replaced with a
different white level: that would change what every value in the image means
without saying so.

## What this stage does not do

No white balance of any kind, no demosaicing, no colour matrix, no gamma, no
orientation, no clipping, no highlight reconstruction. Each is recorded as
`false` on `RAWLinearProcessing`.

## Consequences

- The pipeline now has a defined linear domain to build infrared white balance
  on, and that stage will operate on the mosaic before demosaicing.
- Downstream stages must be written to tolerate values outside `0...1`.
  Anything that needs a bounded range must clip explicitly and say so.
- `sourceRawBitDepth` is documentation and diagnostics only. It is worth
  recording why the wording around it was softened alongside this change:
  LibRaw's `raw_bps` behaves as source bits-per-sample for most cameras,
  including the reference fixture, but for some formats (Phase One among them)
  it can carry a RAW format code rather than a literal bit depth. Since no
  processing behaviour is built on it, that ambiguity costs nothing here — but
  the documentation must not claim more than LibRaw guarantees.
- 49 MB per full-resolution frame of processed output, one owned allocation,
  written once. Reduced-resolution preview strategies are unaffected: they
  would produce a smaller mosaic through the same stage.
