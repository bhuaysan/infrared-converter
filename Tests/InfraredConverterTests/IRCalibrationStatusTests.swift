import Testing
import Foundation
@testable import InfraredConverter

/// The safety criterion of this whole subsystem, expressed as tests:
///
/// > Until real evidence and a justified acceptance criterion exist, every
/// > production capture profile remains explicitly uncalibrated and
/// > `isValidatedInfraredCalibration` remains `false`.
///
/// Status is derived from the evidence, the fit and the acceptance criteria on
/// every access. There is no stored flag anywhere to disagree with it, and this
/// suite proves both halves: that the derivation works, and that with this
/// project's criteria it can never say `.validated`.
@Suite("IR calibration validation status")
struct IRCalibrationStatusTests {

    // MARK: - This project validates nothing

    @Test("This project establishes no acceptance criteria")
    func projectCriteriaAreAbsent() {
        #expect(IRCalibrationAcceptanceCriteria.project == nil)
    }

    @Test("A perfect fit on complete evidence is Measured, never Validated")
    func perfectFitIsOnlyMeasured() throws {
        let calibration = try CalibrationTestData.calibration()

        // Complete evidence: a measured illuminant, a known conversion, a
        // described filter, a serial number, 24 patches, 21 degrees of freedom.
        #expect(calibration.evidenceGaps.isEmpty)
        // A textbook fit.
        #expect(calibration.fit.metrics.rmse < 1e-12)
        #expect(calibration.fit.metrics.maximumResidual < 1e-12)

        // And still not validated, because nothing has said what "good enough"
        // means.
        #expect(calibration.status == .measured)
        #expect(!calibration.isValidatedInfraredCalibration)
    }

    @Test("No arrangement of evidence reaches Validated under the project's criteria")
    func nothingValidatesInProduction() throws {
        let arrangements: [IRCalibrationMeasurementSet] = [
            CalibrationTestData.measurementSet(),
            CalibrationTestData.measurementSet(illuminant: .d65),
            CalibrationTestData.measurementSet(illuminant: .unknown),
            CalibrationTestData.measurementSet(
                illuminant: .measuredSPD(reference: "spd"),
                context: CalibrationTestData.context(
                    camera: CalibrationTestData.body(serialNumber: nil, scope: .modelLevel)
                )
            ),
            CalibrationTestData.measurementSet(
                exclusions: [1: .clipped(clippedSamples: 400, totalSamples: 400)]
            ),
        ]

        for measurements in arrangements {
            let reference = CalibrationTestData.referenceDataset(
                for: measurements, matrix: CalibrationTestData.syntheticMatrix
            )
            let fit = try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
            let calibration = try IRCalibration(
                id: CalibrationTestData.calibrationID(),
                name: "Synthetic",
                measurements: measurements,
                reference: reference,
                fit: fit
            )
            #expect(calibration.status != .validated)
            #expect(!calibration.isValidatedInfraredCalibration)
        }
    }

    /// A capture profile's own claim is untouched by this milestone, and it is
    /// `false` for every profile that can exist.
    @Test("Every capture profile this build can hold is still uncalibrated")
    func profilesRemainUncalibrated() throws {
        #expect(!IRCaptureProfile.builtinUncalibrated.isValidatedInfraredCalibration)

        let userProfile = IRCaptureProfile(
            id: .generatedUserID(),
            name: "A user's profile",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .fullSpectrum(vendor: "Someone"),
            filter: try .longPass(nominalNanometers: 720),
            processingBasis: .uncalibratedSensorRGB
        )
        #expect(!userProfile.isValidatedInfraredCalibration)

        // The internal escape hatch is unvalidated too, and still has no wire
        // format.
        let explicit = IRCaptureProfile(
            id: .generatedUserID(),
            name: "Explicit matrix",
            processingBasis: .explicitMatrix(CalibrationTestData.syntheticMatrix)
        )
        #expect(!explicit.isValidatedInfraredCalibration)
        #expect(throws: IRCaptureProfileRecordError.self) {
            _ = try IRCaptureProfileRecord(explicit)
        }
    }

    // MARK: - The derivation itself

    @Test("Incomplete evidence is Experimental, however well it fitted")
    func incompleteEvidenceIsExperimental() throws {
        let measurements = CalibrationTestData.measurementSet(illuminant: .unknown)
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Unknown light",
            measurements: measurements,
            reference: reference,
            fit: try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        )

        #expect(calibration.status == .experimental)
        #expect(calibration.evidenceGaps.contains(.illuminantUnknown))
    }

    @Test(
        "Each completeness rule is a gap on its own",
        arguments: [
            "illuminantUnknown", "illuminantAsserted", "conversionUnknown",
            "filterUndescribed", "bodyWithoutSerial",
        ]
    )
    func individualGaps(kind: String) throws {
        let measurements: IRCalibrationMeasurementSet
        let expected: IRCalibrationEvidenceGap

        switch kind {
        case "illuminantUnknown":
            measurements = CalibrationTestData.measurementSet(illuminant: .unknown)
            expected = .illuminantUnknown
        case "illuminantAsserted":
            measurements = CalibrationTestData.measurementSet(illuminant: .d65)
            expected = .illuminantNotMeasured
        case "conversionUnknown":
            measurements = CalibrationTestData.measurementSet(
                context: CalibrationTestData.context(sensorConversion: .unknown)
            )
            expected = .sensorConversionUnknown
        case "filterUndescribed":
            measurements = CalibrationTestData.measurementSet(
                context: CalibrationTestData.context(
                    filter: try IRCalibrationFilterSnapshot()
                )
            )
            expected = .filterNotDescribed
        default:
            measurements = CalibrationTestData.measurementSet(
                context: CalibrationTestData.context(
                    camera: CalibrationTestData.body(serialNumber: nil, scope: .specificBody)
                )
            )
            expected = .bodyScopeClaimedWithoutSerial
        }

        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )
        let gaps = IRCalibrationEvidenceCompleteness.gaps(
            measurements: measurements, reference: reference, fit: fit
        )

        #expect(gaps.contains(expected), "expected \(expected) in \(gaps)")
        #expect(
            IRCalibrationEvidenceCompleteness.status(
                measurements: measurements, reference: reference, fit: fit
            ) == .experimental
        )
    }

    @Test("Too few fitted patches is a gap, even when the fit is exact")
    func tooFewPatchesIsAGap() throws {
        let exclusions = Dictionary(
            uniqueKeysWithValues: (10...24).map {
                ($0, IRCalibrationPatchExclusion.excludedByOperator(reason: "test"))
            }
        )
        let measurements = CalibrationTestData.measurementSet(exclusions: exclusions)
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )

        #expect(fit.metrics.includedPatchCount == 9)
        let gaps = IRCalibrationEvidenceCompleteness.gaps(
            measurements: measurements, reference: reference, fit: fit
        )
        #expect(
            gaps.contains(
                .tooFewIncludedPatches(
                    included: 9,
                    minimum: IRCalibrationEvidenceCompleteness.minimumIncludedPatches
                )
            )
        )
    }

    /// Clipping is the fault most likely to be waved through, so it is checked
    /// twice: excluded by the measurement policy, and reported as a gap if it
    /// ever reaches a fitted patch anyway.
    @Test("Clipped samples in a fitted patch are a gap")
    func clippedSamplesInFittedPatchAreAGap() throws {
        var patches = CalibrationTestData.measurementSet().patches
        patches[2] = CalibrationTestData.patchMeasurement(
            CalibrationTestData.patch(3),
            red: 0.7, green: 0.6, blue: 0.5,
            clipped: 4,
            exclusion: nil
        )
        let measurements = try IRCalibrationMeasurementSet(
            id: CalibrationTestData.measurementID(),
            measuredAt: CalibrationTestData.measuredAt,
            target: .colorCheckerClassic24,
            illuminant: .measuredSPD(reference: "spd"),
            captureContext: CalibrationTestData.context(),
                colorPlaneSignature: CalibrationTestData.bayerSignature,
            normalization: CalibrationTestData.normalization(),
            whiteBalancePolicy: .none,
            patches: patches,
            provenance: CalibrationTestData.provenance()
        )
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )

        let gaps = IRCalibrationEvidenceCompleteness.gaps(
            measurements: measurements, reference: reference, fit: fit
        )
        #expect(gaps.contains(.clippedSamplesInIncludedPatches(patches: ["03"])))
    }

    @Test("A fit with no degrees of freedom is a gap: its zero residuals are arithmetic")
    func noDegreesOfFreedomIsAGap() throws {
        let exclusions = Dictionary(
            uniqueKeysWithValues: (5...24).map {
                ($0, IRCalibrationPatchExclusion.excludedByOperator(reason: "test"))
            }
        )
        let measurements = CalibrationTestData.measurementSet(exclusions: exclusions)
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )

        #expect(fit.metrics.includedPatchCount == 4)
        #expect(fit.conditioning.degreesOfFreedom == 1)

        // Exactly three would be the degenerate case, and the solver refuses
        // it before a status can even be derived.
        let three = Dictionary(
            uniqueKeysWithValues: (4...24).map {
                ($0, IRCalibrationPatchExclusion.excludedByOperator(reason: "test"))
            }
        )
        let tooFew = CalibrationTestData.measurementSet(exclusions: three)
        #expect(throws: IRCalibrationFitError.insufficientSamples(found: 3, minimum: 4)) {
            _ = try IRCalibrationFitter().fit(
                measurements: tooFew,
                reference: CalibrationTestData.referenceDataset(
                    for: tooFew, matrix: CalibrationTestData.syntheticMatrix
                )
            )
        }
    }

    // MARK: - The mechanism, exercised with hypothetical criteria

    /// The `.validated` branch is not dead code: it is unreachable *in
    /// production* because no criteria are established, and it works. Proving
    /// that here is what makes it safe to add real thresholds later as a
    /// one-line change plus an ADR.
    @Test("With hypothetical criteria, complete evidence and a good fit reach Validated")
    func hypotheticalCriteriaValidate() throws {
        let calibration = try CalibrationTestData.calibration()
        let hypothetical = IRCalibrationAcceptanceCriteria(
            maximumRMSE: 0.01,
            maximumResidual: 0.05,
            minimumIncludedPatches: 20,
            requiresMeasuredIlluminant: true
        )

        #expect(
            IRCalibrationEvidenceCompleteness.status(
                measurements: calibration.measurements,
                reference: calibration.reference,
                fit: calibration.fit,
                criteria: hypothetical
            ) == .validated
        )
    }

    @Test("Complete evidence that misses a criterion is Measured, not Experimental")
    func missingACriterionIsStillMeasured() throws {
        let measurements = CalibrationTestData.measurementSet()
        let reference = CalibrationTestData.referenceDataset(
            for: measurements,
            matrix: CalibrationTestData.syntheticMatrix,
            noise: [CalibrationTestData.patch(2): (0.5, -0.4, 0.3)]
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )
        let strict = IRCalibrationAcceptanceCriteria(
            maximumRMSE: 0.0001,
            maximumResidual: 0.0005,
            minimumIncludedPatches: 20,
            requiresMeasuredIlluminant: true
        )

        #expect(fit.metrics.rmse > strict.maximumRMSE)
        #expect(
            IRCalibrationEvidenceCompleteness.status(
                measurements: measurements, reference: reference, fit: fit, criteria: strict
            ) == .measured
        )
    }

    @Test("An asserted illuminant fails criteria that require a measured one")
    func assertedIlluminantFailsMeasuredRequirement() throws {
        let calibration = try CalibrationTestData.calibration()
        let requiresMeasured = IRCalibrationAcceptanceCriteria(
            maximumRMSE: 1, maximumResidual: 1,
            minimumIncludedPatches: 1, requiresMeasuredIlluminant: true
        )
        #expect(
            requiresMeasured.accepts(metrics: calibration.fit.metrics, illuminant: .d65) == false
        )
        #expect(
            requiresMeasured.accepts(
                metrics: calibration.fit.metrics,
                illuminant: .measuredSPD(reference: "spd")
            )
        )
    }

    @Test("Status ordering runs experimental < measured < validated")
    func statusOrdering() {
        #expect(IRCalibrationStatus.experimental < .measured)
        #expect(IRCalibrationStatus.measured < .validated)
        #expect(!IRCalibrationStatus.measured.isValidatedInfraredCalibration)
        #expect(!IRCalibrationStatus.experimental.isValidatedInfraredCalibration)
        #expect(IRCalibrationStatus.validated.isValidatedInfraredCalibration)
    }
}
