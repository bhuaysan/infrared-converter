import Testing
import Foundation
@testable import InfraredConverter

/// The calibration wire format: that a calibration survives a round trip
/// unchanged, that the bytes are deterministic, that a newer schema is refused
/// rather than read around, and that every fault in a file is a typed refusal
/// rather than a default.
///
/// The rule this suite exists to enforce is the project's: **a persisted record
/// whose publicly constructible values do not round-trip is a defect**, and a
/// calibration is the artefact where a silently altered value would be least
/// detectable.
@Suite("IRCalibrationRecord")
struct IRCalibrationRecordTests {

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func encode(_ calibration: IRCalibration) throws -> Data {
        try encoder().encode(IRCalibrationRecord(calibration))
    }

    static func decode(_ data: Data) throws -> IRCalibration {
        try JSONDecoder().decode(IRCalibrationRecord.self, from: data).calibration
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Round trip

    @Test("A calibration round-trips through JSON unchanged")
    func roundTrip() throws {
        let original = try CalibrationTestData.calibration()
        let decoded = try Self.decode(try Self.encode(original))

        #expect(decoded == original)
        #expect(decoded.id == original.id)
        #expect(decoded.measurements == original.measurements)
        #expect(decoded.reference == original.reference)
        #expect(decoded.fit == original.fit)
        #expect(decoded.status == original.status)
    }

    @Test("Every kind of illuminant round-trips, including the ones carrying text")
    func illuminantRoundTrip() throws {
        let illuminants: [IRCalibrationIlluminant] = [
            .d65, .d50, .unknown,
            .namedOther("a tungsten lamp"),
            .measuredSPD(reference: "spd-2026-09-14.csv"),
        ]
        for illuminant in illuminants {
            let measurements = CalibrationTestData.measurementSet(illuminant: illuminant)
            let reference = CalibrationTestData.referenceDataset(
                for: measurements,
                matrix: CalibrationTestData.syntheticMatrix,
                illuminant: illuminant
            )
            let calibration = try IRCalibration(
                id: CalibrationTestData.calibrationID(),
                name: "Illuminant \(illuminant.shortDescription)",
                measurements: measurements,
                reference: reference,
                fit: try IRCalibrationFitter().fit(
                    measurements: measurements, reference: reference,
                    now: CalibrationTestData.fittedAt
                )
            )
            let decoded = try Self.decode(try Self.encode(calibration))
            #expect(decoded.measurements.illuminant == illuminant)
            #expect(decoded.reference.illuminant == illuminant)
        }
    }

    @Test("Every kind of patch exclusion round-trips")
    func exclusionRoundTrip() throws {
        let measurements = CalibrationTestData.measurementSet(
            exclusions: [
                1: .clipped(clippedSamples: 12, totalSamples: 400),
                3: .nonFiniteSample,
                4: .noReferenceValue,
                5: .excludedByOperator(reason: "a shadow, and a fingerprint"),
            ],
            // Genuinely short of two planes, because an
            // `.incompleteColorPlanes` exclusion must now describe the patch
            // it is attached to.
            incomplete: [2: [2, 3]]
        )
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Exclusions",
            measurements: measurements,
            reference: reference,
            fit: try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        )

        let decoded = try Self.decode(try Self.encode(calibration))
        #expect(decoded.measurements.excludedPatchCount == 5)
        for patch in measurements.patches {
            #expect(
                decoded.measurements.measurement(for: patch.patch)?.exclusion
                    == patch.exclusion
            )
        }
    }

    @Test("Every kind of sensor conversion and white-balance policy round-trips")
    func policyRoundTrip() throws {
        let conversions: [IRSensorConversion] = [
            .unknown,
            .factorySensor,
            .fullSpectrum(vendor: nil),
            .fullSpectrum(vendor: "Someone"),
            .internalInfrared(filter: .unknown, vendor: nil),
            .internalInfrared(
                filter: try .longPass(nominalNanometers: 830), vendor: "Someone else"
            ),
            .internalInfrared(filter: .named("R72"), vendor: nil),
        ]
        let policies: [IRCalibrationWhiteBalancePolicy] = [
            .none, .neutralPatch(CalibrationTestData.patch(20)),
        ]

        for conversion in conversions {
            for policy in policies {
                let measurements = CalibrationTestData.measurementSet(
                    whiteBalancePolicy: policy,
                    context: CalibrationTestData.context(sensorConversion: conversion)
                )
                let reference = CalibrationTestData.referenceDataset(
                    for: measurements, matrix: CalibrationTestData.syntheticMatrix
                )
                let calibration = try IRCalibration(
                    id: CalibrationTestData.calibrationID(),
                    name: "Policies",
                    measurements: measurements,
                    reference: reference,
                    fit: try IRCalibrationFitter().fit(
                        measurements: measurements, reference: reference,
                        now: CalibrationTestData.fittedAt
                    )
                )
                let decoded = try Self.decode(try Self.encode(calibration))
                #expect(decoded.measurements.captureContext.sensorConversion == conversion)
                #expect(decoded.measurements.whiteBalancePolicy == policy)
                #expect(decoded.fit.whiteBalancePolicy == policy)
            }
        }
    }

    @Test("An absent source file name round-trips as absent, not as an empty string")
    func optionalSourceFileName() throws {
        let measurements = try IRCalibrationMeasurementSet(
            id: CalibrationTestData.measurementID(),
            measuredAt: CalibrationTestData.measuredAt,
            target: .colorCheckerClassic24,
            illuminant: .d65,
            captureContext: CalibrationTestData.context(),
            colorPlaneSignature: CalibrationTestData.bayerSignature,
            normalization: CalibrationTestData.normalization(),
            whiteBalancePolicy: .none,
            patches: CalibrationTestData.measurementSet().patches,
            provenance: CalibrationTestData.provenance(),
            sourceFileName: nil
        )
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "No source file",
            measurements: measurements,
            reference: reference,
            fit: try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        )
        #expect(try Self.decode(try Self.encode(calibration)).measurements.sourceFileName == nil)
    }

    // MARK: - Determinism

    /// A calibration built from the real clock must equal itself after a round
    /// trip. `Date()` carries more precision than an ISO-8601 string with
    /// fractional seconds does, so the domain truncates timestamps on the way
    /// in rather than letting the file silently discard digits.
    @Test("A calibration timestamped from the real clock round-trips exactly")
    func realClockTimestampsRoundTrip() throws {
        let now = Date()
        let measurements = CalibrationTestData.measurementSet()
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Real clock",
            measurements: try IRCalibrationMeasurementSet(
                id: measurements.id,
                measuredAt: now,
                target: measurements.target,
                illuminant: measurements.illuminant,
                captureContext: measurements.captureContext,
                colorPlaneSignature: measurements.colorPlaneSignature,
                normalization: measurements.normalization,
                whiteBalancePolicy: measurements.whiteBalancePolicy,
                patches: measurements.patches,
                provenance: measurements.provenance,
                sourceFileName: measurements.sourceFileName
            ),
            reference: reference,
            fit: try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference, now: now
            )
        )

        let decoded = try Self.decode(try Self.encode(calibration))
        #expect(decoded == calibration)
        #expect(decoded.measurements.measuredAt == calibration.measurements.measuredAt)
        #expect(decoded.fit.fittedAt == calibration.fit.fittedAt)

        // And the truncation is to the millisecond the format carries, not to
        // the second.
        let truncated = calibration.measurements.measuredAt.timeIntervalSince1970
        #expect(abs(truncated - now.timeIntervalSince1970) < 0.001)
    }

    @Test("Encoding the same calibration twice produces identical bytes")
    func deterministicBytes() throws {
        let calibration = try CalibrationTestData.calibration()
        #expect(try Self.encode(calibration) == (try Self.encode(calibration)))
    }

    @Test("Re-encoding a decoded calibration produces the same bytes again")
    func stableUnderReencoding() throws {
        let first = try Self.encode(try CalibrationTestData.calibration())
        let second = try Self.encode(try Self.decode(first))
        #expect(first == second)
    }

    @Test("The file is readable JSON, with the schema version at the top level")
    func readableJSON() throws {
        let data = try Self.encode(try CalibrationTestData.calibration())
        let object = try Self.object(data)

        #expect(object["schemaVersion"] as? Int == IRCalibration.currentSchemaVersion)
        #expect(object["id"] as? String != nil)
        #expect(object["name"] as? String != nil)
        #expect(object["measurements"] != nil)
        #expect(object["reference"] != nil)
        #expect(object["fit"] != nil)
        #expect(String(data: data, encoding: .utf8) != nil)
    }

    /// Derived metrics are not stored, so they cannot disagree with the
    /// residuals they are derived from.
    @Test("RMSE and the maximum residual are absent from the file")
    func derivedMetricsAreNotPersisted() throws {
        let data = try Self.encode(try CalibrationTestData.calibration())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("\"rmse\""))
        #expect(!text.contains("\"maximumResidual\""))
        #expect(text.contains("\"residuals\""))
        #expect(text.contains("\"excludedPatchCount\""))
    }

    @Test("Residuals survive a round trip, and the derived metrics recompute identically")
    func residualsRoundTrip() throws {
        let measurements = CalibrationTestData.measurementSet()
        let reference = CalibrationTestData.referenceDataset(
            for: measurements,
            matrix: CalibrationTestData.syntheticMatrix,
            noise: [
                CalibrationTestData.patch(3): (0.02, -0.01, 0.03),
                CalibrationTestData.patch(11): (-0.04, 0.02, 0.01),
            ]
        )
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "With residuals",
            measurements: measurements,
            reference: reference,
            fit: try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        )

        let decoded = try Self.decode(try Self.encode(calibration))
        #expect(decoded.fit.metrics.residuals == calibration.fit.metrics.residuals)
        #expect(decoded.fit.metrics.rmse == calibration.fit.metrics.rmse)
        #expect(decoded.fit.metrics.maximumResidual == calibration.fit.metrics.maximumResidual)
        #expect(decoded.fit.metrics.worstPatch == calibration.fit.metrics.worstPatch)
        #expect(decoded.fit.conditioning == calibration.fit.conditioning)
        #expect(calibration.fit.metrics.rmse > 0)
    }

    // MARK: - Schema refusals

    @Test("A newer schema version is refused, never read as if it were this one")
    func newerSchemaRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        object["schemaVersion"] = IRCalibration.currentSchemaVersion + 1

        #expect(throws: IRCalibrationRecordError.self) {
            _ = try Self.decode(try Self.data(object))
        }
    }

    @Test("A missing or unusable schema version is refused")
    func missingSchemaRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        object.removeValue(forKey: "schemaVersion")
        #expect(throws: (any Error).self) { _ = try Self.decode(try Self.data(object)) }

        object["schemaVersion"] = 0
        #expect(throws: (any Error).self) { _ = try Self.decode(try Self.data(object)) }
    }

    @Test(
        "A missing top-level field is refused, and nothing is substituted for it",
        arguments: ["id", "name", "measurements", "reference", "fit"]
    )
    func missingTopLevelField(field: String) throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        object.removeValue(forKey: field)
        #expect(throws: (any Error).self) { _ = try Self.decode(try Self.data(object)) }
    }

    @Test(
        "A missing nested field is refused",
        arguments: [
            ["measurements", "illuminant"],
            ["measurements", "normalization"],
            ["measurements", "clippingPolicy"],
            ["measurements", "whiteBalancePolicy"],
            ["measurements", "patches"],
            ["measurements", "provenance"],
            ["measurements", "captureContext"],
            ["reference", "identifier"],
            ["reference", "version"],
            ["reference", "source"],
            ["reference", "values"],
            ["fit", "matrix"],
            ["fit", "metrics"],
            ["fit", "conditioning"],
            ["fit", "method"],
            ["fit", "sourceMeasurementID"],
        ]
    )
    func missingNestedField(path: [String]) throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var nested = try #require(object[path[0]] as? [String: Any])
        nested.removeValue(forKey: path[1])
        object[path[0]] = nested

        #expect(throws: (any Error).self) { _ = try Self.decode(try Self.data(object)) }
    }

    @Test("An unknown token is refused, not guessed at")
    func unknownTokens() throws {
        func mutate(_ change: (inout [String: Any]) throws -> Void) throws {
            var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
            try change(&object)
            #expect(throws: (any Error).self) { _ = try Self.decode(try Self.data(object)) }
        }

        try mutate { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            measurements["illuminant"] = ["kind": "starlight"]
            object["measurements"] = measurements
        }
        try mutate { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            measurements["target"] = "someOtherChart"
            object["measurements"] = measurements
        }
        try mutate { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            var normalization = try #require(measurements["normalization"] as? [String: Any])
            normalization["whiteLevelPolicy"] = "somethingElse"
            measurements["normalization"] = normalization
            object["measurements"] = measurements
        }
        try mutate { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            measurements["domain"] = ["kind": "demosaicedRGB", "green": "meanOfGreenPlaneMeans"]
            object["measurements"] = measurements
        }
    }

    /// A record with two authorities for one value has no reading that is not a
    /// guess, so a tagged object carrying another kind's field is refused
    /// rather than having the stray field ignored.
    @Test("A tagged object carrying a field belonging to another kind is refused")
    func strayTaggedFieldRefused() throws {
        func mutate(_ change: (inout [String: Any]) throws -> Void) throws {
            var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
            try change(&object)
            #expect(throws: (any Error).self) { _ = try Self.decode(try Self.data(object)) }
        }

        // An illuminant calling itself d65 may not also name a reference.
        try mutate { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            measurements["illuminant"] = ["kind": "d65", "reference": "spd.csv"]
            object["measurements"] = measurements
        }
        // A white balance of "none" may not also name a patch.
        try mutate { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            measurements["whiteBalancePolicy"] = ["kind": "none", "patch": "20"]
            object["measurements"] = measurements
        }
        // A "clipped" exclusion may not also carry an operator's reason.
        try mutate { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            var patches = try #require(measurements["patches"] as? [[String: Any]])
            patches[0]["exclusion"] = [
                "kind": "clipped", "clippedSamples": 1, "totalSamples": 4, "reason": "why",
            ]
            measurements["patches"] = patches
            object["measurements"] = measurements
        }
    }

    @Test("A non-finite value in the file is refused rather than becoming a coefficient")
    func nonFiniteValuesRefused() throws {
        // JSON has no NaN literal, so the fault arrives as a string or as an
        // out-of-domain number. Both must be refused.
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var fit = try #require(object["fit"] as? [String: Any])
        var matrix = try #require(fit["matrix"] as? [String: Any])
        matrix["m00"] = "NaN"
        fit["matrix"] = matrix
        object["fit"] = fit

        #expect(throws: (any Error).self) { _ = try Self.decode(try Self.data(object)) }
    }

    @Test("A matrix missing a coefficient is refused: eight numbers are not a transform")
    func incompleteMatrixRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var fit = try #require(object["fit"] as? [String: Any])
        var matrix = try #require(fit["matrix"] as? [String: Any])
        matrix.removeValue(forKey: "m22")
        fit["matrix"] = matrix
        object["fit"] = fit

        #expect(throws: (any Error).self) { _ = try Self.decode(try Self.data(object)) }
    }

    @Test("A conditioning record without three channel norms is refused")
    func malformedConditioningRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var fit = try #require(object["fit"] as? [String: Any])
        var conditioning = try #require(fit["conditioning"] as? [String: Any])
        conditioning["channelNorms"] = [1.0, 2.0]
        fit["conditioning"] = conditioning
        object["fit"] = fit

        #expect(throws: IRCalibrationRecordError.self) {
            _ = try Self.decode(try Self.data(object))
        }
    }

    // MARK: - Cross-field consistency survives the file boundary

    /// The milestone's named rule: a record claiming 24 patches must not
    /// contain 23 residuals — and a hand-edited file must not be able to
    /// smuggle one in.
    @Test("A file whose residual list disagrees with its included patches is refused")
    func inconsistentResidualsInFileRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var fit = try #require(object["fit"] as? [String: Any])
        var metrics = try #require(fit["metrics"] as? [String: Any])
        var residuals = try #require(metrics["residuals"] as? [[String: Any]])
        residuals.removeLast()
        metrics["residuals"] = residuals
        fit["metrics"] = metrics
        object["fit"] = fit

        #expect(throws: IRCalibrationError.self) {
            _ = try Self.decode(try Self.data(object))
        }
    }

    @Test("A file whose fit names other evidence is refused")
    func mismatchedEvidenceInFileRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var fit = try #require(object["fit"] as? [String: Any])
        fit["sourceMeasurementID"] = "measurement.00000000-0000-4000-8000-0000000000ff"
        object["fit"] = fit

        #expect(throws: IRCalibrationError.self) {
            _ = try Self.decode(try Self.data(object))
        }
    }

    @Test("A file whose fit names another reference revision is refused")
    func mismatchedReferenceInFileRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var fit = try #require(object["fit"] as? [String: Any])
        fit["referenceDataset"] = "synthetic.exact@2"
        object["fit"] = fit

        #expect(throws: IRCalibrationError.self) {
            _ = try Self.decode(try Self.data(object))
        }
    }

    @Test("A file naming a patch the target does not have is refused")
    func strayPatchRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var reference = try #require(object["reference"] as? [String: Any])
        var values = try #require(reference["values"] as? [String: Any])
        values["99"] = ["red": 0.1, "green": 0.1, "blue": 0.1]
        reference["values"] = values
        object["reference"] = reference

        #expect(throws: IRCalibrationError.self) {
            _ = try Self.decode(try Self.data(object))
        }
    }

    @Test("A file with an empty required provenance field is refused")
    func emptyProvenanceRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        var measurements = try #require(object["measurements"] as? [String: Any])
        var provenance = try #require(measurements["provenance"] as? [String: Any])
        provenance["author"] = "   "
        measurements["provenance"] = provenance
        object["measurements"] = measurements

        #expect(throws: IRCalibrationError.self) {
            _ = try Self.decode(try Self.data(object))
        }
    }

    @Test("Garbage is refused rather than partially read")
    func garbageRefused() {
        for bytes in ["", "{", "[]", "null", "{\"schemaVersion\": \"one\"}"] {
            #expect(throws: (any Error).self) {
                _ = try Self.decode(Data(bytes.utf8))
            }
        }
    }

    // MARK: - Tampering

    /// The claim this section exists to enforce: **a file cannot describe a
    /// calibration that could not have been constructed in memory.** Every
    /// test below starts from an honest encoded artefact, changes one number
    /// or one token by hand the way a person with a text editor would, and
    /// expects the read to refuse.
    ///
    /// Note what is *not* changed in most of them: the evidence and the
    /// reference dataset stay exactly as they were. That is the whole point —
    /// these are the edits that leave every structural check satisfied.

    static func tampered(
        _ change: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        try change(&object)
        return try Self.data(object)
    }

    static func tamperWithFit(
        _ change: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        try tampered { object in
            var fit = try #require(object["fit"] as? [String: Any])
            try change(&fit)
            object["fit"] = fit
        }
    }

    /// Reads a tampered file and returns the verification failure it produced,
    /// or `nil` if it was accepted or refused for some other reason.
    static func verificationFailure(
        _ data: Data
    ) -> IRCalibrationFitVerificationFailure? {
        do {
            _ = try Self.decode(data)
            return nil
        } catch let error as IRCalibrationError {
            guard case .unverifiableFit(let failure) = error else { return nil }
            return failure
        } catch {
            return nil
        }
    }

    @Test("A file whose matrix was edited is refused: the evidence no longer produces it")
    func tamperedMatrixInFileRefused() throws {
        let data = try Self.tamperWithFit { fit in
            var matrix = try #require(fit["matrix"] as? [String: Any])
            let original = try #require(matrix["m02"] as? Double)
            matrix["m02"] = original + 0.02
            fit["matrix"] = matrix
        }

        guard case .matrixDisagrees(let row, let column, _, _)? =
            Self.verificationFailure(data)
        else {
            Issue.record("A hand-edited matrix was accepted")
            return
        }
        #expect(row == 0)
        #expect(column == 2)
    }

    @Test("A file whose residual was edited is refused")
    func tamperedResidualInFileRefused() throws {
        let data = try Self.tamperWithFit { fit in
            var metrics = try #require(fit["metrics"] as? [String: Any])
            var residuals = try #require(metrics["residuals"] as? [[String: Any]])
            let original = try #require(residuals[2]["green"] as? Double)
            residuals[2]["green"] = original + 0.05
            metrics["residuals"] = residuals
            fit["metrics"] = metrics
        }

        guard case .residualDisagrees(_, let channel, _, _)? = Self.verificationFailure(data)
        else {
            Issue.record("A hand-edited residual was accepted")
            return
        }
        #expect(channel == "green")
    }

    @Test("A file whose normalised Gram determinant was edited is refused")
    func tamperedDeterminantInFileRefused() throws {
        let data = try Self.tamperWithFit { fit in
            var conditioning = try #require(fit["conditioning"] as? [String: Any])
            let original = try #require(conditioning["normalizedGramDeterminant"] as? Double)
            conditioning["normalizedGramDeterminant"] = original * 10
            fit["conditioning"] = conditioning
        }

        guard case .conditioningDisagrees(let field, _, _)? = Self.verificationFailure(data)
        else {
            Issue.record("A hand-edited determinant was accepted")
            return
        }
        #expect(field.contains("determinant"))
    }

    @Test("A file whose channel norms were edited is refused")
    func tamperedChannelNormsInFileRefused() throws {
        let data = try Self.tamperWithFit { fit in
            var conditioning = try #require(fit["conditioning"] as? [String: Any])
            var norms = try #require(conditioning["channelNorms"] as? [Double])
            norms[0] += 1
            conditioning["channelNorms"] = norms
            fit["conditioning"] = conditioning
        }

        guard case .conditioningDisagrees(let field, _, _)? = Self.verificationFailure(data)
        else {
            Issue.record("Hand-edited channel norms were accepted")
            return
        }
        #expect(field.contains("red"))
    }

    @Test("A file whose sample count was edited is refused")
    func tamperedSampleCountInFileRefused() throws {
        let data = try Self.tamperWithFit { fit in
            var conditioning = try #require(fit["conditioning"] as? [String: Any])
            let original = try #require(conditioning["sampleCount"] as? Int)
            conditioning["sampleCount"] = original + 3
            fit["conditioning"] = conditioning
        }

        guard case .sampleCountDisagrees(let stored, let recomputed)? =
            Self.verificationFailure(data)
        else {
            Issue.record("A hand-edited sample count was accepted")
            return
        }
        #expect(stored == 27)
        #expect(recomputed == 24)
    }

    /// A duplicate is invisible to a comparison of patch *sets*, and doubles
    /// that patch's weight in every derived metric.
    @Test("A file carrying two residuals for one patch is refused")
    func duplicateResidualInFileRefused() throws {
        let data = try Self.tamperWithFit { fit in
            var metrics = try #require(fit["metrics"] as? [String: Any])
            var residuals = try #require(metrics["residuals"] as? [[String: Any]])
            // Replace the last patch's residual with a second copy of the
            // first: the count is unchanged and the set of identities shrinks
            // by one.
            residuals[residuals.count - 1] = residuals[0]
            metrics["residuals"] = residuals
            fit["metrics"] = metrics
        }

        do {
            _ = try Self.decode(data)
            Issue.record("A duplicated residual was accepted")
        } catch let error as IRCalibrationError {
            guard case .duplicateTargetPatch = error else {
                Issue.record("Expected a duplicate refusal, got \(error)")
                return
            }
        }
    }

    @Test("A file whose excluded-patch count was edited is refused")
    func tamperedExcludedCountInFileRefused() throws {
        let data = try Self.tamperWithFit { fit in
            var metrics = try #require(fit["metrics"] as? [String: Any])
            metrics["excludedPatchCount"] = 4
            fit["metrics"] = metrics
        }

        do {
            _ = try Self.decode(data)
            Issue.record("A hand-edited excluded-patch count was accepted")
        } catch let error as IRCalibrationError {
            guard case .inconsistentResiduals = error else {
                Issue.record("Expected a residual-consistency refusal, got \(error)")
                return
            }
        }
    }

    @Test(
        "A file naming a fit method this build cannot reproduce is refused",
        arguments: [
            ["algorithm": "least-squares-3x3", "version": 2] as [String: Any],
            ["algorithm": "least-squares-3x3", "version": 99],
            ["algorithm": "ridge-3x3", "version": 1],
        ]
    )
    func unknownFitMethodInFileRefused(method: [String: Any]) throws {
        let data = try Self.tamperWithFit { fit in fit["method"] = method }

        guard case .unreproducibleMethod(let algorithm, let version, _)? =
            Self.verificationFailure(data)
        else {
            Issue.record("An unreproducible fit method was accepted")
            return
        }
        #expect(algorithm == method["algorithm"] as? String)
        #expect(version == method["version"] as? Int)
    }

    /// The other direction: leave the fit alone and edit the *evidence*. The
    /// matrix is then a conclusion drawn from measurements that are no longer
    /// in the file.
    @Test("A file whose measured means were edited is refused, because its matrix is now stale")
    func tamperedEvidenceInFileRefused() throws {
        let data = try Self.tampered { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            var patches = try #require(measurements["patches"] as? [[String: Any]])
            var planes = try #require(patches[3]["planes"] as? [[String: Any]])
            let original = try #require(planes[0]["mean"] as? Double)
            planes[0]["mean"] = original + 0.1
            patches[3]["planes"] = planes
            measurements["patches"] = patches
            object["measurements"] = measurements
        }

        // Which number is reported first is an ordering detail — the matrix
        // is checked before the residuals and the conditioning, and all three
        // have moved. What matters is that the file no longer reads.
        #expect(Self.verificationFailure(data) != nil)
    }

    /// And the same for the values the fit aimed at.
    @Test("A file whose reference values were edited is refused")
    func tamperedReferenceValuesInFileRefused() throws {
        let data = try Self.tampered { object in
            var reference = try #require(object["reference"] as? [String: Any])
            var values = try #require(reference["values"] as? [String: Any])
            var patch = try #require(values["07"] as? [String: Any])
            let original = try #require(patch["blue"] as? Double)
            patch["blue"] = original + 0.08
            values["07"] = patch
            reference["values"] = values
            object["reference"] = reference
        }

        #expect(Self.verificationFailure(data) != nil)
    }

    /// Tampering is refused; an untouched file is not. Verification runs on
    /// every read, so this is the test that would catch it becoming too
    /// strict.
    @Test("An untouched file still reads, and its fit still verifies")
    func honestFileStillReads() throws {
        let original = try CalibrationTestData.calibration()
        let decoded = try Self.decode(try Self.encode(original))
        #expect(decoded == original)
        #expect(throws: Never.self) {
            try IRCalibrationFitVerifier().verify(
                decoded.fit, measurements: decoded.measurements, reference: decoded.reference
            )
        }
    }

    // MARK: - The previous schema version

    /// A version 1 calibration is understood completely and is no longer
    /// accepted as evidence: it records the colour planes each patch
    /// *contained* and never states which planes the sensor produced, so a
    /// systematically absent plane is invisible in it.
    ///
    /// Refused rather than migrated, because every available source for the
    /// missing signature is an invention — the patches themselves are the
    /// inference the field exists to remove, and "four planes means RGGB" is
    /// an assumption about somebody else's camera.
    @Test("A schema version 1 calibration is refused, and the refusal names what it lacks")
    func schemaVersionOneIsRefused() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        object["schemaVersion"] = 1
        var measurements = try #require(object["measurements"] as? [String: Any])
        measurements.removeValue(forKey: "colorPlaneSignature")
        object["measurements"] = measurements

        do {
            _ = try Self.decode(try Self.data(object))
            Issue.record("A version 1 calibration was read")
        } catch let error as IRCalibrationRecordError {
            guard case .insufficientSchemaVersion(let found, let missing, _) = error else {
                Issue.record("Expected .insufficientSchemaVersion, got \(error)")
                return
            }
            #expect(found == 1)
            #expect(missing == "measurements.colorPlaneSignature")
        }
    }

    /// And it is refused as *insufficient*, not as unreadable: a version 1
    /// file that still carries a signature field is refused for the same
    /// reason, because the version is what states whether the field is
    /// authoritative.
    @Test("Version 1 is refused on its version, not on whether a field happens to be present")
    func schemaVersionOneIsRefusedOnItsVersion() throws {
        var object = try Self.object(try Self.encode(try CalibrationTestData.calibration()))
        object["schemaVersion"] = 1

        #expect(throws: IRCalibrationRecordError.self) {
            _ = try Self.decode(try Self.data(object))
        }
    }

    // MARK: - Schema independence

    /// A calibration's schema, a profile's schema and a photograph sidecar's
    /// schema are three counters that move for three different reasons.
    @Test("The calibration schema is its own, independent of the profile and sidecar schemas")
    func schemaIndependence() {
        #expect(IRCalibration.currentSchemaVersion == 2)
        #expect(IRCaptureProfile.currentSchemaVersion == 1)
        #expect(PhotographProcessingState.currentSchemaVersion == 6)
        // The calibration counter has now moved on its own, which is the
        // property this test exists to hold: the profile and the sidecar did
        // not move with it.
        #expect(IRCalibration.PersistedSchemaVersion.allCases.count == 2)
        #expect(
            IRCalibration.PersistedSchemaVersion.current.rawValue
                == IRCalibration.PersistedSchemaVersion.allCases.map(\.rawValue).max()
        )
    }
}
