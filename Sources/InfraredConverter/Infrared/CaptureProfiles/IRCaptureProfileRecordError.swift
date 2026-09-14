import Foundation

/// Why a persisted capture-profile **record** could not be understood, or
/// could not be written.
///
/// Separate from `IRCaptureProfilePersistenceError` for the reason every error
/// type in this project is separate from its neighbours: a different boundary.
/// This is the **record** refusing — a schema version from the future, a
/// missing field, a token this build does not model, a processing basis that
/// has no wire format. That one is the **file** refusing: it could not be read,
/// written or deleted, or the library it belongs to is ambiguous.
///
/// It is the exact counterpart of `PhotographProcessingStateError`, one
/// artefact along. The two schemas are deliberately independent: a photograph's
/// sidecar and a reusable profile definition have different lifetimes,
/// different contents and no reason to change together. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
public enum IRCaptureProfileRecordError: Error, Equatable {

    /// The record declares a schema version this build does not read.
    ///
    /// Refused rather than read as version 1. A newer record may carry a field
    /// whose omission changes what a photograph looks like — a processing basis
    /// above all — and a build that guessed would render somebody's photographs
    /// through the wrong camera transform and say nothing.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    /// A field the record's version requires is absent, or explicitly `null`.
    ///
    /// Never defaulted. A profile with no processing basis is not a profile
    /// with the default one; it is a file this build cannot interpret.
    case missingField(field: String, schemaVersion: Int)

    /// A field the record's version does not have is present.
    ///
    /// A camera match that carries a make while calling itself `any` says two
    /// things about one profile, and there is no reading of it that is not a
    /// guess.
    case unexpectedField(field: String, schemaVersion: Int)

    /// A discriminator this build does not model — a filter kind, a conversion
    /// kind, a camera-match kind.
    case unknownToken(field: String, token: String)

    /// A processing basis that has no persisted form, in either direction.
    ///
    /// Reached from **encoding** when a profile carries
    /// `IRCaptureProcessingBasis.explicitMatrix`, and from **decoding** when a
    /// record names a basis kind this build does not write.
    ///
    /// ## Why `.explicitMatrix` may not be written
    ///
    /// It is an internal escape hatch, present since
    /// [ADR 0006](../../../docs/decisions/0006-working-color-space.md), whose
    /// entire contract is that its coefficients are finite. It carries no
    /// measurement, no provenance and no validation. Giving it a file format
    /// would turn a test-only hatch into a public infrared-calibration
    /// interchange format overnight — a `.irprofile.json` full of coefficients
    /// nobody measured, shared between photographers as though it were
    /// characterisation data.
    ///
    /// So it stays runtime-only, and the refusal is **typed and loud** rather
    /// than a silent downgrade to `uncalibratedSensorRGB`: a profile that
    /// quietly lost its matrix on the way to disk would render differently
    /// after a restart. See
    /// `docs/decisions/0021-user-capture-profile-library.md`.
    case unsupportedProcessingBasis(kind: String, reason: String)
}

extension IRCaptureProfileRecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion:
            return "This capture profile was written by a newer version."
        case .missingField:
            return "This capture profile is missing a required setting."
        case .unexpectedField:
            return "This capture profile contains a setting it should not."
        case .unknownToken:
            return "This capture profile uses a setting this version does not understand."
        case .unsupportedProcessingBasis:
            return "That processing basis cannot be saved in a capture profile."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return """
                The file says schema version \(found); this version reads up to \(supported). \
                It was not read as an older record: a newer one may select a different \
                camera transform, and guessing would change how photographs are rendered.
                """
        case .missingField(let field, let version):
            return """
                "\(field)" is required at schema version \(version) and is absent. Nothing \
                was substituted for it.
                """
        case .unexpectedField(let field, let version):
            return """
                "\(field)" is not part of this profile at schema version \(version). A record \
                with two authorities for one value has no reading that is not a guess.
                """
        case .unknownToken(let field, let token):
            return "\"\(token)\" is not a \(field) this version models."
        case .unsupportedProcessingBasis(let kind, let reason):
            return "\(kind): \(reason)"
        }
    }
}
