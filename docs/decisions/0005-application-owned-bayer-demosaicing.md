# 0005 — Application-owned bilinear Bayer demosaicing

Status: accepted
Date: 2026-09-10

## Context

[ADR 0002](0002-raw-normalization.md) established the first application-owned
processing stage, [ADR 0003](0003-infrared-white-balance.md) the apply half of
infrared white balance and [ADR 0004](0004-neutral-patch-white-balance-estimation.md)
its first producer of gains. All three operate on the CFA mosaic: one value per
sensor location, colour known only through the sensor layout.

This ADR crosses the boundary out of the mosaic domain. It decides who owns
demosaicing, what representation it produces, and exactly what that
representation does and does not mean.

```text
WhiteBalancedRAWMosaic          ← mosaic domain ends here
        ↓
application bilinear Bayer demosaic
        ↓
DemosaicedRAWRGBImage           ← linear camera-native RGB
        ↓
[FUTURE: camera-native RGB → working colour space]
```

## Decision 1 — Demosaicing is application-owned and does not call LibRaw

`RAWDemosaicer` imports no `CLibRaw`, receives no LibRaw context, and calls
nothing in LibRaw. The white-balanced Float32 mosaic is never converted back
into LibRaw structures, never routed through `dcraw_process`, and no new shim
entry point was added for demosaicing.

This is the same reasoning as ADR 0002. The moment interpolation happens inside
the decoder, its border behaviour, its clamping and its arithmetic become
things this project inherits rather than defines, and every one of them is a
property the tests in this milestone assert.

`RAWDecodeOptions.Demosaic` is **not** this. It selects one of LibRaw's own
algorithms on the legacy processed-RGB path, where LibRaw also applies black
levels, white balance, a colour matrix and gamma. The two are deliberately
separate types with separate names, and the legacy path stays intact as
existing functionality and as a diagnostic.

## Decision 2 — The input is `WhiteBalancedRAWMosaic`

Not `LinearRAWMosaic`, and there is no overload that takes one. White balance
therefore **structurally** precedes demosaicing.

Interpolating first would mean averaging samples whose relative scaling is not
yet correct. On the reference camera it would be worse than that: the two green
CFA positions are separate colour planes that can receive different gains, so a
pre-balance mean of neighbouring greens would mix two differently-scaled
quantities and no later per-plane multiplication could undo it.

A caller who genuinely wants no white balance applies
`RAWWhiteBalanceGains.identity`, which leaves every finite value bit-identical
and records that fact in provenance. Identity is a valid answer; skipping the
stage is not a reachable one.

## Decision 3 — The first algorithm is bilinear Bayer, as a reference implementation

`RAWDemosaicAlgorithm` has exactly one case, `.bilinearBayer`. Cases are added
when the algorithm exists, never before: a case for an unimplemented algorithm
would let a caller select something that silently falls back to another one.

Bilinear was chosen for being exactly specifiable and hand-checkable, not for
image quality. It produces the zippering and colour fringing every naive
bilinear demosaicer produces. **This ADR does not claim it is the algorithm
this project will ship**; it claims the mosaic → camera-native-RGB boundary is
now correct, testable, and able to accept a better algorithm without changing
the output representation.

Explicitly not implemented, and not stubbed: AHD, VNG, PPG, DCB, AMaZE,
edge-directed interpolation, X-Trans demosaicing, Foveon processing,
full-colour DNG handling, chroma-noise reduction, false-colour suppression,
sharpening and highlight reconstruction.

## Decision 4 — Only a genuine repeating 2×2 Bayer RGB mosaic is supported

`layout.pattern == .bayer` is **not** the check. That flag says the decoder
packed a CFA code into `filters`; it does not say the code describes something
a 2×2 algorithm may run on. `RAWBayerCellPattern.resolve(from:algorithm:)`
establishes, in order:

1. the layout is `.bayer` at all;
2. `filters != 1`, LibRaw's non-standard 16×16 layout, whose table this project
   does not carry;
3. every position of the **complete packed cell** — 8 rows × 2 columns, the
   extent the `filters` code addresses — names a colour plane;
4. every named plane index is addressable in `colorDescription`;
5. every letter is `R`, `G` or `B`;
6. rows 2 through 7 restate the first two rows' colours exactly;
7. the 2×2 cell holds exactly one red, exactly one blue and exactly two greens.

Step 6 is the one that is easy to skip and expensive to get wrong. A four- or
eight-row CFA demosaiced as 2×2 would produce a plausible image with
systematically wrong colour rather than an obvious failure, so it is proven
rather than assumed.

It compares **colours, not plane indices**, deliberately. A cell whose lower
rows swap which green *plane* sits in which corner still repeats every 2×2 as
far as this stage is concerned: the two green planes were already told apart by
white balance, upstream, and each green sample is copied into output green
wherever it sits. A cell whose lower rows put a different *colour* somewhere is
refused.

Anything refused raises
`RAWProcessingError.unsupportedSensorLayoutForDemosaicing`, carrying the
pattern, the algorithm that refused it, and a reason.

## Decision 5 — The Bayer phase is discovered, never hardcoded

The 2×2 semantic pattern is resolved from the layout's own
`colorPlaneIndex(row:column:)` and `colorDescription`. `RGGB`, `BGGR`, `GRBG`
and `GBRG` are all supported, all tested, and none is special-cased. The
reference camera's phase is not baked in anywhere.

Nothing here re-derives LibRaw's CFA decoding. The layout's accessor is the
single implementation of that, and this walks it.

## Decision 6 — `colorDescription` maps plane indices to semantic R/G/B

A colour-plane index is a slot number, not a colour. `colorDescription` is what
says which colour each slot is, and it is consulted for every reachable index.

Only `R`, `G` and `B` participate. LibRaw's `cdesc` can also carry `E`
(emerald, on RGBE sensors) and `C`/`M`/`Y`, and those are refused rather than
folded onto the nearest RGB channel: a four-filter or subtractive mosaic is not
a Bayer RGB mosaic, and pretending otherwise would invent colour.

Consequently a three-plane Bayer layout, whose two greens share plane index
`1`, and a four-plane `RGBG` layout, whose greens are planes `1` and `3`,
resolve to the same `R/G/G/B` cell. Both are supported.

## Decision 7 — G1 and G2 become one output channel but stay independent samples

This is the invariant most easily lost at this boundary, so it is stated
precisely.

Both green CFA positions map to the single output green channel. They are
**not** merged, averaged, renormalised or reconciled as planes. Specifically:

| Location | Output green |
| --- | --- |
| A G1 location | that location's own G1 white-balanced sample, exactly |
| A G2 location | that location's own G2 white-balanced sample, exactly |
| A red or blue location | the spatial mean of its in-bounds green neighbours, which normally includes both kinds |

There is no global G1/G2 reconciliation stage, and adding one would undo the
per-plane gains the white-balance stage deliberately kept separate. The
independence is tested through the real white-balance stage with four distinct
gains, and on the fixture, where planes 1 and 3 genuinely receive different
estimated gains.

## Decision 8 — Native CFA values are preserved exactly

At every location, the channel the CFA actually measured is the source sample
copied straight across — never averaged with anything, and never routed through
`Double` and back. Its `Float32` bit pattern survives, negative zero included.

Only the two reconstructed channels are computed.

## Decision 9 — The interpolation rules, stated once

```text
at a red location:    R = the native sample
                      G = mean of the in-bounds AXIAL   green neighbours (N S W E)
                      B = mean of the in-bounds DIAGONAL blue  neighbours (NW NE SW SE)

at a blue location:   B = the native sample
                      G = mean of the in-bounds AXIAL   green neighbours
                      R = mean of the in-bounds DIAGONAL red   neighbours

at a green location:  G = the native sample
                      R = mean of the in-bounds AXIAL   red   neighbours
                      B = mean of the in-bounds AXIAL   blue  neighbours
```

A contributor counts only if it is in bounds **and** its own CFA location
carries the colour being reconstructed. For a green location that resolves to
one horizontal pair and one vertical pair, but which is which follows from the
discovered phase: the two green positions in a Bayer cell have opposite
orientations, and both are handled by the same rule rather than by two
hardcoded cases.

## Decision 10 — Borders average only their available contributors

One policy, and it is not reflection, wrapping, edge duplication or cropping. A
corner red location has two axial green neighbours rather than four, and one
diagonal blue neighbour rather than four, and its means are over two and over
one accordingly. No out-of-bounds sample is pretended into existence.

**Every input CFA location produces exactly one output pixel**, borders
included. The image is never trimmed to the region with complete
neighbourhoods.

A channel with *no* valid contributor — reachable only for pathological
geometry such as a 1×1 mosaic, a single row or a single column — raises
`RAWProcessingError.missingDemosaicNeighbors` carrying the row, the column and
the missing channel. Zero is never invented. A 2×2 valid Bayer cell is
demosaicable; a 1×1 mosaic is not.

The consequence, recorded so nobody later reads it as a bug: bilinear
interpolation reproduces an affine field exactly wherever the neighbourhood is
symmetric, which is the interior, and does not at the borders. The tests assert
that property in the interior only.

## Decision 11 — Interpolation accumulates in `Double`; storage stays `Float32`

At most four contributors are summed in `Double`, divided in `Double`, and
narrowed once to `Float`.

The reason is specific, and it is not general precision anxiety:

```text
Float.greatestFiniteMagnitude + Float.greatestFiniteMagnitude   → overflow
their average                                                   → representable
```

Summing in `Float32` would manufacture a failure out of the summation itself,
for data that has a perfectly good mean. Accumulating in `Double` removes that
artefact. It is **not** a reason to store anything in `Double`: there is no
`Double` staging buffer, and the output is `Float32` throughout.

## Decision 12 — Nothing is clamped

Not to `0...1`, not per pixel, not per image, not per channel. Finite negative
values — real black-subtracted sensor noise — stay negative, and values above
`1` stay above `1`. Interpolated values are arithmetic means, so they can land
outside the range too, and they are kept.

No exposure adjustment, no normalisation, no green rebalancing, no highlight
reconstruction.

A non-finite input sample, native or contributor, raises
`RAWProcessingError.nonFiniteInputValue` with the offending coordinate rather
than being skipped; skipping would quietly change the denominator of a mean. A
non-finite result raises `nonFiniteDemosaicResult` rather than being clamped.

## Decision 13 — Output is tightly packed, interleaved, three `Float32` per pixel

```text
R G B  R G B  R G B ...

base = (row * width + column) * 3
```

`[SIMD3<Float>]` is deliberately not the storage type. `SIMD3<Float>` may carry
a 16-byte stride even though it holds three floats, which for the E-PL3 would
turn a 148 MB buffer into 197 MB, a third of it padding. The storage contract
is exactly three `Float32` per pixel, and the tests assert the raw array
ordering rather than only what the accessor returns.

`RAWLinearRGBPixel` exists for handing one pixel back to a caller and is never
stored.

For the reference camera:

```text
4056 × 3040 × 3 × 4 bytes = 147 962 880 bytes ≈ 148 MB
```

## Decision 14 — Output is linear camera-native RGB, not a colour space

The values are the **linear responses of this sensor's three filter colours**,
resolved through `colorDescription`. They are specifically not sRGB, not linear
sRGB, not Display P3, not Adobe RGB, not ProPhoto RGB, not CIE XYZ, not ACES,
and not any other device-independent RGB. Two cameras' `red` values are not
comparable, and writing this buffer to a file tagged sRGB would be wrong.

No camera colour matrix is applied — `RAWMetadata.Color.cameraMultipliers`,
`daylightMultipliers`, `rgbFromCamera` and `cameraFromXYZ` are read nowhere on
this path, and the enforcement is structural: `RAWDemosaicer` receives no
metadata at all. No gamma or other transfer function is applied. No orientation
transform is applied.

Converting camera-native RGB into a defined working representation is a later,
explicit stage. The working colour space remains undecided; ADR 0002 is still
outstanding on that point.

## Decision 15 — X-Trans is recognised and explicitly unsupported

`SensorColorLayout` describes X-Trans, and this algorithm refuses it by name.
The error says the layout is a recognised, fully described 6×6 CFA and that
`.bilinearBayer` is Bayer-only — not that the project fails to understand the
sensor.

It is not treated as Bayer, not demosaiced from a top-left 2×2 subset, not
downsampled, not routed through LibRaw, and not silently handed to another
implementation. A future application-owned X-Trans algorithm would be a new
`RAWDemosaicAlgorithm` case producing the same `DemosaicedRAWRGBImage`
representation, which is what makes adding one cheap.

`.foveon`, `.none` and `.unknown` are refused with their own reasons.

## Decision 16 — Upstream state is retained for reprocessing

`DemosaicedProcessedRAWImage` holds the `WhiteBalancedProcessedRAWMosaic` it
came from, which holds the normalised mosaic, which holds the decoded `UInt16`
mosaic and its metadata.

```text
change the gains          → restart at ProcessedRAWMosaic (normalised)
re-estimate white balance → restart at ProcessedRAWMosaic (normalised)
change demosaic algorithm → restart at WhiteBalancedRAWMosaic
compare two algorithms    → run both from WhiteBalancedRAWMosaic
```

Demosaicing an already-demosaiced RGB buffer is meaningless and re-deriving the
mosaic from it is impossible, so the correct earlier representation stays
reachable and nothing is mutated in place.

This costs memory — roughly 100 MB of Float32 mosaics alongside the 148 MB
image, for the reference camera — and that is a **deliberate tradeoff at this
architecture stage**, not an oversight. It buys re-editing without a second
decode. When interactive editing exists and has been measured, the tradeoff can
be revisited; buffers are not dropped now to make a fixture's number look
smaller.

## What this ADR does not decide

- The **final production-quality Bayer algorithm**. Bilinear is a reference
  implementation and this ADR says so.
- The **X-Trans algorithm**.
- The **working colour space**. Still open; ADR 0002 is outstanding.
- The **camera colour transform** — including whether a visible-light matrix is
  ever valid for infrared capture, which `CLAUDE.md` already flags as an open
  question.
- **Tone mapping**, exposure and highlight handling.
- **Preview / display encoding.**
- A **GPU implementation**. This is a CPU reference implementation; no
  optimised-build measurement has been taken and no performance claim is made.

## Consequences

- The mosaic → camera-native-RGB boundary is now application-owned, exactly
  specified and tested against hand-computable cases, mathematical invariants
  and a real file.
- The output representation is stable enough for a second algorithm to target
  without changing anything downstream.
- Nothing downstream of this stage exists yet, and the values it produces must
  not be treated as displayable colour until a working-space decision and a
  camera transform exist.
