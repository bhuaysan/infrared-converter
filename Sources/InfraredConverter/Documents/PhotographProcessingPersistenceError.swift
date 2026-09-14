import Foundation

/// Why a photograph's saved processing state could not be read or written.
///
/// Separate from the record's own refusals for the reason every error type in
/// this project is separate from its neighbours: a different boundary.
/// `PhotographProcessingStateError`, `ImageAdjustmentError` and
/// `IRCaptureProfileError` are the **record** refusing to be understood — a
/// schema version from the future, an unknown orientation token, a malformed
/// profile identifier. This is the **file** refusing: it could not be read, its
/// bytes were not the record we expected, or it could not be written.
///
/// They meet in `cannotDecode`, which is where a typed refusal arrives wrapped
/// rather than flattened. That wrapping is the point: a caller that wants to
/// know whether the sidecar was written by a newer build can still ask, through
/// `record`.
///
/// ## Nothing here recovers
///
/// No case is repaired, deleted or defaulted. A sidecar that exists and cannot
/// be read means the application knows a user made decisions about this
/// photograph and cannot tell what they were. Substituting
/// `PhotographProcessingState.none` there would silently discard them and
/// render a different photograph without saying so. See
/// `docs/decisions/0013-adjustment-sidecar.md`.
public enum PhotographProcessingPersistenceError: Error {
    /// The sidecar exists and its bytes could not be obtained — permissions,
    /// an unreadable volume, a directory where a file was expected.
    ///
    /// A sidecar that does **not** exist is not this, and not an error at all:
    /// `load` returns `nil`.
    case cannotRead(sidecar: URL, underlying: any Error)

    /// The sidecar's bytes are not a record this build can read.
    ///
    /// Carries the refusal itself — a `PhotographProcessingStateError` for an
    /// unsupported schema version or a missing field, an `ImageAdjustmentError`
    /// for an unknown token, an `IRCaptureProfileError` for a malformed profile
    /// identifier, a `DecodingError` for bytes that are not the JSON we expect.
    case cannotDecode(sidecar: URL, underlying: any Error)

    /// The sidecar could not be written. The state is still correct in memory
    /// and the image on screen is still the right one; only the durable copy is
    /// missing.
    case cannotWrite(sidecar: URL, underlying: any Error)

    /// The sidecar file this error is about.
    public var sidecar: URL {
        switch self {
        case .cannotRead(let sidecar, _),
             .cannotDecode(let sidecar, _),
             .cannotWrite(let sidecar, _):
            return sidecar
        }
    }

    /// The refusal exactly as it was thrown.
    public var underlying: any Error {
        switch self {
        case .cannotRead(_, let underlying),
             .cannotDecode(_, let underlying),
             .cannotWrite(_, let underlying):
            return underlying
        }
    }

    /// The record's own refusal about its shape, when that is what refused.
    ///
    /// The projection that keeps the typed value alive across the file
    /// boundary: an unsupported schema version stays
    /// `.unsupportedSchemaVersion` rather than becoming a sentence about a file
    /// that could not be read.
    public var record: PhotographProcessingStateError? {
        underlying as? PhotographProcessingStateError
    }

    /// One adjustment's own refusal, when that is what refused.
    public var adjustment: ImageAdjustmentError? {
        underlying as? ImageAdjustmentError
    }

    /// The profile system's own refusal, when that is what refused.
    ///
    /// Reached from here only for a **malformed** identifier, which is a
    /// property of the bytes. A well-formed reference to a profile that is not
    /// installed decodes perfectly well and is refused later, by the registry,
    /// where the question is asked.
    public var captureProfile: IRCaptureProfileError? {
        underlying as? IRCaptureProfileError
    }
}

extension PhotographProcessingPersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotRead:
            return "The saved settings could not be read."
        case .cannotDecode:
            return "The saved settings could not be understood."
        case .cannotWrite:
            return "The settings could not be saved."
        }
    }

    public var failureReason: String? {
        let detail = (underlying as? LocalizedError)?.errorDescription
            ?? underlying.localizedDescription
        switch self {
        case .cannotRead(let sidecar, _):
            return "\(sidecar.lastPathComponent) exists but could not be read: \(detail)"
        case .cannotDecode(let sidecar, _):
            return """
                \(sidecar.lastPathComponent) is not a settings record this version can \
                read: \(detail)
                """
        case .cannotWrite(let sidecar, _):
            return """
                \(sidecar.lastPathComponent) could not be written: \(detail) The image is \
                correct; only the saved copy is missing.
                """
        }
    }
}
