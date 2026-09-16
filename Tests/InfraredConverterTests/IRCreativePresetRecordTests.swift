import Testing
import Foundation
@testable import InfraredConverter

/// The creative-preset **wire format**: `IRCreativePresetRecord`, the record
/// that turns one `IRCreativePreset` into one JSON object and back.
///
/// A schema of its own, independent of the photograph sidecar's and of the
/// capture-profile's — see `IRCreativePreset.PersistedSchemaVersion`. Nothing
/// here reads or writes a file: that is `FileIRCreativePresetStoreTests`. This
/// suite is about bytes.
@Suite("IRCreativePresetRecord")
struct IRCreativePresetRecordTests {

    private static func decode(_ json: String) throws -> IRCreativePresetRecord {
        try JSONDecoder().decode(IRCreativePresetRecord.self, from: Data(json.utf8))
    }

    /// The fragments of a well-formed version 1 record, one per top-level
    /// field, keyed by field name so a test can omit or override exactly one.
    private static func fields(
        id: String = #""id":"user.test""#,
        name: String = #""name":"Test""#,
        channelMix: String = #""channelMix":{"kind":"identity"}"#,
        filter: String = #""filter":{"kind":"unknown"}"#
    ) -> [String: String] {
        ["id": id, "name": name, "channelMix": channelMix, "filter": filter]
    }

    private static func json(schemaVersion: Int = 1, fields: [String: String]) -> String {
        "{\"schemaVersion\":\(schemaVersion),\(fields.values.joined(separator: ","))}"
    }

    // MARK: - The mix round-trips exactly

    /// An asymmetric matrix — nine distinct, non-trivial values, negatives and
    /// a value above 1 among them — so a transposed row/column convention
    /// cannot pass by coincidence, and every coefficient is a multiple of
    /// 0.25 so JSON's textual round trip cannot introduce so much as an ULP
    /// of drift.
    @Test("An asymmetric explicit matrix round-trips with every coefficient bit-identical")
    func anAsymmetricMatrixRoundTripsExactly() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 0.5, m01: -1.25, m02: 2.0,
            m10: 0.0, m11: 3.75, m12: -0.5,
            m20: 1.0, m21: 0.25, m22: -2.5
        )
        let preset = IRCreativePreset(
            id: try IRCreativePresetID("user.asymmetric"),
            name: "Asymmetric",
            channelMix: .explicit(matrix)
        )

        let bytes = try JSONEncoder().encode(IRCreativePresetRecord(preset))
        let decoded = try JSONDecoder().decode(IRCreativePresetRecord.self, from: bytes)

        // Rows are output channels: m01 (row 0 / output red, column 1 / input
        // green) must decode back as m01, never swap places with m10.
        #expect(decoded.preset.channelMix.matrix.m00 == 0.5)
        #expect(decoded.preset.channelMix.matrix.m01 == -1.25)
        #expect(decoded.preset.channelMix.matrix.m02 == 2.0)
        #expect(decoded.preset.channelMix.matrix.m10 == 0.0)
        #expect(decoded.preset.channelMix.matrix.m11 == 3.75)
        #expect(decoded.preset.channelMix.matrix.m12 == -0.5)
        #expect(decoded.preset.channelMix.matrix.m20 == 1.0)
        #expect(decoded.preset.channelMix.matrix.m21 == 0.25)
        #expect(decoded.preset.channelMix.matrix.m22 == -2.5)
        #expect(decoded.preset == preset)
    }

    @Test(".identity and .redBlueSwap round-trip as their tokens alone")
    func builtInTokensRoundTrip() throws {
        for mix in [UserChannelMixAdjustment.identity, .redBlueSwap] {
            let preset = IRCreativePreset(
                id: .generatedUserID(), name: "Built-in", channelMix: mix
            )
            let bytes = try JSONEncoder().encode(IRCreativePresetRecord(preset))
            let decoded = try JSONDecoder().decode(IRCreativePresetRecord.self, from: bytes)
            #expect(decoded.preset.channelMix == mix)

            let object = try #require(
                try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            )
            let channelMix = try #require(object["channelMix"] as? [String: Any])
            #expect(channelMix.keys.contains("matrix") == false)
        }
    }

    /// This is `UserChannelMixAdjustment`'s own rule, reached through the
    /// preset record rather than restated by it: a built-in token carrying a
    /// `matrix` key says two things about one mix, and there is no honest
    /// reading of it.
    @Test("A built-in token carrying a matrix key is refused, reached through the record")
    func aBuiltInCarryingAMatrixIsRefused() {
        let json = Self.json(
            fields: Self.fields(
                channelMix: #""channelMix":{"kind":"identity","matrix":[0,0,1,0,1,0,1,0,0]}"#
            )
        )
        #expect(
            throws: ImageAdjustmentError.unexpectedChannelMixField(field: "matrix", kind: "identity")
        ) {
            try Self.decode(json)
        }
    }

    /// The whole architecture of the milestone in one assertion: a preset
    /// carries no matrix of its own, so an authored matrix that happens to
    /// equal a built-in's numbers must not collapse into that built-in on the
    /// way through the wire.
    @Test("An authored matrix equal to a built-in's numbers stays .explicit through the record")
    func anAuthoredIdentityMatrixSurvivesTheRecord() throws {
        let explicitIdentity = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        let preset = IRCreativePreset(
            id: .generatedUserID(), name: "Explicit identity", channelMix: explicitIdentity
        )
        let bytes = try JSONEncoder().encode(IRCreativePresetRecord(preset))
        let decoded = try JSONDecoder().decode(IRCreativePresetRecord.self, from: bytes)

        #expect(decoded.preset.channelMix.kind == .matrix)
        #expect(decoded.preset.channelMix != .identity)
        #expect(decoded.preset.channelMix.matrix == .identity)
    }

    // MARK: - Filter hints round-trip

    @Test(
        "Each common nominal cutoff round-trips and displays as nominal filter-family metadata",
        arguments: IRFilterDescriptor.commonNominalCutoffsNanometers
    )
    func commonNominalCutoffsRoundTrip(nanometers: Double) throws {
        let filter = try IRFilterDescriptor.longPass(nominalNanometers: nanometers)
        let preset = IRCreativePreset(
            id: .generatedUserID(), name: "Filtered", channelMix: .redBlueSwap, filter: filter
        )
        let bytes = try JSONEncoder().encode(IRCreativePresetRecord(preset))
        let decoded = try JSONDecoder().decode(IRCreativePresetRecord.self, from: bytes)

        #expect(decoded.preset.filter == filter)
        let label = try #require(decoded.preset.filterLabel)
        #expect(label.contains("nominal"))
        #expect(label.contains(String(Int(nanometers))))
    }

    @Test("A named filter hint round-trips")
    func aNamedFilterHintRoundTrips() throws {
        let preset = IRCreativePreset(
            id: .generatedUserID(), name: "Named", channelMix: .identity,
            filter: .named("Hoya R72")
        )
        let bytes = try JSONEncoder().encode(IRCreativePresetRecord(preset))
        let decoded = try JSONDecoder().decode(IRCreativePresetRecord.self, from: bytes)
        #expect(decoded.preset.filter == .named("Hoya R72"))
    }

    /// No filter hint at all is an ordinary, complete state — never an error
    /// and never a placeholder for a wavelength somebody forgot to type.
    @Test("An unknown filter hint round-trips and reports itself honestly")
    func anUnknownFilterHintRoundTrips() throws {
        let preset = IRCreativePreset(
            id: .generatedUserID(), name: "No hint", channelMix: .identity, filter: .unknown
        )
        let bytes = try JSONEncoder().encode(IRCreativePresetRecord(preset))
        let decoded = try JSONDecoder().decode(IRCreativePresetRecord.self, from: bytes)

        #expect(decoded.preset.filter == .unknown)
        #expect(!decoded.preset.hasFilterHint)
        #expect(decoded.preset.filterLabel == nil)
    }

    // MARK: - Filter-kind contradictions are refused

    @Test("An unknown filter kind carrying a nominal cutoff is refused")
    func unknownFilterCarryingACutoffIsRefused() {
        let json = Self.json(
            fields: Self.fields(
                filter: #""filter":{"kind":"unknown","nominalCutoffNanometers":720}"#
            )
        )
        #expect(
            throws: IRCreativePresetRecordError.unexpectedField(
                field: "filter.nominalCutoffNanometers", schemaVersion: 1
            )
        ) {
            try Self.decode(json)
        }
    }

    @Test("A long-pass filter kind carrying a name is refused")
    func longPassCarryingANameIsRefused() {
        let json = Self.json(
            fields: Self.fields(
                filter: #""filter":{"kind":"longPass","nominalCutoffNanometers":720,"name":"X"}"#
            )
        )
        #expect(
            throws: IRCreativePresetRecordError.unexpectedField(
                field: "filter.name", schemaVersion: 1
            )
        ) {
            try Self.decode(json)
        }
    }

    /// A file may not create a value a person could not type: the same
    /// validation a typed cutoff goes through runs here too.
    @Test("A nominal cutoff outside the supported range is refused by the descriptor, not accepted")
    func anOutOfRangeCutoffIsRefusedByTheDescriptor() {
        let json = Self.json(
            fields: Self.fields(
                filter: #""filter":{"kind":"longPass","nominalCutoffNanometers":0}"#
            )
        )
        #expect(throws: IRCaptureProfileDescriptorError.self) {
            try Self.decode(json)
        }
    }

    // MARK: - Schema

    @Test("The record writes schema version 1")
    func theRecordWritesSchemaVersion1() throws {
        let preset = IRCreativePreset(id: .generatedUserID(), name: "X", channelMix: .identity)
        let bytes = try JSONEncoder().encode(IRCreativePresetRecord(preset))
        let object = try #require(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
    }

    @Test("The current schema version is the highest case")
    func theCurrentVersionIsTheHighestCase() {
        #expect(
            IRCreativePreset.PersistedSchemaVersion.current
                == IRCreativePreset.PersistedSchemaVersion.allCases.last
        )
        #expect(IRCreativePreset.PersistedSchemaVersion.first.rawValue == 1)
    }

    @Test(
        "A record from a schema version this build does not read is refused, not read as version 1",
        arguments: [2, 99, 1000]
    )
    func aNewerSchemaVersionIsRefused(version: Int) {
        #expect(
            throws: IRCreativePresetRecordError.unsupportedSchemaVersion(found: version, supported: 1)
        ) {
            try Self.decode(Self.json(schemaVersion: version, fields: Self.fields()))
        }
    }

    @Test("A record with no schema version at all is refused")
    func aMissingSchemaVersionIsRefused() {
        #expect(
            throws: IRCreativePresetRecordError.missingField(field: "schemaVersion", schemaVersion: 0)
        ) {
            try Self.decode(#"{"id":"user.test"}"#)
        }
    }

    @Test(
        "Each required top-level field missing is refused, naming that field",
        arguments: ["id", "name", "channelMix", "filter"]
    )
    func eachRequiredFieldMissingIsRefused(field: String) {
        var fields = Self.fields()
        fields.removeValue(forKey: field)
        #expect(
            throws: IRCreativePresetRecordError.missingField(field: field, schemaVersion: 1)
        ) {
            try Self.decode(Self.json(fields: fields))
        }
    }

    /// The point of this test is that the preset schema, the profile schema
    /// and the sidecar schema are three numbers, never one shared constant
    /// written three times. That the preset's and the profile's both happen
    /// to start at 1 is a coincidence of when each was introduced.
    @Test("The preset schema version is its own counter, independent of the sidecar's and the profile's")
    func thePresetSchemaVersionIsItsOwnCounter() {
        #expect(IRCreativePreset.currentSchemaVersion == 1)
        #expect(IRCaptureProfile.currentSchemaVersion == 1)
        #expect(PhotographProcessingState.currentSchemaVersion == 6)
        // Different enum types entirely, so a version bump to one can never
        // silently move the other. Compared here only by their raw numbers,
        // which is all a wire format can see.
        #expect(
            IRCreativePreset.PersistedSchemaVersion.current.rawValue
                != PhotographProcessingState.currentSchemaVersion
        )
    }

    // MARK: - A malformed identifier is refused by the identifier's own rule

    @Test("A malformed persisted identifier is refused by IRCreativePresetID's own validation")
    func aMalformedIDSurfacesAsPresetIDError() {
        #expect(throws: IRCreativePresetError.self) {
            try Self.decode(Self.json(fields: Self.fields(id: #""id":"Not_Valid""#)))
        }
    }

    // MARK: - Determinism

    @Test("Encoding is deterministic: the same preset encodes to identical bytes every time")
    func encodingIsDeterministic() throws {
        let preset = IRCreativePreset(
            id: try IRCreativePresetID("user.deterministic"),
            name: "Deterministic",
            channelMix: try UserChannelMixAdjustment.explicit(
                persistedMatrix: [1, 2, 3, 4, 5, 6, 7, 8, 9]
            ),
            filter: try IRFilterDescriptor.longPass(nominalNanometers: 590)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let record = IRCreativePresetRecord(preset)

        let first = try encoder.encode(record)
        let second = try encoder.encode(record)
        #expect(first == second)
    }
}
