import Foundation

// MARK: - The schema

/// ## A third schema, independent of the other two
///
/// ```text
/// <RAW name>.iradjustments.json   one photograph's state   schema version 5
/// <profile id>.irprofile.json     one reusable profile     schema version 1
/// <calibration id>.ircalibration.json   one measured artefact   schema version 1
/// ```
///
/// A calibration's schema is its own counter, sharing nothing with the
/// photograph sidecar's or the capture profile's. All three gain a version for
/// the same reason — a field was added that changes what a reader must
/// believe — but they gain them on independent schedules: a calibration
/// record can grow a field for a new evidence domain without the sidecar or
/// the profile schema moving at all, and vice versa. Sharing one counter
/// across artefacts with three different lifetimes would force every reader
/// of one to be re-released because an unrelated one changed.
///
/// The forward-compatibility rule is the same rule stated a third time,
/// because it is the rule and not the file that matters:
///
/// ```text
/// non-semantic field      may be added within a schema version, and ignored
/// image-affecting field   requires a schema-version bump
/// ```
///
/// No calibration in this project reaches a pixel yet — `isValidatedInfraredCalibration`
/// is `false` for every calibration this build can produce — so nothing here is
/// "image-affecting" in the sense the sidecar and the profile schema use that
/// phrase. The bump discipline still applies: any field this project would
/// eventually let a validated calibration act through arrives with a new
/// version, decoded through an exhaustive switch with no `default`, exactly as
/// the other two artefacts do. See
/// `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`.
extension IRCalibration {

    /// Every calibration schema version this build reads, as a closed set.
    public enum PersistedSchemaVersion: Int, CaseIterable, Sendable {
        /// Identity, name, one measurement set, one reference dataset and one
        /// fit result, each carrying its own full evidence.
        case initial = 1

        /// The version this build writes. Named explicitly, so adding a case
        /// does not by itself change what is written; a test asserts that it
        /// is the highest case.
        public static let current = PersistedSchemaVersion.initial

        /// The first version any build of this project wrote.
        public static let first = PersistedSchemaVersion.initial
    }

    /// The calibration schema version this build writes, and the highest it
    /// reads. Independent of `IRCaptureProfile.currentSchemaVersion` and of
    /// the photograph sidecar's, by design — see the note above.
    public static let currentSchemaVersion = PersistedSchemaVersion.current.rawValue
}

// MARK: - The wire format

/// One calibration artefact, as one JSON object: identity, evidence, the
/// reference it was fitted against, and the transform that fitting produced.
///
/// ## Why a separate record type rather than `IRCalibration: Codable`
///
/// For the same reason `IRCaptureProfileRecord` exists rather than
/// `IRCaptureProfile: Codable`: keeping the conformance on a record type keeps
/// every domain type — `IRCalibrationMeasurementSet`, `IRCalibrationFitResult`,
/// every enum a calibration is built from — free of `Codable`, so none of them
/// can be written into some other file by a future synthesised conformance
/// nobody reviewed. It also keeps decoding on the reconstruction path this
/// artefact most needs: every nested value is rebuilt through its own public,
/// validating initialiser, so a record that decoded field-by-field without
/// re-checking cross-field consistency could never exist.
///
/// ## What decoding does, and does not, re-validate
///
/// Each wire type below performs its own **structural** checks — a field
/// present that a tagged kind does not carry, a token this build does not
/// know, a fixed-length array of the wrong length — and reports them as
/// `IRCalibrationRecordError`. Every **domain** invariant — a patch measured
/// twice, a residual list that does not match the included patches, a fit
/// whose evidence identity does not match the measurement set it is stored
/// with — is left entirely to the public initialisers of `IRCalibration` and
/// its parts, whose `IRCalibrationError` is allowed to propagate unchanged.
/// Nothing here catches and re-describes it.
public struct IRCalibrationRecord: Codable, Sendable {

    /// The calibration this record carries.
    public let calibration: IRCalibration

    public init(_ calibration: IRCalibration) {
        self.calibration = calibration
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case measurements
        case reference
        case fit
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
                IRCalibrationID.self, .id, in: container, schemaVersion: version
            )
            let name = try Self.require(
                String.self, .name, in: container, schemaVersion: version
            )
            let measurements = try Self.require(
                PersistedMeasurementSet.self, .measurements, in: container, schemaVersion: version
            )
            let reference = try Self.require(
                PersistedReferenceDataset.self, .reference, in: container, schemaVersion: version
            )
            let fit = try Self.require(
                PersistedFitResult.self, .fit, in: container, schemaVersion: version
            )

            self.calibration = try IRCalibration(
                id: id,
                name: name,
                measurements: measurements.value,
                reference: reference.value,
                fit: fit.value
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(IRCalibration.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(calibration.id, forKey: .id)
        try container.encode(calibration.name, forKey: .name)
        try container.encode(PersistedMeasurementSet(calibration.measurements), forKey: .measurements)
        try container.encode(PersistedReferenceDataset(calibration.reference), forKey: .reference)
        try container.encode(PersistedFitResult(calibration.fit), forKey: .fit)
    }

    private static func schemaVersion(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> IRCalibration.PersistedSchemaVersion {
        guard let raw = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) else {
            throw IRCalibrationRecordError.missingField(
                field: CodingKeys.schemaVersion.stringValue, schemaVersion: 0
            )
        }
        guard raw >= IRCalibration.PersistedSchemaVersion.first.rawValue,
              raw <= IRCalibration.PersistedSchemaVersion.current.rawValue,
              let schema = IRCalibration.PersistedSchemaVersion(rawValue: raw)
        else {
            throw IRCalibrationRecordError.unsupportedSchemaVersion(
                found: raw, supported: IRCalibration.currentSchemaVersion
            )
        }
        return schema
    }

    /// Reads a top-level field its version requires, refusing its absence.
    private static func require<Value: Decodable>(
        _ type: Value.Type,
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        schemaVersion: Int
    ) throws -> Value {
        guard let value = try container.decodeIfPresent(type, forKey: key) else {
            throw IRCalibrationRecordError.missingField(
                field: key.stringValue, schemaVersion: schemaVersion
            )
        }
        return value
    }
}

// MARK: - A field with a name, for consistent error messages

/// A nested wire object that knows which field of the record it is. Every
/// wire type below conforms to this for its `require`/`refuse` helpers, not
/// only the tagged `{"kind": …}` ones: a plain object such as the camera
/// identity still needs `require` for its own mandatory fields, even though
/// it has no kind to discriminate and nothing to `refuse`.
///
/// The strictness `refuse` enforces matters most for the tagged kinds: every
/// descriptor below that has more than one `case` refuses the fields
/// belonging to the other cases, so a white-balance policy that calls itself
/// `none` while also carrying a `patch` cannot be read as either — it is
/// rejected outright, the same discipline `IRCaptureProfileRecord`'s
/// `TaggedProfileField` applies to capture profiles.
private protocol CalibrationRecordField {
    /// The dotted path of the field this object sits in, for error messages —
    /// for example `"captureContext.camera"` or `"fit.conditioning"`.
    static var fieldName: String { get }
}

extension CalibrationRecordField {
    static func refuse<Key: CodingKey>(
        _ key: Key, in container: KeyedDecodingContainer<Key>
    ) throws {
        guard !container.contains(key) else {
            throw IRCalibrationRecordError.unexpectedField(
                field: "\(fieldName).\(key.stringValue)",
                schemaVersion: IRCalibration.currentSchemaVersion
            )
        }
    }

    static func require<Value: Decodable, Key: CodingKey>(
        _ type: Value.Type, _ key: Key, in container: KeyedDecodingContainer<Key>
    ) throws -> Value {
        guard let value = try container.decodeIfPresent(type, forKey: key) else {
            throw IRCalibrationRecordError.missingField(
                field: "\(fieldName).\(key.stringValue)",
                schemaVersion: IRCalibration.currentSchemaVersion
            )
        }
        return value
    }
}

// MARK: - Dates

/// The one ISO-8601 rule this record reads and writes dates with, so
/// `IRCalibrationMeasurementSet.measuredAt` and `IRCalibrationFitResult.fittedAt`
/// are never parsed by two formatters that could silently drift apart.
/// Fractional seconds are part of the format: a calibration session and its
/// fit can happen inside the same second, and truncating to whole seconds
/// would make two genuinely different timestamps collide on disk.
private enum IRCalibrationRecordDateFormatter {
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Illuminant

/// `IRCalibrationIlluminant`, on the wire.
private struct PersistedIlluminant: Codable, CalibrationRecordField {
    static let fieldName = "illuminant"

    let value: IRCalibrationIlluminant

    init(_ value: IRCalibrationIlluminant) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case kind, name, reference
    }

    private enum Kind: String {
        case d65, d50, namedOther, measuredSPD, unknown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try Self.require(String.self, CodingKeys.kind, in: container)
        guard let kind = Kind(rawValue: token) else {
            throw IRCalibrationRecordError.unknownToken(field: Self.fieldName, token: token)
        }
        switch kind {
        case .d65:
            try Self.refuse(CodingKeys.name, in: container)
            try Self.refuse(CodingKeys.reference, in: container)
            value = .d65
        case .d50:
            try Self.refuse(CodingKeys.name, in: container)
            try Self.refuse(CodingKeys.reference, in: container)
            value = .d50
        case .namedOther:
            try Self.refuse(CodingKeys.reference, in: container)
            value = .namedOther(try Self.require(String.self, CodingKeys.name, in: container))
        case .measuredSPD:
            try Self.refuse(CodingKeys.name, in: container)
            value = .measuredSPD(
                reference: try Self.require(String.self, CodingKeys.reference, in: container)
            )
        case .unknown:
            try Self.refuse(CodingKeys.name, in: container)
            try Self.refuse(CodingKeys.reference, in: container)
            value = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .d65:
            try container.encode(Kind.d65.rawValue, forKey: .kind)
        case .d50:
            try container.encode(Kind.d50.rawValue, forKey: .kind)
        case .namedOther(let name):
            try container.encode(Kind.namedOther.rawValue, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .measuredSPD(let reference):
            try container.encode(Kind.measuredSPD.rawValue, forKey: .kind)
            try container.encode(reference, forKey: .reference)
        case .unknown:
            try container.encode(Kind.unknown.rawValue, forKey: .kind)
        }
    }
}

// MARK: - Capture context

/// `IRCalibrationBodyIdentity`, on the wire. Not a tagged kind — every field
/// but `serialNumber` is required, and there is only one shape.
private struct PersistedBodyIdentity: Codable, CalibrationRecordField {
    static let fieldName = "captureContext.camera"

    let value: IRCalibrationBodyIdentity

    init(_ value: IRCalibrationBodyIdentity) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case make, model, serialNumber, scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let make = try Self.require(String.self, CodingKeys.make, in: container)
        let model = try Self.require(String.self, CodingKeys.model, in: container)
        let serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        let scopeToken = try Self.require(String.self, CodingKeys.scope, in: container)
        guard let scope = IRCalibrationBodyScope(rawValue: scopeToken) else {
            throw IRCalibrationRecordError.unknownToken(
                field: "\(Self.fieldName).scope", token: scopeToken
            )
        }
        value = try IRCalibrationBodyIdentity(
            make: make, model: model, serialNumber: serialNumber, scope: scope
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.make, forKey: .make)
        try container.encode(value.model, forKey: .model)
        try container.encodeIfPresent(value.serialNumber, forKey: .serialNumber)
        try container.encode(value.scope.rawValue, forKey: .scope)
    }
}

/// `IRFilterDescriptor`, on the wire, exactly as `IRCaptureProfileRecord`'s
/// own `PersistedFilterDescriptor` shapes it. Used only for the filter fitted
/// **inside** a converted body (`IRSensorConversion.internalInfrared`) — the
/// filter screwed onto the lens is `PersistedFilterSnapshot`, below, a
/// different and richer shape. The two are not interchangeable: a capture
/// profile's filter is one of *either* a nominal cutoff *or* a product name,
/// which is the right shape for a menu selection, while a calibration's own
/// `filter` field may carry both at once.
private struct PersistedInternalFilterDescriptor: Codable, CalibrationRecordField {
    static let fieldName = "captureContext.sensorConversion.filter"

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
            throw IRCalibrationRecordError.unknownToken(field: Self.fieldName, token: token)
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

/// `IRSensorConversion`, on the wire, exactly as `IRCaptureProfileRecord`'s own
/// `PersistedSensorConversion` shapes it.
private struct PersistedSensorConversion: Codable, CalibrationRecordField {
    static let fieldName = "captureContext.sensorConversion"

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
            throw IRCalibrationRecordError.unknownToken(field: Self.fieldName, token: token)
        }
        switch kind {
        case .unknown, .factorySensor:
            try Self.refuse(CodingKeys.vendor, in: container)
            try Self.refuse(CodingKeys.filter, in: container)
            value = kind == .unknown ? .unknown : .factorySensor
        case .fullSpectrum:
            try Self.refuse(CodingKeys.filter, in: container)
            value = .fullSpectrum(
                vendor: try container.decodeIfPresent(String.self, forKey: .vendor)
            )
        case .internalInfrared:
            value = .internalInfrared(
                filter: try Self.require(
                    PersistedInternalFilterDescriptor.self, CodingKeys.filter, in: container
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
            try container.encode(PersistedInternalFilterDescriptor(filter), forKey: .filter)
            try container.encodeIfPresent(vendor, forKey: .vendor)
        }
    }
}

/// `IRCalibrationFilterSnapshot`, on the wire — the filter screwed onto the
/// lens, described as richly as it was recorded. Every field is optional in
/// the model, so this is a plain object rather than a tagged kind: there is
/// nothing to discriminate, only facts that may or may not be known.
private struct PersistedFilterSnapshot: Codable {
    let value: IRCalibrationFilterSnapshot

    init(_ value: IRCalibrationFilterSnapshot) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case manufacturer, product, nominalCutoffNanometers, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try IRCalibrationFilterSnapshot(
            manufacturer: try container.decodeIfPresent(String.self, forKey: .manufacturer),
            product: try container.decodeIfPresent(String.self, forKey: .product),
            nominalCutoffNanometers: try container.decodeIfPresent(
                Double.self, forKey: .nominalCutoffNanometers
            ),
            notes: try container.decodeIfPresent(String.self, forKey: .notes)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(value.manufacturer, forKey: .manufacturer)
        try container.encodeIfPresent(value.product, forKey: .product)
        try container.encodeIfPresent(value.nominalCutoffNanometers, forKey: .nominalCutoffNanometers)
        try container.encodeIfPresent(value.notes, forKey: .notes)
    }
}

/// `IRCalibrationCaptureContext`, on the wire: the camera, the conversion and
/// the filter, snapshotted by value, plus the profile identity that is
/// context only. See the type's own documentation for why this is a snapshot
/// and not a profile reference.
private struct PersistedCaptureContext: Codable, CalibrationRecordField {
    static let fieldName = "captureContext"

    let value: IRCalibrationCaptureContext

    init(_ value: IRCalibrationCaptureContext) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case camera, sensorConversion, filter, measuredUnderProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let camera = try Self.require(
            PersistedBodyIdentity.self, CodingKeys.camera, in: container
        ).value
        let sensorConversion = try Self.require(
            PersistedSensorConversion.self, CodingKeys.sensorConversion, in: container
        ).value
        let filter = try Self.require(
            PersistedFilterSnapshot.self, CodingKeys.filter, in: container
        ).value
        let measuredUnderProfile = try container.decodeIfPresent(
            IRCaptureProfileID.self, forKey: .measuredUnderProfile
        )
        value = IRCalibrationCaptureContext(
            camera: camera,
            sensorConversion: sensorConversion,
            filter: filter,
            measuredUnderProfile: measuredUnderProfile
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PersistedBodyIdentity(value.camera), forKey: .camera)
        try container.encode(
            PersistedSensorConversion(value.sensorConversion), forKey: .sensorConversion
        )
        try container.encode(PersistedFilterSnapshot(value.filter), forKey: .filter)
        try container.encodeIfPresent(value.measuredUnderProfile, forKey: .measuredUnderProfile)
    }
}

// MARK: - Measurement domain, normalisation, clipping, white balance

/// `IRCalibrationMeasurementDomain`, on the wire.
private struct PersistedMeasurementDomain: Codable, CalibrationRecordField {
    static let fieldName = "measurements.domain"

    let value: IRCalibrationMeasurementDomain

    init(_ value: IRCalibrationMeasurementDomain) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case kind, green
    }

    private enum Kind: String {
        case cfaPlaneMeans
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try Self.require(String.self, CodingKeys.kind, in: container)
        guard let kind = Kind(rawValue: token) else {
            throw IRCalibrationRecordError.unknownToken(field: Self.fieldName, token: token)
        }
        switch kind {
        case .cfaPlaneMeans:
            let greenToken = try Self.require(String.self, CodingKeys.green, in: container)
            guard let green = IRCalibrationGreenChannelPolicy(rawValue: greenToken) else {
                throw IRCalibrationRecordError.unknownToken(
                    field: "\(Self.fieldName).green", token: greenToken
                )
            }
            value = .cfaPlaneMeans(green: green)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .cfaPlaneMeans(let green):
            try container.encode(Kind.cfaPlaneMeans.rawValue, forKey: .kind)
            try container.encode(green.rawValue, forKey: .green)
        }
    }
}

/// `IRCalibrationNormalizationProvenance`, on the wire. `whiteLevelPolicy` is
/// a single-case enum today, and is still read through an explicit token
/// match rather than assumed: a file naming a policy this build does not
/// recognise is refused rather than silently treated as
/// `.metadataMaximum`.
private struct PersistedNormalizationProvenance: Codable, CalibrationRecordField {
    static let fieldName = "measurements.normalization"

    let value: IRCalibrationNormalizationProvenance

    init(_ value: IRCalibrationNormalizationProvenance) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case version, blackLevelSubtracted, whiteLevelPolicy, whiteLevel
    }

    private enum WhiteLevelPolicyToken: String {
        case metadataMaximum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try Self.require(Int.self, CodingKeys.version, in: container)
        let blackLevelSubtracted = try Self.require(
            Bool.self, CodingKeys.blackLevelSubtracted, in: container
        )
        let policyToken = try Self.require(String.self, CodingKeys.whiteLevelPolicy, in: container)
        guard WhiteLevelPolicyToken(rawValue: policyToken) != nil else {
            throw IRCalibrationRecordError.unknownToken(
                field: "\(Self.fieldName).whiteLevelPolicy", token: policyToken
            )
        }
        let whiteLevel = try Self.require(UInt32.self, CodingKeys.whiteLevel, in: container)
        value = IRCalibrationNormalizationProvenance(
            blackLevelSubtracted: blackLevelSubtracted,
            whiteLevelPolicy: .metadataMaximum,
            whiteLevel: whiteLevel,
            version: version
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.version, forKey: .version)
        try container.encode(value.blackLevelSubtracted, forKey: .blackLevelSubtracted)
        switch value.whiteLevelPolicy {
        case .metadataMaximum:
            try container.encode(WhiteLevelPolicyToken.metadataMaximum.rawValue, forKey: .whiteLevelPolicy)
        }
        try container.encode(value.whiteLevel, forKey: .whiteLevel)
    }
}

/// `IRCalibrationClippingPolicy`, on the wire.
private struct PersistedClippingPolicy: Codable, CalibrationRecordField {
    static let fieldName = "measurements.clippingPolicy"

    let value: IRCalibrationClippingPolicy

    init(_ value: IRCalibrationClippingPolicy) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case normalizedClippingThreshold, maximumClippedSampleFraction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Through the validating initialiser, like every other decoded
        // value in this record: a hand-edited threshold of `0`, or a
        // tolerance of `2`, is refused on the way in rather than silently
        // changing which patches a re-read calibration would have fitted.
        value = try IRCalibrationClippingPolicy(
            normalizedClippingThreshold: try Self.require(
                Double.self, CodingKeys.normalizedClippingThreshold, in: container
            ),
            maximumClippedSampleFraction: try Self.require(
                Double.self, CodingKeys.maximumClippedSampleFraction, in: container
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.normalizedClippingThreshold, forKey: .normalizedClippingThreshold)
        try container.encode(value.maximumClippedSampleFraction, forKey: .maximumClippedSampleFraction)
    }
}

/// `IRCalibrationWhiteBalancePolicy`, on the wire. Shared between a
/// measurement set's own session balance and a fit result's — the same
/// domain type describes both, and this is the one place its wire shape is
/// written.
private struct PersistedWhiteBalancePolicy: Codable, CalibrationRecordField {
    static let fieldName = "whiteBalancePolicy"

    let value: IRCalibrationWhiteBalancePolicy

    init(_ value: IRCalibrationWhiteBalancePolicy) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case kind, patch
    }

    private enum Kind: String {
        case none, neutralPatch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try Self.require(String.self, CodingKeys.kind, in: container)
        guard let kind = Kind(rawValue: token) else {
            throw IRCalibrationRecordError.unknownToken(field: Self.fieldName, token: token)
        }
        switch kind {
        case .none:
            try Self.refuse(CodingKeys.patch, in: container)
            value = .none
        case .neutralPatch:
            value = .neutralPatch(
                try Self.require(IRCalibrationTargetPatchID.self, CodingKeys.patch, in: container)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .none:
            try container.encode(Kind.none.rawValue, forKey: .kind)
        case .neutralPatch(let patch):
            try container.encode(Kind.neutralPatch.rawValue, forKey: .kind)
            try container.encode(patch, forKey: .patch)
        }
    }
}

// MARK: - Patches

/// `RAWActiveAreaRegion`, on the wire.
private struct PersistedActiveAreaRegion: Codable, CalibrationRecordField {
    static let fieldName = "measurements.patches.region"

    let value: RAWActiveAreaRegion

    init(_ value: RAWActiveAreaRegion) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case originRow, originColumn, width, height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = RAWActiveAreaRegion(
            originRow: try Self.require(Int.self, CodingKeys.originRow, in: container),
            originColumn: try Self.require(Int.self, CodingKeys.originColumn, in: container),
            width: try Self.require(Int.self, CodingKeys.width, in: container),
            height: try Self.require(Int.self, CodingKeys.height, in: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.originRow, forKey: .originRow)
        try container.encode(value.originColumn, forKey: .originColumn)
        try container.encode(value.width, forKey: .width)
        try container.encode(value.height, forKey: .height)
    }
}

/// The token a `RAWLinearRGBChannel` is written as. That type carries no
/// `RawRepresentable` conformance of its own — it names which colour filter
/// produced a value, not a wire format — so the mapping is written out here,
/// explicitly and exhaustively, rather than invented through a case name.
private enum PersistedLinearRGBChannelToken: String {
    case red, green, blue

    init(_ channel: RAWLinearRGBChannel) {
        switch channel {
        case .red: self = .red
        case .green: self = .green
        case .blue: self = .blue
        }
    }

    var channel: RAWLinearRGBChannel {
        switch self {
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }
}

/// `IRCalibrationPlaneMeasurement`, on the wire.
private struct PersistedPlaneMeasurement: Codable, CalibrationRecordField {
    static let fieldName = "measurements.patches.planes"

    let value: IRCalibrationPlaneMeasurement

    init(_ value: IRCalibrationPlaneMeasurement) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case colorPlane, channel, sampleCount, mean, clippedSampleCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let channelToken = try Self.require(String.self, CodingKeys.channel, in: container)
        guard let token = PersistedLinearRGBChannelToken(rawValue: channelToken) else {
            throw IRCalibrationRecordError.unknownToken(
                field: "\(Self.fieldName).channel", token: channelToken
            )
        }
        value = try IRCalibrationPlaneMeasurement(
            colorPlane: try Self.require(Int.self, CodingKeys.colorPlane, in: container),
            channel: token.channel,
            sampleCount: try Self.require(Int.self, CodingKeys.sampleCount, in: container),
            mean: try Self.require(Double.self, CodingKeys.mean, in: container),
            clippedSampleCount: try Self.require(Int.self, CodingKeys.clippedSampleCount, in: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.colorPlane, forKey: .colorPlane)
        try container.encode(PersistedLinearRGBChannelToken(value.channel).rawValue, forKey: .channel)
        try container.encode(value.sampleCount, forKey: .sampleCount)
        try container.encode(value.mean, forKey: .mean)
        try container.encode(value.clippedSampleCount, forKey: .clippedSampleCount)
    }
}

/// `IRCalibrationPatchExclusion`, on the wire.
private struct PersistedPatchExclusion: Codable, CalibrationRecordField {
    static let fieldName = "measurements.patches.exclusion"

    let value: IRCalibrationPatchExclusion

    init(_ value: IRCalibrationPatchExclusion) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case kind, clippedSamples, totalSamples, missing, reason
    }

    private enum Kind: String {
        case clipped, incompleteColorPlanes, nonFiniteSample, noReferenceValue, excludedByOperator
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try Self.require(String.self, CodingKeys.kind, in: container)
        guard let kind = Kind(rawValue: token) else {
            throw IRCalibrationRecordError.unknownToken(field: Self.fieldName, token: token)
        }
        switch kind {
        case .clipped:
            try Self.refuse(CodingKeys.missing, in: container)
            try Self.refuse(CodingKeys.reason, in: container)
            value = .clipped(
                clippedSamples: try Self.require(Int.self, CodingKeys.clippedSamples, in: container),
                totalSamples: try Self.require(Int.self, CodingKeys.totalSamples, in: container)
            )
        case .incompleteColorPlanes:
            try Self.refuse(CodingKeys.clippedSamples, in: container)
            try Self.refuse(CodingKeys.totalSamples, in: container)
            try Self.refuse(CodingKeys.reason, in: container)
            value = .incompleteColorPlanes(
                missing: try Self.require([Int].self, CodingKeys.missing, in: container)
            )
        case .nonFiniteSample:
            try Self.refuse(CodingKeys.clippedSamples, in: container)
            try Self.refuse(CodingKeys.totalSamples, in: container)
            try Self.refuse(CodingKeys.missing, in: container)
            try Self.refuse(CodingKeys.reason, in: container)
            value = .nonFiniteSample
        case .noReferenceValue:
            try Self.refuse(CodingKeys.clippedSamples, in: container)
            try Self.refuse(CodingKeys.totalSamples, in: container)
            try Self.refuse(CodingKeys.missing, in: container)
            try Self.refuse(CodingKeys.reason, in: container)
            value = .noReferenceValue
        case .excludedByOperator:
            try Self.refuse(CodingKeys.clippedSamples, in: container)
            try Self.refuse(CodingKeys.totalSamples, in: container)
            try Self.refuse(CodingKeys.missing, in: container)
            value = .excludedByOperator(
                reason: try Self.require(String.self, CodingKeys.reason, in: container)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .clipped(let clippedSamples, let totalSamples):
            try container.encode(Kind.clipped.rawValue, forKey: .kind)
            try container.encode(clippedSamples, forKey: .clippedSamples)
            try container.encode(totalSamples, forKey: .totalSamples)
        case .incompleteColorPlanes(let missing):
            try container.encode(Kind.incompleteColorPlanes.rawValue, forKey: .kind)
            try container.encode(missing, forKey: .missing)
        case .nonFiniteSample:
            try container.encode(Kind.nonFiniteSample.rawValue, forKey: .kind)
        case .noReferenceValue:
            try container.encode(Kind.noReferenceValue.rawValue, forKey: .kind)
        case .excludedByOperator(let reason):
            try container.encode(Kind.excludedByOperator.rawValue, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// `IRCalibrationPatchMeasurement`, on the wire. `exclusion` is absent for an
/// included patch and present, tagged, for an excluded one — never a `null`
/// that stands in for "included", which would give one JSON value two
/// meanings.
private struct PersistedPatchMeasurement: Codable, CalibrationRecordField {
    static let fieldName = "measurements.patches"

    let value: IRCalibrationPatchMeasurement

    init(_ value: IRCalibrationPatchMeasurement) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case patch, region, planes, exclusion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let patch = try Self.require(IRCalibrationTargetPatchID.self, CodingKeys.patch, in: container)
        let region = try Self.require(
            PersistedActiveAreaRegion.self, CodingKeys.region, in: container
        ).value
        let planes = try Self.require(
            [PersistedPlaneMeasurement].self, CodingKeys.planes, in: container
        ).map(\.value)
        let exclusion = try container
            .decodeIfPresent(PersistedPatchExclusion.self, forKey: .exclusion)?.value

        value = try IRCalibrationPatchMeasurement(
            patch: patch, region: region, planes: planes, exclusion: exclusion
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.patch, forKey: .patch)
        try container.encode(PersistedActiveAreaRegion(value.region), forKey: .region)
        try container.encode(value.planes.map(PersistedPlaneMeasurement.init), forKey: .planes)
        try container.encodeIfPresent(
            value.exclusion.map(PersistedPatchExclusion.init), forKey: .exclusion
        )
    }
}

// MARK: - Provenance

/// `IRCalibrationProvenance`, on the wire.
private struct PersistedProvenance: Codable, CalibrationRecordField {
    static let fieldName = "measurements.provenance"

    let value: IRCalibrationProvenance

    init(_ value: IRCalibrationProvenance) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case author, tool, toolVersion, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try IRCalibrationProvenance(
            author: try Self.require(String.self, CodingKeys.author, in: container),
            tool: try Self.require(String.self, CodingKeys.tool, in: container),
            toolVersion: try Self.require(String.self, CodingKeys.toolVersion, in: container),
            notes: try container.decodeIfPresent(String.self, forKey: .notes)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.author, forKey: .author)
        try container.encode(value.tool, forKey: .tool)
        try container.encode(value.toolVersion, forKey: .toolVersion)
        try container.encodeIfPresent(value.notes, forKey: .notes)
    }
}

// MARK: - Measurement set

/// `IRCalibrationMeasurementSet`, on the wire: everything a camera actually
/// produced, in front of one target, under one illumination, on one occasion.
/// Reconstructed through `IRCalibrationMeasurementSet`'s own throwing
/// initialiser, so an evidence set claiming a patch its target does not have,
/// or a neutral-patch white-balance policy naming a patch that was not
/// measured, is refused there rather than accepted here and caught later.
private struct PersistedMeasurementSet: Codable, CalibrationRecordField {
    static let fieldName = "measurements"

    let value: IRCalibrationMeasurementSet

    init(_ value: IRCalibrationMeasurementSet) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case id, measuredAt, target, illuminant, captureContext, domain,
             normalization, clippingPolicy, whiteBalancePolicy, patches, provenance, sourceFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let id = try Self.require(IRCalibrationMeasurementSetID.self, CodingKeys.id, in: container)

        let measuredAtToken = try Self.require(String.self, CodingKeys.measuredAt, in: container)
        guard let measuredAt = IRCalibrationRecordDateFormatter.shared.date(from: measuredAtToken) else {
            throw IRCalibrationRecordError.unknownToken(
                field: "\(Self.fieldName).\(CodingKeys.measuredAt.stringValue)", token: measuredAtToken
            )
        }

        let targetToken = try Self.require(String.self, CodingKeys.target, in: container)
        guard let target = IRCalibrationTarget(rawValue: targetToken) else {
            throw IRCalibrationRecordError.unknownToken(
                field: "\(Self.fieldName).\(CodingKeys.target.stringValue)", token: targetToken
            )
        }

        let illuminant = try Self.require(
            PersistedIlluminant.self, CodingKeys.illuminant, in: container
        ).value
        let captureContext = try Self.require(
            PersistedCaptureContext.self, CodingKeys.captureContext, in: container
        ).value
        let domain = try Self.require(
            PersistedMeasurementDomain.self, CodingKeys.domain, in: container
        ).value
        let normalization = try Self.require(
            PersistedNormalizationProvenance.self, CodingKeys.normalization, in: container
        ).value
        let clippingPolicy = try Self.require(
            PersistedClippingPolicy.self, CodingKeys.clippingPolicy, in: container
        ).value
        let whiteBalancePolicy = try Self.require(
            PersistedWhiteBalancePolicy.self, CodingKeys.whiteBalancePolicy, in: container
        ).value
        let patches = try Self.require(
            [PersistedPatchMeasurement].self, CodingKeys.patches, in: container
        ).map(\.value)
        let provenance = try Self.require(
            PersistedProvenance.self, CodingKeys.provenance, in: container
        ).value
        let sourceFileName = try container.decodeIfPresent(String.self, forKey: .sourceFileName)

        value = try IRCalibrationMeasurementSet(
            id: id,
            measuredAt: measuredAt,
            target: target,
            illuminant: illuminant,
            captureContext: captureContext,
            domain: domain,
            normalization: normalization,
            clippingPolicy: clippingPolicy,
            whiteBalancePolicy: whiteBalancePolicy,
            patches: patches,
            provenance: provenance,
            sourceFileName: sourceFileName
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.id, forKey: .id)
        try container.encode(
            IRCalibrationRecordDateFormatter.shared.string(from: value.measuredAt), forKey: .measuredAt
        )
        try container.encode(value.target.rawValue, forKey: .target)
        try container.encode(PersistedIlluminant(value.illuminant), forKey: .illuminant)
        try container.encode(PersistedCaptureContext(value.captureContext), forKey: .captureContext)
        try container.encode(PersistedMeasurementDomain(value.domain), forKey: .domain)
        try container.encode(
            PersistedNormalizationProvenance(value.normalization), forKey: .normalization
        )
        try container.encode(PersistedClippingPolicy(value.clippingPolicy), forKey: .clippingPolicy)
        try container.encode(
            PersistedWhiteBalancePolicy(value.whiteBalancePolicy), forKey: .whiteBalancePolicy
        )
        try container.encode(value.patches.map(PersistedPatchMeasurement.init), forKey: .patches)
        try container.encode(PersistedProvenance(value.provenance), forKey: .provenance)
        try container.encodeIfPresent(value.sourceFileName, forKey: .sourceFileName)
    }
}

// MARK: - Reference dataset

/// `IRCalibrationReferenceRGB`, on the wire.
private struct PersistedReferenceRGB: Codable, CalibrationRecordField {
    static let fieldName = "reference.values"

    let value: IRCalibrationReferenceRGB

    init(_ value: IRCalibrationReferenceRGB) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case red, green, blue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try IRCalibrationReferenceRGB(
            red: try Self.require(Double.self, CodingKeys.red, in: container),
            green: try Self.require(Double.self, CodingKeys.green, in: container),
            blue: try Self.require(Double.self, CodingKeys.blue, in: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.red, forKey: .red)
        try container.encode(value.green, forKey: .green)
        try container.encode(value.blue, forKey: .blue)
    }
}

/// `IRCalibrationReferenceDataset`, on the wire. `values` is written as a JSON
/// **object** keyed by patch id, not the array-of-pairs shape
/// `Dictionary<IRCalibrationTargetPatchID, _>` would otherwise fall back to —
/// `IRCalibrationTargetPatchID` is not `String` and carries no
/// `CodingKeyRepresentable` conformance, so the keys are converted to and from
/// their raw strings explicitly here, once.
private struct PersistedReferenceDataset: Codable, CalibrationRecordField {
    static let fieldName = "reference"

    let value: IRCalibrationReferenceDataset

    init(_ value: IRCalibrationReferenceDataset) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case identifier, version, source, colorSpace, illuminant, target, values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let identifier = try Self.require(String.self, CodingKeys.identifier, in: container)
        let version = try Self.require(String.self, CodingKeys.version, in: container)
        let source = try Self.require(String.self, CodingKeys.source, in: container)

        let colorSpaceToken = try Self.require(String.self, CodingKeys.colorSpace, in: container)
        guard let colorSpace = IRCalibrationReferenceColorSpace(rawValue: colorSpaceToken) else {
            throw IRCalibrationRecordError.unknownToken(
                field: "\(Self.fieldName).colorSpace", token: colorSpaceToken
            )
        }

        let illuminant = try Self.require(
            PersistedIlluminant.self, CodingKeys.illuminant, in: container
        ).value

        let targetToken = try Self.require(String.self, CodingKeys.target, in: container)
        guard let target = IRCalibrationTarget(rawValue: targetToken) else {
            throw IRCalibrationRecordError.unknownToken(
                field: "\(Self.fieldName).target", token: targetToken
            )
        }

        let rawValues = try Self.require(
            [String: PersistedReferenceRGB].self, CodingKeys.values, in: container
        )
        var values: [IRCalibrationTargetPatchID: IRCalibrationReferenceRGB] = [:]
        for (token, rgb) in rawValues {
            let patch = try IRCalibrationTargetPatchID(token)
            values[patch] = rgb.value
        }

        value = try IRCalibrationReferenceDataset(
            identifier: identifier,
            version: version,
            source: source,
            colorSpace: colorSpace,
            illuminant: illuminant,
            target: target,
            values: values
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.identifier, forKey: .identifier)
        try container.encode(value.version, forKey: .version)
        try container.encode(value.source, forKey: .source)
        try container.encode(value.colorSpace.rawValue, forKey: .colorSpace)
        try container.encode(PersistedIlluminant(value.illuminant), forKey: .illuminant)
        try container.encode(value.target.rawValue, forKey: .target)

        var rawValues: [String: PersistedReferenceRGB] = [:]
        for (patch, rgb) in value.values {
            rawValues[patch.rawValue] = PersistedReferenceRGB(rgb)
        }
        try container.encode(rawValues, forKey: .values)
    }
}

// MARK: - Fit result

/// `RAWColorMatrix3x3`, on the wire: nine required coefficients, named for
/// their row and column exactly as the type documents them.
private struct PersistedMatrix: Codable, CalibrationRecordField {
    static let fieldName = "fit.matrix"

    let value: RAWColorMatrix3x3

    init(_ value: RAWColorMatrix3x3) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case m00, m01, m02, m10, m11, m12, m20, m21, m22
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try RAWColorMatrix3x3(
            m00: try Self.require(Double.self, CodingKeys.m00, in: container),
            m01: try Self.require(Double.self, CodingKeys.m01, in: container),
            m02: try Self.require(Double.self, CodingKeys.m02, in: container),
            m10: try Self.require(Double.self, CodingKeys.m10, in: container),
            m11: try Self.require(Double.self, CodingKeys.m11, in: container),
            m12: try Self.require(Double.self, CodingKeys.m12, in: container),
            m20: try Self.require(Double.self, CodingKeys.m20, in: container),
            m21: try Self.require(Double.self, CodingKeys.m21, in: container),
            m22: try Self.require(Double.self, CodingKeys.m22, in: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.m00, forKey: .m00)
        try container.encode(value.m01, forKey: .m01)
        try container.encode(value.m02, forKey: .m02)
        try container.encode(value.m10, forKey: .m10)
        try container.encode(value.m11, forKey: .m11)
        try container.encode(value.m12, forKey: .m12)
        try container.encode(value.m20, forKey: .m20)
        try container.encode(value.m21, forKey: .m21)
        try container.encode(value.m22, forKey: .m22)
    }
}

/// `IRCalibrationFitMethod`, on the wire.
private struct PersistedFitMethod: Codable, CalibrationRecordField {
    static let fieldName = "fit.method"

    let value: IRCalibrationFitMethod

    init(_ value: IRCalibrationFitMethod) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case algorithm, version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = IRCalibrationFitMethod(
            algorithm: try Self.require(String.self, CodingKeys.algorithm, in: container),
            version: try Self.require(Int.self, CodingKeys.version, in: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.algorithm, forKey: .algorithm)
        try container.encode(value.version, forKey: .version)
    }
}

/// `IRCalibrationConditioning`, on the wire. `channelNorms` must carry exactly
/// three values — one per RGB channel — and a record whose array has a
/// different count is refused with `.inconsistentRecord` rather than passed
/// through to `IRCalibrationConditioning`'s own memberwise initialiser, which
/// performs no such check itself.
private struct PersistedConditioning: Codable, CalibrationRecordField {
    static let fieldName = "fit.conditioning"

    let value: IRCalibrationConditioning

    init(_ value: IRCalibrationConditioning) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case normalizedGramDeterminant, channelNorms, sampleCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let determinant = try Self.require(
            Double.self, CodingKeys.normalizedGramDeterminant, in: container
        )
        let channelNorms = try Self.require([Double].self, CodingKeys.channelNorms, in: container)
        guard channelNorms.count == 3 else {
            throw IRCalibrationRecordError.inconsistentRecord(
                reason: """
                    "\(Self.fieldName).channelNorms" must carry exactly 3 values, one per RGB \
                    channel; this record carries \(channelNorms.count).
                    """
            )
        }
        value = IRCalibrationConditioning(
            normalizedGramDeterminant: determinant,
            channelNorms: channelNorms,
            sampleCount: try Self.require(Int.self, CodingKeys.sampleCount, in: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.normalizedGramDeterminant, forKey: .normalizedGramDeterminant)
        try container.encode(value.channelNorms, forKey: .channelNorms)
        try container.encode(value.sampleCount, forKey: .sampleCount)
    }
}

/// `IRCalibrationPatchResidual`, on the wire.
private struct PersistedPatchResidual: Codable, CalibrationRecordField {
    static let fieldName = "fit.metrics.residuals"

    let value: IRCalibrationPatchResidual

    init(_ value: IRCalibrationPatchResidual) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case patch, red, green, blue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try IRCalibrationPatchResidual(
            patch: try Self.require(IRCalibrationTargetPatchID.self, CodingKeys.patch, in: container),
            red: try Self.require(Double.self, CodingKeys.red, in: container),
            green: try Self.require(Double.self, CodingKeys.green, in: container),
            blue: try Self.require(Double.self, CodingKeys.blue, in: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.patch, forKey: .patch)
        try container.encode(value.red, forKey: .red)
        try container.encode(value.green, forKey: .green)
        try container.encode(value.blue, forKey: .blue)
    }
}

/// `IRCalibrationFitMetrics`, on the wire.
///
/// ## `rmse` and `maximumResidual` are deliberately absent
///
/// Both are computed properties on `IRCalibrationFitMetrics`, derived from
/// `residuals` every time they are read. Persisting them here would create a
/// second authority for a number the type already knows how to compute, and
/// the two could disagree — a hand-edited file, or a future change to the
/// derivation, would leave a stored RMSE that no longer matches the residuals
/// beside it, with nothing to catch the mismatch. Only `excludedPatchCount` is
/// carried, because it is not derivable from `residuals` at all: it is a fact
/// about patches that are *not* in the list.
private struct PersistedFitMetrics: Codable, CalibrationRecordField {
    static let fieldName = "fit.metrics"

    let value: IRCalibrationFitMetrics

    init(_ value: IRCalibrationFitMetrics) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case excludedPatchCount, residuals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let excludedPatchCount = try Self.require(
            Int.self, CodingKeys.excludedPatchCount, in: container
        )
        let residuals = try Self.require(
            [PersistedPatchResidual].self, CodingKeys.residuals, in: container
        ).map(\.value)
        // A duplicate residual, or a negative excluded count, is refused by
        // the metrics themselves — the same refusal a caller building this in
        // memory would meet, propagating unchanged rather than being restated
        // here as a second description of one fault.
        value = try IRCalibrationFitMetrics(
            residuals: residuals, excludedPatchCount: excludedPatchCount
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.excludedPatchCount, forKey: .excludedPatchCount)
        try container.encode(value.residuals.map(PersistedPatchResidual.init), forKey: .residuals)
    }
}

/// `IRCalibrationFitResult`, on the wire.
private struct PersistedFitResult: Codable, CalibrationRecordField {
    static let fieldName = "fit"

    let value: IRCalibrationFitResult

    init(_ value: IRCalibrationFitResult) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case matrix, sourceMeasurementID, referenceDataset, whiteBalancePolicy,
             method, conditioning, metrics, fittedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let matrix = try Self.require(PersistedMatrix.self, CodingKeys.matrix, in: container).value
        let sourceMeasurementID = try Self.require(
            IRCalibrationMeasurementSetID.self, CodingKeys.sourceMeasurementID, in: container
        )
        let referenceDataset = try Self.require(
            String.self, CodingKeys.referenceDataset, in: container
        )
        let whiteBalancePolicy = try Self.require(
            PersistedWhiteBalancePolicy.self, CodingKeys.whiteBalancePolicy, in: container
        ).value
        let method = try Self.require(PersistedFitMethod.self, CodingKeys.method, in: container).value
        let conditioning = try Self.require(
            PersistedConditioning.self, CodingKeys.conditioning, in: container
        ).value
        let metrics = try Self.require(
            PersistedFitMetrics.self, CodingKeys.metrics, in: container
        ).value

        let fittedAtToken = try Self.require(String.self, CodingKeys.fittedAt, in: container)
        guard let fittedAt = IRCalibrationRecordDateFormatter.shared.date(from: fittedAtToken) else {
            throw IRCalibrationRecordError.unknownToken(
                field: "\(Self.fieldName).\(CodingKeys.fittedAt.stringValue)", token: fittedAtToken
            )
        }

        value = IRCalibrationFitResult(
            matrix: matrix,
            sourceMeasurementID: sourceMeasurementID,
            referenceDataset: referenceDataset,
            whiteBalancePolicy: whiteBalancePolicy,
            method: method,
            conditioning: conditioning,
            metrics: metrics,
            fittedAt: fittedAt
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PersistedMatrix(value.matrix), forKey: .matrix)
        try container.encode(value.sourceMeasurementID, forKey: .sourceMeasurementID)
        try container.encode(value.referenceDataset, forKey: .referenceDataset)
        try container.encode(
            PersistedWhiteBalancePolicy(value.whiteBalancePolicy), forKey: .whiteBalancePolicy
        )
        try container.encode(PersistedFitMethod(value.method), forKey: .method)
        try container.encode(PersistedConditioning(value.conditioning), forKey: .conditioning)
        try container.encode(PersistedFitMetrics(value.metrics), forKey: .metrics)
        try container.encode(
            IRCalibrationRecordDateFormatter.shared.string(from: value.fittedAt), forKey: .fittedAt
        )
    }
}
