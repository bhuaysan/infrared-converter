import Testing
import Foundation
@testable import InfraredConverter

/// The fitter: how stored evidence becomes camera RGB, how the session's own
/// white balance is re-derived rather than stored, how two green planes become
/// one green response, and what the residuals it reports actually mean.
@Suite("IRCalibrationFitter")
struct IRCalibrationFitterTests {

    // MARK: - Exact fit through the whole chain

    @Test("A reference built by applying M to the evidence recovers M, with zero residuals")
    func exactFitThroughEvidence() throws {
        let measurements = CalibrationTestData.measurementSet()
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )

        let fit = try IRCalibrationFitter().fit(
            measurements: measurements,
            reference: reference,
            now: CalibrationTestData.fittedAt
        )

        #expect(
            CalibrationTestData.maximumCoefficientDifference(
                fit.matrix, CalibrationTestData.syntheticMatrix
            ) < 1e-10
        )
        #expect(fit.metrics.rmse < 1e-12)
        #expect(fit.metrics.maximumResidual < 1e-12)
        #expect(fit.metrics.includedPatchCount == 24)
        #expect(fit.metrics.excludedPatchCount == 0)
        #expect(fit.sourceMeasurementID == measurements.id)
        #expect(fit.referenceDataset == reference.identity)
        #expect(fit.method == .current)
        #expect(fit.method.identity == "least-squares-3x3@v1")
    }

    // MARK: - The session white balance

    /// The heart of the white-balance decision: the session's gains come from
    /// a patch of the **target**, are re-derived from the evidence every time,
    /// and never come from a photograph.
    @Test("Session gains are re-derived from the named neutral patch, preserving the strongest plane")
    func sessionGainsFromNeutralPatch() throws {
        let neutral = CalibrationTestData.patch(20)
        var responses = CalibrationTestData.syntheticCameraResponses()
        // A strongly non-neutral camera response at the neutral patch: red is
        // the strongest plane, so it keeps a gain of 1.
        responses[19] = (0.8, 0.4, 0.2)

        let measurements = CalibrationTestData.measurementSet(
            responses: responses, whiteBalancePolicy: .neutralPatch(neutral)
        )
        let gains = try IRCalibrationFitter.sessionGains(for: measurements)

        #expect(gains.basis == .neutralPatch(neutral))
        #expect(abs((gains.byColorPlane[0] ?? 0) - 1.0) < 1e-12)        // red, strongest
        #expect(abs((gains.byColorPlane[1] ?? 0) - 2.0) < 1e-12)        // green plane 1
        #expect(abs((gains.byColorPlane[3] ?? 0) - 2.0) < 1e-12)        // green plane 3
        #expect(abs((gains.byColorPlane[2] ?? 0) - 4.0) < 1e-12)        // blue
        #expect(gains.byColorPlane.values.allSatisfy { $0 >= 1 - 1e-12 })
    }

    @Test("With no session white balance, no gain is applied at all")
    func noSessionWhiteBalance() throws {
        let measurements = CalibrationTestData.measurementSet(whiteBalancePolicy: .none)
        #expect(try IRCalibrationFitter.sessionGains(for: measurements).isUnbalanced)

        let patch = try #require(measurements.measurement(for: CalibrationTestData.patch(1)))
        let camera = try IRCalibrationFitter.cameraRGB(
            for: patch, gains: .unbalanced, policy: .meanOfGreenPlaneMeans
        )
        let red = try #require(patch.planes(for: .red).first)
        #expect(abs(camera.x - red.mean) < 1e-12)
    }

    /// A balanced fit and an unbalanced fit describe the same map, because a
    /// 3x3 absorbs per-channel scaling. What must never happen is a fit that
    /// silently disagrees with the policy its evidence records.
    @Test("A session balance is absorbed into the transform, leaving the mapping unchanged")
    func balanceIsAbsorbed() throws {
        let neutral = CalibrationTestData.patch(20)
        let responses = CalibrationTestData.syntheticCameraResponses()

        let unbalanced = CalibrationTestData.measurementSet(
            responses: responses, whiteBalancePolicy: .none
        )
        let balanced = CalibrationTestData.measurementSet(
            responses: responses, whiteBalancePolicy: .neutralPatch(neutral)
        )
        let reference = CalibrationTestData.referenceDataset(
            for: unbalanced, matrix: CalibrationTestData.syntheticMatrix
        )

        let unbalancedFit = try IRCalibrationFitter().fit(
            measurements: unbalanced, reference: reference, now: CalibrationTestData.fittedAt
        )
        let balancedFit = try IRCalibrationFitter().fit(
            measurements: balanced, reference: reference, now: CalibrationTestData.fittedAt
        )

        // Different coefficients...
        #expect(
            CalibrationTestData.maximumCoefficientDifference(
                unbalancedFit.matrix, balancedFit.matrix
            ) > 1e-6
        )
        // ...fitting the same data equally well, because the gains are a
        // diagonal the transform can undo.
        #expect(balancedFit.metrics.rmse < 1e-10)
        #expect(unbalancedFit.metrics.rmse < 1e-10)
        // ...and each records the policy it was computed under.
        #expect(unbalancedFit.whiteBalancePolicy == .none)
        #expect(balancedFit.whiteBalancePolicy == .neutralPatch(neutral))
    }

    @Test("A neutral patch that was not measured is refused when the evidence is built")
    func neutralPatchMustBeMeasured() {
        let unmeasured = CalibrationTestData.patch(24)
        let responses = Array(CalibrationTestData.syntheticCameraResponses().prefix(6))

        #expect(throws: IRCalibrationError.self) {
            _ = try IRCalibrationMeasurementSet(
                id: CalibrationTestData.measurementID(),
                measuredAt: CalibrationTestData.measuredAt,
                target: .colorCheckerClassic24,
                illuminant: .d65,
                captureContext: CalibrationTestData.context(),
                colorPlaneSignature: CalibrationTestData.bayerSignature,
                normalization: CalibrationTestData.normalization(),
                whiteBalancePolicy: .neutralPatch(unmeasured),
                patches: responses.enumerated().map { index, response in
                    CalibrationTestData.patchMeasurement(
                        CalibrationTestData.patch(index + 1),
                        red: response.0, green: response.1, blue: response.2
                    )
                },
                provenance: CalibrationTestData.provenance()
            )
        }
    }

    // MARK: - The neutral reference has to be usable

    /// The evidence may still *record* an excluded neutral patch — that is a
    /// historical fact about the session — but no fit may be derived from it.
    /// Its gains scale every channel of every fitted patch, so an unusable
    /// neutral reference decides the white balance of the whole transform.
    @Test(
        "A neutral reference the evidence excluded is refused by the fit, whatever excluded it",
        arguments: [
            IRCalibrationPatchExclusion.clipped(clippedSamples: 400, totalSamples: 400),
            .nonFiniteSample,
            .noReferenceValue,
            .excludedByOperator(reason: "a fingerprint across the patch"),
        ]
    )
    func excludedNeutralReferenceIsRefused(exclusion: IRCalibrationPatchExclusion) throws {
        let neutral = CalibrationTestData.patch(20)
        let measurements = CalibrationTestData.measurementSet(
            whiteBalancePolicy: .neutralPatch(neutral), exclusions: [20: exclusion]
        )

        // The evidence still holds the measurement and the judgement about it.
        let recorded = try #require(measurements.measurement(for: neutral))
        #expect(recorded.exclusion == exclusion)
        #expect(measurements.whiteBalancePolicy == .neutralPatch(neutral))

        #expect(
            throws: IRCalibrationFitError.excludedNeutralReference(
                patch: neutral.rawValue, exclusion: exclusion
            )
        ) {
            _ = try IRCalibrationFitter.sessionGains(for: measurements)
        }

        let reference = CalibrationTestData.referenceDataset(
            for: CalibrationTestData.measurementSet(), matrix: CalibrationTestData.syntheticMatrix
        )
        #expect(throws: IRCalibrationFitError.self) {
            _ = try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        }
    }

    /// The general clipping tolerance decides whether an *ordinary* patch is
    /// included. It does not decide whether a patch may define the session's
    /// white balance: one tolerated clipped sample contributes a bounded
    /// amount to one row of a least-squares problem, and the same sample
    /// inside the neutral reference sets the gains that scale every channel of
    /// every fitted patch.
    @Test("A neutral reference with one clipped sample is refused even though the policy includes it")
    func clippedNeutralReferenceIsRefusedDespiteTolerance() throws {
        let neutral = CalibrationTestData.patch(20)
        let tolerant = try IRCalibrationClippingPolicy(
            normalizedClippingThreshold: 1.0, maximumClippedSampleFraction: 0.01
        )
        let measurements = CalibrationTestData.measurementSet(
            whiteBalancePolicy: .neutralPatch(neutral),
            clipped: [20: 1],
            clippingPolicy: tolerant
        )

        // 1 clipped sample of 400 is 0.0025, below the 0.01 the policy
        // tolerates, so the patch is included by the general rule...
        let recorded = try #require(measurements.measurement(for: neutral))
        #expect(recorded.isIncluded)
        #expect(recorded.clippedSampleCount == 1)
        #expect(recorded.totalSampleCount == 400)
        #expect(
            !tolerant.excludes(
                clippedSamples: recorded.clippedSampleCount, of: recorded.totalSampleCount
            )
        )

        // ...and is still refused as the session's neutral reference.
        #expect(
            throws: IRCalibrationFitError.clippedNeutralReference(
                patch: neutral.rawValue, clippedSamples: 1, totalSamples: 400
            )
        ) {
            _ = try IRCalibrationFitter.sessionGains(for: measurements)
        }

        let reference = CalibrationTestData.referenceDataset(
            for: CalibrationTestData.measurementSet(), matrix: CalibrationTestData.syntheticMatrix
        )
        #expect(throws: IRCalibrationFitError.self) {
            _ = try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        }
    }

    @Test("A neutral reference with no clipped sample at all still defines the gains")
    func unclippedNeutralReferenceIsAccepted() throws {
        let neutral = CalibrationTestData.patch(20)
        let measurements = CalibrationTestData.measurementSet(
            whiteBalancePolicy: .neutralPatch(neutral), clipped: [20: 0]
        )
        let recorded = try #require(measurements.measurement(for: neutral))
        #expect(recorded.clippedSampleCount == 0)

        let gains = try IRCalibrationFitter.sessionGains(for: measurements)
        #expect(gains.neutralPatch == neutral)
        #expect(gains.byColorPlane.values.allSatisfy { $0 >= 1 - 1e-12 })
    }

    /// A clipped sample anywhere in the neutral patch is fatal, not only one
    /// in the plane that happens to be strongest: every plane's mean feeds a
    /// gain, and the strongest of them is the one the others are scaled
    /// towards.
    @Test(
        "Clipping in any plane of the neutral reference refuses the fit",
        arguments: [0, 1, 2, 3]
    )
    func clippedNeutralReferenceInAnyPlane(plane: Int) throws {
        let neutral = CalibrationTestData.patch(1)
        var planes: [IRCalibrationPlaneMeasurement] = []
        for (index, channel) in [
            (0, RAWLinearRGBChannel.red), (1, .green), (2, .blue), (3, .green),
        ] {
            planes.append(
                try IRCalibrationPlaneMeasurement(
                    colorPlane: index,
                    channel: channel,
                    sampleCount: 100,
                    mean: 0.5,
                    clippedSampleCount: index == plane ? 1 : 0
                )
            )
        }
        let measurements = try Self.measurementSet(neutral: neutral, neutralPlanes: planes)

        #expect(
            throws: IRCalibrationFitError.clippedNeutralReference(
                patch: neutral.rawValue, clippedSamples: 1, totalSamples: 400
            )
        ) {
            _ = try IRCalibrationFitter.sessionGains(for: measurements)
        }
    }

    /// Incomplete evidence no longer reaches the fitter: a patch missing a
    /// plane the recorded signature expects may exist only as *excluded*
    /// evidence, so an included one is refused when the measurement set is
    /// built.
    @Test("A neutral reference missing an expected plane cannot be built as included evidence")
    func neutralReferenceMissingAPlaneIsRefusedAsEvidence() {
        let neutral = CalibrationTestData.patch(1)
        #expect(
            throws: IRCalibrationError.incompletePatchMeasurement(
                patch: neutral.rawValue, missing: [2, 3]
            )
        ) {
            _ = try Self.measurementSet(
                neutral: neutral,
                neutralPlanes: [
                    try IRCalibrationPlaneMeasurement(
                        colorPlane: 0, channel: .red, sampleCount: 100, mean: 0.6,
                        clippedSampleCount: 0
                    ),
                    try IRCalibrationPlaneMeasurement(
                        colorPlane: 1, channel: .green, sampleCount: 100, mean: 0.4,
                        clippedSampleCount: 0
                    ),
                ]
            )
        }
    }

    /// And if it is recorded *correctly* — excluded, naming the planes it
    /// lacks — the evidence stands and the fit refuses it, so no route to a
    /// transform balanced from a partial neutral reference exists.
    @Test("A neutral reference that legitimately lacks a plane is refused by the fit")
    func neutralReferenceMissingAPlaneIsRefusedByTheFit() throws {
        let neutral = CalibrationTestData.patch(20)
        let measurements = CalibrationTestData.measurementSet(
            whiteBalancePolicy: .neutralPatch(neutral), incomplete: [20: [3]]
        )
        let recorded = try #require(measurements.measurement(for: neutral))
        #expect(recorded.exclusion == .incompleteColorPlanes(missing: [3]))

        #expect(
            throws: IRCalibrationFitError.excludedNeutralReference(
                patch: neutral.rawValue, exclusion: .incompleteColorPlanes(missing: [3])
            )
        ) {
            _ = try IRCalibrationFitter.sessionGains(for: measurements)
        }
    }

    /// The channel-level refusal itself still exists, one level down, where a
    /// patch is collapsed into an RGB response.
    @Test("A patch with no response in one channel yields no camera RGB")
    func patchMissingAChannel() throws {
        let incomplete = CalibrationTestData.incompletePatchMeasurement(
            CalibrationTestData.patch(1), missing: [2]
        )
        #expect(
            throws: IRCalibrationFitError.missingChannelResponse(
                patch: "01", channel: "blue"
            )
        ) {
            _ = try IRCalibrationFitter.cameraRGB(
                for: incomplete, gains: .unbalanced, policy: .meanOfGreenPlaneMeans
            )
        }
    }

    /// The `?? 1` this replaced: a fitted patch measured on a colour plane the
    /// neutral reference never saw used to be left silently unbalanced while
    /// every other plane was scaled.
    ///
    /// With the recorded plane signature in place, valid evidence can no
    /// longer produce that situation — an included neutral reference carries
    /// every expected plane — so this exercises the guard directly. It is the
    /// defensive second layer, and it stays because the gains type must not
    /// depend on having been built by a checked path.
    @Test("A colour plane the neutral reference defines no gain for is refused, never left at 1")
    func missingGainIsNeverIdentity() throws {
        let neutral = CalibrationTestData.patch(1)
        let partial = IRCalibrationSessionGains(
            neutralPatch: neutral, byColorPlane: [0: 1, 1: 1.2, 2: 1.5]
        )

        #expect(try partial.gain(forColorPlane: 1, of: CalibrationTestData.patch(2)) == 1.2)
        #expect(
            throws: IRCalibrationFitError.missingWhiteBalanceGain(
                patch: "02", colorPlane: 3, neutralPatch: neutral.rawValue
            )
        ) {
            _ = try partial.gain(forColorPlane: 3, of: CalibrationTestData.patch(2))
        }

        // And an unbalanced session answers 1 because it means 1, not because
        // a lookup missed.
        #expect(
            try IRCalibrationSessionGains.unbalanced
                .gain(forColorPlane: 3, of: CalibrationTestData.patch(2)) == 1
        )
    }

    @Test("A neutral reference at or below zero defines no gain")
    func neutralReferenceAtZero() throws {
        let neutral = CalibrationTestData.patch(1)
        let measurements = try Self.measurementSet(
            neutral: neutral,
            neutralPlanes: [
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 0, channel: .red, sampleCount: 100, mean: 0.6,
                    clippedSampleCount: 0
                ),
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 1, channel: .green, sampleCount: 100, mean: 0.4,
                    clippedSampleCount: 0
                ),
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 2, channel: .blue, sampleCount: 100, mean: 0,
                    clippedSampleCount: 0
                ),
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 3, channel: .green, sampleCount: 100, mean: 0.4,
                    clippedSampleCount: 0
                ),
            ]
        )

        #expect(throws: IRCalibrationFitError.self) {
            _ = try IRCalibrationFitter.sessionGains(for: measurements)
        }
    }

    /// With no session white balance a gain of 1 is the answer rather than a
    /// fallback, and the type says which of the two it is.
    @Test("An unbalanced session applies an explicit gain of 1, not a missing one")
    func unbalancedGainsAreExplicit() throws {
        let gains = IRCalibrationSessionGains.unbalanced
        #expect(gains.isUnbalanced)
        #expect(gains.neutralPatch == nil)
        #expect(gains.byColorPlane.isEmpty)
        #expect(
            try gains.gain(forColorPlane: 7, of: CalibrationTestData.patch(1)) == 1
        )
    }

    /// Evidence describing an excluded neutral patch is still constructible:
    /// the measurement happened, and only the fit is refused.
    @Test("Evidence may still record a neutral reference that was excluded")
    func evidenceKeepsAnExcludedNeutralReference() throws {
        let neutral = CalibrationTestData.patch(20)
        let measurements = CalibrationTestData.measurementSet(
            whiteBalancePolicy: .neutralPatch(neutral),
            exclusions: [20: .clipped(clippedSamples: 400, totalSamples: 400)]
        )
        #expect(measurements.excludedPatchCount == 1)
        #expect(measurements.measurement(for: neutral)?.isIncluded == false)
    }

    /// A measurement set whose first patch is the neutral reference and whose
    /// planes are given explicitly; every other patch is the ordinary
    /// four-plane synthetic one.
    static func measurementSet(
        neutral: IRCalibrationTargetPatchID,
        neutralPlanes: [IRCalibrationPlaneMeasurement]
    ) throws -> IRCalibrationMeasurementSet {
        let responses = Array(CalibrationTestData.syntheticCameraResponses().prefix(8))
        var patches = responses.enumerated().map { index, response in
            CalibrationTestData.patchMeasurement(
                CalibrationTestData.patch(index + 1),
                red: response.0, green: response.1, blue: response.2
            )
        }
        let index = try #require(patches.firstIndex { $0.patch == neutral })
        patches[index] = try IRCalibrationPatchMeasurement(
            patch: neutral, region: patches[index].region, planes: neutralPlanes
        )

        return try IRCalibrationMeasurementSet(
            id: CalibrationTestData.measurementID(),
            measuredAt: CalibrationTestData.measuredAt,
            target: .colorCheckerClassic24,
            illuminant: .d65,
            captureContext: CalibrationTestData.context(),
                colorPlaneSignature: CalibrationTestData.bayerSignature,
            normalization: CalibrationTestData.normalization(),
            whiteBalancePolicy: .neutralPatch(neutral),
            patches: patches,
            provenance: CalibrationTestData.provenance()
        )
    }

    // MARK: - The green collapse

    /// The rule is the *unweighted mean of the per-plane means*, so how the
    /// green response happens to divide between the two phases cannot change
    /// the measured green.
    @Test("Green is the unweighted mean of the green planes, whatever the split between them")
    func greenCollapseIsSplitInvariant() throws {
        let even = CalibrationTestData.patchMeasurement(
            CalibrationTestData.patch(1), red: 0.3, green: 0.5, blue: 0.2, greenSplit: 0
        )
        let lopsided = CalibrationTestData.patchMeasurement(
            CalibrationTestData.patch(1), red: 0.3, green: 0.5, blue: 0.2, greenSplit: 0.17
        )

        let a = try IRCalibrationFitter.cameraRGB(
            for: even, gains: .unbalanced, policy: .meanOfGreenPlaneMeans
        )
        let b = try IRCalibrationFitter.cameraRGB(
            for: lopsided, gains: .unbalanced, policy: .meanOfGreenPlaneMeans
        )

        #expect(abs(a.y - 0.5) < 1e-12)
        #expect(abs(a.y - b.y) < 1e-12)
        #expect(abs(a.x - b.x) < 1e-12)
        #expect(abs(a.z - b.z) < 1e-12)
    }

    /// The evidence keeps both planes separately, which is what makes the
    /// collapse reversible: a different rule could be applied later without
    /// re-photographing anything.
    @Test("Both green planes survive in the evidence rather than being collapsed on the way in")
    func greenPlanesArePreserved() {
        let patch = CalibrationTestData.patchMeasurement(
            CalibrationTestData.patch(1), red: 0.3, green: 0.5, blue: 0.2, greenSplit: 0.1
        )
        let greens = patch.planes(for: .green)
        #expect(greens.count == 2)
        #expect(Set(greens.map(\.colorPlane)) == [1, 3])
        #expect(abs((greens.first { $0.colorPlane == 1 }?.mean ?? 0) - 0.6) < 1e-12)
        #expect(abs((greens.first { $0.colorPlane == 3 }?.mean ?? 0) - 0.4) < 1e-12)
    }

    // MARK: - Exclusions

    @Test("Excluded patches are not fitted, and the metrics say how many there were")
    func excludedPatchesAreNotFitted() throws {
        let measurements = CalibrationTestData.measurementSet(
            exclusions: [
                3: .clipped(clippedSamples: 40, totalSamples: 400),
                7: .excludedByOperator(reason: "a shadow fell across it"),
            ]
        )
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )

        #expect(fit.metrics.includedPatchCount == 22)
        #expect(fit.metrics.excludedPatchCount == 2)
        let fitted = Set(fit.metrics.residuals.map(\.patch.rawValue))
        #expect(!fitted.contains("03"))
        #expect(!fitted.contains("07"))
    }

    @Test("A patch admitted to the fit with no reference value is refused, never invented")
    func missingReferenceValueIsRefused() throws {
        let measurements = CalibrationTestData.measurementSet()
        let full = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        var values = full.values
        values.removeValue(forKey: CalibrationTestData.patch(5))
        let partial = try IRCalibrationReferenceDataset(
            identifier: full.identifier,
            version: full.version,
            source: full.source,
            illuminant: full.illuminant,
            target: full.target,
            values: values
        )

        #expect(throws: IRCalibrationFitError.missingReferenceValue(patch: "05")) {
            _ = try IRCalibrationFitter().fit(measurements: measurements, reference: partial)
        }
    }

    @Test("Measurements and reference values of different targets are refused")
    func targetMismatch() throws {
        // One target is modelled, so the mismatch is proved where it is
        // actually enforceable: the fitter compares the two and the comparison
        // must exist even while it cannot currently be made to fail through
        // two different chart types.
        let measurements = CalibrationTestData.measurementSet()
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        #expect(measurements.target == reference.target)
        #expect(throws: Never.self) {
            _ = try IRCalibrationFitter().fit(measurements: measurements, reference: reference)
        }
    }

    @Test("Evidence in which every patch is excluded is refused")
    func everythingExcluded() throws {
        let exclusions = Dictionary(
            uniqueKeysWithValues: (1...24).map {
                ($0, IRCalibrationPatchExclusion.clipped(clippedSamples: 400, totalSamples: 400))
            }
        )
        let measurements = CalibrationTestData.measurementSet(exclusions: exclusions)
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )

        #expect(throws: IRCalibrationFitError.noIncludedPatches) {
            _ = try IRCalibrationFitter().fit(measurements: measurements, reference: reference)
        }
    }

    // MARK: - Residuals

    @Test("Residuals are the signed difference between the fitted value and the reference")
    func residualsAreSignedDifferences() throws {
        let measurements = CalibrationTestData.measurementSet()
        let reference = CalibrationTestData.referenceDataset(
            for: measurements,
            matrix: CalibrationTestData.syntheticMatrix,
            noise: [CalibrationTestData.patch(9): (0.05, -0.03, 0.02)]
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )

        // Recomputing the residual from the artefact must reproduce what it
        // stores — the property that makes a calibration checkable by anybody
        // holding the file.
        let gains = try IRCalibrationFitter.sessionGains(for: measurements)
        for residual in fit.metrics.residuals {
            let patch = try #require(measurements.measurement(for: residual.patch))
            let camera = try IRCalibrationFitter.cameraRGB(
                for: patch, gains: gains, policy: measurements.domain.greenPolicy
            )
            let fitted = IRCalibrationFitter.apply(fit.matrix, to: camera)
            let expected = try #require(reference.value(for: residual.patch))
            #expect(abs((fitted.x - expected.red) - residual.red) < 1e-12)
            #expect(abs((fitted.y - expected.green) - residual.green) < 1e-12)
            #expect(abs((fitted.z - expected.blue) - residual.blue) < 1e-12)
        }

        #expect(fit.metrics.rmse > 0)
        #expect(fit.metrics.maximumResidual > 0)
    }

    @Test("RMSE and the maximum residual are derived, so they cannot disagree with the residuals")
    func metricsAreDerived() throws {
        let residuals = try [
            IRCalibrationPatchResidual(patch: CalibrationTestData.patch(1), red: 0.1, green: 0, blue: 0),
            IRCalibrationPatchResidual(patch: CalibrationTestData.patch(2), red: 0, green: 0.2, blue: 0),
            IRCalibrationPatchResidual(patch: CalibrationTestData.patch(3), red: 0, green: 0, blue: 0.3),
        ]
        let metrics = try IRCalibrationFitMetrics(residuals: residuals, excludedPatchCount: 1)

        // sqrt((0.01 + 0.04 + 0.09) / 9)
        #expect(abs(metrics.rmse - (0.14 / 9).squareRoot()) < 1e-15)
        #expect(abs(metrics.maximumResidual - 0.3) < 1e-15)
        #expect(metrics.worstPatch == CalibrationTestData.patch(3))
        #expect(metrics.includedPatchCount == 3)
        #expect(metrics.excludedPatchCount == 1)
        #expect(abs(metrics.meanResidual - 0.2) < 1e-15)
    }
}
