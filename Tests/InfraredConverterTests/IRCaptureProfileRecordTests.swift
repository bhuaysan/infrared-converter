import Testing
import Foundation
@testable import InfraredConverter

/// The capture-profile **wire format**: `IRCaptureProfileRecord`, the record
/// that turns one `IRCaptureProfile` into one JSON object and back.
///
/// This is a different schema from the sidecar's, on purpose — a profile's
/// version changes when a new capture-configuration field can reach a pixel;
/// the sidecar's changes when a new photograph-local adjustment can. Nothing
/// here reads or writes a file: this suite is about bytes, not disk.
@Suite("IRCaptureProfileRecord")
struct IRCaptureProfileRecordTests {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func decode(_ json: String) throws -> IRCaptureProfileRecord {
        try JSONDecoder().decode(IRCaptureProfileRecord.self, from: Data(json.utf8))
    }

    private static func encoded(_ record: IRCaptureProfileRecord) throws -> String {
        String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    /// The fragments of a well-formed version 1 record, one per top-level
    /// field, keyed by field name so a test can omit or override exactly one.
    private static func fields(
        id: String = #""id":"builtin.uncalibrated""#,
        name: String = #""name":"Test""#,
        cameraMatch: String = #""cameraMatch":{"kind":"any"}"#,
        sensorConversion: String = #""sensorConversion":{"kind":"unknown"}"#,
        filter: String = #""filter":{"kind":"unknown"}"#,
        processingBasis: String = #""processingBasis":{"kind":"uncalibratedSensorRGB"}"#
    ) -> [String: String] {
        [
            "id": id, "name": name, "cameraMatch": cameraMatch,
            "sensorConversion": sensorConversion, "filter": filter,
            "processingBasis": processingBasis,
        ]
    }

    private static func json(schemaVersion: Int = 1, fields: [String: String]) -> String {
        "{\"schemaVersion\":\(schemaVersion),\(fields.values.joined(separator: ","))}"
    }

    // MARK: - Round-tripping

    /// Every descriptive case at once: a named camera, an internal conversion
    /// carrying its own nested long-pass filter, an external named filter, and
    /// the one processing basis this build persists.
    @Test("A fully populated profile round-trips through every descriptor case")
    func aFullyPopulatedProfileRoundTrips() throws {
        let profile = IRCaptureProfile(
            id: try IRCaptureProfileID("user.epl3-720nm"),
            name: "My Olympus E-PL3 — R72",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .internalInfrared(
                filter: try IRFilterDescriptor.longPass(nominalNanometers: 720),
                vendor: "Kolari"
            ),
            filter: .named("Hoya R72"),
            processingBasis: .uncalibratedSensorRGB
        )
        let record = try IRCaptureProfileRecord(profile)
        let bytes = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(IRCaptureProfileRecord.self, from: bytes)
        #expect(decoded.profile == profile)
    }

    @Test("A minimal profile — any camera, unknown conversion, unknown filter — round-trips")
    func aMinimalProfileRoundTrips() throws {
        let profile = IRCaptureProfile(
            id: try IRCaptureProfileID("user.minimal"),
            name: "Minimal",
            cameraMatch: .any,
            sensorConversion: .unknown,
            filter: .unknown,
            processingBasis: .uncalibratedSensorRGB
        )
        let record = try IRCaptureProfileRecord(profile)
        let bytes = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(IRCaptureProfileRecord.self, from: bytes)
        #expect(decoded.profile == profile)
    }

    /// An unrecorded converter is an honest state, not a missing field: the
    /// key is absent from the wire rather than written as `null`, and it
    /// decodes back to `vendor: nil` rather than to some placeholder string.
    @Test("An unrecorded conversion vendor is an absent key, not a null one")
    func anUnrecordedVendorIsAnAbsentKey() throws {
        let profile = IRCaptureProfile(
            id: try IRCaptureProfileID("user.plain"),
            name: "Plain",
            sensorConversion: .fullSpectrum(vendor: nil),
            processingBasis: .uncalibratedSensorRGB
        )
        let record = try IRCaptureProfileRecord(profile)
        let bytes = try JSONEncoder().encode(record)

        // The key itself is absent from `sensorConversion` — not present and
        // `null`, and not merely absent from a substring search that a
        // coincidental "vendor" elsewhere in the document could pass.
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let conversion = try #require(object["sensorConversion"] as? [String: Any])
        #expect(!conversion.keys.contains("vendor"))

        let decoded = try JSONDecoder().decode(
            IRCaptureProfileRecord.self, from: bytes
        )
        guard case .fullSpectrum(let vendor) = decoded.profile.sensorConversion else {
            Issue.record("Expected .fullSpectrum, got \(decoded.profile.sensorConversion)")
            return
        }
        #expect(vendor == nil)
    }

    // MARK: - The documented shape

    @Test("The encoded JSON carries the schema version and the profile's identity at the top level")
    func theEncodedShapeIsTheDocumentedOne() throws {
        let profile = IRCaptureProfile(
            id: try IRCaptureProfileID("user.550e8400-e29b-41d4-a716-446655440000"),
            name: "My Olympus E-PL3 — R72",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .fullSpectrum(vendor: "Some Converter"),
            filter: try IRFilterDescriptor.longPass(nominalNanometers: 720),
            processingBasis: .uncalibratedSensorRGB
        )
        let record = try IRCaptureProfileRecord(profile)
        let bytes = try JSONEncoder().encode(record)
        let object = try #require(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["id"] as? String == "user.550e8400-e29b-41d4-a716-446655440000")
        #expect(object["name"] as? String == "My Olympus E-PL3 — R72")

        let cameraMatch = try #require(object["cameraMatch"] as? [String: Any])
        #expect(cameraMatch["kind"] as? String == "camera")
        #expect(cameraMatch["make"] as? String == "OLYMPUS IMAGING CORP.")
        #expect(cameraMatch["model"] as? String == "E-PL3")

        let conversion = try #require(object["sensorConversion"] as? [String: Any])
        #expect(conversion["kind"] as? String == "fullSpectrum")
        #expect(conversion["vendor"] as? String == "Some Converter")

        let filter = try #require(object["filter"] as? [String: Any])
        #expect(filter["kind"] as? String == "longPass")
        #expect(filter["nominalCutoffNanometers"] as? Double == 720)

        let basis = try #require(object["processingBasis"] as? [String: Any])
        #expect(basis["kind"] as? String == "uncalibratedSensorRGB")
    }

    // MARK: - Schema version independence

    /// The point of this test is that the profile schema and the sidecar
    /// schema are two numbers, never one shared constant that happens to be
    /// written twice.
    @Test("The profile schema version is independent of the sidecar's")
    func theProfileSchemaVersionIsIndependentOfTheSidecars() {
        #expect(IRCaptureProfile.currentSchemaVersion == 1)
        #expect(PhotographProcessingState.currentSchemaVersion == 5)
        #expect(
            IRCaptureProfile.currentSchemaVersion
                != PhotographProcessingState.currentSchemaVersion
        )
    }

    @Test("The current profile schema version is the highest case")
    func theCurrentVersionIsTheHighestCase() {
        #expect(
            IRCaptureProfile.PersistedSchemaVersion.current
                == IRCaptureProfile.PersistedSchemaVersion.allCases.last
        )
        #expect(IRCaptureProfile.PersistedSchemaVersion.first.rawValue == 1)
    }

    // MARK: - Refusals about the version itself

    @Test(
        "A record from a schema version this build does not read is refused, not read as version 1",
        arguments: [2, 99, 1000]
    )
    func aNewerSchemaVersionIsRefused(version: Int) {
        #expect(
            throws: IRCaptureProfileRecordError.unsupportedSchemaVersion(found: version, supported: 1)
        ) {
            try Self.decode(Self.json(schemaVersion: version, fields: Self.fields()))
        }
    }

    @Test("A schema version below one is refused", arguments: [0, -1, -7])
    func anImpossibleSchemaVersionIsRefused(version: Int) {
        #expect(
            throws: IRCaptureProfileRecordError.unsupportedSchemaVersion(found: version, supported: 1)
        ) {
            try Self.decode(Self.json(schemaVersion: version, fields: Self.fields()))
        }
    }

    @Test("A record with no schema version at all is refused")
    func aMissingSchemaVersionIsRefused() {
        #expect(
            throws: IRCaptureProfileRecordError.missingField(field: "schemaVersion", schemaVersion: 0)
        ) {
            try Self.decode(#"{"id":"builtin.uncalibrated"}"#)
        }
    }

    // MARK: - Version 1's required fields

    @Test(
        "Each required top-level field missing is refused, naming that field",
        arguments: ["id", "name", "cameraMatch", "sensorConversion", "filter", "processingBasis"]
    )
    func eachRequiredFieldMissingIsRefused(field: String) {
        var fields = Self.fields()
        fields.removeValue(forKey: field)
        #expect(
            throws: IRCaptureProfileRecordError.missingField(field: field, schemaVersion: 1)
        ) {
            try Self.decode(Self.json(fields: fields))
        }
    }

    // MARK: - Tagged-field strictness

    @Test(
        "A tagged field carrying a key its kind does not have is refused",
        arguments: [
            ("cameraMatch", #"{"kind":"any","make":"X"}"#, "cameraMatch.make"),
            ("filter", #"{"kind":"unknown","name":"X"}"#, "filter.name"),
            ("filter", #"{"kind":"longPass","nominalCutoffNanometers":720,"name":"X"}"#, "filter.name"),
        ]
    )
    func aTaggedFieldWithAnUnexpectedKeyIsRefused(
        topLevelField: String, overrideValue: String, expectedField: String
    ) {
        var fields = Self.fields()
        fields[topLevelField] = "\"\(topLevelField)\":\(overrideValue)"
        #expect(
            throws: IRCaptureProfileRecordError.unexpectedField(field: expectedField, schemaVersion: 1)
        ) {
            try Self.decode(Self.json(fields: fields))
        }
    }

    @Test(
        "An unknown kind token is refused by name, in each tagged field",
        arguments: ["cameraMatch", "sensorConversion", "filter"]
    )
    func anUnknownTokenIsRefused(topLevelField: String) {
        var fields = Self.fields()
        fields[topLevelField] = "\"\(topLevelField)\":{\"kind\":\"exotic\"}"
        #expect(
            throws: IRCaptureProfileRecordError.unknownToken(field: topLevelField, token: "exotic")
        ) {
            try Self.decode(Self.json(fields: fields))
        }
    }

    // MARK: - The central safety boundary: `.explicitMatrix` has no wire format

    /// `.explicitMatrix` is a test-only escape hatch with no measured
    /// evidence behind it. Saving it would turn that hatch into a public
    /// infrared-calibration interchange format nobody validated, so it must
    /// throw rather than be quietly written as the uncalibrated basis.
    @Test("Building a record for an explicit-matrix profile throws, and is not downgraded")
    func explicitMatrixProfileRefusesToBecomeARecord() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 0, m01: 1, m02: 0,
            m10: 0, m11: 0, m12: 1,
            m20: 1, m21: 0, m22: 0
        )
        let profile = IRCaptureProfile(
            id: try IRCaptureProfileID("user.explicit"),
            name: "Explicit",
            processingBasis: .explicitMatrix(matrix)
        )

        var caught: IRCaptureProfileRecordError?
        do {
            _ = try IRCaptureProfileRecord(profile)
            Issue.record("Expected IRCaptureProfileRecord(profile) to throw")
        } catch {
            // `IRCaptureProfileRecord.init(_:)` is a typed throw, so `error`
            // here is already `IRCaptureProfileRecordError` — no cast needed.
            caught = error
        }

        guard let caught, case .unsupportedProcessingBasis(let kind, _) = caught else {
            Issue.record("Expected .unsupportedProcessingBasis, got \(String(describing: caught))")
            return
        }
        #expect(kind == "explicitMatrix")
    }

    @Test("The persisted-basis conversion carries the same refusal, in both directions")
    func thePersistedBasisConversionMirrorsTheRefusal() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 1, m01: 0, m02: 0,
            m10: 0, m11: 1, m12: 0,
            m20: 0, m21: 0, m22: 1
        )

        var caught: IRCaptureProfileRecordError?
        do {
            _ = try PersistedIRCaptureProcessingBasis(.explicitMatrix(matrix))
            Issue.record("Expected .explicitMatrix to be refused")
        } catch {
            caught = error
        }
        guard let caught, case .unsupportedProcessingBasis(let kind, _) = caught else {
            Issue.record("Expected .unsupportedProcessingBasis, got \(String(describing: caught))")
            return
        }
        #expect(kind == "explicitMatrix")

        let persisted = try PersistedIRCaptureProcessingBasis(.uncalibratedSensorRGB)
        #expect(persisted.basis == .uncalibratedSensorRGB)
    }

    /// The refusal holds even for a file nobody wrote through the throwing
    /// initialiser — a hand-typed `.irprofile.json` naming `explicitMatrix`
    /// cannot smuggle one in either.
    @Test("A hand-written file naming `explicitMatrix` cannot smuggle one in")
    func aHandWrittenExplicitMatrixIsRefused() throws {
        let json = Self.json(
            fields: Self.fields(processingBasis: #""processingBasis":{"kind":"explicitMatrix"}"#)
        )

        var caught: IRCaptureProfileRecordError?
        do {
            _ = try Self.decode(json)
            Issue.record("Expected decode to throw")
        } catch let error as IRCaptureProfileRecordError {
            caught = error
        }
        guard let caught, case .unsupportedProcessingBasis(let kind, _) = caught else {
            Issue.record("Expected .unsupportedProcessingBasis, got \(String(describing: caught))")
            return
        }
        #expect(kind == "explicitMatrix")
    }

    // MARK: - Refusals that belong to the value types themselves

    /// A malformed identity is refused by `IRCaptureProfileID`'s own
    /// validation, not by anything in the record — the record never gets a
    /// chance to see an ill-formed identity as such.
    @Test(
        "A malformed id is refused by `IRCaptureProfileID`'s own validation",
        arguments: ["Builtin.Uncalibrated", "nodots"]
    )
    func aMalformedIDSurfacesAsProfileIDError(token: String) {
        #expect(throws: IRCaptureProfileError.self) {
            try Self.decode(Self.json(fields: Self.fields(id: #""id":"\#(token)""#)))
        }
    }

    /// A file may not create a value a person could not type: the same
    /// validation a UI would run against a typed cutoff runs here too.
    @Test("A filter cutoff that could not describe a real filter is refused by the descriptor")
    func aZeroCutoffIsRefusedByTheDescriptor() {
        #expect(throws: IRCaptureProfileDescriptorError.self) {
            try Self.decode(
                Self.json(
                    fields: Self.fields(
                        filter: #""filter":{"kind":"longPass","nominalCutoffNanometers":0}"#
                    )
                )
            )
        }
    }

    // MARK: - Determinism

    @Test("Encoding is deterministic: the same profile encodes to identical bytes every time")
    func encodingIsDeterministic() throws {
        let profile = IRCaptureProfile(
            id: try IRCaptureProfileID("user.deterministic"),
            name: "Deterministic",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .internalInfrared(
                filter: try IRFilterDescriptor.longPass(nominalNanometers: 590),
                vendor: "Kolari"
            ),
            filter: .named("Custom"),
            processingBasis: .uncalibratedSensorRGB
        )
        let record = try IRCaptureProfileRecord(profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let first = try encoder.encode(record)
        let second = try encoder.encode(record)
        #expect(first == second)
    }
}
