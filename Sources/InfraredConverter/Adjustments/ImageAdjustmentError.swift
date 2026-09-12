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
    /// A persisted adjustment record carries a field its declared schema
    /// version does not have.
    ///
    /// The mirror image of `missingAdjustment`, and it exists for the same
    /// reason: an image-affecting field requires a schema version, so a record
    /// that declares version 1 and carries a version 2 field is not a version
    /// 1 record. Reading around the field would render a different photograph
    /// from the one the user saved and then write the record back without it.
    case unexpectedAdjustment(field: String, schemaVersion: Int)
    /// A persisted channel mix names a kind this version does not model — a
    /// typo, a corrupted file, or a token a newer version writes.
    ///
    /// Reported verbatim, and never read as `.identity`: rendering the
    /// photograph with no creative remapping would look exactly like success
    /// while discarding the rendering the user chose.
    case unknownChannelMixKind(token: String)
    /// A persisted channel mix is missing a field its kind requires — the
    /// `kind` token itself, or the coefficients an explicit matrix is.
    case missingChannelMixField(field: String)
    /// A persisted channel mix carries a field its kind does not have — a
    /// built-in (`identity`, `redBlueSwap`) carrying `matrix` coefficients.
    ///
    /// The mirror image of `missingChannelMixField`. A built-in's matrix is
    /// derived from its token, so a record carrying one says two things about
    /// the same nine numbers. Ignoring the coefficients would silently discard
    /// part of what was written; trusting them would render something the
    /// token does not name. Neither is a reading, so the record is refused.
    case unexpectedChannelMixField(field: String, kind: String)
    /// A persisted explicit channel mix does not carry nine coefficients.
    ///
    /// The shape is part of the matrix: a 3×3 map is nine numbers in row-major
    /// order, and a record with eight or ten of them describes no transform at
    /// all.
    case malformedChannelMixMatrix(coefficientCount: Int, expected: Int)
    /// A persisted channel-mix coefficient is not a finite number.
    ///
    /// The same contract `RAWColorMatrix3x3` enforces at construction,
    /// restated at the persistence boundary so the refusal names the sidecar
    /// rather than a processing stage the user never chose to run.
    case nonFiniteChannelMixCoefficient(index: Int, value: Double)
    /// An exposure compensation is NaN or an infinity.
    ///
    /// Never read as `0 EV`: a value we could not use and a deliberate
    /// decision to leave the exposure alone are different facts.
    case nonFiniteExposureAdjustment(ev: Double)
    /// An exposure compensation is finite and outside the range a record may
    /// hold.
    ///
    /// Refused rather than clamped. A clamped exposure renders a different
    /// photograph from the one the record describes, and nothing on screen
    /// would say so.
    case exposureAdjustmentOutOfRange(ev: Double, supported: ClosedRange<Double>)
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
        case .unexpectedAdjustment:
            return "The saved adjustments were written by a different version of this app."
        case .unknownChannelMixKind:
            return "The saved channel mix could not be understood."
        case .missingChannelMixField:
            return "The saved channel mix is incomplete."
        case .unexpectedChannelMixField:
            return "The saved channel mix contradicts itself."
        case .malformedChannelMixMatrix:
            return "The saved channel-mix matrix is not a 3×3 matrix."
        case .nonFiniteChannelMixCoefficient:
            return "The saved channel-mix matrix contains a value that is not a finite number."
        case .nonFiniteExposureAdjustment:
            return "The saved exposure is not a finite number."
        case .exposureAdjustmentOutOfRange:
            return "The saved exposure is outside the supported range."
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
        case .unexpectedAdjustment(let field, let schemaVersion):
            return """
                Schema version \(schemaVersion) has no "\(field)", and the record contains \
                one. A setting that changes the image requires its own schema version, so a \
                record carrying this field is not a version \(schemaVersion) record and is \
                refused rather than read around.
                """
        case .unknownChannelMixKind(let token):
            return """
                "\(token)" is not one of the channel mixes this version models. It is \
                reported rather than treated as "no remapping", because a value we could not \
                read and a deliberate decision to leave the channels alone are different \
                facts.
                """
        case .missingChannelMixField(let field):
            return """
                The saved channel mix does not contain "\(field)", which its kind requires.
                """
        case .unexpectedChannelMixField(let field, let kind):
            return """
                The saved channel mix is "\(kind)", which is defined by its name alone, and \
                it also contains "\(field)". The record says two different things about one \
                matrix, so it is refused rather than read with part of it ignored.
                """
        case .malformedChannelMixMatrix(let count, let expected):
            return """
                A channel-mix matrix is \(expected) coefficients in row-major order, and the \
                record contains \(count).
                """
        case .nonFiniteChannelMixCoefficient(let index, let value):
            return """
                Channel-mix coefficient \(index) is \(value), which is not a finite number \
                and cannot describe a transform.
                """
        case .nonFiniteExposureAdjustment(let ev):
            return """
                The exposure is \(ev) EV, which is not a finite number. It is reported rather \
                than treated as 0 EV, because a value we could not use and a deliberate \
                decision to leave the exposure alone are different facts.
                """
        case .exposureAdjustmentOutOfRange(let ev, let supported):
            return """
                The exposure is \(ev) EV; a saved exposure must lie between \
                \(supported.lowerBound) and \(supported.upperBound) EV. It is refused rather \
                than clamped, because a clamped exposure would render a different photograph.
                """
        }
    }
}
