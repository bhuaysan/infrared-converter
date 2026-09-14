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

The magnitude is justified from both sides. Above: the forward error of the
solve is bounded by roughly the condition number of the normal equations times
the machine epsilon, and the conditioning floor admits data whose worst case is
of order `1e-14`, so `1e-12` leaves two orders of magnitude of headroom. Below:
a coefficient, residual or determinant edited by a person differs in a digit
that is visible in the file. An edit small enough to pass this test changes no
number anybody reads.

The absolute floor exists because an exact fit has residuals of exactly zero,
and a relative comparison of `0` against `3e-17` compares nothing. Residuals
live in the working representation, where the magnitudes that matter are of
order `1`, so at that scale the two terms say the same thing.

If the solver's arithmetic ever changes enough to break bit-identity, the
answer is a fit-method version bump, not a wider tolerance.

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
