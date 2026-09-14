import Foundation

/// Why a persisted photograph record could not be understood.
///
/// ```text
/// PhotographProcessingStateError   the RECORD's shape: which schema version,
///                                  which fields that version has
/// ImageAdjustmentError             one ADJUSTMENT's value: an orientation
///                                  token, a channel-mix kind, a patch
/// IRCaptureProfileError            the PROFILE system: a malformed identity,
///                                  a reference to a profile that is not here
/// PhotographProcessingPersistenceError
///                                  the FILE: unreadable, unwritable, or bytes
///                                  that are not this record at all
/// ```
///
/// Four types because there are four boundaries, and a caller that wants to
/// tell "your sidecar was written by a newer version of this app" from "that
/// profile is not installed" has to be able to ask. Each stays intact across
/// the ones above it; nothing is flattened into a sentence.
///
/// ## Nothing here is recovered
///
/// No case is defaulted, repaired or deleted. A record that exists and cannot
/// be read means the application knows the user made decisions about this
/// photograph and cannot tell what they were. See
/// `docs/decisions/0013-adjustment-sidecar.md` and
/// `docs/decisions/0020-ir-capture-profile-foundation.md`.
public enum PhotographProcessingStateError: Error, Equatable {

    /// The record names a schema version this build does not read.
    ///
    /// A version above the current one is a record from a newer build, and it
    /// may carry settings whose omission would change the photograph — so it is
    /// refused rather than read around. A version below `1` was written by no
    /// build of this project.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    /// A field the record's own schema version requires is absent.
    ///
    /// Absence is refused, never defaulted. A default would be a guess about
    /// what the user chose, presented as their choice.
    case missingField(field: String, schemaVersion: Int)

    /// The record carries a field its schema version does not have.
    ///
    /// Refused rather than read. Reading it would mean a version number no
    /// longer describes a record's contents; writing the record back at the
    /// current version would then make whatever was misread permanent.
    case unexpectedField(field: String, schemaVersion: Int)
}

extension PhotographProcessingStateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion:
            return "These saved settings were written by a different version of this app."
        case .missingField:
            return "The saved settings are missing something they need."
        case .unexpectedField:
            return "The saved settings contain something that version does not have."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            let direction = found > supported
                ? "a newer version of this app wrote it"
                : "no version of this app wrote it"
            return """
                The record says schema version \(found); this build reads up to \(supported), \
                so \(direction). It was left exactly as it is.
                """

        case .missingField(let field, let version):
            return """
                Schema version \(version) requires "\(field)", and the record does not have it. \
                Guessing what it was would present a value the user never chose as their choice.
                """

        case .unexpectedField(let field, let version):
            return """
                The record says schema version \(version), which has no "\(field)". Reading it \
                anyway would mean the version number no longer describes the contents.
                """
        }
    }
}
