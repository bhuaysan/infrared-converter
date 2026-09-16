import Foundation

/// Failures the display rendering stage can report.
///
/// Deliberately separate from `RAWProcessingError` and `IRProcessingError`,
/// for the reason those two are separate from each other: this is a different
/// boundary. `RAWProcessingError` is the RAW pipeline refusing to interpret
/// sensor data. `IRProcessingError` belongs to a stage that remixes
/// coordinates in an established working space. Nothing here interprets sensor
/// data and nothing here is a creative colour decision — what can go wrong is
/// geometry, a value that is not a number, and the platform declining to build
/// an image.
///
/// ## Two cases left with the exposure
///
/// `nonFiniteExposure` and `nonFiniteExposedValue` were here while this stage
/// applied exposure itself. It no longer does: `SceneLinearExposer` runs
/// upstream and reports both through `SceneLinearExposureError`, and
/// `LinearLevelsApplier` reports its own through `LinearLevelsError`. Keeping
/// unreachable cases would have described a stage that no longer exists. See
/// `docs/decisions/0026-linear-levels.md`.
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
    /// A linear-light input coordinate was NaN or infinite.
    ///
    /// No upstream stage in this project can produce either — the channel
    /// mixer, the exposer and the levels stage each refuse them on every path
    /// — so this means a hand-constructed or otherwise unvalidated image
    /// reached the renderer. Reported with its coordinate and channel rather
    /// than encoded into a plausible-looking pixel.
    ///
    /// Named for what it actually receives. The input to this stage has had
    /// Levels applied, so it is linear-light but no longer scene-linear, and a
    /// case called `nonFiniteSceneLinearInput` would say otherwise.
    case nonFiniteLinearInput(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        value: Float
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
        case .nonFiniteLinearInput:
            return "The image data contains a value that is not a finite number."
        case .displayImageUnavailable:
            return "The preview image could not be created."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .nonFiniteLinearInput(let row, let column, let channel, let value):
            return """
                Linear \(channel) coordinate \(value) at row \(row), column \(column) \
                is not finite.
                """
        case .displayImageUnavailable(let reason):
            return reason
        }
    }
}
