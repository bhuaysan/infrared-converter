import Testing
import Foundation
@testable import InfraredConverter

/// A calibration has to be able to justify its matrix from its own evidence.
///
/// Every test here attacks the same claim from a different side: that the nine
/// coefficients, the residual list and the solver diagnostics in an artefact
/// are the ones the stored measurements and the stored reference dataset
/// actually produce — and that an artefact where they are not is refused,
/// whether it was assembled in memory or read from a file.
@Suite("IRCalibration fit verification")
struct IRCalibrationFitVerificationTests {

    // MARK: - Rebuilding one field of a fit

    /// A copy of `fit` with one part replaced. Every tampering test below is
    /// one call to this.
    static func fit(
        _ fit: IRCalibrationFitResult,
        matrix: RAWColorMatrix3x3? = nil,
        method: IRCalibrationFitMethod? = nil,
        conditioning: IRCalibrationConditioning? = nil,
        metrics: IRCalibrationFitMetrics? = nil,
        whiteBalancePolicy: IRCalibrationWhiteBalancePolicy? = nil
    ) -> IRCalibrationFitResult {
        IRCalibrationFitResult(
            matrix: matrix ?? fit.matrix,
            sourceMeasurementID: fit.sourceMeasurementID,
            referenceDataset: fit.referenceDataset,
            whiteBalancePolicy: whiteBalancePolicy ?? fit.whiteBalancePolicy,
            method: method ?? fit.method,
            conditioning: conditioning ?? fit.conditioning,
            metrics: metrics ?? fit.metrics,
            fittedAt: fit.fittedAt
        )
    }

    /// The refusal `IRCalibration` gives for a tampered fit, or `nil` if it
    /// accepted one.
    static func refusal(
        _ calibration: IRCalibration, fit: IRCalibrationFitResult
    ) -> IRCalibrationFitVerificationFailure? {
        do {
            _ = try IRCalibration(
                id: calibration.id,
                name: calibration.name,
                measurements: calibration.measurements,
                reference: calibration.reference,
                fit: fit
            )
            return nil
        } catch {
            guard case .unverifiableFit(let failure) = error else { return nil }
            return failure
        }
    }

    // MARK: - Determinism, which is what makes verification possible at all

    /// The tolerance exists for a future compiler, not for today. Today the
    /// solver reproduces its own coefficients **exactly**, and this test is
    /// what would notice if that ever stopped being true — at which point the
    /// right answer is a fit-method version bump, not a wider tolerance.
    @Test("Re-deriving a fit from the same evidence reproduces it bit for bit")
    func derivationIsBitIdentical() throws {
        let measurements = CalibrationTestData.measurementSet(
            whiteBalancePolicy: .neutralPatch(CalibrationTestData.patch(20))
        )
        let reference = CalibrationTestData.referenceDataset(
            for: measurements,
            matrix: CalibrationTestData.syntheticMatrix,
            noise: [CalibrationTestData.patch(7): (0.03, -0.02, 0.01)]
        )

        let first = try IRCalibrationFitter.derive(
            measurements: measurements, reference: reference
        )
        let second = try IRCalibrationFitter.derive(
            measurements: measurements, reference: reference
        )

        #expect(first == second)
        #expect(first.matrix == second.matrix)
        #expect(first.conditioning == second.conditioning)
        #expect(first.residuals == second.residuals)
    }

    @Test("A fit produced by this build verifies against its own evidence")
    func anHonestFitVerifies() throws {
        for policy: IRCalibrationWhiteBalancePolicy in [
            .none, .neutralPatch(CalibrationTestData.patch(20)),
        ] {
            let measurements = CalibrationTestData.measurementSet(whiteBalancePolicy: policy)
            let reference = CalibrationTestData.referenceDataset(
                for: measurements, matrix: CalibrationTestData.syntheticMatrix
            )
            let fit = try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
            #expect(throws: Never.self) {
                try IRCalibrationFitVerifier().verify(
                    fit, measurements: measurements, reference: reference
                )
            }
        }
    }

    // MARK: - The matrix

    @Test("A matrix coefficient that does not follow from the evidence is refused")
    func tamperedMatrixRefused() throws {
        let calibration = try CalibrationTestData.calibration()
        let original = calibration.fit.matrix
        let tampered = try RAWColorMatrix3x3(
            m00: original.m00, m01: original.m01, m02: original.m02,
            m10: original.m10, m11: original.m11 + 0.01, m12: original.m12,
            m20: original.m20, m21: original.m21, m22: original.m22
        )

        guard case .matrixDisagrees(let row, let column, let stored, _)? = Self.refusal(
            calibration, fit: Self.fit(calibration.fit, matrix: tampered)
        ) else {
            Issue.record("Expected a matrix refusal")
            return
        }
        #expect(row == 1)
        #expect(column == 1)
        #expect(abs(stored - (original.m11 + 0.01)) < 1e-15)
    }

    /// Every coefficient is checked, not only the first one that happens to be
    /// looked at.
    @Test(
        "Each of the nine coefficients is verified",
        arguments: Array(0..<9)
    )
    func everyCoefficientIsVerified(index: Int) throws {
        let calibration = try CalibrationTestData.calibration()
        var values = calibration.fit.matrix.rows.flatMap { $0 }
        values[index] += 0.25
        let tampered = try RAWColorMatrix3x3(
            m00: values[0], m01: values[1], m02: values[2],
            m10: values[3], m11: values[4], m12: values[5],
            m20: values[6], m21: values[7], m22: values[8]
        )

        guard case .matrixDisagrees(let row, let column, _, _)? = Self.refusal(
            calibration, fit: Self.fit(calibration.fit, matrix: tampered)
        ) else {
            Issue.record("Coefficient \(index) was not verified")
            return
        }
        #expect(row * 3 + column == index)
    }

    // MARK: - Residuals

    @Test("A residual that does not follow from the evidence is refused")
    func tamperedResidualRefused() throws {
        let calibration = try CalibrationTestData.calibration()
        var residuals = calibration.fit.metrics.residuals
        let target = residuals[5]
        residuals[5] = try IRCalibrationPatchResidual(
            patch: target.patch, red: target.red + 0.002, green: target.green, blue: target.blue
        )

        let metrics = try IRCalibrationFitMetrics(
            residuals: residuals, excludedPatchCount: calibration.fit.metrics.excludedPatchCount
        )

        guard case .residualDisagrees(let patch, let channel, _, _)? = Self.refusal(
            calibration, fit: Self.fit(calibration.fit, metrics: metrics)
        ) else {
            Issue.record("Expected a residual refusal")
            return
        }
        #expect(patch == target.patch.rawValue)
        #expect(channel == "red")
    }

    /// The residual list is where a calibration's claim to be any good lives,
    /// so a plausible-looking one that was simply made up is refused too.
    @Test("A residual list of zeroes beside a real matrix is refused")
    func fabricatedZeroResidualsRefused() throws {
        let measurements = CalibrationTestData.measurementSet()
        let reference = CalibrationTestData.referenceDataset(
            for: measurements,
            matrix: CalibrationTestData.syntheticMatrix,
            noise: [
                CalibrationTestData.patch(2): (0.05, -0.04, 0.03),
                CalibrationTestData.patch(15): (-0.06, 0.02, 0.04),
            ]
        )
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Imperfect",
            measurements: measurements,
            reference: reference,
            fit: try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        )
        #expect(calibration.fit.metrics.rmse > 0)

        let flattered = try IRCalibrationFitMetrics(
            residuals: try calibration.fit.metrics.residuals.map {
                try IRCalibrationPatchResidual(patch: $0.patch, red: 0, green: 0, blue: 0)
            },
            excludedPatchCount: calibration.fit.metrics.excludedPatchCount
        )

        guard case .residualDisagrees? = Self.refusal(
            calibration, fit: Self.fit(calibration.fit, metrics: flattered)
        ) else {
            Issue.record("Expected a residual refusal")
            return
        }
    }

    // MARK: - Conditioning

    @Test("A normalised Gram determinant that does not follow from the evidence is refused")
    func tamperedDeterminantRefused() throws {
        let calibration = try CalibrationTestData.calibration()
        let stored = calibration.fit.conditioning
        let tampered = IRCalibrationConditioning(
            normalizedGramDeterminant: stored.normalizedGramDeterminant * 2,
            channelNorms: stored.channelNorms,
            sampleCount: stored.sampleCount
        )

        guard case .conditioningDisagrees(let field, _, _)? = Self.refusal(
            calibration, fit: Self.fit(calibration.fit, conditioning: tampered)
        ) else {
            Issue.record("Expected a conditioning refusal")
            return
        }
        #expect(field.contains("determinant"))
    }

    @Test("A channel norm that does not follow from the evidence is refused")
    func tamperedChannelNormRefused() throws {
        let calibration = try CalibrationTestData.calibration()
        let stored = calibration.fit.conditioning
        var norms = stored.channelNorms
        norms[2] += 0.5
        let tampered = IRCalibrationConditioning(
            normalizedGramDeterminant: stored.normalizedGramDeterminant,
            channelNorms: norms,
            sampleCount: stored.sampleCount
        )

        guard case .conditioningDisagrees(let field, _, _)? = Self.refusal(
            calibration, fit: Self.fit(calibration.fit, conditioning: tampered)
        ) else {
            Issue.record("Expected a conditioning refusal")
            return
        }
        #expect(field.contains("blue"))
    }

    @Test("A sample count that does not match the fitted patches is refused")
    func tamperedSampleCountRefused() throws {
        let calibration = try CalibrationTestData.calibration()
        let stored = calibration.fit.conditioning
        let tampered = IRCalibrationConditioning(
            normalizedGramDeterminant: stored.normalizedGramDeterminant,
            channelNorms: stored.channelNorms,
            sampleCount: stored.sampleCount + 6
        )

        guard case .sampleCountDisagrees(let claimed, let actual)? = Self.refusal(
            calibration, fit: Self.fit(calibration.fit, conditioning: tampered)
        ) else {
            Issue.record("Expected a sample-count refusal")
            return
        }
        #expect(claimed == stored.sampleCount + 6)
        #expect(actual == 24)
    }

    // MARK: - Fit method

    @Test(
        "A fit this build cannot reproduce is refused rather than trusted",
        arguments: [
            IRCalibrationFitMethod(algorithm: "least-squares-3x3", version: 2),
            IRCalibrationFitMethod(algorithm: "least-squares-3x3", version: 0),
            IRCalibrationFitMethod(algorithm: "qr-householder-3x3", version: 1),
            IRCalibrationFitMethod(algorithm: "", version: 1),
        ]
    )
    func unknownFitMethodRefused(method: IRCalibrationFitMethod) throws {
        #expect(!method.isReproducibleByThisBuild)

        let calibration = try CalibrationTestData.calibration()
        guard case .unreproducibleMethod(let algorithm, let version, let reproducible)? =
            Self.refusal(calibration, fit: Self.fit(calibration.fit, method: method))
        else {
            Issue.record("Expected a method refusal for \(method.identity)")
            return
        }
        #expect(algorithm == method.algorithm)
        #expect(version == method.version)
        #expect(reproducible == "least-squares-3x3@v1")
    }

    @Test("The method this build fits with is the one it can reproduce")
    func currentMethodIsReproducible() {
        #expect(IRCalibrationFitMethod.current.isReproducibleByThisBuild)
        #expect(IRCalibrationFitMethod.current.identity == "least-squares-3x3@v1")
    }

    // MARK: - The white balance the fit was computed under

    @Test("A fit recording a session balance its evidence does not is refused")
    func whiteBalancePolicyMismatchRefused() throws {
        let calibration = try CalibrationTestData.calibration()
        #expect(calibration.measurements.whiteBalancePolicy == .none)

        // The structural check in `IRCalibration` catches this one first, and
        // it must: the two authorities for the session balance may not
        // disagree however the numbers happen to come out.
        #expect(throws: IRCalibrationError.self) {
            _ = try IRCalibration(
                id: calibration.id,
                name: calibration.name,
                measurements: calibration.measurements,
                reference: calibration.reference,
                fit: Self.fit(
                    calibration.fit,
                    whiteBalancePolicy: .neutralPatch(CalibrationTestData.patch(20))
                )
            )
        }
    }

    /// The gains are not stored, so they cannot be tampered with directly —
    /// but they are re-derived inside the verification, which means a fit
    /// computed under different gains cannot survive it. Changing the neutral
    /// patch changes the whole matrix, and the stored one no longer follows.
    @Test("A fit computed from a different neutral patch does not verify")
    func fitFromAnotherNeutralPatchRefused() throws {
        let evidence = CalibrationTestData.measurementSet(
            whiteBalancePolicy: .neutralPatch(CalibrationTestData.patch(20))
        )
        let other = CalibrationTestData.measurementSet(
            whiteBalancePolicy: .neutralPatch(CalibrationTestData.patch(4))
        )
        let reference = CalibrationTestData.referenceDataset(
            for: evidence, matrix: CalibrationTestData.syntheticMatrix
        )

        // Both sets carry the same measurements and the same identity; only
        // the session's neutral reference differs.
        #expect(evidence.id == other.id)
        #expect(evidence.patches == other.patches)

        let foreignFit = try IRCalibrationFitter().fit(
            measurements: other, reference: reference, now: CalibrationTestData.fittedAt
        )

        #expect(throws: IRCalibrationError.self) {
            _ = try IRCalibration(
                id: CalibrationTestData.calibrationID(),
                name: "Balanced elsewhere",
                measurements: evidence,
                reference: reference,
                fit: foreignFit
            )
        }
    }

    // MARK: - The agreement rule itself

    @Test("A difference at the last places of a Double is agreement; a visible one is not")
    func toleranceBoundaries() {
        #expect(IRCalibrationFitAgreement.agree(stored: 1.0, recomputed: 1.0))
        #expect(IRCalibrationFitAgreement.agree(stored: 0, recomputed: 0))

        // A handful of ulps at unit scale: the drift the tolerance exists for.
        #expect(
            IRCalibrationFitAgreement.agree(
                stored: 1.0, recomputed: 1.0 + 8 * .ulpOfOne
            )
        )
        // Ten parts per billion: far smaller than any edit that means anything,
        // and still refused.
        #expect(
            !IRCalibrationFitAgreement.agree(stored: 1.0, recomputed: 1.0 + 1e-8)
        )
        #expect(
            !IRCalibrationFitAgreement.agree(stored: 1.0, recomputed: 1.0 + 1e-11)
        )

        // Scale-free: the same relative difference is judged the same way at
        // any magnitude that matters.
        #expect(IRCalibrationFitAgreement.agree(stored: 1e6, recomputed: 1e6 * (1 + 1e-13)))
        #expect(!IRCalibrationFitAgreement.agree(stored: 1e6, recomputed: 1e6 * (1 + 1e-9)))

        // Near zero, the absolute floor does the work a relative test cannot.
        #expect(IRCalibrationFitAgreement.agree(stored: 0, recomputed: 1e-17))
        #expect(!IRCalibrationFitAgreement.agree(stored: 0, recomputed: 1e-6))

        // Nothing non-finite is ever agreement.
        #expect(!IRCalibrationFitAgreement.agree(stored: .nan, recomputed: .nan))
        #expect(!IRCalibrationFitAgreement.agree(stored: .infinity, recomputed: .infinity))
    }

    /// A perturbation inside the tolerance is accepted, which is the whole
    /// point of having one: a stored artefact must survive last-place drift.
    @Test("A coefficient perturbed inside the tolerance still verifies")
    func withinToleranceStillVerifies() throws {
        let calibration = try CalibrationTestData.calibration()
        let original = calibration.fit.matrix
        let nudged = try RAWColorMatrix3x3(
            m00: original.m00 * (1 + 1e-14), m01: original.m01, m02: original.m02,
            m10: original.m10, m11: original.m11, m12: original.m12,
            m20: original.m20, m21: original.m21, m22: original.m22
        )
        #expect(nudged.m00 != original.m00)

        #expect(throws: Never.self) {
            _ = try IRCalibration(
                id: calibration.id,
                name: calibration.name,
                measurements: calibration.measurements,
                reference: calibration.reference,
                fit: Self.fit(calibration.fit, matrix: nudged)
            )
        }
    }

    // MARK: - Evidence that determines nothing

    /// A file can be edited so that its *measurements* no longer determine a
    /// transform at all. The matrix beside them then cannot have come from
    /// them, and the refusal says so rather than reporting a mismatch in the
    /// first coefficient.
    @Test("Evidence that no longer determines a transform is refused as such")
    func degenerateEvidenceIsRefused() throws {
        let calibration = try CalibrationTestData.calibration()

        // Every patch measured identically: three collinear camera columns.
        let flattened = try IRCalibrationMeasurementSet(
            id: calibration.measurements.id,
            measuredAt: calibration.measurements.measuredAt,
            target: calibration.measurements.target,
            illuminant: calibration.measurements.illuminant,
            captureContext: calibration.measurements.captureContext,
            colorPlaneSignature: calibration.measurements.colorPlaneSignature,
            normalization: calibration.measurements.normalization,
            whiteBalancePolicy: calibration.measurements.whiteBalancePolicy,
            patches: calibration.measurements.patches.map {
                CalibrationTestData.patchMeasurement(
                    $0.patch, red: 0.4, green: 0.4, blue: 0.4
                )
            },
            provenance: calibration.measurements.provenance,
            sourceFileName: calibration.measurements.sourceFileName
        )

        do {
            _ = try IRCalibration(
                id: calibration.id,
                name: calibration.name,
                measurements: flattened,
                reference: calibration.reference,
                fit: calibration.fit
            )
            Issue.record("Degenerate evidence was accepted")
        } catch {
            guard case .unverifiableFit(.refitRefused(let refusal)) = error else {
                Issue.record("Expected a refit refusal, got \(error)")
                return
            }
            switch refusal {
            case .illConditioned, .singularNormalEquations, .zeroChannelVariation:
                break
            default:
                Issue.record("Expected a degeneracy refusal, got \(refusal)")
            }
        }
    }
}
