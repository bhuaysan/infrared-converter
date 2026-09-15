import Testing
import Foundation
@testable import InfraredConverter

/// That one reference dataset identity can be produced by exactly one
/// `(identifier, version)` pair.
///
/// A fit result stores nothing about the dataset it aimed at except that one
/// string, and `IRCalibration` accepts the artefact when the string matches the
/// identity of the reference dataset stored beside it. That check is worth
/// something only if the mapping from pair to string is injective — and while
/// `@` was permitted inside either part it was not.
@Suite("IR calibration reference dataset identity")
struct IRCalibrationReferenceIdentityTests {

    static func dataset(
        identifier: String, version: String
    ) throws -> IRCalibrationReferenceDataset {
        try IRCalibrationReferenceDataset(
            identifier: identifier,
            version: version,
            source: "Synthesised inside the test suite; not a measurement of anything.",
            illuminant: .d65,
            target: .colorCheckerClassic24,
            values: [
                CalibrationTestData.patch(1):
                    try IRCalibrationReferenceRGB(red: 0.1, green: 0.1, blue: 0.1)
            ]
        )
    }

    @Test("An ordinary identifier and version are accepted and joined by @")
    func ordinaryIdentity() throws {
        let dataset = try Self.dataset(identifier: "dataset", version: "1")
        #expect(dataset.identity == "dataset@1")
    }

    @Test("The separator is refused inside the identifier")
    func separatorInIdentifierRefused() {
        #expect(throws: IRCalibrationError.self) {
            _ = try Self.dataset(identifier: "dataset@x", version: "1")
        }
    }

    @Test("The separator is refused inside the version")
    func separatorInVersionRefused() {
        #expect(throws: IRCalibrationError.self) {
            _ = try Self.dataset(identifier: "dataset", version: "1@x")
        }
    }

    /// The regression, stated as the collision it was: two different pairs,
    /// one identity.
    ///
    /// ```text
    /// identifier "a@b", version "c"    ->  a@b@c
    /// identifier "a",   version "b@c"  ->  a@b@c
    /// ```
    ///
    /// Both halves of that must not be constructible at once; in fact neither
    /// is, which is the stronger and simpler rule.
    @Test("The historical collision cannot be constructed from either side")
    func historicalCollisionRefused() {
        #expect(throws: IRCalibrationError.self) {
            _ = try Self.dataset(identifier: "a@b", version: "c")
        }
        #expect(throws: IRCalibrationError.self) {
            _ = try Self.dataset(identifier: "a", version: "b@c")
        }
    }

    @Test("The refusal names the field and says why, rather than rewriting the label")
    func refusalExplainsItself() {
        do {
            _ = try Self.dataset(identifier: "a@b", version: "c")
            Issue.record("An ambiguous reference dataset identity was accepted")
        } catch let error as IRCalibrationError {
            guard case .ambiguousReferenceDatasetIdentity(let field, let token) = error else {
                Issue.record("Refused for the wrong reason: \(error)")
                return
            }
            #expect(field == "referenceDataset.identifier")
            #expect(token == "a@b")
            #expect(error.failureReason?.contains("a@b") == true)
        } catch {
            Issue.record("Refused with the wrong error type: \(error)")
        }
    }

    /// Trimming still happens first, so the rule sees the identifier that will
    /// actually be stored.
    @Test("Outer whitespace is trimmed before the separator rule is applied")
    func trimmingStillApplies() throws {
        let dataset = try Self.dataset(identifier: "  dataset  ", version: " 2 ")
        #expect(dataset.identifier == "dataset")
        #expect(dataset.version == "2")
        #expect(dataset.identity == "dataset@2")

        #expect(throws: IRCalibrationError.self) {
            _ = try Self.dataset(identifier: "  a@b  ", version: "1")
        }
    }

    /// The grammar is unchanged, so schema version 2 files still read: nothing
    /// about the wire format moved, only what may be put into it.
    @Test("The identity grammar is still identifier@version, so the schema is untouched")
    func grammarUnchanged() throws {
        let calibration = try CalibrationTestData.calibration()
        #expect(
            calibration.reference.identity
                == "\(calibration.reference.identifier)@\(calibration.reference.version)"
        )
        #expect(calibration.fit.referenceDataset == calibration.reference.identity)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(IRCalibrationRecord(calibration))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == IRCalibration.currentSchemaVersion)

        // identifier and version are two separate fields on the wire; the
        // identity is derived, never stored.
        let reference = try #require(object["reference"] as? [String: Any])
        #expect(reference["identifier"] as? String == calibration.reference.identifier)
        #expect(reference["version"] as? String == calibration.reference.version)
        #expect(reference["identity"] == nil)
    }

    /// A file whose identifier carries the separator is refused on the way in,
    /// by the same initialiser — there is no second rule on the persistence
    /// path.
    @Test("A file carrying an ambiguous reference identity is refused")
    func ambiguousIdentityInFileRefused() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            IRCalibrationRecord(try CalibrationTestData.calibration())
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var reference = try #require(object["reference"] as? [String: Any])
        let identifier = try #require(reference["identifier"] as? String)
        reference["identifier"] = "\(identifier)@extra"
        object["reference"] = reference

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                IRCalibrationRecord.self,
                from: try JSONSerialization.data(withJSONObject: object)
            ).calibration
        }
    }
}
