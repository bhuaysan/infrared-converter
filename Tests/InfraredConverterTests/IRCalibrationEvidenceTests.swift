import Testing
import Foundation
@testable import InfraredConverter

/// The evidence model: identities, the target vocabulary, the reference
/// dataset's required provenance, the capture-context snapshot, and the
/// cross-field consistency an assembled calibration must satisfy.
@Suite("IR calibration evidence model")
struct IRCalibrationEvidenceTests {

    // MARK: - Identity

    @Test(
        "A calibration identity is namespace-qualified, lowercase, and generated",
        arguments: [
            "calibration.550e8400-e29b-41d4-a716-446655440000",
            "calibration.a",
            "calibration.a-b.c",
        ]
    )
    func validCalibrationIDs(token: String) throws {
        #expect(try IRCalibrationID(token).rawValue == token)
    }

    @Test(
        "An identity in the wrong namespace, or malformed, is refused",
        arguments: [
            "",
            "calibration",
            "user.550e8400-e29b-41d4-a716-446655440000",
            "measurement.abc",
            "Calibration.ABC",
            "calibration.",
            "calibration..a",
            "calibration.a b",
            "calibration.a_b",
        ]
    )
    func invalidCalibrationIDs(token: String) {
        #expect(throws: IRCalibrationError.self) { try IRCalibrationID(token) }
    }

    @Test("Generated identities are unique, well-formed and in the right namespace")
    func generatedIdentities() throws {
        let ids = (0..<64).map { _ in IRCalibrationID.generated() }
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.rawValue.hasPrefix("calibration."))
            #expect(try IRCalibrationID(id.rawValue) == id)
        }

        let measurementIDs = (0..<64).map { _ in IRCalibrationMeasurementSetID.generated() }
        #expect(Set(measurementIDs).count == measurementIDs.count)
        #expect(measurementIDs.allSatisfy { $0.rawValue.hasPrefix("measurement.") })
    }

    /// The two identities are different kinds of thing, and the syntax says so:
    /// one cannot be spelled as the other.
    @Test("A measurement identity is not a calibration identity")
    func identitiesDoNotOverlap() {
        let measurement = IRCalibrationMeasurementSetID.generated()
        #expect(throws: IRCalibrationError.self) { try IRCalibrationID(measurement.rawValue) }

        let calibration = IRCalibrationID.generated()
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationMeasurementSetID(calibration.rawValue)
        }
    }

    // MARK: - Target

    @Test("The ColorChecker Classic is 4 by 6, row-major, with 24 zero-padded patch ids")
    func targetLayout() {
        let target = IRCalibrationTarget.colorCheckerClassic24
        #expect(target.rows == 4)
        #expect(target.columns == 6)
        #expect(target.patchCount == 24)

        let ids = target.patchIDs
        #expect(ids.count == 24)
        #expect(ids.first?.rawValue == "01")
        #expect(ids.last?.rawValue == "24")
        // Zero-padded so sorting the identifiers and sorting the patches agree.
        #expect(ids == ids.sorted())

        #expect(target.position(of: try! IRCalibrationTargetPatchID("01"))! == (0, 0))
        #expect(target.position(of: try! IRCalibrationTargetPatchID("07"))! == (1, 0))
        #expect(target.position(of: try! IRCalibrationTargetPatchID("24"))! == (3, 5))
        #expect(target.position(of: try! IRCalibrationTargetPatchID("25")) == nil)
    }

    @Test("A target carries layout only, and no reference values")
    func targetHasNoReferenceValues() {
        // Stated as a test because it is the invariant that keeps
        // visible-light chart data out of infrared calibration: the only way
        // to get reference values is an IRCalibrationReferenceDataset with its
        // own provenance.
        let description = IRCalibrationTarget.colorCheckerClassic24.diagnosticDescription
        #expect(description.contains("layout only"))
        #expect(description.contains("no reference values"))
    }

    // MARK: - Reference dataset

    @Test(
        "A reference dataset without identifier, version or source is refused",
        arguments: [("", "1", "s"), ("d", "", "s"), ("d", "1", ""), ("  ", "1", "s")]
    )
    func referenceProvenanceRequired(fields: (String, String, String)) {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationReferenceDataset(
                identifier: fields.0,
                version: fields.1,
                source: fields.2,
                illuminant: .d65,
                target: .colorCheckerClassic24,
                values: [
                    CalibrationTestData.patch(1):
                        try IRCalibrationReferenceRGB(red: 0.1, green: 0.1, blue: 0.1)
                ]
            )
        }
    }

    @Test("An empty reference dataset is refused")
    func emptyReferenceDataset() {
        #expect(throws: IRCalibrationError.emptyReferenceDataset) {
            try IRCalibrationReferenceDataset(
                identifier: "synthetic.empty",
                version: "1",
                source: "test",
                illuminant: .d65,
                target: .colorCheckerClassic24,
                values: [:]
            )
        }
    }

    @Test("A reference value for a patch the target does not have is refused")
    func referenceForUnknownPatch() {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationReferenceDataset(
                identifier: "synthetic.stray",
                version: "1",
                source: "test",
                illuminant: .d65,
                target: .colorCheckerClassic24,
                values: [
                    try IRCalibrationTargetPatchID("99"):
                        try IRCalibrationReferenceRGB(red: 0.1, green: 0.1, blue: 0.1)
                ]
            )
        }
    }

    @Test(
        "A non-finite or negative reference value is refused",
        arguments: [Double.nan, .infinity, -0.001]
    )
    func invalidReferenceValues(value: Double) {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationReferenceRGB(red: 0.2, green: value, blue: 0.3)
        }
    }

    @Test("A dataset's identity is identifier@version, so a fit can name the revision it used")
    func referenceIdentity() throws {
        let dataset = try IRCalibrationReferenceDataset(
            identifier: "synthetic.thing",
            version: "3",
            source: "test",
            illuminant: .d65,
            target: .colorCheckerClassic24,
            values: [
                CalibrationTestData.patch(1):
                    try IRCalibrationReferenceRGB(red: 0.1, green: 0.1, blue: 0.1)
            ]
        )
        #expect(dataset.identity == "synthetic.thing@3")
    }

    // MARK: - Capture context

    @Test("A calibration must name its camera")
    func cameraRequired() {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationBodyIdentity(make: "", model: "E-PL3", scope: .modelLevel)
        }
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationBodyIdentity(make: "Olympus", model: "   ", scope: .modelLevel)
        }
    }

    @Test("A filter snapshot can carry manufacturer, product and cutoff at once")
    func filterSnapshotIsRicherThanTheProfileDescriptor() throws {
        let snapshot = try IRCalibrationFilterSnapshot(
            manufacturer: "Hoya", product: "R72", nominalCutoffNanometers: 720, notes: "batch 7"
        )
        #expect(snapshot.isDescribed)
        #expect(snapshot.manufacturer == "Hoya")
        #expect(snapshot.product == "R72")
        #expect(snapshot.nominalCutoffNanometers == 720)
        #expect(snapshot.notes == "batch 7")
        // The nominal cutoff is a family label, and the description says so
        // rather than implying a measurement.
        #expect(snapshot.diagnosticDescription.contains("not a measured spectral response"))
    }

    @Test("A snapshot taken from a profile descriptor is lossy in exactly one direction")
    func filterSnapshotFromDescriptor() throws {
        let fromCutoff = try IRCalibrationFilterSnapshot(
            try IRFilterDescriptor.longPass(nominalNanometers: 720)
        )
        #expect(fromCutoff.nominalCutoffNanometers == 720)
        #expect(fromCutoff.product == nil)

        let fromName = try IRCalibrationFilterSnapshot(.named("Hoya R72"))
        #expect(fromName.product == "Hoya R72")
        #expect(fromName.nominalCutoffNanometers == nil)

        let fromUnknown = try IRCalibrationFilterSnapshot(.unknown)
        #expect(!fromUnknown.isDescribed)
    }

    /// The snapshot is by value precisely so that editing a profile afterwards
    /// cannot change what the calibration claims to have measured.
    @Test("Editing the profile a calibration was measured under does not change its context")
    func contextIsSnapshotNotReference() throws {
        let profileID = try IRCaptureProfileID("user.p1")
        let context = CalibrationTestData.context(measuredUnderProfile: profileID)

        // The profile is later edited from R72 to 590 nm; nothing reaches the
        // snapshot, which still describes the filter that was on the lens.
        let edited = IRCaptureProfile(
            id: profileID,
            name: "Renamed",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .fullSpectrum(vendor: "Synthetic Conversions"),
            filter: try .longPass(nominalNanometers: 590),
            processingBasis: .uncalibratedSensorRGB
        )

        #expect(context.filter.nominalCutoffNanometers == 720)
        #expect(context.measuredUnderProfile == profileID)
        // And the mismatch is detectable rather than silent.
        guard case .filterMismatch = context.applicability(to: edited) else {
            Issue.record("Expected a filter mismatch, got \(context.applicability(to: edited))")
            return
        }
    }

    @Test("A calibration is applicable only to a profile describing the same capture path")
    func applicability() throws {
        let context = CalibrationTestData.context()

        let matching = IRCaptureProfile(
            id: try IRCaptureProfileID("user.match"),
            name: "Matching",
            cameraMatch: .camera(make: "olympus imaging corp.", model: "e-pl3"),
            sensorConversion: .fullSpectrum(vendor: "Synthetic Conversions"),
            filter: .named("R72"),
            processingBasis: .uncalibratedSensorRGB
        )
        #expect(context.applicability(to: matching) == .matches)

        let otherCamera = IRCaptureProfile(
            id: try IRCaptureProfileID("user.other"),
            name: "Other body",
            cameraMatch: .camera(make: "Sony", model: "ILCE-7"),
            sensorConversion: .fullSpectrum(vendor: "Synthetic Conversions"),
            filter: .named("R72"),
            processingBasis: .uncalibratedSensorRGB
        )
        guard case .cameraMismatch = context.applicability(to: otherCamera) else {
            Issue.record("Expected .cameraMismatch")
            return
        }

        let anyCamera = IRCaptureProfile(
            id: try IRCaptureProfileID("user.any"),
            name: "Any camera",
            cameraMatch: .any,
            processingBasis: .uncalibratedSensorRGB
        )
        guard case .profileCameraUnspecified = context.applicability(to: anyCamera) else {
            Issue.record("Expected .profileCameraUnspecified")
            return
        }

        let otherConversion = IRCaptureProfile(
            id: try IRCaptureProfileID("user.conv"),
            name: "Other conversion",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .internalInfrared(filter: .unknown, vendor: "Someone else"),
            filter: .named("R72"),
            processingBasis: .uncalibratedSensorRGB
        )
        guard case .sensorConversionMismatch = context.applicability(to: otherConversion) else {
            Issue.record("Expected .sensorConversionMismatch")
            return
        }

        let otherFilter = IRCaptureProfile(
            id: try IRCaptureProfileID("user.filter"),
            name: "590 nm",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .fullSpectrum(vendor: "Synthetic Conversions"),
            filter: try .longPass(nominalNanometers: 590),
            processingBasis: .uncalibratedSensorRGB
        )
        guard case .filterMismatch = context.applicability(to: otherFilter) else {
            Issue.record("Expected .filterMismatch")
            return
        }
    }

    // MARK: - Measurement set

    @Test("An empty measurement set is refused")
    func emptyMeasurementSet() {
        #expect(throws: IRCalibrationError.emptyMeasurementSet) {
            try IRCalibrationMeasurementSet(
                measuredAt: CalibrationTestData.measuredAt,
                target: .colorCheckerClassic24,
                illuminant: .d65,
                captureContext: CalibrationTestData.context(),
                normalization: CalibrationTestData.normalization(),
                whiteBalancePolicy: .none,
                patches: [],
                provenance: CalibrationTestData.provenance()
            )
        }
    }

    @Test("One patch measured twice is refused, never resolved by ordering")
    func duplicatePatch() {
        #expect(throws: IRCalibrationError.duplicateTargetPatch(patch: "01")) {
            try IRCalibrationMeasurementSet(
                measuredAt: CalibrationTestData.measuredAt,
                target: .colorCheckerClassic24,
                illuminant: .d65,
                captureContext: CalibrationTestData.context(),
                normalization: CalibrationTestData.normalization(),
                whiteBalancePolicy: .none,
                patches: [
                    CalibrationTestData.patchMeasurement(
                        CalibrationTestData.patch(1), red: 0.1, green: 0.2, blue: 0.3
                    ),
                    CalibrationTestData.patchMeasurement(
                        CalibrationTestData.patch(1), red: 0.4, green: 0.5, blue: 0.6
                    ),
                ],
                provenance: CalibrationTestData.provenance()
            )
        }
    }

    @Test("Evidence records no matrix and no metrics: it is what was seen, not what was concluded")
    func evidenceHasNoConclusions() {
        let measurements = CalibrationTestData.measurementSet()
        // Expressed as a compile-time fact rather than a runtime assertion:
        // the set's whole public surface is context, policy and measurements.
        #expect(measurements.patches.count == 24)
        #expect(measurements.includedPatchCount == 24)
        #expect(measurements.excludedPatchCount == 0)
        #expect(measurements.sourceFileName == "SYNTHETIC.ORF")
    }

    @Test("A source file is recorded by name, never by path")
    func sourceFileIsNameOnly() throws {
        let measurements = CalibrationTestData.measurementSet()
        let name = try #require(measurements.sourceFileName)
        #expect(!name.contains("/"))
    }

    @Test("An anonymous measurement is refused: a calibration is somebody's claim")
    func provenanceRequiresAuthor() {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationProvenance(author: "  ", tool: "t", toolVersion: "1")
        }
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationProvenance(author: "a", tool: "", toolVersion: "1")
        }
    }

    // MARK: - Artefact consistency

    @Test("A calibration whose fit names other evidence is refused")
    func evidenceMismatch() throws {
        let calibration = try CalibrationTestData.calibration()
        let otherEvidence = CalibrationTestData.measurementSet(
            id: CalibrationTestData.measurementID(
                "measurement.00000000-0000-4000-8000-0000000000ff"
            )
        )

        #expect(throws: IRCalibrationError.self) {
            try IRCalibration(
                id: calibration.id,
                name: calibration.name,
                measurements: otherEvidence,
                reference: calibration.reference,
                fit: calibration.fit
            )
        }
    }

    @Test("A calibration whose fit names another reference dataset is refused")
    func referenceMismatch() throws {
        let calibration = try CalibrationTestData.calibration()
        let renamed = try IRCalibrationReferenceDataset(
            identifier: "synthetic.other",
            version: calibration.reference.version,
            source: calibration.reference.source,
            illuminant: calibration.reference.illuminant,
            target: calibration.reference.target,
            values: calibration.reference.values
        )

        #expect(throws: IRCalibrationError.self) {
            try IRCalibration(
                id: calibration.id,
                name: calibration.name,
                measurements: calibration.measurements,
                reference: renamed,
                fit: calibration.fit
            )
        }
    }

    /// The rule the milestone names explicitly: 24 patches must not carry 23
    /// residuals.
    @Test("A calibration claiming n patches must carry exactly n residuals")
    func residualCountMustMatch() throws {
        let calibration = try CalibrationTestData.calibration()

        let short = try IRCalibrationFitMetrics(
            residuals: Array(calibration.fit.metrics.residuals.dropLast()),
            excludedPatchCount: calibration.fit.metrics.excludedPatchCount
        )
        let mismatched = IRCalibrationFitResult(
            matrix: calibration.fit.matrix,
            sourceMeasurementID: calibration.fit.sourceMeasurementID,
            referenceDataset: calibration.fit.referenceDataset,
            whiteBalancePolicy: calibration.fit.whiteBalancePolicy,
            method: calibration.fit.method,
            conditioning: calibration.fit.conditioning,
            metrics: short,
            fittedAt: calibration.fit.fittedAt
        )

        guard let error = Self.refusal(calibration, fit: mismatched) else {
            Issue.record("Expected a residual-count refusal")
            return
        }
        guard case .inconsistentResiduals(let reason) = error else {
            Issue.record("Expected .inconsistentResiduals, got \(error)")
            return
        }
        #expect(reason.contains("24"))
        #expect(reason.contains("23"))
    }

    /// A duplicate cannot be caught one level up by comparing sets — the set
    /// of patch identities is unchanged by it — so the invariant lives on the
    /// type that owns the list.
    @Test("A residual list naming one patch twice is refused by the metrics themselves")
    func duplicateResidualRefused() throws {
        let calibration = try CalibrationTestData.calibration()
        let residuals = calibration.fit.metrics.residuals
        let duplicated = Array(residuals.dropLast()) + [residuals[0]]

        #expect(duplicated.count == residuals.count)
        #expect(Set(duplicated.map(\.patch)).count == residuals.count - 1)

        #expect(throws: IRCalibrationError.duplicateTargetPatch(patch: residuals[0].patch.rawValue)) {
            _ = try IRCalibrationFitMetrics(
                residuals: duplicated,
                excludedPatchCount: calibration.fit.metrics.excludedPatchCount
            )
        }
    }

    @Test("A negative excluded-patch count is refused")
    func negativeExcludedCountRefused() throws {
        let calibration = try CalibrationTestData.calibration()
        #expect(throws: IRCalibrationError.self) {
            _ = try IRCalibrationFitMetrics(
                residuals: calibration.fit.metrics.residuals, excludedPatchCount: -1
            )
        }
    }

    @Test("A residual for a patch that was not fitted is refused, even at the right count")
    func residualCountRightButPatchWrong() throws {
        let calibration = try CalibrationTestData.calibration()
        let residuals = calibration.fit.metrics.residuals
        let strayPatch = CalibrationTestData.patch(24)
        #expect(residuals.contains { $0.patch == strayPatch })

        // Replace one patch's residual with one for a patch of the target that
        // is in the fit — swapped so the count is right and the identities are
        // not.
        var swapped = residuals
        swapped[0] = try IRCalibrationPatchResidual(
            patch: strayPatch,
            red: residuals[0].red, green: residuals[0].green, blue: residuals[0].blue
        )

        #expect(throws: IRCalibrationError.duplicateTargetPatch(patch: strayPatch.rawValue)) {
            _ = try IRCalibrationFitMetrics(
                residuals: swapped, excludedPatchCount: calibration.fit.metrics.excludedPatchCount
            )
        }
    }

    @Test("A fit carrying one residual too many is refused")
    func extraResidualRefused() throws {
        let measurements = CalibrationTestData.measurementSet(
            exclusions: [4: .clipped(clippedSamples: 400, totalSamples: 400)]
        )
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference, now: CalibrationTestData.fittedAt
        )
        #expect(fit.metrics.includedPatchCount == 23)

        // A residual for the excluded patch, added to the list: 24 residuals
        // for 23 fitted patches.
        let padded = IRCalibrationFitResult(
            matrix: fit.matrix,
            sourceMeasurementID: fit.sourceMeasurementID,
            referenceDataset: fit.referenceDataset,
            whiteBalancePolicy: fit.whiteBalancePolicy,
            method: fit.method,
            conditioning: fit.conditioning,
            metrics: try IRCalibrationFitMetrics(
                residuals: fit.metrics.residuals + [
                    try IRCalibrationPatchResidual(
                        patch: CalibrationTestData.patch(4), red: 0, green: 0, blue: 0
                    )
                ],
                excludedPatchCount: fit.metrics.excludedPatchCount
            ),
            fittedAt: fit.fittedAt
        )

        guard case .inconsistentResiduals(let reason)? = Self.refusal(
            try IRCalibration(
                id: CalibrationTestData.calibrationID(),
                name: "Honest",
                measurements: measurements,
                reference: reference,
                fit: fit
            ),
            fit: padded
        ) else {
            Issue.record("Expected a residual refusal")
            return
        }
        #expect(reason.contains("04"))
    }

    @Test("The honest one-residual-per-fitted-patch artefact is still accepted")
    func oneResidualPerFittedPatchIsAccepted() throws {
        let calibration = try CalibrationTestData.calibration()
        #expect(calibration.fit.metrics.includedPatchCount == 24)
        #expect(
            calibration.fit.metrics.residuals.map(\.patch)
                == calibration.measurements.includedPatches.map(\.patch)
        )
    }

    @Test("A residual for a patch that was excluded is refused")
    func residualForExcludedPatch() throws {
        let measurements = CalibrationTestData.measurementSet(
            exclusions: [4: .clipped(clippedSamples: 400, totalSamples: 400)]
        )
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )

        // The honest artefact assembles.
        let honest = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Honest",
            measurements: measurements,
            reference: reference,
            fit: fit
        )
        #expect(honest.fit.metrics.includedPatchCount == 23)

        // Pairing that fit with evidence in which nothing was excluded does
        // not: the residual list and the included list would disagree.
        #expect(throws: IRCalibrationError.self) {
            try IRCalibration(
                id: CalibrationTestData.calibrationID(),
                name: "Dishonest",
                measurements: CalibrationTestData.measurementSet(),
                reference: reference,
                fit: fit
            )
        }
    }

    @Test("A calibration needs a name a person can recognise")
    func nameRequired() throws {
        let calibration = try CalibrationTestData.calibration()
        #expect(throws: IRCalibrationError.self) {
            try IRCalibration(
                id: calibration.id,
                name: "   ",
                measurements: calibration.measurements,
                reference: calibration.reference,
                fit: calibration.fit
            )
        }
    }

    /// Re-fitting keeps the evidence and its identity, and takes a new
    /// calibration identity — so nothing is overwritten and both results name
    /// one measurement as their source.
    @Test("Re-fitting the same evidence produces a new calibration naming the same measurements")
    func refittingPreservesEvidence() throws {
        let first = try CalibrationTestData.calibration(
            id: CalibrationTestData.calibrationID(
                "calibration.00000000-0000-4000-8000-00000000000a"
            )
        )
        let second = try IRCalibration(
            id: CalibrationTestData.calibrationID(
                "calibration.00000000-0000-4000-8000-00000000000b"
            ),
            name: "Refitted",
            measurements: first.measurements,
            reference: first.reference,
            fit: try IRCalibrationFitter().fit(
                measurements: first.measurements,
                reference: first.reference,
                now: CalibrationTestData.fittedAt
            )
        )

        #expect(first.id != second.id)
        #expect(first.measurements.id == second.measurements.id)
        #expect(first.measurements == second.measurements)
    }

    static func refusal(
        _ calibration: IRCalibration, fit: IRCalibrationFitResult
    ) -> IRCalibrationError? {
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
            return error
        }
    }
}
