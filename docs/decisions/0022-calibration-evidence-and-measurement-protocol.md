# 0022 — Calibration evidence and measurement protocol

Status: accepted
Date: 2026-09-14

> Numbering note: `CLAUDE.md` used `0022-metal-render-pipeline.md` as an
> illustrative future filename, after [ADR 0021](0021-user-capture-profile-library.md)
> took the number the previous example used. This decision took `0022`, so that
> example now reads `0023-metal-render-pipeline.md`. No ADR was renamed.

## Context

[ADR 0020](0020-ir-capture-profile-foundation.md) built the capture-profile
domain and [ADR 0021](0021-user-capture-profile-library.md) gave a person
somewhere to keep their profiles. A photographer can now record that their
E-PL3 is full-spectrum converted and that a Hoya R72 was on the lens, assign
that profile to any number of photographs, and see it resolved on every open.

Every one of those profiles renders camera-native sensor values straight into
the working space through `sensorRGBIdentityFalseColor`, and
`isValidatedInfraredCalibration` is `false` for all of them. Both milestones
said so explicitly, and both listed the same limitation:

> **No calibration, still.** Nothing in this milestone measures anything.

The obvious next step looks small. `IRCaptureProcessingBasis` already has an
`.explicitMatrix` case; making it `Codable`, adding a matrix field to the
profile editor, and letting people paste in coefficients would produce something
that renders differently and looks like calibration.

It would be the worst thing this project could do.

## Problem

**A 3×3 matrix does not justify a calibration claim, and nothing about a matrix
reveals whether it is justified.**

Nine plausible-looking numbers are indistinguishable from nine measured ones.
They render, they produce an image, and the image looks like a deliberate
rendering rather than a mistake. There is no visual symptom, no error, and no
way for a second person — or the same person two years later — to tell one from
the other. A folder of such files passed between photographers is an
infrared-calibration interchange format that nobody validated, which is exactly
what ADR 0021 refused to create by accident.

The questions that separate a calibration from nine numbers are not about the
numbers at all:

```text
What exactly was measured?
Under what conditions?
Against what reference?
With what residual error?
What claim does the result justify?
```

None of those can be answered by a matrix. All of them have to be recorded at
the moment of measurement, because none can be reconstructed afterwards.

There is a second, subtler problem. This project already has a user-owned white
balance ([ADR 0019](0019-interactive-white-balance.md)) recorded as the neutral
region a person picked in **one photograph**. A calibration fitted from a
photograph that carried such a decision would bake one creative choice about one
image into a transform reused across every frame ever shot with that camera —
and the symptom would be that the calibration works on that photograph and
subtly fails everywhere else.

## Decision

**Calibration evidence is a first-class, persisted artefact; measurement and
fitting are separate; the capture context is snapshotted by value; validation
status is derived; error metrics are mandatory; and no capture profile becomes
calibrated by this milestone.**

```text
IRCalibrationMeasurementSet    what the camera produced      immutable evidence
IRCalibrationReferenceDataset  what it should have produced  identified, versioned
IRCalibrationFitResult         the transform and its error   derived from both
IRCalibration                  all three, checked together   one artefact, one file
```

---

### 1. The calibration objective, stated before any code

**A defined infrared false-colour calibration.**

```text
input     white-balanced, scene-linear, camera-native RGB responses
output    a defined linear working RGB reference rendering
```

It maps what one camera-and-filter combination produces in front of a known
target onto the rendering somebody decided those patches should produce, in
extended linear sRGB ([ADR 0006](0006-working-color-space.md)).

It is **not** a recovery of human-visible scene colour from infrared photons.
That is not possible and is not attempted: behind a 720 nm long-pass filter
there is no "true colour" of the scene to recover, and two patches that look
very different to a person can be nearly identical there. It is not a spectral
characterisation, not an ICC profile, not a DNG colour matrix, and not
transferable to another body, conversion, filter or illuminant.

The distinction is not pedantry. "Colour-accurate infrared" is a claim that
cannot be true, and a subsystem whose vocabulary permits it will eventually make
it.

### 2. Where the transform sits

```text
normalised RAW → white balance → demosaic → CALIBRATION TRANSFORM → working RGB
```

Exactly where `RAWCameraToWorkingColorTransform` sits today, because that is the
stage whose job it does: the map from camera-native RGB into the working
representation. Not after display encoding, where values are no longer
proportional to light and a linear transform means nothing; not before white
balance, because the responses it is fitted from are balanced ones.

The pipeline's stage ordering is unchanged by this milestone. Nothing new runs.

### 3. Measurement happens in the mosaic domain, and the choice is recorded

```text
RAW → decode → normalise → per-patch, per-plane means   ← evidence is taken here
```

The two candidates were evaluated deliberately:

```text
demosaic → RGB patch means → fit      one extra variable: the demosaicer
CFA plane means → camera RGB → fit    no interpolation involved at all
```

A calibration chart patch is a large, flat, uniform area — exactly the case
where a demosaicer has nothing to reconstruct, so averaging after demosaicing
measures very nearly the same thing *plus* the interpolator. This project's
demosaicer is its own decision
([ADR 0005](0005-application-owned-bayer-demosaicing.md)) and is expected to
improve; a calibration whose coefficients silently depended on the bilinear
reconstruction of 2026 would be a calibration of the demosaicer.

It is also where the white-balance estimator already works, on the same
normalised buffer, producing the same per-plane statistics — so the measurement
path is machinery this project already has, aimed at a grid of regions instead
of one.

Only near a patch's **edges** does interpolation mix in a neighbour, and the
protocol answers that by sampling the central 50% of each patch rather than by
choosing a domain.

`IRCalibrationMeasurementDomain` has one case because one path exists. A
demosaiced-RGB domain would be a second case added when a second path is, not a
placeholder now.

### 4. Green is collapsed by a named, versioned, reversible rule

A Bayer cell has two green sites. Both are measured, and **both survive
separately in the evidence**. The fit collapses them:

```text
meanOfGreenPlaneMeans     green = (mean(G1) + mean(G2)) / 2
```

Unweighted rather than sample-count weighted. A patch rectangle can contain one
more G1 site than G2 depending on where its corner lands on the CFA grid, and a
count-weighted mean would make the measured green depend on that alignment — a
geometric accident of how somebody dragged a rectangle. (Regions are snapped to
even origins and extents so the counts are in fact equal; the rule is
phase-independent anyway, which is the point.)

Because the per-plane means are kept, a different rule can be applied later
without re-photographing anything. No hidden channel collapse: the rule is in
the evidence, by name.

### 5. The calibration session's white balance is not a photograph's

```text
ImageAdjustments.whiteBalance     one photograph's editing decision
IRCalibrationWhiteBalancePolicy   the session's own neutral reference
```

Of the three options — fit from raw responses, fit after a session white
balance, or normalise white balance out analytically — the decision is the
second, with the first offered as an explicit alternative:

```text
neutralPatch(patch)   gains from one named patch of the target
none                  fitted from raw normalised responses
```

`neutralPatch` uses exactly the rule the interactive white balance uses,
`preserveStrongestMeasuredPlane`. There is one definition of neutral in this
project and a second one here would be two.

Three properties make this safe:

- The gains come from a patch **of the target**, chosen once for the session.
- They are **re-derived from the stored evidence on every fit**, never stored, so
  a fit cannot disagree with the measurements it claims to come from.
- The measurement path never reads a sidecar and never sees an
  `ImageAdjustments`. The confusion is not merely avoided, it is unreachable.

Mathematically the choice barely matters — a 3×3 absorbs per-channel scaling
into its own diagonal — which is precisely why it had to be decided explicitly
rather than left implicit.

### 6. The capture context is snapshotted by value

This is the most important structural decision in the milestone.

A capture profile is **mutable and shared**: editing one changes what every
photograph referencing it resolves to (ADR 0021). If a calibration recorded only
"measured under profile P":

```text
profile P calibrated for a Hoya R72 on a converted E-PL3
  → a person edits P, changing the filter to 590 nm
  → the calibration still says "P"
  → its provenance is now false, and nothing detected it
```

So `IRCalibrationCaptureContext` carries the camera, the conversion and the
filter **as they were**, by value. The profile identity is kept alongside, as
context — who was measuring, not what was measured.

The filter snapshot is deliberately richer than `IRFilterDescriptor`, which is
one of *either* a nominal cutoff *or* a product name — the right shape for
something a person picks from a menu, and not enough for evidence. A calibration
tied to one physical piece of glass records manufacturer, product, nominal
cutoff and batch notes together. `IRFilterDescriptor` is not redesigned; nothing
a person already saved changes shape.

Camera identity carries an optional serial number and an explicit
`IRCalibrationBodyScope`: `specificBody` or `modelLevel`. Make and model are not
enough for a converted body — the replacement filter glass differs per unit,
and that is the part of the optical path being characterised — but a serial
number is not *required*, because no decoder here is guaranteed to expose one
and requiring it would make a real measurement unrecordable.

### 7. Evidence and result are separate, and evidence is immutable

```text
IRCalibrationMeasurementSetID   measurement.<uuid>   a historical fact
IRCalibrationID                 calibration.<uuid>   a derivation from it
```

A measurement is what a camera produced on one occasion; a fit is a conclusion
drawn from it, and conclusions get redone — with a better solver, a corrected
reference dataset, a different patch selection. Re-fitting produces a **new**
`IRCalibration` carrying the **same** measurement set with the same identity.
Nothing is mutated and no history is lost.

Both identities are generated, validated, namespace-qualified and lowercase, for
the reasons `IRCaptureProfileID` already documents: a name is rewritten, and an
identity derived from one takes every reference away with it silently. Unlike a
profile's, each namespace is **fixed** — there is one kind of thing in each, and
a fixed namespace lets a store tell from a filename alone what it is looking at.

### 8. Error metrics are mandatory, and derived

Per-patch signed residuals are stored. Everything else is computed from them:

```text
RMSE               sqrt( Σ e² / (3n) )   per channel, over every included patch
maximum residual   max over patches of ||e||
included count     the number of residuals
excluded count     stored separately; not derivable from the residuals
```

Storing RMSE alongside the residuals would create a second authority that can
disagree with the first, and would need a consistency check on every read that
is only as good as somebody remembering to write it. Deriving removes the
possibility instead of policing it.

The cross-field rule the milestone names explicitly is enforced at construction
and survives the file boundary: **a calibration claiming 24 patches may not
carry 23 residuals**, and a hand-edited file that tries is refused.

`excludedPatchCount` travels with the metrics because "RMSE 0.02 over 6 of 24
patches" and "RMSE 0.02 over 24 of 24" are very different claims.

### 9. Clipping excludes a patch; it is never averaged in

A clipped sample is not a slightly wrong measurement, it is a **censored** one:
the sensor saw more than it could record and the value returned is the limit.
Fitting to censored data pulls every coefficient towards the clip, silently —
the solver converges and the residuals look plausible.

`IRCalibrationClippingPolicy` defaults to a threshold of `1.0` (exactly the
normalised saturation level, since `RAWMosaicNormalizer` maps the metadata white
level onto `1.0` and does not clamp) and a tolerated clipped fraction of `0`:
**any** clipped sample excludes the patch. A capture in which every patch clips
is refused outright.

The tolerance is zero rather than small because the answer to a clipped patch is
to re-expose and re-photograph, which takes two minutes, and a calibration is
not the place to accept known-bad data because collecting good data was
inconvenient.

The measured values are still recorded for an excluded patch. The evidence is
what was seen; the exclusion is a judgement about it.

### 10. The solver refuses degenerate data rather than producing coefficients

Ordinary least squares, `output = M × input`, column vectors, channel order
R, G, B — the project's one matrix convention, shared with `RAWColorMatrix3x3`
and `RAWWorkingColorConverter`. Normal equations, Gaussian elimination with
partial pivoting, `Double` throughout, deterministic.

Three deliberate absences:

- **No offset term.** An intercept would absorb a black-level error into the
  transform and make the two indistinguishable. Black level is handled upstream,
  in one place.
- **No regularisation.** No ridge, no prior, no nudge towards the identity. A fit
  stabilised by an undocumented prior is not a measurement, and its failure mode
  is that it always succeeds.
- **No weighting.** A weighting scheme is a modelling decision that needs
  justification from real data, and none exists.

Refusals: fewer than four included patches; no included patches; a patch with no
reference value; a channel zero across every patch; a column-normalised Gram
determinant below `1e-9`; any non-finite input or coefficient.

Four rather than three, because three is the algebraic minimum and leaves *no
residual to report* — a calibration whose error metrics are zero by construction
is the exact false confidence this subsystem exists to prevent. That is a stated
engineering floor, not a scientific threshold.

The conditioning test is computed on **column-normalised** responses so the
verdict describes independence rather than exposure; an unnormalised determinant
scales with the cube of brightness. It is a numerical-degeneracy guard, not a
quality threshold: a poor fit is reported with its residuals and left for a
person to judge.

### 11. Validation status is derived, and this project validates nothing

```text
experimental   measured, and something a validated calibration must record is missing
measured       complete evidence, a fit that converged, residuals reported
validated      measured, and it meets a documented acceptance criterion
```

Three levels rather than a Boolean, because "not validated" covers two very
different situations — incomplete evidence, and complete evidence held against
no standard — and collapsing them makes a careful measurement indistinguishable
from a sloppy one.

**There is no stored `isValidated` flag anywhere.** Status is recomputed from the
evidence, the fit and the acceptance criteria every time it is asked for. A
stored flag is a second authority that can disagree with the data it describes,
and when it does, it is the flag that gets believed.

`IRCalibrationAcceptanceCriteria.project` is **`nil`**. There is no justified
acceptance threshold for an infrared false-colour calibration and no honest way
to invent one: "RMSE below 0.02" would be a number chosen because it sounded
small, and a threshold chosen that way converts a residual a person could have
judged into a verdict the software appears to have justified.

So the best status any calibration currently reaches is `measured`, and
`isValidatedInfraredCalibration` is `false` everywhere. **The system computes and
reports residuals; it does not declare success.**

The type exists — rather than the status simply never being `.validated` —
because the mechanism must be in place, tested, and visibly waiting for the one
thing it lacks. Tests exercise the `.validated` branch with hypothetical
criteria, so the day a threshold can be justified from real measurements it is a
documented value here plus an ADR, and nothing else changes.

A calibration that misses a criterion is `measured`, not `experimental`: its
evidence is complete and its fit converged. What it lacks is a verdict, not a
measurement.

### 12. Chart registration is manual, and bilinear

A person marks the four corners of the patch array; the target's known 4×6
layout does the rest, and the central 50% of each patch is sampled.

**No automatic chart detection, and none planned.** A detector that is right 95%
of the time produces, in the other 5%, a measurement set that looks perfectly
ordinary and was sampled from the wrong squares — and nothing downstream can
tell.

The unit square maps onto the quadrilateral bilinearly, which is exact for any
affine arrangement and approximate for a perspective one. A homography would be
exact for both, at the cost of an 8×8 solve and a second numerical path to get
right; the protocol's answer is simpler and better anyway — photograph the chart
square-on, which a calibration session can always arrange. For a rotated
outline the sampling rectangle is inscribed *inside* the mapped cell, so it
never reaches into a neighbouring patch, and at a large enough angle it vanishes
and is reported rather than silently approximated.

### 13. Reference values are their own artefact, and none is bundled

```text
identifier   what dataset this is
version      which revision of it
source       where it came from, in words somebody can follow
colorSpace   extended linear sRGB
illuminant   what the values are defined for
values       patch -> linear RGB
```

`IRCalibrationTarget` carries **layout only** — how many patches, how they are
arranged, what each is called. That is a physical fact about a piece of card.
Reference values are separate because they are not a fact about the card at all.

A ColorChecker's published values describe how its patches reflect **visible**
light. They are not physical truth for an infrared capture, and using them as
infrared reference would be fitting towards numbers that describe a different
experiment. A reference dataset here is a deliberate choice — the rendering
somebody decided those patches should produce — which is why identifier, version
and source are all required and a dataset missing any of them is refused.

**This project bundles no reference dataset.** Tests construct synthetic ones
whose identifiers begin `synthetic.`, so no test can be mistaken for evidence.

### 14. Illumination is recorded as what it was

```text
measuredSPD(reference)   the strongest evidence
d65 / d50                a standard illuminant somebody arranged: an assertion
namedOther("...")        a source that can be named but not characterised
unknown                  nobody recorded it
```

For infrared work the illuminant is most of the experiment: tungsten emits
copiously above 700 nm, many LED panels emit almost nothing there. **Do not claim
D65 because a photograph was taken outdoors** — daylight varies with time,
season, cloud and surroundings, and its infrared content varies with all of
them.

`.unknown` is a real answer, and it is an evidence *gap* rather than a default.
So is an asserted `.d65`: it is far better than unknown and it is not a
measurement, and the completeness rules distinguish the two.

### 15. Persistence: its own file, its own folder, its own schema

```text
~/Library/Application Support/Infrared Converter/Calibrations/
  calibration.550e8400-e29b-41d4-a716-446655440000.ircalibration.json
```

One JSON file per calibration, named by its validated identifier, at schema
version 1 — **independent** of the profile schema and of the photograph sidecar
schema. Three counters that move for three different reasons; one shared counter
would force every reader of one artefact to be re-released because another
changed.

Beside the profile folder, not inside it: two artefacts, two lifetimes, two
schemas, two stores. Evidence never goes into a photograph sidecar.

All three parts travel in one file. Splitting them into artefacts that reference
each other by identity would produce a calibration that can lose its own
evidence — and a calibration whose evidence is missing is a matrix, which is the
thing that justifies nothing.

The store repeats every judgement `FileIRCaptureProfileStore` arrived at, and
starts with the fix this milestone made there: a filename is classified as
foreign, ours, or **ours and malformed**, and the third is reported rather than
skipped. Atomic writes, lazy directory creation, a corrupt file costing one
calibration, deterministic ordering, and a payload whose identity disagrees with
its filename refused rather than reconciled.

Decoding reconstructs through the public domain initialisers, so every
invariant — residual consistency, evidence agreement, required provenance,
finite values — is re-checked on the way in. A file cannot describe a
calibration that could not have been constructed in memory.

### 16. No capture profile becomes calibrated

`IRCaptureProcessingBasis` is **unchanged**. No `.validatedCalibration` case was
added, the profile schema is still version 1, and no profile references a
calibration.

This was the milestone's own gate — a profile schema may evolve "if and only if
the validated calibration model is complete" — and it is not met, because
validation requires acceptance criteria that do not exist. Adding a persisted
`validatedCalibration` basis that nothing can legitimately produce would create a
file format for a claim this project cannot make, which is the failure the whole
milestone is built to avoid.

`.explicitMatrix` remains exactly what ADR 0021 made it: runtime-only,
unvalidated, with no wire format. It is **not** promoted to the calibrated case.

The applicability rule that will gate a future reference is nevertheless
implemented and tested — camera, conversion and filter must agree — because it
is part of the evidence model rather than of the reference, and because "exact
compatibility rules must be explicit" is easier to satisfy now than after
something depends on it.

### 17. Selection is always a person's

Nothing auto-attaches a calibration to a profile because a camera matches or a
filter says 720 nm. Matching **validates** a choice; it never makes one. A
nominal wavelength is a family label shared by filters that are not
interchangeable.

A calibration is also not a *recommendation*. It defines how camera data enters
the working representation, which is a property of the profile's processing
basis, not a creative suggestion to be applied and then overwritten by a later
edit.

## Consequences

- The project can explain why a future calibration is valid without pointing at
  its matrix: the artefact states what was measured, under what conditions,
  against which reference, how the transform was fitted, and how well it fit.
- Evidence and conclusions are separable, so a fit can be redone without
  rewriting history.
- A calibration's provenance cannot be falsified by editing a profile.
- Clipped, collinear, under-sampled and non-finite data are refused with reasons
  rather than turned into coefficients.
- Error metrics cannot disagree with the residuals they describe.
- Every production capture profile remains explicitly uncalibrated, and
  `isValidatedInfraredCalibration` remains `false`.

## Known limitations

- **Nothing has been measured.** There is no calibration for any camera,
  conversion or filter in this project, and none can be produced without a
  chart, a controlled light and a reference dataset.
- **No reference dataset exists.** Producing one — and writing down the
  reasoning behind every value — is the next substantial piece of work.
- **No acceptance criteria.** Nothing reaches `validated`, by design.
- **No user interface.** Measurement is an API. There is no chart-marking view,
  no calibration inspector and no library window, because a read-only inspector
  would currently have nothing to inspect.
- **No profile reference.** A capture profile cannot name a calibration, so
  preview and export are untouched and neither can resolve one.
- **Bilinear, not projective.** A chart photographed at a steep angle is
  approximated, and a steep enough one is refused.
- **One target.** ColorChecker Classic 24 only.
- **One measurement domain.** CFA plane means only.
- **Body serial numbers are not read from files.** The measurement path records
  `nil`, so a `specificBody` claim is an evidence gap until a caller supplies
  one.
- **No deletion policy for referenced calibrations**, because nothing can
  reference one yet.

## Prerequisites for the first real calibrated profile

In order:

1. A reference dataset: identifier, version, stated source, and a defended value
   for every patch, expressed as a false-colour objective rather than borrowed
   from visible-light chart data.
2. A measurement session carried out to `docs/calibration-protocol.md`, on a
   known body with a known conversion and a known filter, under a recorded
   illuminant, with nothing clipped.
3. A fit whose residuals are inspected per patch, not only as an average.
4. Acceptance criteria justified by measurements across more than one session —
   and an ADR recording why those numbers and not others.
5. A new `IRCaptureProcessingBasis` case carrying a calibration reference, a
   profile schema bump to version 2, and a resolution path that refuses rather
   than falls back when the referenced calibration is missing.
6. Preview and export resolving the **same** calibration artefact, snapshotted at
   the start of an export.

Steps 1 to 3 need a chart and a lamp, not code. Step 4 cannot be shortened by
choosing a number.

## Non-goals

Automatic target detection, computer-vision chart recognition, spectral sensor
reconstruction, arbitrary spectral response fitting, ICC profile generation, DNG
`ColorMatrix` export, a calibration marketplace, cloud sync, crowdsourced
matrices, a generic "paste matrix" calibration interface, automatic calibration
selection, filter inference, temperature/tint, tone curves, and GPU or Metal
work.

---

## Amendment (2026-09-14) — the artefact verifies its own matrix

Three claims above were true of the design and not yet true of the code. An
independent review found the gaps, and this amendment closes them. No decision
here is reversed; each is enforced where it had been described.

### 1. The fit is re-derived, not believed

Decision 7 says evidence and result are separate and a result is a conclusion
drawn from evidence. Decision 15 says:

> A file cannot describe a calibration that could not have been constructed in
> memory.

Both were true of every field *except the numbers that matter*. `IRCalibration`
checked that its three parts named each other — the measurement identity, the
reference identity, the session white-balance policy, the residual patch set,
the excluded count — and nothing looked at a coefficient. A hand-edited
`.ircalibration.json` could keep honest measurements and honest-looking
residuals beside a matrix fitted from nothing at all, and every check passed.

Constructing a calibration now **recomputes** the transform from the stored
evidence and the stored reference dataset, and refuses the artefact unless the
stored matrix, residuals, conditioning and sample count agree with what comes
out. Decoding reconstructs through that same initialiser, so the guarantee
holds at the file boundary rather than only in memory.

```text
stored measurements + stored reference dataset
         ↓  IRCalibrationFitter.derive
recomputed matrix, residuals, conditioning
         ↓  IRCalibrationFitAgreement
agrees with what the artefact stores  —  or IRCalibrationError.unverifiableFit
```

**One implementation, not two.** The arithmetic that `fit` runs was separated
from the `IRCalibrationFitResult` packaging around it —
`IRCalibrationFitter.derive` — and the verifier calls exactly that. A checker
written independently "to check the first" would be a second definition of the
white-balance derivation, the green collapse and the solver, and the day the
two disagreed nothing could say which was right. Recomputation catches a
tampered or corrupted artefact; it does not claim to catch a wrong solver.

### 2. Agreement is tight, tolerated, and defined in one place

`IRCalibrationFitAgreement` is the only rule by which a stored number is judged
against a recomputed one:

```text
relative   1e-12    ≈ 4500 × Double.ulpOfOne
absolute   1e-12    for residuals that are legitimately zero
```

Not exact equality — although the solver *does* reproduce itself bit for bit,
and a test asserts that it does, because the arithmetic is deterministic and
IEEE 754 `+ - * /` and `sqrt` are correctly rounded. Requiring exactness would
additionally assert that every future compiler, standard library and
architecture will agree in the last place, and the cost of that assertion being
wrong falls on somebody's stored measurements: a chart, a lamp and an afternoon
become unreadable because a re-derived coefficient moved by one ulp.

The magnitude is sized against the right quantity. What it has to absorb is
not the *accuracy* of a fit — that is what the residuals and the conditioning
are for — but the difference between two runs of the same arithmetic on the
same inputs. That difference is zero today, and would be a few last places if a
future build accumulated the normal equations in a different order; a few
thousand ulps at unit scale covers it comfortably.

It deliberately does **not** stretch to cover the worst case the conditioning
floor admits. A change to the solver that moves a coefficient by more than a
part in `1e12` has changed what the solver computes, and that belongs behind a
fit-method version bump where a reader can see it, not behind a tolerance wide
enough to hide it.

At the other end: a coefficient, residual or determinant edited by a person
differs in a digit that is visible in the file. An edit small enough to pass
this test changes no number anybody reads.

The absolute floor exists because an exact fit has residuals of exactly zero,
and a relative comparison of `0` against `3e-17` compares nothing. Residuals
live in the working representation, where the magnitudes that matter are of
order `1`, so at that scale the two terms say the same thing.

If the solver's arithmetic ever changes enough to break bit-identity on this
platform, the answer is a fit-method version bump, not a wider tolerance.

### 3. An unreproducible fit method is refused

`IRCalibrationFitMethod` records what produced a matrix. It may not be taken as
a promise that this build can reproduce it. `isReproducibleByThisBuild` is true
only for `least-squares-3x3@v1`, and a persisted fit naming any other algorithm
or version is refused.

Refused rather than carried with an "unverified but historical" status, because
no such status exists in this model and inventing one would create exactly the
place to park a matrix nothing has checked. A historical algorithm becomes
reproducible by being implemented, which is a deliberate act: a solver that can
still produce its coefficients, and a case here.

### 4. One residual per fitted patch, on the type that owns the list

Decision 8 states the rule as "a calibration claiming 24 patches may not carry
23 residuals", and the check compared **sets** of patch identities. A set is
unchanged by a duplicate, so a fit carrying two residuals for one patch and
none for another passed it — while doubling that patch's weight in the RMSE,
the mean residual and the included-patch count, and in any future acceptance
criterion computed from them.

`IRCalibrationFitMetrics` now refuses a duplicate patch outright, and a
negative excluded count with it. `IRCalibration` keeps its own second layer and
no longer relies on `Set`: it counts the residuals against the included patches
and compares the two sorted lists element by element.

### 5. A neutral reference must be usable, not merely present

Decision 5 gives a calibration session its own neutral reference; decision 9
says a clipped patch is excluded and never averaged in. Between them was a gap:
`IRCalibrationMeasurementSet` required only that the named neutral patch had
been *measured*, and the fitter then used it even when the evidence had
excluded it — for clipping, for missing colour planes, for a non-finite sample,
or by the operator's own judgement. An excluded patch could therefore set the
white balance of the whole transform, because gains scale every channel of
every fitted patch.

The evidence keeps that permission, deliberately. A measurement is a historical
fact and an exclusion is a judgement about it, so a session whose neutral patch
turned out to be clipped must still be recordable — otherwise the evidence
would have to be edited to describe what happened, which is the failure
decision 7 exists to prevent. The refusal belongs where the judgement is acted
on, and that is the fit.

`IRCalibrationFitter` refuses a neutral reference that is unmeasured, excluded,
non-positive in any plane, or missing a red, green or blue response.

The silent identity gain is gone with it. Gains were a `[Int: Double]`, and
`gains[plane] ?? 1` reads correctly for an unbalanced session and silently
wrongly for a balanced one — a plane the neutral reference never saw was left
unbalanced while every other plane was scaled, producing a transform balanced
in two channels and not in the third, with nothing in the artefact saying so.
`IRCalibrationSessionGains` carries whether a session was balanced at all: under
`.unbalanced` a gain of `1` is the stated answer, and under `.neutralPatch` a
missing gain is a typed refusal.

### What did not change

- `IRCalibration` is still not `Codable`; persistence is still
  `IRCalibrationRecord`, still at schema version 1.
- RMSE and the maximum residual are still derived and still not persisted.
- No capture profile became calibrated, `IRCaptureProcessingBasis` is
  untouched, `.explicitMatrix` still has no wire format, and
  `isValidatedInfraredCalibration` is still `false` everywhere.
- No acceptance criteria were established; nothing reaches `validated`.
- Preview and export are untouched, and neither resolves a calibration.

---

## Amendment (2026-09-14, second) — evidence states what it expected to measure

Two further gaps from the same review. Both are cases where a rule was stated
against the wrong quantity, so data that broke the rule passed it.

### 1. A neutral reference may contain no clipped sample at all

The previous amendment made the fit refuse a neutral reference the evidence had
**excluded**. That turned out to be the wrong test, because whether a patch is
excluded is decided by `IRCalibrationClippingPolicy`, and
`maximumClippedSampleFraction` is configurable:

```text
clipped samples            1
total samples            400
maximum clipped fraction  0.01
```

Under that policy the patch is included, and could then define the session's
white balance.

The tolerance is defensible for an *ordinary* patch, and its defensibility is
bounded: a tolerated patch contributes one row to a least-squares problem with
many rows, and the other rows constrain it. The neutral reference is not one
row. Its gains multiply every channel of every patch admitted to the fit, so a
censored sample inside it does not perturb the fit — it displaces the white
balance of the whole transform, from a value the sensor did not record.

So the neutral reference requires `clippedSampleCount == 0` over every plane,
independent of the policy, and `IRCalibrationFitter` refuses with
`clippedNeutralReference` naming the patch and the counts. Zero is a definition
here, not a threshold.

A patch may therefore be included by the general policy and refused as the
neutral reference, and that is not the two rules disagreeing. It is the
difference between what a patch *contributes* and what a reference *decides*.

As in the previous amendment, nothing is repaired: the policy is not rewritten,
the evidence is not edited, the patch is not excluded behind the operator's
back. The measurement stands exactly as recorded, because what happened is a
fact. Re-expose the capture, or fit the session unbalanced.

`IRCalibrationClippingPolicy`'s own initialiser was hardened while this was
being written. It accepted any pair of `Double`s, including ones whose effect is
silent rather than loud — a NaN threshold makes every clipping comparison false,
so nothing is ever clipped and a saturated chart fits cleanly, which on the
artefact is indistinguishable from a well-exposed one. A finite positive
threshold and a fraction in `0...1` are now required, as typed domain errors,
and decoding goes through the same initialiser. These are definitions, not new
empirical constants; the default is still normalised saturation with no
tolerance.

### 2. Evidence records the sensor colour-plane signature

Decision 3 records *where* responses were measured and decision 4 records *how*
green is collapsed. Neither records **which colour planes the sensor produced**,
and an `IRCalibrationPatchMeasurement` carries only the planes that were
present inside its region.

Nothing in a list of present planes says which planes were supposed to be
there. So evidence assembled by hand, or read from an edited file, could carry

```text
0 -> R
1 -> G
2 -> B
```

for every patch of a four-plane RGGB sensor and look complete. The fitter would
see red, green and blue, collapse a one-element green "pair" — the mean of one
number — and produce a transform fitted to half the green sites, with nothing
anywhere saying so. The measurement-set check was "has it red, green and blue?",
which this passes.

The failure is invisible precisely when it is systematic. A plane missing from
one patch shows up as an incomplete patch; a plane missing from every patch
shows up as nothing at all. Deriving the expectation from the measurements
cannot catch it, because the measurements are what is in question.

So `IRCalibrationMeasurementSet` carries an `IRCalibrationColorPlaneSignature`:
an ordered `plane -> channel` list, sorted ascending by plane so two records of
one layout are equal and encode identically.

**The authority is the sensor layout at the moment of measurement.**
`IRCalibrationMeasurementPipeline` already reads it, once, through
`channelsByColorPlane(in:)` — the same reading of `colorDescription` the
demosaicer uses — and that reading becomes the recorded signature. Never a union
of the planes the patches happen to contain; never the first patch; never an
assumption that four planes mean RGGB. A genuinely three-plane Bayer layout, on
which both green sites share plane `1`, records three entries and is correct to.

#### Completeness against the signature

Every patch is checked when the evidence is built:

```text
plane not in the signature          refused, always
plane recorded as another channel   refused, always
every expected plane present        included, or excluded for any reason
                                    except a claim of incompleteness
a plane absent                      must be excluded, and a claim of
                                    incompleteness must name exactly the
                                    planes that are absent
```

The asymmetry between included and excluded is the point.

A **fitted** patch must be complete, because collapsing a channel from fewer
planes than the sensor has silently changes what was measured — on an RGGB
layout, a green taken from one phase instead of the mean of two, which is
exactly the phase dependence decision 4 exists to remove.

An **excluded** patch may be incomplete, because incompleteness is a real thing
that happens to a region near the edge of the active area, and evidence has to
be able to record it. This is decision 7 again: a measurement is a historical
fact and an exclusion is a judgement about it. What an excluded patch may not
do is *misdescribe* which planes it lacks — an exclusion is the evidence's own
account of why a patch was not fitted, and one naming planes other than the
missing ones is a statement about a different patch.

A patch excluded for some other reason entirely — a non-finite sample, an
operator's judgement — is left alone: it makes no claim about which planes are
present, so there is nothing to contradict.

#### The neutral reference, again

With the signature recorded, the fitter's neutral-reference check is against it
rather than against "has it red, green and blue?". A four-plane neutral patch
missing its second green has all three channels, and the gains it defines would
balance green from one phase.

Valid evidence can no longer reach that guard — an included patch is complete,
and an excluded neutral reference was already refused — which is why it is
stated there rather than trusted. `missingWhiteBalanceGain` stays for the same
reason, as a layer that is now unreachable from valid evidence and is tested
directly.

### 3. Schema version 2, and version 1 is refused

The signature is evidence, so it is persisted, and its absence and its presence
mean different things about the fit a file carries. That is a schema-version
bump rather than an optional field with a default: a reader that defaulted it
would be deciding what somebody else's evidence said.

```text
<calibration id>.ircalibration.json   schema version 2
```

still independent of the capture profile's schema and of the photograph
sidecar's, which did not move.

A version 1 file is **refused**, with a typed
`IRCalibrationRecordError.insufficientSchemaVersion` naming the field it lacks.
It is understood completely — this is not a record from the future — and it is
not migrated, because every available source for the missing signature is an
invention:

- the patches themselves are the inference the field exists to remove;
- "four planes means RGGB" is an assumption about somebody else's camera.

Reading an old calibration as though it carried evidence it does not is worse
than refusing it, because the refusal is visible and the invention is not. No
calibration in this project reaches a pixel, no capture profile references one,
and the RAW files and reference datasets are unchanged, so the recovery is to
re-measure and re-fit.

### 4. What self-verification proves, stated more carefully

The previous amendment's wording, and the protocol's, said that editing a
number "makes the file unreadable". That is too strong in one direction and too
weak in another, and the difference matters to somebody deciding what to trust.

More precisely: **material changes to fit-determining values, without
recomputing the fit, are refused.** A calibration's matrix, residuals,
conditioning and sample count are recomputed from its evidence and reference
dataset on construction, and an edit to any of those — or to the evidence or
reference values they were derived from — makes the recomputation disagree, and
the artefact is refused. An edit small enough to pass the `1e-12` agreement
changes no digit anybody reads.

What it does **not** prove:

- It is not tamper protection in the cryptographic sense. There is no
  signature, no MAC and no chain of custody. Anybody who edits the evidence
  *and* re-runs the fit produces a file that verifies, because it is a
  consistent calibration of whatever the edited evidence now says.
- It says nothing about provenance or authorship. `provenance.author` is a
  string somebody typed.
- It does not check fields the fit does not determine — the illuminant, the
  capture context, the notes, the source file name. Those are evidence about
  the world, and no arithmetic here can confirm them.

Self-verification proves **internal consistency**: that the conclusion in the
file follows from the evidence in the file, by the method the file names. That
is what makes a calibration reviewable, and it is a different claim from
authenticity.

### What did not change

- `IRCaptureProcessingBasis` is untouched, `.explicitMatrix` still has no wire
  format, and `isValidatedInfraredCalibration` is still `false` everywhere.
- No acceptance criteria were established; nothing reaches `validated`.
- The capture profile schema and the photograph sidecar schema did not move.
- Preview, export, Metal, demosaicing and the reference dataset semantics are
  untouched, and nothing resolves a calibration.
- The illuminant model, the chart geometry, the lens scope and the solver are
  unchanged.

---

## Amendment (2026-09-15, third) — a fit may not cross illuminants, and a reference dataset has one identity

Section 14 records the illuminant on both artefacts and says why it is most of
the experiment. It never said that the two have to agree, and nothing checked
it. Section 13 gives a reference dataset the identity `identifier@version` and
never constrained either part, so two different pairs could produce one
identity.

Both are closed here. Neither changes the calibration schema, the wire format,
the solver, the status rules or anything downstream of a calibration.

### 1. Reference values are defined *under* an illuminant

A reference dataset is not a table of numbers that is true in general. It is
the rendering somebody decided a chart's patches should produce **under a
stated illuminant** — as section 13 already says, a defined false-colour
objective rather than colour accuracy. The illuminant is part of the
definition, not an annotation beside it.

Evidence is the same in the other direction: a measurement set records what a
camera produced under a stated illuminant, and outside that statement the
numbers describe nothing in particular.

So a fit pairs two illuminant statements, and until now nothing compared them.
`IRCalibrationFitter.fit` checked only that the two artefacts described the
same *target*. It would happily fit measurements recorded under
`measuredSPD("lamp-a.spd")` against values defined for `.d65`, or tungsten
evidence against an LED panel's reference, and report small residuals about it.

### 2. The rule: same recorded identity, and nothing more clever

> Two calibration illuminants are compatible only when their recorded identity
> is exactly the same.

```text
.d65              ↔ .d65                      compatible
.d50              ↔ .d50                      compatible
.namedOther("X")  ↔ .namedOther("X")          compatible
.measuredSPD("X") ↔ .measuredSPD("X")         compatible
.unknown          ↔ .unknown                  compatible, structurally

.d65              ↔ .d50                      refused
.d65              ↔ .measuredSPD("d65.spd")   refused
.namedOther("A")  ↔ .namedOther("B")          refused
.measuredSPD("A") ↔ .measuredSPD("B")         refused
.unknown          ↔ anything recorded         refused
```

The rule is conservative because the project's knowledge is. It reads no
spectral power distributions and compares none, so it cannot show that a
measured SPD is D65, that two differently named lamps match, or that one
standard illuminant approximates another in the infrared. A file called
`d65-measurement.csv` is a file name. A lamp called "Daylight LED" is a name.
Fuzzy matching, case folding and substring rules are all inventions of a
spectral comparison that has not been performed.

**"Same recorded identity" is not "proven identical spectrum."** Two records
saying "LED Panel A" are two people's words, and nothing here can check them.
What the rule guarantees is narrower and worth exactly what it says: nothing
pairs evidence with reference values that *state* different illumination.

### 3. `.unknown ↔ .unknown` stays constructible

Not because two unrecorded illuminants are known to match — they are not known
to be anything, and nothing derives a standard illuminant from `.unknown` in
either direction. It is allowed because the arithmetic is well defined on it
and refusing would stop somebody fitting data they already have.

What such a calibration may *claim* was already answered, in section 11 and by
the completeness rules: `.unknown` produces the `illuminantUnknown` evidence
gap, so the artefact's status is `experimental` and stays there. Structural
constructibility and evidential standing are separate questions, and this
amendment changes neither `experimental`, `measured` nor `validated`. A
compatible but merely *asserted* illuminant — matched `.d65` on both sides —
is still `illuminantNotMeasured`, exactly as before.

### 4. One authority, three enforcement points

The rule lives in `IRCalibrationIlluminantCompatibility`, which owns both the
comparison and the explanation a person reads. Three layers ask it:

```text
IRCalibrationFitter.fit        before the solver runs
IRCalibration.init             an artefact assembled in memory or read from a file
IRCalibrationFitVerifier       defensive second line
```

Each throws its own typed refusal — `IRCalibrationFitError.illuminantMismatch`,
`IRCalibrationError.illuminantMismatch`,
`IRCalibrationFitVerificationFailure.illuminantMismatch` — and all three
`failureReason`s come from the one shared text. Three layers, one definition.

`IRCalibrationFitter.derive` deliberately does **not** check it, for the same
reason it does not compare targets: that is a rule about the record, not a
property of the arithmetic, and `derive` is the one place the arithmetic lives.

The verifier's check is redundant against valid input, because `IRCalibration`
refuses an incompatible pair before verification runs. It is stated anyway: the
verifier is also called directly, and it must not depend on having been handed
a pair somebody else already checked.

### 5. Why the matrix self-verification could never have caught this

The second amendment made a calibration re-derive its own transform. That
catches an edited matrix, an edited residual, edited evidence and edited
reference values. It cannot catch this one, by construction:

> An illuminant mismatch moves no number. The same responses fitted against the
> same reference values produce the same coefficients, the same residuals and
> the same conditioning, whatever the two artefacts record about the light.

So changing one illuminant in a persisted file — the measurement's or the
reference's — leaves every arithmetic check satisfied and every identity string
matching. It is a defect in what the calibration *claims*, and it needs a
semantic rule. The suite demonstrates exactly that: a calibration that verifies
perfectly, with only its reference dataset's illuminant changed, is refused.

### 6. An illuminant identity has to say something

`.namedOther("")`, `.namedOther("   ")` and `.measuredSPD(reference: "")` were
all constructible, and an empty `.measuredSPD` still reported `isMeasured ==
true` — the strongest claim the type can make, pointing at no measurement at
all, and the one illuminant condition `IRCalibrationAcceptanceCriteria` is able
to require.

The two cases carrying text carry the *entire* identity of the illuminant in
that text. So:

- outer whitespace is trimmed, the same convention `identifier`, `version`,
  `source` and provenance already use;
- after trimming, an empty identity is refused;
- after trimming, the identity is **exact and case-sensitive**. `"LED Panel A"`
  and `"led panel a"` are two different records. These are evidence
  identifiers, not search terms, and case folding them would be a matching rule
  with nothing behind it — the person who wrote one of them meant what they
  wrote.

The enum shape is unchanged; there is no second illuminant representation. The
invariant lives in `IRCalibrationIlluminant.validated(field:)`, called by the
two domain boundaries that create calibration evidence —
`IRCalibrationMeasurementSet.init` and `IRCalibrationReferenceDataset.init`.
Decoding a persisted record goes through those same initialisers, so there is
no separate validation on the wire that could drift out of step, and an invalid
illuminant cannot reach a valid artefact from any direction.

Normalisation is idempotent, so re-validating an already-validated value —
which `IRCalibrationMeasurementSet.excluding(_:because:)` does — changes
nothing.

### 7. A reference dataset identity is produced by one pair only

`identity` is `identifier@version`, and a fit result stores that one string as
its entire record of what it aimed at. `IRCalibration` accepts an artefact when
the stored string matches the reference dataset beside it — a check worth
something only if one string can come from one pair. While `@` was permitted
inside either part it could not:

```text
identifier "a@b", version "c"    ->  a@b@c
identifier "a",   version "b@c"  ->  a@b@c
```

Two different revisions of two different tables of numbers, indistinguishable
to every identity check — exactly the confusion `version` exists to prevent.

The fix is the small one: the separator is declared once, as
`IRCalibrationReferenceDataset.identitySeparator`, and refused inside both
`identifier` and `version` by the initialiser, with the typed
`IRCalibrationError.ambiguousReferenceDatasetIdentity(field:token:)` naming
which field and why.

Refused rather than escaped or rewritten. A dataset identifier is a person's
own label for their evidence, and an artefact that silently names something
they did not write is worse than one that refuses. Trimming happens first, so
the rule sees the identifier that will actually be stored.

No typed identity object, and no wire-shape change: `identifier` and `version`
remain two separate fields, `identity` remains derived and is never persisted,
and the grammar remains `identifier@version`. **The calibration schema stays at
version 2.** A stronger redesign would have bought nothing this rule does not
already guarantee, and would have cost a migration.

### What did not change

- The calibration schema is still version 2; the wire format is byte-identical
  for every artefact that was valid before.
- `experimental`, `measured` and `validated` mean exactly what they meant.
  `IRCalibrationAcceptanceCriteria.project` is still `nil`, nothing reaches
  `validated`, and `isValidatedInfraredCalibration` is still `false` everywhere.
- The solver, its conditioning floor, the green collapse, the session
  white-balance rule, the clipping policy, the colour-plane signature and the
  agreement tolerance are untouched.
- No spectral data is read, stored or compared, and no SPD is consumed.
- Lens identity and lens scope, calibration applicability, profile→calibration
  references, chart homography, X-Trans geometry, acceptance thresholds and the
  measurement UI are all untouched, and no calibration reaches preview, export
  or a capture profile.
