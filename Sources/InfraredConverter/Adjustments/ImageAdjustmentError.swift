import Foundation

/// Failures the user-owned adjustment model can report.
///
/// Separate from `RAWProcessingError`, `IRProcessingError`, `OrientationError`
/// and `DisplayRenderingError` for the same reason each of those is separate:
/// a different boundary. Nothing here is sensor data, colour, geometry or
/// display encoding. What can go wrong is **persisted state that cannot be
/// understood** — and the policy for that is to say so, never to guess.
///
/// ## Why nothing recovers to identity
///
/// Identity is a meaningful adjustment: it means "the user asked for no
/// correction". Substituting it for a value we failed to read would turn a
/// parse failure into a silent, plausible editing decision — the photograph
/// would quietly lose a rotation the user had made, and nothing on screen or
/// in provenance would say why.
///
/// So an unreadable adjustment is reported, and the caller decides. That is
/// the same policy `RAWImageOrientation.init?(decoderFlip:)` applies to an
/// unmodelled decoder value, for the same reason.
public enum ImageAdjustmentError: Error, Equatable {
    /// A persisted orientation adjustment names a state this version does not
    /// model — a typo, a corrupted file, or a token a newer version writes.
    ///
    /// The token is reported verbatim so the state can be investigated rather
    /// than guessed at.
    case unknownOrientationAdjustment(token: String)
    /// The persisted adjustments declare a schema version this build cannot
    /// read.
    ///
    /// A **newer** version may contain adjustments whose omission would change
    /// the rendered image, so it is refused rather than partially applied. A
    /// version below `1` is not a schema this project ever wrote.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// A persisted adjustment record is missing a field its declared schema
    /// version requires.
    case missingAdjustment(field: String, schemaVersion: Int)
}

extension ImageAdjustmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownOrientationAdjustment:
            return "The saved orientation adjustment could not be understood."
        case .unsupportedSchemaVersion:
            return "The saved adjustments were written by a different version of this app."
        case .missingAdjustment:
            return "The saved adjustments are incomplete."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unknownOrientationAdjustment(let token):
            return """
                "\(token)" is not one of the eight orientation adjustments this version \
                models. It is reported rather than treated as "no correction", because a \
                value we could not read and a deliberate decision to leave the photograph \
                alone are different facts.
                """
        case .unsupportedSchemaVersion(let found, let supported):
            return """
                The adjustments declare schema version \(found); this version reads up to \
                \(supported). A newer record may contain adjustments that change the image, \
                so it is refused rather than partly applied.
                """
        case .missingAdjustment(let field, let schemaVersion):
            return """
                Schema version \(schemaVersion) requires "\(field)", and the record does not \
                contain it.
                """
        }
    }
}
