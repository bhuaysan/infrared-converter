import Testing
import Foundation
@testable import InfraredConverter

/// What a calibration may pair: evidence recorded under one illuminant against
/// reference values defined for another — never.
///
/// Three separate claims live here, and they fail in different ways:
///
/// ```text
/// compatibility   the two recorded identities must be the same
/// validity        an illuminant identity must say something
/// identity        identifier@version must be produced by one pair only
/// ```
///
/// The compatibility rule is the one the existing suites could not have caught.
/// An illuminant mismatch moves no coefficient and no residual — the same
/// responses fitted against the same values produce the same transform whatever
/// the two artefacts record about the light — so
/// `IRCalibrationFitVerifier`'s recomputation is blind to it by construction.
/// It is a defect in what the calibration *claims*.
@Suite("IR calibration illuminant semantics")
struct IRCalibrationIlluminantSemanticsTests {

    // MARK: - Building a pair with two illuminants

    static func measurements(
        _ illuminant: IRCalibrationIlluminant
    ) -> IRCalibrationMeasurementSet {
        CalibrationTestData.measurementSet(illuminant: illuminant)
    }

    static func reference(
        for measurements: IRCalibrationMeasurementSet, _ illuminant: IRCalibrationIlluminant
    ) -> IRCalibrationReferenceDataset {
        CalibrationTestData.referenceDataset(
            for: measurements,
            matrix: CalibrationTestData.syntheticMatrix,
            illuminant: illuminant
        )
    }

    /// Fits a transform across the two illuminants, and returns whatever the
    /// fitter decided.
    static func fit(
        measurement: IRCalibrationIlluminant, reference referenceIlluminant: IRCalibrationIlluminant
    ) throws -> IRCalibrationFitResult {
        let measurements = Self.measurements(measurement)
        return try IRCalibrationFitter().fit(
            measurements: measurements,
            reference: Self.reference(for: measurements, referenceIlluminant),
            now: CalibrationTestData.fittedAt
        )
    }

    /// The same reference dataset under another illuminant: identifier,
    /// version, target and every value identical, so a fit computed against
    /// the original still names it and still verifies against it.
    static func relit(
        _ dataset: IRCalibrationReferenceDataset, _ illuminant: IRCalibrationIlluminant
    ) throws -> IRCalibrationReferenceDataset {
        try IRCalibrationReferenceDataset(
            identifier: dataset.identifier,
            version: dataset.version,
            source: dataset.source,
            colorSpace: dataset.colorSpace,
            illuminant: illuminant,
            target: dataset.target,
            values: dataset.values
        )
    }

    /// A whole calibration across the two illuminants.
    ///
    /// The fit is computed under a **compatible** pair and the reference
    /// dataset is then relit, which is the only way to reach
    /// `IRCalibration.init` at all: the fitter refuses the incompatible pair
    /// first. That is exactly the artefact this rule has to catch — one
    /// assembled from parts that each satisfy every arithmetic check.
    static func calibration(
        measurement: IRCalibrationIlluminant, reference referenceIlluminant: IRCalibrationIlluminant
    ) throws -> IRCalibration {
        let measurements = Self.measurements(measurement)
        let fitted = Self.reference(for: measurements, measurement)
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: fitted, now: CalibrationTestData.fittedAt
        )
        return try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Synthetic calibration",
            measurements: measurements,
            reference: try Self.relit(fitted, referenceIlluminant),
            fit: fit
        )
    }

    // MARK: - Compatible pairs

    @Test(
        "Evidence and reference recording the same illuminant identity fit",
        arguments: [
            IRCalibrationIlluminant.d65,
            .d50,
            .namedOther("LED Panel A"),
            .measuredSPD(reference: "spd-2026-09-14.csv"),
        ]
    )
    func matchingIlluminantsFit(illuminant: IRCalibrationIlluminant) throws {
        let calibration = try Self.calibration(measurement: illuminant, reference: illuminant)
        #expect(calibration.measurements.illuminant == illuminant)
        #expect(calibration.reference.illuminant == illuminant)
        #expect(
            CalibrationTestData.maximumCoefficientDifference(
                calibration.matrix, CalibrationTestData.syntheticMatrix
            ) < 1e-12
        )
    }

    // MARK: - Incompatible pairs

    /// The pairings this step exists to make impossible. Each is a plausible
    /// mistake somebody could make with two honest artefacts in hand.
    static let incompatiblePairs:
        [(measurement: IRCalibrationIlluminant, reference: IRCalibrationIlluminant)] = [
            (.d65, .d50),
            (.d50, .d65),
            // A file named after a standard illuminant is not that illuminant.
            (.measuredSPD(reference: "d65.spd"), .d65),
            (.d65, .measuredSPD(reference: "d65.spd")),
            (.namedOther("LED panel"), .namedOther("Tungsten")),
            (.measuredSPD(reference: "lamp-a.spd"), .measuredSPD(reference: "lamp-b.spd")),
            // A name is not a standard illuminant either, however it is spelt.
            (.namedOther("D65"), .d65),
            // Case is part of an evidence identifier.
            (.namedOther("LED Panel A"), .namedOther("led panel a")),
            // Nothing is derived from an unrecorded illuminant, in either
            // direction.
            (.unknown, .d65),
            (.d65, .unknown),
            (.unknown, .measuredSPD(reference: "lamp-a.spd")),
            (.unknown, .namedOther("LED Panel A")),
        ]

    @Test("The fitter refuses incompatible illuminants", arguments: incompatiblePairs)
    func fitterRefusesIncompatibleIlluminants(
        pair: (measurement: IRCalibrationIlluminant, reference: IRCalibrationIlluminant)
    ) {
        #expect(throws: IRCalibrationFitError.self) {
            _ = try Self.fit(measurement: pair.measurement, reference: pair.reference)
        }
    }

    @Test("A calibration refuses incompatible illuminants", arguments: incompatiblePairs)
    func calibrationRefusesIncompatibleIlluminants(
        pair: (measurement: IRCalibrationIlluminant, reference: IRCalibrationIlluminant)
    ) {
        #expect(throws: IRCalibrationError.self) {
            _ = try Self.calibration(measurement: pair.measurement, reference: pair.reference)
        }
    }

    @Test("The refusal names both recorded identities and infers no spectral equivalence")
    func refusalExplainsItself() throws {
        do {
            _ = try Self.fit(
                measurement: .measuredSPD(reference: "lamp-a.spd"), reference: .d65
            )
            Issue.record("A fit across two illuminants was accepted")
        } catch let error as IRCalibrationFitError {
            guard case .illuminantMismatch(let measured, let reference) = error else {
                Issue.record("Refused for the wrong reason: \(error)")
                return
            }
            #expect(measured.contains("lamp-a.spd"))
            #expect(reference.contains("D65"))
            let reason = try #require(error.failureReason)
            #expect(reason.contains("lamp-a.spd"))
            #expect(reason.contains("D65"))
            #expect(reason.lowercased().contains("infrared"))
            #expect(reason.lowercased().contains("spectral"))
        }
    }

    // MARK: - The one case that stays constructible

    /// `.unknown ↔ .unknown` is not a claim that two unrecorded illuminants
    /// match. It is allowed through because the arithmetic is well defined on
    /// it and refusing would stop somebody fitting data they already have —
    /// and what the resulting artefact may *claim* is answered elsewhere, by
    /// the evidence gaps, which is where it belongs.
    @Test("Two unrecorded illuminants fit, and the result stays experimental")
    func unknownPairsRemainExperimental() throws {
        let calibration = try Self.calibration(measurement: .unknown, reference: .unknown)

        #expect(calibration.status == .experimental)
        #expect(calibration.isValidatedInfraredCalibration == false)
        #expect(calibration.evidenceGaps.contains(.illuminantUnknown))
    }

    /// And nothing quietly promotes `.unknown` to a standard illuminant to get
    /// there: the status rule still sees an unrecorded illuminant.
    @Test("An unrecorded illuminant is never resolved to a standard one")
    func unknownIsNotResolved() throws {
        let calibration = try Self.calibration(measurement: .unknown, reference: .unknown)
        #expect(calibration.measurements.illuminant == .unknown)
        #expect(calibration.measurements.illuminant.isKnown == false)
        #expect(calibration.measurements.illuminant.isMeasured == false)
    }

    /// A compatible pair is not thereby a validated one. This step changes the
    /// meaning of no status.
    @Test("A matched, asserted illuminant does not become validated")
    func assertedIlluminantStaysUnvalidated() throws {
        let calibration = try Self.calibration(measurement: .d65, reference: .d65)
        #expect(calibration.status == .experimental)
        #expect(calibration.evidenceGaps.contains(.illuminantNotMeasured))
        #expect(IRCalibrationAcceptanceCriteria.project == nil)
    }

    // MARK: - The mismatch the matrix verification cannot see

    /// The point of the whole rule, demonstrated: take a calibration that
    /// verifies perfectly, change **only** the reference dataset's illuminant,
    /// and every arithmetic check still passes — the identity string, the
    /// matrix, the residuals and the conditioning are all untouched, because
    /// none of them depends on what the artefacts say about the light.
    ///
    /// Without the compatibility rule this assembles into a valid calibration.
    @Test("Same matrix, same residuals, incompatible illuminants: refused anyway")
    func identicalArithmeticIsNotEnough() throws {
        let honest = try CalibrationTestData.calibration()
        let relit = try Self.relit(honest.reference, .d50)

        // Nothing the fit names has changed.
        #expect(relit.identity == honest.reference.identity)
        #expect(honest.fit.referenceDataset == relit.identity)
        #expect(relit.values == honest.reference.values)

        do {
            _ = try IRCalibration(
                id: honest.id,
                name: honest.name,
                measurements: honest.measurements,
                reference: relit,
                fit: honest.fit
            )
            Issue.record("A calibration across two illuminants was assembled")
        } catch {
            guard case .illuminantMismatch = error else {
                Issue.record("Refused for the wrong reason: \(error)")
                return
            }
        }
    }

    /// And the verifier, asked directly, says the same thing — it is a second
    /// line rather than the first, and it must not depend on having been
    /// handed a pair somebody else already checked.
    @Test("The fit verifier refuses an incompatible pair on its own")
    func verifierRefusesIncompatiblePair() throws {
        let honest = try CalibrationTestData.calibration()
        let relit = try Self.relit(honest.reference, .d50)

        #expect(throws: IRCalibrationFitVerificationFailure.self) {
            try IRCalibrationFitVerifier().verify(
                honest.fit, measurements: honest.measurements, reference: relit
            )
        }
    }

    // MARK: - Illuminant identities must say something

    static let emptyIlluminants: [IRCalibrationIlluminant] = [
        .namedOther(""),
        .namedOther("   "),
        .namedOther("\n\t "),
        .measuredSPD(reference: ""),
        .measuredSPD(reference: "   "),
    ]

    @Test("An empty illuminant identity is not evidence", arguments: emptyIlluminants)
    func emptyIlluminantRefusedByMeasurementSet(illuminant: IRCalibrationIlluminant) {
        #expect(throws: IRCalibrationError.self) {
            _ = try IRCalibrationMeasurementSet(
                id: CalibrationTestData.measurementID(),
                measuredAt: CalibrationTestData.measuredAt,
                target: .colorCheckerClassic24,
                illuminant: illuminant,
                captureContext: CalibrationTestData.context(),
                colorPlaneSignature: CalibrationTestData.bayerSignature,
                normalization: CalibrationTestData.normalization(),
                whiteBalancePolicy: .none,
                patches: [
                    CalibrationTestData.patchMeasurement(
                        CalibrationTestData.patch(1), red: 0.3, green: 0.4, blue: 0.2
                    )
                ],
                provenance: CalibrationTestData.provenance()
            )
        }
    }

    @Test("An empty illuminant identity is not a reference either", arguments: emptyIlluminants)
    func emptyIlluminantRefusedByReferenceDataset(illuminant: IRCalibrationIlluminant) {
        #expect(throws: IRCalibrationError.self) {
            _ = try IRCalibrationReferenceDataset(
                identifier: "synthetic.empty-illuminant",
                version: "1",
                source: "Synthesised inside the test suite.",
                illuminant: illuminant,
                target: .colorCheckerClassic24,
                values: [
                    CalibrationTestData.patch(1):
                        try IRCalibrationReferenceRGB(red: 0.1, green: 0.1, blue: 0.1)
                ]
            )
        }
    }

    /// The specific danger an empty measured SPD carries: it reports itself as
    /// *measured* illumination — the strongest claim the type can make — while
    /// pointing at no measurement at all.
    @Test("An empty measured SPD would claim measured illumination, so it is refused")
    func emptyMeasuredSPDWouldClaimMeasurement() {
        let empty = IRCalibrationIlluminant.measuredSPD(reference: "  ")
        #expect(empty.isMeasured)
        #expect(throws: IRCalibrationError.self) {
            _ = try empty.validated(field: "measurements.illuminant")
        }
    }

    @Test("Outer whitespace is trimmed; the identity is otherwise exact")
    func illuminantIdentityIsTrimmedAndExact() throws {
        let measurements = Self.measurements(.namedOther("  LED Panel A  "))
        #expect(measurements.illuminant == .namedOther("LED Panel A"))

        let reference = Self.reference(for: measurements, .namedOther("LED Panel A\n"))
        #expect(reference.illuminant == .namedOther("LED Panel A"))

        // Which is what makes the two compatible: both were normalised by the
        // same rule at the boundary that created them.
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Synthetic calibration",
            measurements: measurements,
            reference: reference,
            fit: try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        )
        #expect(calibration.measurements.illuminant == .namedOther("LED Panel A"))
    }

    @Test("A trimmed identity round-trips through the file unchanged")
    func trimmedIdentityRoundTrips() throws {
        let measurements = Self.measurements(.measuredSPD(reference: "  spd-a.csv  "))
        let reference = Self.reference(for: measurements, .measuredSPD(reference: "spd-a.csv"))
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Synthetic calibration",
            measurements: measurements,
            reference: reference,
            fit: try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(IRCalibrationRecord(calibration))
        let decoded = try JSONDecoder().decode(IRCalibrationRecord.self, from: data).calibration

        #expect(decoded == calibration)
        #expect(decoded.measurements.illuminant == .measuredSPD(reference: "spd-a.csv"))
        #expect(decoded.reference.illuminant == .measuredSPD(reference: "spd-a.csv"))
    }

    @Test("Case is part of an illuminant identity, not something to fold away")
    func illuminantIdentityIsCaseSensitive() {
        #expect(
            IRCalibrationIlluminantCompatibility.areCompatible(
                measurement: .namedOther("LED Panel A"), reference: .namedOther("led panel a")
            ) == false
        )
        #expect(
            IRCalibrationIlluminantCompatibility.areCompatible(
                measurement: .measuredSPD(reference: "Lamp-A.spd"),
                reference: .measuredSPD(reference: "lamp-a.spd")
            ) == false
        )
    }

    // MARK: - Editing one illuminant in a persisted file

    static func tampered(
        _ change: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            IRCalibrationRecord(try CalibrationTestData.calibration())
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func read(_ data: Data) throws -> IRCalibration {
        try JSONDecoder().decode(IRCalibrationRecord.self, from: data).calibration
    }

    /// Editing one illuminant is the hand edit that leaves every number in the
    /// file intact, so it is the edit the matrix self-verification was always
    /// going to miss.
    @Test("A file whose measurement illuminant alone was edited is refused")
    func tamperedMeasurementIlluminantRefused() throws {
        let data = try Self.tampered { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            measurements["illuminant"] = ["kind": "d65"]
            object["measurements"] = measurements
        }

        do {
            _ = try Self.read(data)
            Issue.record("A file with mismatched illuminants was accepted")
        } catch let error as IRCalibrationError {
            guard case .illuminantMismatch = error else {
                Issue.record("Refused for the wrong reason: \(error)")
                return
            }
        }
    }

    @Test("A file whose reference illuminant alone was edited is refused")
    func tamperedReferenceIlluminantRefused() throws {
        let data = try Self.tampered { object in
            var reference = try #require(object["reference"] as? [String: Any])
            reference["illuminant"] = ["kind": "unknown"]
            object["reference"] = reference
        }

        do {
            _ = try Self.read(data)
            Issue.record("A file with mismatched illuminants was accepted")
        } catch let error as IRCalibrationError {
            guard case .illuminantMismatch = error else {
                Issue.record("Refused for the wrong reason: \(error)")
                return
            }
        }
    }

    /// Changing the *text* of a measured SPD reference is likewise invisible to
    /// every arithmetic check, and likewise refused.
    @Test("A file whose measured SPD reference was renamed on one side is refused")
    func tamperedSPDReferenceRefused() throws {
        let data = try Self.tampered { object in
            var reference = try #require(object["reference"] as? [String: Any])
            reference["illuminant"] = ["kind": "measuredSPD", "reference": "synthetic-spd-2"]
            object["reference"] = reference
        }

        #expect(throws: IRCalibrationError.self) { _ = try Self.read(data) }
    }

    /// And an empty identity does not survive the file boundary either:
    /// decoding runs through the same domain initialisers, so there is no
    /// second validation to keep in step.
    @Test("A file carrying an empty illuminant identity is refused")
    func tamperedEmptyIlluminantRefused() throws {
        let data = try Self.tampered { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            measurements["illuminant"] = ["kind": "measuredSPD", "reference": "   "]
            object["measurements"] = measurements
        }

        #expect(throws: (any Error).self) { _ = try Self.read(data) }
    }

    /// The untouched file still reads. Without this the suite above would pass
    /// just as well if the rule refused everything.
    @Test("An untouched file still reads")
    func honestFileStillReads() throws {
        let original = try CalibrationTestData.calibration()
        let data = try Self.tampered { _ in }
        #expect(try Self.read(data) == original)
    }
}
