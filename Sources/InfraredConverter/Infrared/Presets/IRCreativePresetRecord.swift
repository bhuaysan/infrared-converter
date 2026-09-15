import Foundation

// MARK: - The schema

/// ## A schema of its own, and why it is neither the sidecar's nor the
/// profile's
///
/// ```text
/// <RAW name>.iradjustments.json   one photograph's state     schema version 5
/// <profile id>.irprofile.json     one capture profile        schema version 1
/// <preset id>.irpreset.json       one creative preset        schema version 1
/// ```
///
/// Three artefacts, three lifetimes, three schemas. A photograph's record
/// gains a version whenever a new **adjustment** can change its pixels; a
/// profile's whenever a new **capture-configuration** field can; a preset's
/// whenever what a preset **carries** changes. None of those events implies
/// the others, and a shared counter would force every reader of one file to be
/// re-released because another changed.
///
/// That the profile schema and the preset schema both start at 1 is a
/// coincidence of when each was introduced, and a test pins that they are
/// independent numbers rather than one constant written twice.
///
/// The forward-compatibility rule is the sidecar's, restated because it is the
/// rule and not the file that matters:
///
/// ```text
/// non-semantic field      may be added within a schema version, and ignored
/// image-affecting field   requires a schema-version bump
/// ```
///
/// `channelMix` is the image-affecting field here — the only part of a preset
/// that can reach a pixel, and only once a person applies it — so any future
/// change to what a preset can carry arrives with a new version, and this
/// build refuses a version it does not know rather than reading around it. See
/// `docs/decisions/0024-reusable-creative-presets.md`.
extension IRCreativePreset {

    /// Every preset schema version this build reads, as a closed set.
    ///
    /// A closed type rather than a bare `Int`, for the reason the sidecar's and
    /// the profile's are: the dispatch below is exhaustive and has no
    /// `default`, so adding a version is a compile error in the decoding until
    /// somebody decides what that version's record contains.
    public enum PersistedSchemaVersion: Int, CaseIterable, Sendable {
        /// Identity, display name, channel-mix adjustment and filter hint.
        case initial = 1

        /// The version this build writes. Named explicitly, so adding a case
        /// does not by itself change what is written; a test asserts that it is
        /// the highest case.
        public static let current = PersistedSchemaVersion.initial

        /// The first version any build of this project wrote.
        public static let first = PersistedSchemaVersion.initial
    }

    /// The preset schema version this build writes, and the highest it reads.
    public static let currentSchemaVersion = PersistedSchemaVersion.current.rawValue
}

// MARK: - The wire format

/// One reusable creative preset, as one JSON object.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "id": "user.550e8400-e29b-41d4-a716-446655440000",
///   "name": "My 720 nm Blue Sky",
///   "channelMix": { "kind": "matrix", "matrix": [0, 0, 1, 0, 1, 0, 1, 0, 0] },
///   "filter": { "kind": "longPass", "nominalCutoffNanometers": 720 }
/// }
/// ```
///
/// ## The mix is the sidecar's own format, deliberately
///
/// `channelMix` is encoded by `UserChannelMixAdjustment`'s existing `Codable`
/// conformance — the same bytes a photograph's sidecar holds, produced by the
/// same code. That is the whole architecture of this milestone in one field: a
/// preset does not carry a matrix of its own, so there is no second persisted
/// representation of a channel mix that could come to disagree with the first
/// about what `redBlueSwap` means. Applying a preset hands that exact value to
/// `DocumentState.setChannelMix`, and the photograph then stores it as it
/// always did.
///
/// A preset that resolves to a built-in therefore persists as its token alone,
/// and a built-in carrying coefficients is refused, because those are that
/// type's rules and it enforces them here too.
///
/// ## Why a separate record type rather than `IRCreativePreset: Codable`
///
/// The reason `IRCaptureProfileRecord` gives, applied here for consistency of
/// shape rather than because a preset can currently fail to encode: keeping the
/// conformance on a record type keeps the domain types free of `Codable`, so
/// none of them can be written into some other file by a future synthesised
/// conformance nobody reviewed.
///
/// ## What is not here
///
/// No white balance, and no neutral patch. A neutral region is a place in one
/// photograph — `(0.42, 0.31)` means something only about that frame — and it
/// can never be reusable state. No exposure and no orientation, for the same
/// reason at a different scale. No calibration data, because none exists, and
/// because a preset is creative colour rather than a measured transform.
public struct IRCreativePresetRecord: Codable, Sendable {

    /// The preset this record carries.
    public let preset: IRCreativePreset

    public init(_ preset: IRCreativePreset) {
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case channelMix
        case filter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try Self.schemaVersion(in: container)
        let version = schema.rawValue

        // Exhaustive, with no `default`: a version 2 added later is a compile
        // error here rather than a silent reading of it as version 1.
        switch schema {
        case .initial:
            let id = try Self.require(
                IRCreativePresetID.self, .id, in: container, schemaVersion: version
            )
            let name = try Self.require(
                String.self, .name, in: container, schemaVersion: version
            )
            // Decoded by `UserChannelMixAdjustment` itself, so a preset and a
            // sidecar read the same bytes through the same code — including
            // its refusal of a built-in that carries a matrix, and of a matrix
            // that is not nine finite coefficients.
            let channelMix = try Self.require(
                UserChannelMixAdjustment.self, .channelMix,
                in: container, schemaVersion: version
            )
            let filter = try Self.require(
                PersistedPresetFilterDescriptor.self, .filter,
                in: container, schemaVersion: version
            )

            self.preset = IRCreativePreset(
                id: id, name: name, channelMix: channelMix, filter: filter.value
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(IRCreativePreset.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(preset.id, forKey: .id)
        try container.encode(preset.name, forKey: .name)
        try container.encode(preset.channelMix, forKey: .channelMix)
        try container.encode(
            PersistedPresetFilterDescriptor(preset.filter), forKey: .filter
        )
    }

    private static func schemaVersion(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> IRCreativePreset.PersistedSchemaVersion {
        guard let raw = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) else {
            throw IRCreativePresetRecordError.missingField(
                field: CodingKeys.schemaVersion.stringValue, schemaVersion: 0
            )
        }
        guard raw >= IRCreativePreset.PersistedSchemaVersion.first.rawValue,
              raw <= IRCreativePreset.PersistedSchemaVersion.current.rawValue,
              let schema = IRCreativePreset.PersistedSchemaVersion(rawValue: raw)
        else {
            throw IRCreativePresetRecordError.unsupportedSchemaVersion(
                found: raw, supported: IRCreativePreset.currentSchemaVersion
            )
        }
        return schema
    }

    /// Reads a field its version requires, refusing its absence.
    ///
    /// `decodeIfPresent` is used only to turn absence — or an explicit `null` —
    /// into the typed refusal rather than a `DecodingError`. It never yields a
    /// default.
    private static func require<Value: Decodable>(
        _ type: Value.Type,
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        schemaVersion: Int
    ) throws -> Value {
        guard let value = try container.decodeIfPresent(type, forKey: key) else {
            throw IRCreativePresetRecordError.missingField(
                field: key.stringValue, schemaVersion: schemaVersion
            )
        }
        return value
    }
}

// MARK: - The filter hint, on the wire

/// `IRFilterDescriptor`, on the wire, shaped exactly as `IRCaptureProfileRecord`
/// and `IRCalibrationRecord` shape it.
///
/// A mirror per record file is this project's established convention, and the
/// reason is that each record owns its own typed refusals: a preset file that
/// cannot be read must refuse with a preset error, naming the preset's field,
/// rather than with a capture profile's. What must not be duplicated is the
/// **domain** rule, and it is not: the value is read back through
/// `IRFilterDescriptor.longPass(nominalNanometers:)`, so a file claiming a
/// cutoff that could not describe a real filter is refused by the same
/// validation a person's typing goes through. No file may create a value the
/// application would not.
///
/// A tagged object that refuses the fields belonging to other kinds, for the
/// sidecar's reason: a hint that calls itself `unknown` and also carries a
/// wavelength says two things about one preset, and reading it leniently means
/// choosing one of them without being asked.
private struct PersistedPresetFilterDescriptor: Codable {
    static let fieldName = "filter"

    let value: IRFilterDescriptor

    init(_ value: IRFilterDescriptor) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case kind, nominalCutoffNanometers, name
    }

    private enum Kind: String {
        case unknown, longPass, named
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try Self.require(String.self, CodingKeys.kind, in: container)
        guard let kind = Kind(rawValue: token) else {
            throw IRCreativePresetRecordError.unknownToken(
                field: Self.fieldName, token: token
            )
        }
        switch kind {
        case .unknown:
            try Self.refuse(CodingKeys.nominalCutoffNanometers, in: container)
            try Self.refuse(CodingKeys.name, in: container)
            value = .unknown
        case .longPass:
            try Self.refuse(CodingKeys.name, in: container)
            value = try IRFilterDescriptor.longPass(
                nominalNanometers: try Self.require(
                    Double.self, CodingKeys.nominalCutoffNanometers, in: container
                )
            )
        case .named:
            try Self.refuse(CodingKeys.nominalCutoffNanometers, in: container)
            value = .named(try Self.require(String.self, CodingKeys.name, in: container))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .unknown:
            try container.encode(Kind.unknown.rawValue, forKey: .kind)
        case .longPass(let nanometers):
            try container.encode(Kind.longPass.rawValue, forKey: .kind)
            try container.encode(nanometers, forKey: .nominalCutoffNanometers)
        case .named(let name):
            try container.encode(Kind.named.rawValue, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }

    /// Refuses a key this kind does not use.
    private static func refuse<Key: CodingKey>(
        _ key: Key, in container: KeyedDecodingContainer<Key>
    ) throws {
        guard !container.contains(key) else {
            throw IRCreativePresetRecordError.unexpectedField(
                field: "\(fieldName).\(key.stringValue)",
                schemaVersion: IRCreativePreset.currentSchemaVersion
            )
        }
    }

    /// Reads a key this kind requires.
    private static func require<Value: Decodable, Key: CodingKey>(
        _ type: Value.Type, _ key: Key, in container: KeyedDecodingContainer<Key>
    ) throws -> Value {
        guard let value = try container.decodeIfPresent(type, forKey: key) else {
            throw IRCreativePresetRecordError.missingField(
                field: "\(fieldName).\(key.stringValue)",
                schemaVersion: IRCreativePreset.currentSchemaVersion
            )
        }
        return value
    }
}
