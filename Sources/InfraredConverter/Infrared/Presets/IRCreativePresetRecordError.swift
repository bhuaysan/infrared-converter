import Foundation

/// Why a stored creative-preset record could not be understood.
///
/// The record boundary, kept apart from `IRCreativePresetPersistenceError` —
/// which is about files — exactly as `IRCaptureProfileRecordError` is kept
/// apart from `IRCaptureProfilePersistenceError`. This is a **record**
/// refusing to be read; that is a **file** refusing to be read.
public enum IRCreativePresetRecordError: Error, Equatable {

    /// The record names a schema version this build does not read.
    ///
    /// Refused rather than read around. A preset written by a newer build may
    /// carry a field that changes which matrix is applied, and reading it as
    /// though it were version 1 would apply a mix nobody chose.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    /// A field the record's version requires is absent, or is `null`.
    case missingField(field: String, schemaVersion: Int)

    /// A field is present that the record's shape does not have.
    case unexpectedField(field: String, schemaVersion: Int)

    /// A tagged object names a kind this build does not know.
    case unknownToken(field: String, token: String)
}

extension IRCreativePresetRecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion:
            return "That creative preset was written by a newer version."
        case .missingField:
            return "A creative preset is incomplete."
        case .unexpectedField:
            return "A creative preset contains a field that contradicts it."
        case .unknownToken:
            return "A creative preset describes something this version does not know."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return """
                It is at preset schema version \(found); this version reads up to \
                \(supported). The file was left exactly as it is.
                """
        case .missingField(let field, let version):
            return """
                Schema version \(version) requires "\(field)", and it is missing. No value \
                was invented for it.
                """
        case .unexpectedField(let field, let version):
            return """
                "\(field)" is not part of what this record says it is, at schema version \
                \(version). Reading it would mean choosing between two things the record \
                says about itself.
                """
        case .unknownToken(let field, let token):
            return "\"\(field)\" is \"\(token)\", which this version does not recognise."
        }
    }
}
