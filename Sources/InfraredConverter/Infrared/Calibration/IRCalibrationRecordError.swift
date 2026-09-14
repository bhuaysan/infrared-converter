import Foundation

/// Why a persisted calibration **record** could not be understood, or could
/// not be written.
///
/// Separate from `IRCalibrationPersistenceError` for the reason every error
/// type in this project is separate from its neighbours: a different
/// boundary. This is the **record** refusing — a schema version from the
/// future, a missing field, a field its kind does not carry, a token this
/// build does not model, or a fit whose own numbers disagree with each other.
/// That one is the **file** refusing: it could not be read, written or
/// deleted, or the library it belongs to found two files claiming one
/// identity.
///
/// It is the exact counterpart of `IRCaptureProfileRecordError`, one artefact
/// along, plus one case that type does not need:
/// ``inconsistentRecord(reason:)``. A capture profile's fields are
/// independent of one another; a calibration record carries a fit whose
/// `channelNorms` must have exactly three entries — one per RGB channel — and
/// a record that says otherwise is not a schema violation in any single
/// field, it is two fields disagreeing about how many there are.
public enum IRCalibrationRecordError: Error, Equatable {

    /// The record declares a schema version this build does not read.
    ///
    /// Refused rather than read as an older version. A newer record may carry
    /// evidence, a reference dataset or a fit shape this build does not model,
    /// and guessing at it would silently drop a field somebody's measurement
    /// depends on.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    /// A field the record's version requires is absent, or explicitly `null`.
    ///
    /// Never defaulted. A calibration with no fit is not a calibration with a
    /// default one; it is a file this build cannot interpret.
    case missingField(field: String, schemaVersion: Int)

    /// A field the record's version, or the tagged kind it is inside, does not
    /// have is present.
    ///
    /// A white-balance policy that calls itself `none` while also carrying a
    /// `patch` says two things about one session, and there is no reading of
    /// it that is not a guess.
    case unexpectedField(field: String, schemaVersion: Int)

    /// A discriminator this build does not model — an illuminant kind, a
    /// white-balance-policy kind, a filter kind, a colour-space token, a
    /// channel letter, a target name.
    case unknownToken(field: String, token: String)

    /// A record whose fields are each individually well-formed but disagree
    /// with each other in a way a single field's validation cannot catch.
    ///
    /// The one case in this type that has no counterpart in
    /// `IRCaptureProfileRecordError`, because a capture profile has no field
    /// whose length is a constraint on another field. A fit's conditioning
    /// carries exactly one column norm per RGB channel; a record whose
    /// `channelNorms` array has two entries or four is not describing three
    /// camera channels, and no amount of per-field decoding catches that.
    ///
    /// Consistency rules that concern the **domain values themselves** —
    /// residual counts against measured patches, a fit's evidence identity
    /// against the measurement set it is stored with — are not duplicated
    /// here at all: decoding reconstructs through `IRCalibration`'s own
    /// initialiser, and its `IRCalibrationError` is left to propagate rather
    /// than re-expressed as a second, competing description of the same
    /// fault.
    case inconsistentRecord(reason: String)
}

extension IRCalibrationRecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion:
            return "This calibration was written by a newer version."
        case .missingField:
            return "This calibration is missing a required value."
        case .unexpectedField:
            return "This calibration contains a value it should not."
        case .unknownToken:
            return "This calibration uses a value this version does not understand."
        case .inconsistentRecord:
            return "This calibration's own values do not agree with each other."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return """
                The file says schema version \(found); this version reads up to \(supported). \
                It was not read as an older record: a newer one may carry evidence or a fit \
                shape this build does not model, and guessing would silently drop it.
                """
        case .missingField(let field, let version):
            return """
                "\(field)" is required at schema version \(version) and is absent. Nothing was \
                substituted for it.
                """
        case .unexpectedField(let field, let version):
            return """
                "\(field)" is not part of this record at schema version \(version). A record \
                with two authorities for one value has no reading that is not a guess.
                """
        case .unknownToken(let field, let token):
            return "\"\(token)\" is not a \(field) this version models."
        case .inconsistentRecord(let reason):
            return reason
        }
    }
}
