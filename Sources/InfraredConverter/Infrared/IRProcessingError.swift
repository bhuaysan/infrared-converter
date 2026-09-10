import Foundation

/// Failures the infrared creative-processing stages can report.
///
/// Deliberately separate from `RAWProcessingError`, for the same reason that
/// type is separate from `RAWDecodingError`: these describe a different
/// boundary. `RAWProcessingError` is the RAW pipeline refusing to interpret
/// sensor data — black levels, CFA planes, white-balance gains, demosaicing,
/// the camera-to-working transform. The cases here belong to a stage that has
/// no sensor data left to interpret: it operates on coordinates in an already
/// established working colour space, and the only things it can refuse are a
/// mix authored for a different space and values that are not finite numbers.
///
/// Reporting a channel-mixer input as a "camera-native working-colour
/// conversion input" would name the wrong stage in a user-visible message and
/// send a reader looking at the wrong code, which is why
/// `nonFiniteWorkingColorInput` is not reused here.
///
/// One deliberate exception: constructing a `RAWColorMatrix3x3` reports
/// `RAWProcessingError.invalidColorMatrix3x3` even when the matrix is destined
/// for an `IRChannelMix`. The matrix is shared infrastructure and its
/// finiteness check belongs to neither stage, so it keeps one error rather
/// than gaining a duplicate per consumer.
public enum IRProcessingError: Error, Equatable {
    /// The input image's declared geometry does not add up (non-positive
    /// dimensions, a buffer of the wrong length, or arithmetic that would
    /// overflow). Bare image types are publicly constructible, so this is a
    /// real boundary rather than an internal assertion.
    case invalidGeometry(reason: String)
    /// The mix was authored for one working colour space and the image is in
    /// another, so its coefficients would mean something different applied
    /// here.
    ///
    /// Rejected rather than converted: converting between working spaces is a
    /// separate operation this stage does not perform, and reinterpreting the
    /// coefficients in place would silently change the rendering.
    ///
    /// Exactly one working colour space exists today, so this cannot currently
    /// be raised through any public construction. It stays because the
    /// invariant it protects is about the future: the first day a second space
    /// exists, a mix authored for the other one must not quietly run.
    case channelMixWorkingColorSpaceMismatch(
        image: RAWWorkingColorSpace,
        mix: RAWWorkingColorSpace
    )
    /// A working-space input coordinate was NaN or infinite. No upstream stage
    /// in this project can produce either, so this means a hand-constructed or
    /// otherwise unvalidated image reached the channel mixer; it is reported
    /// with its coordinate and channel rather than mixed and propagated.
    case nonFiniteChannelMixInput(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        value: Float
    )
    /// A channel-mix dot product did not produce a finite `Float32`.
    ///
    /// Three arithmetic outcomes reach this case, and they are not all
    /// "too large":
    ///
    /// ```text
    /// infinite Double accumulation   magnitude left Double's range
    /// NaN Double accumulation        e.g. (+inf) + (-inf) from opposing terms
    /// Float32 narrowing overflow     finite in Double, infinite as Float32
    /// ```
    ///
    /// The middle one is why the case is named for finiteness rather than for
    /// magnitude: a matrix with large coefficients of opposing sign, applied
    /// to large inputs, can produce a result that is not a number at all
    /// rather than one that is merely unrepresentable.
    ///
    /// Reported rather than clamped to `Float.greatestFiniteMagnitude` or
    /// replaced with zero: an image carrying a silently invented value is
    /// worse than a failed stage.
    case nonFiniteChannelMixResult(row: Int, column: Int, channel: RAWLinearRGBChannel)
}

extension IRProcessingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The image's dimensions are inconsistent and cannot be processed."
        case .channelMixWorkingColorSpaceMismatch:
            return "This channel mix was made for a different working colour space."
        case .nonFiniteChannelMixInput:
            return "The image data contains a value that is not a finite number."
        case .nonFiniteChannelMixResult:
            return "This channel mix produces values that are not finite numbers."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .channelMixWorkingColorSpaceMismatch(let image, let mix):
            return """
                The image is in \(image.diagnosticDescription) and the mix was authored for \
                \(mix.diagnosticDescription). Channel-mix coefficients are defined relative \
                to the RGB axes they were written for, and this stage does not convert \
                between working colour spaces.
                """
        case .nonFiniteChannelMixInput(let row, let column, let channel, let value):
            return """
                Working-space \(channel) coordinate \(value) at row \(row), column \(column) \
                is not finite.
                """
        case .nonFiniteChannelMixResult(let row, let column, let channel):
            return """
                The channel-mixed \(channel) coordinate at row \(row), column \(column) is \
                not a finite Float32.
                """
        }
    }
}
