import Foundation

/// Failures the preview-reduction stage can report.
///
/// Separate from `RAWProcessingError`, `IRProcessingError`, `OrientationError`
/// and `DisplayRenderingError` for the same reason those are separate from
/// each other: this stage refuses a different kind of thing. It has no sensor
/// data to interpret, no colour space to reconcile and no display to encode
/// for. It resamples scene-linear values, and the only things it can refuse
/// are geometry it cannot make sense of, a size policy that has no answer, and
/// values that are not finite numbers.
///
/// Cancellation is deliberately not a case here. A superseded reduction throws
/// `CancellationError`, as every other cancellable stage in this project does:
/// "nobody wants this any more" is not a processing failure and must never be
/// shown as one.
public enum PreviewReductionError: Error, Equatable {
    /// The input image's declared geometry does not add up — non-positive
    /// dimensions, a buffer of the wrong length, or arithmetic that would
    /// overflow.
    case invalidGeometry(reason: String)
    /// The policy could not name a preview size for this image. Either the
    /// source dimensions or the limit was non-positive.
    case unusablePreviewSize(
        sourceWidth: Int, sourceHeight: Int, maximumLongestEdge: Int
    )
    /// A source coordinate was NaN or infinite. Reported with its coordinate
    /// and channel rather than averaged into a neighbourhood, where a single
    /// NaN would silently poison every destination pixel that overlaps it.
    case nonFiniteInput(
        row: Int, column: Int, channel: RAWLinearRGBChannel, value: Float
    )
    /// An area-weighted mean did not produce a finite `Float32`. Reported
    /// rather than clamped: an image carrying an invented value is worse than
    /// a failed stage.
    case nonFiniteResult(row: Int, column: Int, channel: RAWLinearRGBChannel)
}

// Two cases used to live here and no longer can be reached, so they no longer
// exist: `channelMixAlreadyApplied`, for a second mix on an already-mixed
// preview, and `channelMixNotApplied`, for orienting a preview the creative
// stage had not run on. Both were guards on one reduced image type that
// represented the pre-mix and post-mix states at once. There are now two
// types, so neither call compiles, and an error case describing an impossible
// state would be a claim about nothing. See
// `docs/decisions/0016-interactive-channel-mixer.md`.
//
// `IRProcessingError.channelMixWorkingColorSpaceMismatch` is deliberately
// *not* treated the same way: it is unreachable today because one working
// space exists, and it becomes reachable the day a second one does.

extension PreviewReductionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The image's dimensions are inconsistent and cannot be processed."
        case .unusablePreviewSize:
            return "No preview size could be chosen for this image."
        case .nonFiniteInput:
            return "The image data contains a value that is not a finite number."
        case .nonFiniteResult:
            return "Reducing this image produces values that are not finite numbers."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .unusablePreviewSize(let width, let height, let limit):
            return """
                A \(width)x\(height) image and a longest-edge limit of \(limit) do not \
                describe a preview: every dimension and the limit must be positive.
                """
        case .nonFiniteInput(let row, let column, let channel, let value):
            return """
                Scene-linear \(channel) coordinate \(value) at row \(row), column \(column) \
                is not finite.
                """
        case .nonFiniteResult(let row, let column, let channel):
            return """
                The reduced \(channel) coordinate at row \(row), column \(column) is not a \
                finite Float32.
                """
        }
    }
}
