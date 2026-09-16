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
///
/// ## What is deliberately not here any more
///
/// The **record's** own shape — which schema version it declares, and which
/// fields that version has — moved to `PhotographProcessingStateError` when the
/// sidecar stopped being an adjustments-only file. Everything below is one
/// adjustment refusing one value; nothing below knows what a schema version is
/// except as context in a message. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`.
public enum ImageAdjustmentError: Error, Equatable {
    /// A persisted orientation adjustment names a state this version does not
    /// model — a typo, a corrupted file, or a token a newer version writes.
    ///
    /// The token is reported verbatim so the state can be investigated rather
    /// than guessed at.
    case unknownOrientationAdjustment(token: String)
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
    /// A persisted white balance names a kind this version does not model — a
    /// typo, a corrupted file, or a token a newer version writes.
    ///
    /// Reported verbatim, and never read as the default centred patch:
    /// balancing from the middle of the frame when the user chose a grey card
    /// in the corner would look exactly like success.
    case unknownWhiteBalanceKind(token: String)
    /// A persisted white balance is missing a field its kind requires — the
    /// `kind` token itself, or the `region` a picked patch is.
    case missingWhiteBalanceField(field: String)
    /// A persisted white balance carries a field its kind does not have — the
    /// default patch carrying a `region`.
    ///
    /// The mirror image of `missingWhiteBalanceField`, and the same rule that
    /// refuses a built-in channel mix carrying a matrix: the record says two
    /// different things about which samples were measured, and there is no
    /// reading of it that is not a guess.
    case unexpectedWhiteBalanceField(field: String, kind: String)
    /// A persisted neutral patch is missing one of its four coordinates.
    ///
    /// All four are required: the rectangle *is* the four numbers, and there
    /// is no value a missing origin or extent could be defaulted to.
    case missingNeutralPatchField(field: String)
    /// A persisted neutral-patch coordinate is NaN or an infinity.
    case nonFiniteNeutralPatchCoordinate(field: String, value: Double)
    /// A persisted neutral patch has a width or height that is zero or
    /// negative.
    ///
    /// An empty selection measures nothing, and a negative one is not a
    /// rectangle at all.
    case emptyNeutralPatch(width: Double, height: Double)
    /// A persisted neutral patch starts before the active area or ends past
    /// it.
    ///
    /// Refused rather than clamped. A clamped patch measures different samples
    /// from the ones the record names, which would silently change the white
    /// balance of the photograph.
    case neutralPatchOutsideActiveArea(
        originX: Double, originY: Double, width: Double, height: Double
    )
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
    /// A persisted levels adjustment is missing `blackPoint` or `whitePoint`.
    ///
    /// Both are required. The pair *is* the interval, and there is no value a
    /// missing endpoint could be defaulted to: neutral would silently discard
    /// a tone decision the user made, and any other number would be invented.
    case missingLevelsField(field: String)
    /// A persisted black or white point is NaN or an infinity.
    ///
    /// Never read as neutral: a value we could not use and a deliberate
    /// decision to leave the levels alone are different facts.
    case nonFiniteLevelsBound(field: String, value: Double)
    /// A persisted levels adjustment has a black point that is not below its
    /// white point.
    ///
    /// Refused rather than reordered. Swapping the two would invert the
    /// photograph, which nobody asked for; treating them as equal would divide
    /// by zero. Both are decisions, and neither is one this record makes on a
    /// user's behalf.
    case levelsNotOrdered(blackPoint: Double, whitePoint: Double)
    /// A persisted levels interval is ordered and finite, but its arithmetic is
    /// not representable.
    ///
    /// Two endpoints about `1e308` apart overflow the subtraction, giving a
    /// scale of exactly `0` that would render every pixel black while every
    /// number stayed finite; two endpoints closer than about `1e-308` overflow
    /// the reciprocal, turning every finite input into an infinity. The span
    /// and the scale are both reported, so which of the two happened is
    /// readable rather than guessed at.
    case levelsSpanNotRepresentable(
        blackPoint: Double, whitePoint: Double, span: Double, scale: Double
    )
}

extension ImageAdjustmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownOrientationAdjustment:
            return "The saved orientation adjustment could not be understood."
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
        case .unknownWhiteBalanceKind:
            return "The saved white balance could not be understood."
        case .missingWhiteBalanceField:
            return "The saved white balance is incomplete."
        case .unexpectedWhiteBalanceField:
            return "The saved white balance contradicts itself."
        case .missingNeutralPatchField:
            return "The saved neutral patch is incomplete."
        case .nonFiniteNeutralPatchCoordinate:
            return "The saved neutral patch contains a value that is not a finite number."
        case .emptyNeutralPatch:
            return "The saved neutral patch has no area."
        case .neutralPatchOutsideActiveArea:
            return "The saved neutral patch lies outside the image."
        case .nonFiniteExposureAdjustment:
            return "The saved exposure is not a finite number."
        case .exposureAdjustmentOutOfRange:
            return "The saved exposure is outside the supported range."
        case .missingLevelsField:
            return "The saved black and white points are incomplete."
        case .nonFiniteLevelsBound:
            return "The saved black or white point is not a finite number."
        case .levelsNotOrdered:
            return "The saved black point is not below the saved white point."
        case .levelsSpanNotRepresentable:
            return "The saved black and white points are too far apart, or too close together."
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
        case .unknownWhiteBalanceKind(let token):
            return """
                "\(token)" is not one of the white balances this version models. It is \
                reported rather than treated as the default centred patch, because a value \
                we could not read and a deliberate decision to measure the middle of the \
                frame are different facts.
                """
        case .missingWhiteBalanceField(let field):
            return """
                The saved white balance does not contain "\(field)", which its kind requires.
                """
        case .unexpectedWhiteBalanceField(let field, let kind):
            return """
                The saved white balance is "\(kind)", which is defined by its name alone, and \
                it also contains "\(field)". The record says two different things about which \
                samples were measured, so it is refused rather than read with part of it \
                ignored.
                """
        case .missingNeutralPatchField(let field):
            return """
                A neutral patch is four fractions of the active image area, and the record \
                does not contain "\(field)".
                """
        case .nonFiniteNeutralPatchCoordinate(let field, let value):
            return """
                The neutral patch's \(field) is \(value), which is not a finite number and \
                cannot describe a rectangle.
                """
        case .emptyNeutralPatch(let width, let height):
            return """
                The neutral patch measures \(width) × \(height) of the active area. Both \
                extents must be greater than zero; an empty selection measures no samples.
                """
        case .neutralPatchOutsideActiveArea(let originX, let originY, let width, let height):
            return """
                The neutral patch at \(originX), \(originY) measuring \(width) × \(height) is \
                not inside the active image area, whose coordinates run from 0 to 1. It is \
                refused rather than clamped, because a clamped patch measures different \
                samples from the ones the record names.
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
        case .missingLevelsField(let field):
            return """
                A levels adjustment is a black point and a white point together, and the \
                record does not contain "\(field)". It is refused rather than defaulted, \
                because neutral levels and a levels decision we could not read are different \
                facts.
                """
        case .nonFiniteLevelsBound(let field, let value):
            return """
                The \(field) is \(value), which is not a finite number and cannot bound an \
                interval.
                """
        case .levelsNotOrdered(let blackPoint, let whitePoint):
            return """
                The black point is \(blackPoint) and the white point is \(whitePoint); the \
                black point must be strictly below the white point. The two are refused \
                rather than swapped, because exchanging them inverts the photograph, and \
                that is a decision nobody made.
                """
        case .levelsSpanNotRepresentable(
            let blackPoint, let whitePoint, let span, let scale
        ):
            return """
                The black point \(blackPoint) and the white point \(whitePoint) are ordered \
                and finite, but the interval between them measures \(span) and scales by \
                \(scale). One of those is not a finite number, so the levels cannot be \
                applied to any pixel.
                """
        }
    }
}
