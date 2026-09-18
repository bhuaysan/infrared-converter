import Foundation

// MARK: - The schema

/// ## A schema of its own, and why it is not the sidecar's
///
/// ```text
/// <RAW name>.iradjustments.json   one photograph's state   schema version 5
/// <profile id>.irprofile.json     one reusable profile     schema version 1
/// ```
///
/// Two artefacts, two lifetimes, two schemas. A photograph's record gains a
/// version whenever a new **adjustment** can change its pixels; a profile's
/// gains one whenever a new **capture-configuration** field can. Neither event
/// implies the other, and sharing one counter would force every reader of one
/// file to be re-released because the other changed.
///
/// The forward-compatibility rule is the sidecar's, restated for this artefact
/// because it is the rule and not the file that matters:
///
/// ```text
/// non-semantic field      may be added within a schema version, and ignored
/// image-affecting field   requires a schema-version bump
/// ```
///
/// `processingBasis` is the image-affecting field here — the one part of a
/// profile that reaches a pixel — so any future basis arrives with a new
/// version, and this build refuses a version it does not know rather than
/// reading around it. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
extension IRCaptureProfile {

    /// Every profile schema version this build reads, as a closed set.
    ///
    /// A closed type rather than a bare `Int`, for the reason the sidecar's is:
    /// the dispatch below is exhaustive and has no `default`, so adding a
    /// version is a compile error in the decoding until somebody decides what
    /// that version's record contains.
    public enum PersistedSchemaVersion: Int, CaseIterable, Sendable {
        /// Identity, display name, camera match, sensor conversion, external
        /// filter, and a processing basis restricted to
        /// `uncalibratedSensorRGB`.
        case initial = 1

        /// The version this build writes. Named explicitly, so adding a case
        /// does not by itself change what is written; a test asserts that it is
        /// the highest case.
        public static let current = PersistedSchemaVersion.initial

        /// The first version any build of this project wrote.
        public static let first = PersistedSchemaVersion.initial
    }

    /// The profile schema version this build writes, and the highest it reads.
    ///
    /// Deliberately **not** `PhotographProcessingState.currentSchemaVersion`. A
    /// test pins that the two are independent numbers rather than one shared
    /// constant that happens to be written twice.
    public static let currentSchemaVersion = PersistedSchemaVersion.current.rawValue
}

// MARK: - The processing basis a profile may carry to disk

/// The processing bases that have a wire format — today, exactly one.
///
/// ```text
/// IRCaptureProcessingBasis          runtime      uncalibratedSensorRGB, explicitMatrix
/// PersistedIRCaptureProcessingBasis persisted    uncalibratedSensorRGB
/// ```
///
/// The narrowing is the point, and it is the most important safety boundary in
/// this milestone. `IRCaptureProcessingBasis` is deliberately **not** `Codable`:
/// a synthesised conformance would have given `.explicitMatrix` a file format
/// by accident, and an internal escape hatch whose only contract is "the
/// coefficients are finite" would have become a public infrared-calibration
/// interchange format that nobody designed and nothing validates.
///
/// So the two types are kept apart, and the conversion from the runtime one
/// **throws**. A basis with no wire format is refused by name rather than
/// silently downgraded — a profile that lost its matrix on the way to disk
/// would render differently after a restart, which is exactly the class of
/// failure this project refuses to ship.
///
/// A measured calibration would arrive here as a second case, with its
/// evidence, under a new schema version. None exists. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
public enum PersistedIRCaptureProcessingBasis: Sendable, Equatable {

    /// `IRCaptureProcessingBasis.uncalibratedSensorRGB`.
    case uncalibratedSensorRGB

    /// The token written to disk.
    public var token: String {
        switch self {
        case .uncalibratedSensorRGB: return "uncalibratedSensorRGB"
        }
    }

    /// The runtime basis this stands for.
    public var basis: IRCaptureProcessingBasis {
        switch self {
        case .uncalibratedSensorRGB: return .uncalibratedSensorRGB
        }
    }

    /// The persisted form of a runtime basis, refusing one that has none.
    ///
    /// - Throws: `IRCaptureProfileRecordError.unsupportedProcessingBasis` for
    ///   `.explicitMatrix`.
    public init(_ basis: IRCaptureProcessingBasis) throws(IRCaptureProfileRecordError) {
        switch basis {
        case .uncalibratedSensorRGB:
            self = .uncalibratedSensorRGB
        case .explicitMatrix:
            throw .unsupportedProcessingBasis(
                kind: "explicitMatrix",
                reason: """
                    An explicit camera-to-working matrix is an internal experiment, not a \
                    measured calibration, and it deliberately has no file format. Saving one \
                    would turn a test-only escape hatch into an infrared-calibration \
                    interchange format that nothing in this project validates.
                    """
            )
        }
    }

    /// The persisted form named by a token, refusing one this build does not
    /// write.
    public init(token: String) throws(IRCaptureProfileRecordError) {
        switch token {
        case PersistedIRCaptureProcessingBasis.uncalibratedSensorRGB.token:
            self = .uncalibratedSensorRGB
        default:
            throw .unsupportedProcessingBasis(
                kind: token,
                reason: """
                    This version writes only an uncalibrated sensor-RGB processing basis, and \
                    will not guess at one it does not model.
                    """
            )
        }
    }
}

// MARK: - The wire format

/// One reusable capture profile, as one JSON object.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "id": "user.550e8400-e29b-41d4-a716-446655440000",
///   "name": "My Olympus E-PL3 — R72",
///   "cameraMatch": { "kind": "camera", "make": "OLYMPUS IMAGING CORP.", "model": "E-PL3" },
///   "sensorConversion": { "kind": "fullSpectrum", "vendor": "Some Converter" },
///   "filter": { "kind": "longPass", "nominalCutoffNanometers": 720 },
///   "processingBasis": { "kind": "uncalibratedSensorRGB" }
/// }
/// ```
///
/// ## Why a separate record type rather than `IRCaptureProfile: Codable`
///
/// Because encoding a profile can legitimately **fail**, and a domain type that
/// is `Codable` invites every caller to believe it cannot. A profile carrying
/// `.explicitMatrix` has no persisted form, and the refusal has to be
/// unmissable at the point somebody tries to save it rather than buried in a
/// conformance. Keeping the conformance on a record type also keeps the
/// domain enums — `IRCameraMatch`, `IRSensorConversion`, `IRFilterDescriptor`,
/// `IRCaptureProcessingBasis` — free of `Codable`, so none of them can be
/// written into some other file by a future synthesised conformance nobody
/// reviewed. Above all, `IRCaptureProcessingBasis` must never become `Codable`.
///
/// ## What is not here
///
/// No calibration data, because none exists. No recommended adjustments: a
/// profile is capture context, and a photograph's own adjustments — its white
/// balance, orientation, channel mix, exposure and levels — live in its own
/// sidecar. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 11.
public struct IRCaptureProfileRecord: Codable, Sendable {

    /// The profile this record carries.
    public let profile: IRCaptureProfile

    /// The record for a profile, refusing one that cannot be represented.
    ///
    /// The check happens **here**, before any file is opened, so that a
    /// profile with no wire format is refused without leaving a partial file
    /// or an empty one behind.
    ///
    /// - Throws: `IRCaptureProfileRecordError.unsupportedProcessingBasis`.
    public init(_ profile: IRCaptureProfile) throws(IRCaptureProfileRecordError) {
        _ = try PersistedIRCaptureProcessingBasis(profile.processingBasis)
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case cameraMatch
        case sensorConversion
        case filter
        case processingBasis
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
                IRCaptureProfileID.self, .id, in: container, schemaVersion: version
            )
            let name = try Self.require(
                String.self, .name, in: container, schemaVersion: version
            )
            let camera = try Self.require(
                PersistedCameraMatch.self, .cameraMatch, in: container, schemaVersion: version
            )
            let conversion = try Self.require(
                PersistedSensorConversion.self, .sensorConversion,
                in: container, schemaVersion: version
            )
            let filter = try Self.require(
                PersistedFilterDescriptor.self, .filter, in: container, schemaVersion: version
            )
            let basis = try Self.require(
                PersistedProcessingBasis.self, .processingBasis,
                in: container, schemaVersion: version
            )

            self.profile = IRCaptureProfile(
                id: id,
                name: name,
                cameraMatch: camera.value,
                sensorConversion: conversion.value,
                filter: filter.value,
                processingBasis: basis.value.basis
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(IRCaptureProfile.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(profile.id, forKey: .id)
        try container.encode(profile.name, forKey: .name)
        try container.encode(PersistedCameraMatch(profile.cameraMatch), forKey: .cameraMatch)
        try container.encode(
            PersistedSensorConversion(profile.sensorConversion), forKey: .sensorConversion
        )
        try container.encode(PersistedFilterDescriptor(profile.filter), forKey: .filter)
        // The second refusal of `.explicitMatrix`, after the initialiser's.
        // Both exist on purpose: the initialiser is where a caller learns, and
        // this is where the guarantee holds even for a value that reached an
        // encoder another way.
        try container.encode(
            PersistedProcessingBasis(try PersistedIRCaptureProcessingBasis(profile.processingBasis)),
            forKey: .processingBasis
        )
    }

    private static func schemaVersion(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> IRCaptureProfile.PersistedSchemaVersion {
        guard let raw = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) else {
            throw IRCaptureProfileRecordError.missingField(
                field: CodingKeys.schemaVersion.stringValue, schemaVersion: 0
            )
        }
        guard raw >= IRCaptureProfile.PersistedSchemaVersion.first.rawValue,
              raw <= IRCaptureProfile.PersistedSchemaVersion.current.rawValue,
              let schema = IRCaptureProfile.PersistedSchemaVersion(rawValue: raw)
        else {
            throw IRCaptureProfileRecordError.unsupportedSchemaVersion(
                found: raw, supported: IRCaptureProfile.currentSchemaVersion
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
            throw IRCaptureProfileRecordError.missingField(
                field: key.stringValue, schemaVersion: schemaVersion
            )
        }
        return value
    }
}

// MARK: - The persisted mirrors of the descriptive enums

/// A tagged object, refusing a field its kind does not have.
///
/// Every descriptor below is `{ "kind": "…" }` plus the fields that kind
/// carries, and every one of them refuses the fields belonging to the other
/// kinds. The strictness is the sidecar's, for the same reason: a camera match
/// that calls itself `any` and also carries a make says two things about one
/// profile, and reading it leniently means choosing one of them without being
/// asked.
private protocol TaggedProfileField {
    /// The name of the field this object sits in, for error messages.
    static var fieldName: String { get }
}

extension TaggedProfileField {
    /// Refuses a key this kind does not use.
    static func refuse<Key: CodingKey>(
        _ key: Key, in container: KeyedDecodingContainer<Key>
    ) throws {
        guard !container.contains(key) else {
            throw IRCaptureProfileRecordError.unexpectedField(
                field: "\(fieldName).\(key.stringValue)",
                schemaVersion: IRCaptureProfile.currentSchemaVersion
            )
        }
    }

    /// Reads a key this kind requires.
    static func require<Value: Decodable, Key: CodingKey>(
        _ type: Value.Type, _ key: Key, in container: KeyedDecodingContainer<Key>
    ) throws -> Value {
        guard let value = try container.decodeIfPresent(type, forKey: key) else {
            throw IRCaptureProfileRecordError.missingField(
                field: "\(fieldName).\(key.stringValue)",
                schemaVersion: IRCaptureProfile.currentSchemaVersion
            )
        }
        return value
    }
}

/// `IRCameraMatch`, on the wire.
private struct PersistedCameraMatch: Codable, TaggedProfileField {
    static let fieldName = "cameraMatch"

    let value: IRCameraMatch

    init(_ value: IRCameraMatch) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case kind, make, model
    }

    private enum Kind: String {
        case any, camera
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try Self.require(String.self, CodingKeys.kind, in: container)
        guard let kind = Kind(rawValue: token) else {
            throw IRCaptureProfileRecordError.unknownToken(
                field: Self.fieldName, token: token
            )
        }
        switch kind {
        case .any:
            try Self.refuse(CodingKeys.make, in: container)
            try Self.refuse(CodingKeys.model, in: container)
            value = .any
        case .camera:
            value = .camera(
                make: try Self.require(String.self, CodingKeys.make, in: container),
                model: try Self.require(String.self, CodingKeys.model, in: container)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .any:
            try container.encode(Kind.any.rawValue, forKey: .kind)
        case .camera(let make, let model):
            try container.encode(Kind.camera.rawValue, forKey: .kind)
            try container.encode(make, forKey: .make)
            try container.encode(model, forKey: .model)
        }
    }
}

/// `IRFilterDescriptor`, on the wire.
///
/// The nominal cutoff is written as the number it is and read back through
/// `IRFilterDescriptor.longPass(nominalNanometers:)`, so a file claiming a
/// cutoff that could not describe a real filter is refused by the same
/// validation a person's typing goes through. No file may create a value the
/// application would not.
private struct PersistedFilterDescriptor: Codable, TaggedProfileField {
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
            throw IRCaptureProfileRecordError.unknownToken(
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
}

/// `IRSensorConversion`, on the wire.
///
/// The internally fitted filter is nested here rather than merged with the
/// profile's own filter, because they are two facts: one is part of the camera
/// and the other is screwed onto the lens, and a capture can have both.
private struct PersistedSensorConversion: Codable, TaggedProfileField {
    static let fieldName = "sensorConversion"

    let value: IRSensorConversion

    init(_ value: IRSensorConversion) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case kind, vendor, filter
    }

    private enum Kind: String {
        case unknown, factorySensor, fullSpectrum, internalInfrared
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try Self.require(String.self, CodingKeys.kind, in: container)
        guard let kind = Kind(rawValue: token) else {
            throw IRCaptureProfileRecordError.unknownToken(
                field: Self.fieldName, token: token
            )
        }
        switch kind {
        case .unknown, .factorySensor:
            try Self.refuse(CodingKeys.vendor, in: container)
            try Self.refuse(CodingKeys.filter, in: container)
            value = kind == .unknown ? .unknown : .factorySensor
        case .fullSpectrum:
            try Self.refuse(CodingKeys.filter, in: container)
            // The vendor is genuinely optional: a conversion whose converter
            // nobody recorded is an ordinary, honest state, not a missing
            // field.
            value = .fullSpectrum(
                vendor: try container.decodeIfPresent(String.self, forKey: .vendor)
            )
        case .internalInfrared:
            value = .internalInfrared(
                filter: try Self.require(
                    PersistedFilterDescriptor.self, CodingKeys.filter, in: container
                ).value,
                vendor: try container.decodeIfPresent(String.self, forKey: .vendor)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .unknown:
            try container.encode(Kind.unknown.rawValue, forKey: .kind)
        case .factorySensor:
            try container.encode(Kind.factorySensor.rawValue, forKey: .kind)
        case .fullSpectrum(let vendor):
            try container.encode(Kind.fullSpectrum.rawValue, forKey: .kind)
            try container.encodeIfPresent(vendor, forKey: .vendor)
        case .internalInfrared(let filter, let vendor):
            try container.encode(Kind.internalInfrared.rawValue, forKey: .kind)
            try container.encode(PersistedFilterDescriptor(filter), forKey: .filter)
            try container.encodeIfPresent(vendor, forKey: .vendor)
        }
    }
}

/// `PersistedIRCaptureProcessingBasis`, on the wire.
///
/// An object rather than a bare token, so that the day a measured calibration
/// earns a wire format it has somewhere to put its matrix and its evidence
/// without changing the shape of this field.
private struct PersistedProcessingBasis: Codable, TaggedProfileField {
    static let fieldName = "processingBasis"

    let value: PersistedIRCaptureProcessingBasis

    init(_ value: PersistedIRCaptureProcessingBasis) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try PersistedIRCaptureProcessingBasis(
            token: try Self.require(String.self, CodingKeys.kind, in: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.token, forKey: .kind)
    }
}
