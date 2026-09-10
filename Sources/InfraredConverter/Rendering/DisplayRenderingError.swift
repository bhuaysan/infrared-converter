import Foundation

/// Failures the display rendering stage can report.
///
/// Deliberately separate from `RAWProcessingError` and `IRProcessingError`,
/// for the reason those two are separate from each other: this is a different
/// boundary. `RAWProcessingError` is the RAW pipeline refusing to interpret
/// sensor data. `IRProcessingError` belongs to a stage that remixes
/// coordinates in an established working space. Nothing here interprets sensor
/// data and nothing here is a creative colour decision — what can go wrong is
/// geometry, an exposure that cannot be applied, a value that is not a number,
/// and the platform declining to build an image.
///
/// The bare image types are publicly constructible, so every case below is a
/// real boundary rather than an internal assertion, and none of them is a
/// precondition failure: nothing in this stage traps on malformed input.
public enum DisplayRenderingError: Error, Equatable {
    /// Declared geometry and buffer length disagree, dimensions are
    /// non-positive, or the storage arithmetic would overflow.
    ///
    /// Covers the input image and the output buffer both. The output half
    /// cannot currently fire — a consistent input already proves
    /// `width × height × 3` is representable, and the output needs exactly the
    /// same product — but it is checked rather than assumed, and it reports
    /// this case rather than a second one that would mean the same thing.
    case invalidGeometry(reason: String)
    /// The requested exposure cannot be applied.
    ///
    /// Two causes share this case, because both mean exactly that and both are
    /// fully diagnosed by reporting the EV together with the scale it
    /// produced:
    ///
    /// ```text
    /// exposureEV is NaN or infinite      → scale is NaN or infinite
    /// exposureEV is finite but enormous  → 2^EV overflows to infinity
    /// ```
    case nonFiniteExposure(exposureEV: Double, scale: Double)
    /// A scene-linear input coordinate was NaN or infinite.
    ///
    /// No upstream stage in this project can produce either — the channel
    /// mixer refuses them on every path — so this means a hand-constructed or
    /// otherwise unvalidated image reached the renderer. Reported with its
    /// coordinate and channel rather than encoded into a plausible-looking
    /// pixel.
    case nonFiniteSceneLinearInput(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        value: Float
    )
    /// Exposure produced a value `Float32` cannot hold: a finite coordinate
    /// multiplied by a finite scale, overflowing on the single narrowing back
    /// to `Float`.
    ///
    /// Refused rather than left to the clip. A sample that overflowed to
    /// infinity would clip to `1` and reach the screen as an ordinary white
    /// pixel, indistinguishable from a legitimately bright one — which is
    /// exactly the kind of invented value this pipeline does not produce.
    case nonFiniteExposedValue(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        exposureEV: Double
    )
    /// CoreGraphics would not build an image from the rendered bytes.
    ///
    /// Reported rather than returned as `nil`, so a preview that cannot be
    /// shown is a failure with a reason rather than a blank pane. This belongs
    /// to the display stage even though it arises at the platform adapter: it
    /// is the same stage's job, and splitting it into its own error type would
    /// make a caller handle two error domains for one call.
    case displayImageUnavailable(reason: String)
}

extension DisplayRenderingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The image's dimensions are inconsistent and cannot be rendered."
        case .nonFiniteExposure:
            return "The requested exposure cannot be applied."
        case .nonFiniteSceneLinearInput:
            return "The image data contains a value that is not a finite number."
        case .nonFiniteExposedValue:
            return "This exposure produces values that are not finite numbers."
        case .displayImageUnavailable:
            return "The preview image could not be created."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .nonFiniteExposure(let exposureEV, let scale):
            return """
                Exposure \(exposureEV) EV gives a linear scale of \(scale), which is not a \
                finite number.
                """
        case .nonFiniteSceneLinearInput(let row, let column, let channel, let value):
            return """
                Scene-linear \(channel) coordinate \(value) at row \(row), column \(column) \
                is not finite.
                """
        case .nonFiniteExposedValue(let row, let column, let channel, let exposureEV):
            return """
                The \(channel) coordinate at row \(row), column \(column) is not a finite \
                Float32 after \(exposureEV) EV of exposure.
                """
        case .displayImageUnavailable(let reason):
            return reason
        }
    }
}
