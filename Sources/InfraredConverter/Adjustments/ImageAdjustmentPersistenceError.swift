import Foundation

/// Why the user's saved adjustments could not be read or written.
///
/// Separate from `ImageAdjustmentError` for the reason every error type in
/// this project is separate from its neighbours: a different boundary.
/// `ImageAdjustmentError` is the **record** refusing to be understood — an
/// unknown orientation token, a schema version from the future. This is the
/// **file** refusing: it could not be read, its bytes were not the record we
/// expected, or it could not be written.
///
/// The two meet in `cannotDecode`, which is where a typed
/// `ImageAdjustmentError` arrives wrapped rather than flattened. That
/// wrapping is the point: a caller that wants to know whether the sidecar was
/// written by a newer build can still ask, through `adjustment`.
///
/// ## Nothing here recovers
///
/// No case is repaired, deleted or defaulted. A sidecar that exists and cannot
/// be read means the application knows a user made decisions about this
/// photograph and cannot tell what they were. Substituting
/// `ImageAdjustments.none` there would silently discard them and render a
/// different photograph without saying so. See
/// `docs/decisions/0013-adjustment-sidecar.md`.
public enum ImageAdjustmentPersistenceError: Error {
    /// The sidecar exists and its bytes could not be obtained — permissions,
    /// an unreadable volume, a directory where a file was expected.
    ///
    /// A sidecar that does **not** exist is not this, and not an error at all:
    /// `load` returns `nil`.
    case cannotRead(sidecar: URL, underlying: any Error)

    /// The sidecar's bytes are not an adjustment record this build can read.
    ///
    /// Carries the refusal itself — an `ImageAdjustmentError` for an
    /// unsupported schema version, an unknown orientation token or a missing
    /// field; a `DecodingError` for bytes that are not the JSON we expect.
    case cannotDecode(sidecar: URL, underlying: any Error)

    /// The sidecar could not be written. The adjustments are still correct in
    /// memory and the image on screen is still the right one; only the durable
    /// copy is missing.
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

    /// The adjustment model's own refusal, when the record was what refused.
    ///
    /// The projection that keeps the typed value alive across the file
    /// boundary: an unsupported schema version stays
    /// `.unsupportedSchemaVersion`, rather than becoming a sentence about a
    /// file that could not be read.
    public var adjustment: ImageAdjustmentError? {
        underlying as? ImageAdjustmentError
    }
}

extension ImageAdjustmentPersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotRead:
            return "The saved adjustments could not be read."
        case .cannotDecode:
            return "The saved adjustments could not be understood."
        case .cannotWrite:
            return "The adjustments could not be saved."
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
                \(sidecar.lastPathComponent) is not an adjustment record this version can \
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
