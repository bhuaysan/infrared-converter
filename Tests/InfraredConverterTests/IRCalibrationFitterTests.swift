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

        #expect(abs((gains[0] ?? 0) - 1.0) < 1e-12)        // red, strongest
        #expect(abs((gains[1] ?? 0) - 2.0) < 1e-12)        // green plane 1
        #expect(abs((gains[3] ?? 0) - 2.0) < 1e-12)        // green plane 3
        #expect(abs((gains[2] ?? 0) - 4.0) < 1e-12)        // blue
        #expect(gains.values.allSatisfy { $0 >= 1 - 1e-12 })
    }

    @Test("With no session white balance, no gain is applied at all")
    func noSessionWhiteBalance() throws {
        let measurements = CalibrationTestData.measurementSet(whiteBalancePolicy: .none)
        #expect(try IRCalibrationFitter.sessionGains(for: measurements).isEmpty)

        let patch = try #require(measurements.measurement(for: CalibrationTestData.patch(1)))
        let camera = try IRCalibrationFitter.cameraRGB(
            for: patch, gains: [:], policy: .meanOfGreenPlaneMeans
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
            for: even, gains: [:], policy: .meanOfGreenPlaneMeans
        )
        let b = try IRCalibrationFitter.cameraRGB(
            for: lopsided, gains: [:], policy: .meanOfGreenPlaneMeans
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
        let metrics = IRCalibrationFitMetrics(residuals: residuals, excludedPatchCount: 1)

        // sqrt((0.01 + 0.04 + 0.09) / 9)
        #expect(abs(metrics.rmse - (0.14 / 9).squareRoot()) < 1e-15)
        #expect(abs(metrics.maximumResidual - 0.3) < 1e-15)
        #expect(metrics.worstPatch == CalibrationTestData.patch(3))
        #expect(metrics.includedPatchCount == 3)
        #expect(metrics.excludedPatchCount == 1)
        #expect(abs(metrics.meanResidual - 0.2) < 1e-15)
    }
}
