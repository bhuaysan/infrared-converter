# Infrared calibration measurement protocol

Status: version 1
Date: 2026-09-14

This document is meant to be **executed by a person**, not read for
background. It says what to photograph, how, what is recorded, how a transform
is fitted from it, and what the result is and is not allowed to claim.

Its companion is [ADR 0022](decisions/0022-calibration-evidence-and-measurement-protocol.md),
which records why it is shaped this way.

> **Nothing in this project has been measured yet.** No calibration exists for
> any camera, conversion or filter here, and every capture profile is
> explicitly uncalibrated. This protocol is the thing that has to be carried
> out before the first one can exist.

---

## 1. What a calibration in this project is

**A defined infrared false-colour calibration.**

```text
input     white-balanced, scene-linear, camera-native RGB responses
output    a defined linear working RGB reference rendering
```

It maps the responses one camera-and-filter combination produces in front of a
known target onto the rendering somebody decided those patches should produce,
in the project's working representation (extended linear sRGB —
[ADR 0006](decisions/0006-working-color-space.md)).

### What it is not

It is **not** a recovery of human-visible scene colour from infrared photons.
That is not possible and is not attempted. Behind a 720 nm long-pass filter the
sensor is recording a part of the spectrum a person cannot see; there is no
"true colour" of the scene to recover, and two patches that look very different
to a person can be nearly identical there.

It is also not a spectral characterisation of the sensor, not an ICC profile,
not a DNG colour matrix, and not transferable to another body, another
conversion, another filter or another illuminant.

Use the phrase **defined infrared false-colour calibration**. If a sentence
about this work would still be true with the word "accurate" in it, the
sentence is probably wrong.

---

## 2. Scope of one calibration

One calibration covers exactly one combination:

```text
camera body        make, model, and — where the file records it — serial number
sensor conversion  factory, full spectrum, or internal IR, and by whom
filter             manufacturer, product, nominal cutoff, and batch if known
illuminant         what was lighting the target
```

Change any one of them and the calibration does not apply. In particular:

- **Two bodies of one model are not interchangeable.** A conversion replaces the
  filter glass in front of the sensor, and the replacement's thickness and
  spectral behaviour vary per unit. Record `specificBody` unless there is
  evidence across several bodies.
- **Two "720 nm" filters are not interchangeable.** A nominal cutoff is a family
  label with a transition band tens of nanometres wide and per-batch variation.
  Nothing in this project matches calibrations by wavelength.

---

## 3. Target

**ColorChecker Classic 24**, 4 rows by 6 columns, patches numbered `01`–`24`
row-major from the top left, with the neutral row along the bottom
(`19` white → `24` black).

One target is supported. Do not substitute a different chart and record it as
this one: the patch identifiers would then mean different colours, and every
reference value would be attached to the wrong measurement.

### The reference values are not the chart's published values

This is the single most important paragraph in this document.

A ColorChecker's published Lab or sRGB values describe how its patches reflect
**visible** light. They are not a physical fact about what the chart does
beyond 700 nm, and using them as infrared reference values would be fitting a
transform towards numbers that describe a different experiment.

So a reference dataset here is a deliberate choice: *the rendering you have
decided those patches should produce*. It is recorded as its own artefact with
an identifier, a version, a stated source and an illuminant, and a calibration
names the exact revision it was fitted against.

### How a reference dataset is named

A calibration records the dataset it was fitted against as one string:

```text
identifier@version        e.g.  foliage-falsecolour@3
```

Because that one string is the whole record, the grammar has to be
unambiguous, so **neither the identifier nor the version may contain `@`**. Were
they allowed to, identifier `a@b` at version `c` and identifier `a` at version
`b@c` would both produce `a@b@c` — two different tables of numbers that every
identity check would read as one. An identifier or version containing the
separator is refused, naming the field and the reason; it is never escaped and
never silently rewritten, because the label is yours and an artefact should not
name something you did not write. Pick a different separator of your own.

Everything else is free text: use a name you will recognise in a year, and bump
the version whenever any value in the table changes.

**This project bundles no reference dataset.** Producing one, and writing down
the reasoning behind every value in it, is part of the work this protocol
precedes.

---

## 4. Illumination

Record what it actually was.

```text
measuredSPD(reference)   a measured spectral power distribution — the strongest evidence
d65 / d50                a standard illuminant you arranged; an assertion, not a measurement
namedOther("...")        a source you can name but not characterise
unknown                  nobody recorded it
```

**Do not record `d65` because the photograph was taken outdoors.** Daylight
varies with time, season, cloud and surroundings, and its infrared content
varies with all of them. D65 is a defined spectrum, not a synonym for "outside".

For infrared work the illuminant matters more than it does in the visible:
tungsten emits copiously above 700 nm, many LED panels emit almost nothing
there, and a transform fitted under one and applied under the other is a
coincidence rather than a calibration.

### The measurement and the reference must name the same illuminant

Reference values are defined **under** an illuminant; they are not true in
general. Your measurements were likewise recorded under one. A fit pairs the
two, and the application refuses the pair unless the **recorded identity** is
exactly the same on both sides:

```text
.d65              ↔ .d65                      allowed
.d50              ↔ .d50                      allowed
.namedOther("X")  ↔ .namedOther("X")          allowed
.measuredSPD("X") ↔ .measuredSPD("X")         allowed
.unknown          ↔ .unknown                  allowed, and stays experimental

.d65              ↔ .d50                      refused
.d65              ↔ .measuredSPD("d65.spd")   refused
.namedOther("A")  ↔ .namedOther("B")          refused
.measuredSPD("A") ↔ .measuredSPD("B")         refused
.unknown          ↔ anything recorded         refused
```

Three things this rule does and does not mean:

- **A measured SPD is an identifier, not the spectrum.** This project stores a
  reference to your measurement — a file name, an instrument reading, a
  document — and reads no spectral data at all. So it cannot tell that
  `d65-measurement.csv` is or is not D65, and it will not pretend to: a
  measured SPD never matches an asserted `.d65`, however the file is named.
- **No equivalence is inferred between differently named sources.** There is no
  fuzzy matching, no case folding, no substring rule. `"LED Panel A"` and
  `"led panel a"` are two different records, because these are evidence
  identifiers rather than search terms. Outer whitespace is trimmed and nothing
  else is touched.
- **Same recorded identity is not proven identical spectrum.** Two records
  saying "LED Panel A" are two people's words, and nothing here can check them.
  The rule guarantees only that nothing pairs evidence with reference values
  that *state* different illumination — which is worth having, and is all it
  claims.

Practically: when you produce a reference dataset, record the illuminant you
intend it to be used under, and record the *same* identity in the session that
measures against it. If you later measure that lamp's SPD, that is a new
illuminant identity and therefore a new dataset revision.

### An illuminant identity has to say something

`namedOther` and `measuredSPD` carry the entire identity of the illuminant in
their text, so an empty or whitespace-only one is refused rather than stored. An
empty measured-SPD reference is refused especially firmly: it would report
itself as *measured* illumination — the strongest claim available — while
pointing at no measurement at all. If you cannot name the source, record
`unknown`. That is an honest answer the status rules already account for, and it
is better than a name that says nothing.

Practical requirements:

1. One source, or several of the same type. Mixed illumination makes the
   recorded illuminant a fiction.
2. Even across the whole chart. Check by photographing a blank grey card in the
   chart's position and confirming the corners and the centre agree; a falloff
   of more than a few percent will appear in the residuals as a spatial
   pattern.
3. No specular reflection of the source in the chart. Light at roughly 45° to
   the chart's surface, camera on the normal.
4. Stable for the whole session. Let discharge sources warm up.

---

## 5. Capture

### Geometry

- Chart **square-on**. The patch grid is mapped bilinearly from the four marked
  corners, which is exact for an affine arrangement and approximate for a
  perspective one. Photographing the chart frontally removes the approximation
  entirely.
- Chart filling most of the frame, but away from the extreme corners where lens
  falloff is strongest.
- Chart flat. A card that bows changes both the geometry and the illumination
  across it.

### Focus and aperture

- Focus on the chart. **Focus with the filter on**, or focus and then refocus:
  a converted camera's infrared focus plane is not its visible one.
- A middle aperture — enough depth of field to keep the whole chart sharp,
  short of the aperture where diffraction begins to matter. Sharpness is not
  critical for large flat patches, but a chart half out of focus has its patch
  edges smeared into each other.

### Exposure — the requirement that matters most

**No patch may clip in any channel.**

A clipped sample is not a slightly wrong measurement, it is a censored one: the
sensor saw more than it could record, and the number that comes back is the
limit rather than the response. Fitting a linear transform to censored data
pulls every coefficient towards the clip, silently, and the residuals still look
plausible.

The measurement path enforces this: a patch containing **any** sample at or
above the normalised saturation level is excluded from the fit, and a capture in
which every patch clips is refused outright.

How to get it right:

1. Meter for the brightest patch, not for the scene.
2. Bracket. Three or five exposures a stop apart costs nothing and one of them
   will be right.
3. Aim for the brightest patch around two thirds of the way up the normalised
   range. Headroom is cheap; a clipped white patch costs the session.
4. Do not go so dark that the dark patches sit in the noise floor. The bottom
   of the range is where read noise dominates and a patch mean stops being a
   measurement of the patch.
5. Check after measuring: the evidence records `clippedSampleCount` per plane
   per patch, and `excludedPatchCount` for the set. If anything was excluded for
   clipping, re-expose and re-photograph. The answer is never to relax the rule.

### RAW settings

- RAW, not RAW+JPEG-derived anything. The measurement path reads the mosaic.
- Base ISO. Everything above it trades dynamic range for nothing useful here.
- Fixed white balance in camera is irrelevant — the measurement path does not
  read the camera's white-balance metadata — but leaving it fixed makes the
  in-camera preview comparable between frames.
- Long-exposure noise reduction and any in-camera "enhancement" off.
- One frame per exposure. Nothing here averages frames.

---

## 6. White balance — the session's own, never a photograph's

```text
ImageAdjustments.whiteBalance     one photograph's editing decision
IRCalibrationWhiteBalancePolicy   the calibration session's neutral reference
```

These must never be the same thing, and the measurement path physically cannot
confuse them: it never reads a sidecar and never sees an `ImageAdjustments`.

A photograph's neutral patch is a place in *that* picture, chosen for how that
picture should look. Baking it into a reusable transform would make the
calibration depend on a creative decision about an unrelated image, and the
symptom would be that it works on that photograph and subtly fails everywhere
else.

Two session policies:

```text
neutralPatch(patch)   gains derived from one named patch of the target
none                  fitted from raw normalised responses, with no balancing
```

`neutralPatch` uses exactly the rule the interactive white balance uses —
`preserveStrongestMeasuredPlane`, so the strongest measured plane keeps a gain
of `1` and nothing is scaled past the data. Prefer patch `20` (the second
neutral) over `19` (white): the white patch is the one most likely to clip in an
exposure set chosen for the coloured patches, and a neutral reference measured
from clipped samples is not a neutral reference.

Either policy is defensible. A 3×3 transform can absorb per-channel scaling into
its own diagonal, so balancing first is not mathematically necessary; it is
offered because a balanced fit's coefficients are easier to compare between
sessions. **The gains are re-derived from the stored evidence on every fit**, so
a calibration cannot disagree with the measurements it claims to come from.

### The neutral reference has to be usable

Its gains scale every channel of every fitted patch, so an unusable neutral
reference does not spoil one patch — it sets the white balance of the whole
transform. A fit is therefore refused when the named patch is:

```text
not measured at all
excluded by the evidence      clipping, incomplete planes, a non-finite sample, the operator
carrying any clipped sample   even one, and even when the policy would include it
at or below zero in a plane   a neutral reference at zero defines no gain
missing an expected plane     every plane of the layout has to be there, not every channel
```

**Zero clipped samples, whatever the general clipping tolerance says.**
`maximumClippedSampleFraction` decides whether an *ordinary* patch is included,
and that judgement is bounded: a tolerated patch contributes one row to a fit
with many rows, and the other rows constrain it. The neutral reference is not
one row. Its gains multiply every channel of every fitted patch, so one censored
sample inside it sets the white balance of the whole transform from a value the
sensor did not record. A patch may therefore be included by the policy and
refused as the neutral reference; that is the difference between what a patch
contributes and what a reference decides.

**Every expected plane, not merely every channel.** On a four-plane RGGB layout
a neutral patch carrying `0 R, 1 G, 2 B` has all three channels and is still
refused: its green gain would come from one phase, and every patch in the fit
would be scaled by it. See section 7.

The **evidence** may still record every one of those. A measurement is a
historical fact and an exclusion is a judgement about it, so a session whose
neutral patch turned out to be clipped is recordable exactly as it happened.
What cannot follow from it is a fit. Re-photograph the chart, choose another
neutral patch, or fit the session `none`.

There is no identity fallback anywhere in this. Under `none` every plane has a
gain of `1` because that is the answer; under `neutralPatch` a plane the neutral
reference never saw is a refusal, not a `1`.

---

## 7. Measurement domain — the mosaic, before demosaicing

```text
RAW
 ↓ decode                the project's own decoder boundary
sensor mosaic
 ↓ normalise             black level, white level, unclamped, no clipping
normalised mosaic  ← measurements are taken here
```

Patch responses are **per-colour-plane means of normalised CFA samples**, taken
before white balance, before demosaicing, and before any colour transform.

Why the mosaic and not the demosaiced image: a chart patch is a large flat
uniform area, exactly the case where a demosaicer has nothing to reconstruct, so
averaging after demosaicing measures very nearly the same thing plus one extra
variable — the demosaicer. This project's demosaicer is its own decision
([ADR 0005](decisions/0005-application-owned-bayer-demosaicing.md)) and is
expected to improve; a calibration whose coefficients depended on the bilinear
reconstruction of 2026 would be a calibration of the interpolator.

What must never be measured from:

- a `WorkspacePreview`, its `CGImage`, or any display buffer;
- 8-bit values of any kind;
- anything with the sRGB transfer function applied;
- anything clipped to `0...1`;
- a JPEG, a TIFF export, or a screenshot.

All of those are display-referred: they are no longer proportional to light, and
no linear transform can honestly be fitted from them.

### Green

A Bayer cell has two green sites. Both are measured and **both are kept
separately in the evidence**. The fit collapses them by the recorded policy:

```text
meanOfGreenPlaneMeans     green = (mean(G1) + mean(G2)) / 2
```

Unweighted, so that a patch rectangle containing one more G1 site than G2 —
which depends on where its corner lands on the CFA grid — cannot change the
measured green. Because the per-plane means survive in the evidence, a different
rule can be applied later without re-photographing anything.

### The sensor's colour planes are recorded, not inferred

A patch measurement carries the planes that were **present** inside its region,
and nothing in a list of present planes says which planes were supposed to be
there. Evidence in which every patch carries `0 R, 1 G, 2 B` on a four-plane
RGGB sensor would look complete, and the fit would collapse a "pair" of one
green and produce a transform fitted to half the green sites.

That failure is invisible exactly when it is systematic: a plane missing from
one patch is an incomplete patch, and a plane missing from every patch is
nothing at all.

So the measurement set records the **signature** of the sensor layout — an
ordered `plane -> channel` list — read from the decoder's own colour
description at the moment of measurement, by the same code the demosaicer uses:

```text
0 -> red
1 -> green
2 -> blue
3 -> green
```

Never inferred from the patches. A genuinely three-plane Bayer layout, on which
both green sites share plane `1`, records three entries and is right to.

Every patch is then checked against it:

```text
a plane the layout has not           refused, always
a plane recorded as another channel  refused, always
every expected plane present         may be included, or excluded for any
                                     reason except a claim of incompleteness
a plane absent                       must be excluded, and if it claims
                                     incompleteness it must name exactly the
                                     planes that are absent
```

A **fitted** patch has to be complete. An **incomplete** patch may exist only as
explicitly excluded evidence — which is a real thing that happens to a region
near the edge of the active area, and evidence has to be able to record it —
and it may not misdescribe which planes it lacks.

### Patch regions

Mark the four corners of the patch array. The grid is derived from the target's
known 4×6 layout, and only the **centred 50%** of each patch cell is sampled, so
that the printed gaps between patches, any light falling off at a patch edge,
and any small misregistration all stay outside the measurement.

Regions are snapped to even origins and even extents, so each covers whole 2×2
CFA cells and every colour plane is sampled equally often.

There is **no automatic chart detection**, and none is planned. A detector that
is right 95% of the time produces, in the other 5%, a measurement set that looks
perfectly ordinary and was sampled from the wrong squares.

---

## 8. Normalisation

The application's own path — `RAWMosaicNormalizer`, the same one the preview and
the export use ([ADR 0002](decisions/0002-raw-normalization.md)):

```text
value = (sample − blackLevel) / (whiteLevel − blackLevel)
```

Per-plane black levels, the metadata white level, **unclamped**. There is no
parallel black-level interpretation for calibration.

The evidence records which normalisation produced its numbers — the policy, the
white level, whether black was subtracted, and a version — so a later reader can
tell whether two measurement sets are comparable and whether a change to the
normaliser invalidates a stored calibration.

---

## 9. Fitting

```text
minimise   Σ  || M · cᵢ  −  rᵢ ||²
           i

cᵢ   camera response of patch i, (R, G, B) column vector, session-balanced
rᵢ   reference value of patch i, (R, G, B) column vector, linear
M    the 3×3 transform
```

- **Convention: `output = M × input`**, column vectors, channel order R, G, B —
  the project's one matrix convention, shared with `RAWColorMatrix3x3` and
  `RAWWorkingColorConverter`.
- Ordinary least squares, solved through the normal equations by Gaussian
  elimination with partial pivoting, in `Double` throughout.
- **No offset term.** The model is a pure linear map. An intercept would absorb
  a black-level error into the transform and make the two indistinguishable.
- **No regularisation.** No ridge, no prior, no nudge towards the identity. A fit
  stabilised by an undocumented prior is not a measurement, and its failure mode
  is silent — it always succeeds.
- **No weighting.** Every included patch counts once.
- Deterministic: the same samples in the same order give bit-identical
  coefficients.

### Refusals

The fit refuses rather than producing coefficients when:

| Condition | Why |
|---|---|
| fewer than 4 included patches | 3 is the algebraic minimum and leaves no residual to report |
| every patch excluded | usually a clipped capture; the answer is a new capture |
| a patch with no reference value | fitting towards an invented value is the failure this prevents |
| the measurement and reference illuminants differ | reference values are defined under an illuminant, and no spectral equivalence is inferred |
| a channel zero across every patch | nothing can be learned about that column |
| normalised Gram determinant < 1e-9 | the responses are too collinear to determine a unique map |
| a non-finite measured or reference value | one propagates into all nine coefficients |
| an unmeasured, excluded or zero neutral reference | its gains would set the white balance of the whole transform |
| a colour plane the neutral reference defines no gain for | the transform would be balanced in some channels and not others |

The conditioning test is computed on **column-normalised** responses, so it
measures independence rather than exposure. It is a numerical-degeneracy guard,
not a quality threshold: a poor fit is reported with its residuals and left for a
person to judge.

---

## 10. Error metrics

Recorded per patch, signed, in the reference dataset's own representation:

```text
residual = M · c  −  r
```

Everything else is **derived** from the residual list, so nothing can disagree
with it:

```text
RMSE               sqrt( Σ e² / (3n) )   per channel, over every included patch
maximum residual   max over patches of ||e||
worst patch        which patch that was
included count     the number of residuals
excluded count     recorded separately; not derivable from the residuals
```

"RMSE 0.02 over 6 of 24 patches" and "RMSE 0.02 over 24 of 24" are very
different claims, which is why both numbers travel together.

---

## 11. Acceptance — and why nothing is accepted yet

```text
experimental   measured, and something a validated calibration must record is missing
measured       complete evidence, a fit that converged, residuals reported
validated      measured, and it meets a documented acceptance criterion
```

Status is **derived** from the evidence, the fit and the acceptance criteria
every time it is asked for. There is no stored `isValidated` flag anywhere.

**This project establishes no acceptance criteria.** There is no justified
threshold for an infrared false-colour calibration, and there is no honest way
to invent one: "RMSE below 0.02" would be a number chosen because it sounded
small, and a threshold chosen that way converts a residual a person could have
judged into a verdict the software appears to have justified.

So the best status any calibration currently reaches is `measured`, and
`isValidatedInfraredCalibration` is `false` everywhere. The system computes and
reports residuals; it does not declare success.

### Completeness

A calibration is `experimental` rather than `measured` if any of these is
missing, however well it fitted:

- a **measured** illuminant (an asserted D65 is a gap, not a failure);
- a known sensor conversion;
- a described filter;
- a serial number, when a specific body is claimed;
- at least 12 included patches;
- at least one degree of freedom;
- no clipped samples among the fitted patches.

Plane completeness is not on that list, because it is not a matter of degree:
an included patch short of a plane the signature expects is not a calibration
with a gap, it is evidence that is refused when it is built. See section 7.

---

## 12. What is recorded

Every calibration artefact carries all three of these, together, checked against
each other:

```text
measurements   what the camera produced          immutable, never revised
reference      what it was supposed to produce   identified and versioned
fit            the transform, and how it fitted  derivable from the two above
```

The measurement set records: its own identity, when, the target, the illuminant,
the capture context (camera, conversion, filter — **by value**), the sensor's
colour-plane signature, the measurement domain and green policy, the normalisation provenance, the clipping policy, the
session white-balance policy, every patch's region and per-plane means and
sample counts and clipped counts and inclusion, the author and tool, and the
source file's **name** (never its path).

The capture context is a snapshot rather than a profile reference, deliberately.
A profile is mutable and shared: if a calibration recorded only "measured under
profile P", then editing P from R72 to 590 nm would leave the calibration's
provenance false with nothing to detect it.

---

## 13. Reproducing a calibration

Anybody holding a calibration artefact can check it without the RAW file:

1. Re-derive the session gains from the neutral patch's stored per-plane means.
2. Collapse each patch's balanced plane means to `(R, G, B)` by the recorded
   green policy.
3. Pair each with the reference value for that patch, from the recorded
   dataset revision.
4. Re-run the fit and compare the coefficients.
5. Recompute the residuals and compare them, and RMSE and the maximum with them.

If any step disagrees, the artefact is wrong. That property — not the size of
any residual — is what makes a calibration reviewable.

### The application does this on every read

It is not left to a diligent reader. Constructing a calibration — from a fresh
fit or from a file, which is the same code path — recomputes the transform from
the stored evidence and the stored reference dataset and refuses the artefact
unless the stored matrix, residuals, conditioning and sample count agree with
the result. A file cannot describe a calibration that could not have been
constructed in memory.

Two consequences worth knowing before you edit one by hand:

- **Material changes to fit-determining values, without recomputing the fit,
  are refused.** Edit a matrix, a residual or a conditioning figure and the
  recomputation disagrees; edit the evidence or the reference values and it
  disagrees too, because the matrix beside them is then a conclusion drawn from
  numbers that are no longer there. Re-fit instead: a new calibration identity
  naming the same measurement set, with the old one left intact.
- **A fit recorded by a method this build cannot reproduce is refused**, not
  read unverified. Today that means anything other than `least-squares-3x3@v1`.

Agreement is judged at `1e-12` relative with a `1e-12` absolute floor for
residuals that are legitimately zero — tight enough that no edit a person could
make and mean would pass, loose enough that a stored artefact survives
last-place drift in a future build's arithmetic. It is one rule, in one place
(`IRCalibrationFitAgreement`).

### What this proves, and what it does not

It proves **internal consistency**: that the conclusion in the file follows from
the evidence in the file, by the method the file names. That is what makes a
calibration reviewable.

It is **not** tamper protection in the cryptographic sense — there is no
signature, no MAC and no chain of custody. Anybody who edits the evidence *and*
re-runs the fit gets a file that verifies, because it is a consistent
calibration of whatever the edited evidence now says. It proves nothing about
provenance or authorship: `provenance.author` is a string somebody typed. And it
cannot check the fields the fit does not determine — the illuminant, the capture
context, the notes, the source file name — because those are evidence about the
world, and no arithmetic here can confirm them.

### Older artefacts

A calibration file at **schema version 1** predates the colour-plane signature
and is refused rather than read. It is understood completely; what it lacks is
the statement of which planes the sensor produced, and that cannot be recovered
without inventing it — the patches are the inference the signature exists to
remove, and "four planes means RGGB" is an assumption about somebody else's
camera. Re-measure the chart and re-fit; the RAW file and the reference dataset
are unchanged.

---

## 14. The checklist

```text
Before
  [ ] one camera, one conversion, one filter, written down
  [ ] serial number recorded if the file has it
  [ ] filter manufacturer, product, nominal cutoff, batch
  [ ] single illuminant, warmed up, no mixing
  [ ] reference dataset chosen, with identifier, version and stated source
  [ ] identifier and version contain no "@"
  [ ] the reference dataset's illuminant identity is the one you will record
      for the session — character for character

Capture
  [ ] chart flat, square-on, filling most of the frame, away from the corners
  [ ] light at ~45°, even across the chart, no specular reflection
  [ ] focused with the filter in place
  [ ] base ISO, middle aperture, in-camera processing off
  [ ] bracketed; brightest patch around two thirds of the range
  [ ] RAW kept

Measure
  [ ] four chart corners marked, clockwise from the top left
  [ ] no patch excluded for clipping — if any was, re-expose and start again
  [ ] session neutral patch chosen from the target (20, not 19), with zero
      clipped samples — not merely below the clipping tolerance
  [ ] the recorded colour-plane signature matches the sensor you shot with

Fit
  [ ] the fit converged, and the conditioning number is comfortably above 1e-9
  [ ] residuals inspected per patch, not only as an average
  [ ] evidence gaps read and understood

Record
  [ ] author, tool and version
  [ ] illuminant recorded as what it was, not as what would be convenient, and
      named rather than left as an empty string
  [ ] status read from the artefact, not asserted
```

---

## 15. What this protocol does not cover

Automatic target detection, comparison of spectral power distributions or any
other proof that two differently named sources are the same light, spectral
sensor reconstruction, arbitrary spectral response fitting, ICC profile generation, DNG colour matrices, multi-illuminant
calibration, multi-body model-level calibration, temperature/tint, tone curves,
sharing or exchanging calibrations between photographers, and any means by which
a user can assert that a calibration is validated.
