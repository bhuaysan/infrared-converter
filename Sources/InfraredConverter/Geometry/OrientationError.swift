import Foundation

/// Failures the orientation stage, and the layer that chooses an orientation
/// for it, can report.
///
/// Deliberately separate from `RAWProcessingError`, `IRProcessingError` and
/// `DisplayRenderingError`, for the reason each of those is separate from the
/// others: this is a different boundary. Nothing here interprets sensor data,
/// nothing here is a colour decision, and nothing here encodes for a display.
/// What can go wrong is geometry — and a file asking for an arrangement this
/// application does not model.
///
/// There is deliberately **no** case for a value problem. Orientation moves
/// whole pixels and never reads one as a number, so a NaN, an infinity, a
/// negative coordinate and a coordinate above `1` all pass through untouched
/// and unremarked. Refusing them here would be a claim this stage has no
/// standing to make; `DisplayPreviewRenderer` is where a non-finite coordinate
/// meets a stage that genuinely cannot proceed.
public enum OrientationError: Error, Equatable {
    /// The input image's declared geometry does not add up: non-positive
    /// dimensions, a buffer of the wrong length, or arithmetic that would
    /// overflow.
    ///
    /// Bare image types are publicly constructible, so this is a real boundary
    /// rather than an internal assertion.
    case invalidGeometry(reason: String)
    /// The oriented geometry cannot be represented or allocated.
    ///
    /// Orientation exchanges width and height and never changes the pixel
    /// count, so a consistent input already proves the output's element count
    /// is representable, and this cannot currently fire. It is checked rather
    /// than assumed, and reported as its own case rather than folded into
    /// `invalidGeometry`, because the two would send a reader to different
    /// code.
    case unrepresentableOrientedGeometry(reason: String)
    /// The decoder reported an orientation value this application does not
    /// model, and the caller required one.
    ///
    /// The explicit alternative to the silent substitution this project does
    /// not make: an unmodelled `flip` is **not** read as upright. The value is
    /// reported verbatim so the file can be investigated rather than guessed
    /// at.
    ///
    /// See `RAWImageOrientation.init?(decoderFlip:)` for how a value outside
    /// `0...7` reaches the application at all.
    case unsupportedDecoderOrientation(flip: Int)
}

extension OrientationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The image's dimensions are inconsistent and cannot be oriented."
        case .unrepresentableOrientedGeometry:
            return "The oriented image's dimensions cannot be represented."
        case .unsupportedDecoderOrientation:
            return "The file records an orientation this application does not recognise."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .unrepresentableOrientedGeometry(let reason):
            return reason
        case .unsupportedDecoderOrientation(let flip):
            return """
                The decoder reported orientation code \(flip), which is not one of the eight \
                standard orientations. It is reported rather than treated as upright, because \
                an unreadable orientation and a recorded upright orientation are different \
                facts.
                """
        }
    }
}
