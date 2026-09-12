import Foundation

/// How the workspace's exposure slider maps to the exposure adjustment.
///
/// A UI policy and nothing else: it decides what the slider offers and how a
/// slider position becomes a decision. It does no exposure arithmetic — the
/// adjustment carries an EV and the display renderer applies it.
///
/// ## Two ranges, deliberately different
///
/// ```text
/// slider range      −4 … +4 EV     what a drag can reach
/// supported range   −10 … +10 EV   what a record may hold (UserExposureAdjustment)
/// ```
///
/// Eight stops of travel across a compact control keeps a twentieth of a stop
/// a usable fraction of a point. A saved value outside it — from a hand-edited
/// sidecar, or a future recipe — is still a valid decision and is **never
/// altered by being displayed**: the slider pins to its end stop, the numeric
/// label shows the real value, and nothing is written until the user actually
/// moves the slider.
///
/// Internal rather than private so the mapping is testable without SwiftUI.
enum ExposureControlScale {

    /// What the slider can reach.
    static let range: ClosedRange<Double> = -4...4

    /// The slider moves in twentieths of a stop.
    ///
    /// Expressed as steps per stop rather than as `0.05`, because a position is
    /// quantised by rounding `ev × 20` and dividing by `20`: dividing an
    /// integer by an integer gives the closest `Double` to the intended
    /// decimal, where multiplying by `0.05` accumulates the binary error of
    /// `0.05` itself and would write `0.30000000000000004` to a sidecar.
    static let stepsPerStop: Double = 20

    /// Where the slider's thumb sits for an adjustment: the value itself, or
    /// the nearer end stop when the value lies beyond the slider.
    static func sliderPosition(for adjustment: UserExposureAdjustment) -> Double {
        min(max(adjustment.ev, range.lowerBound), range.upperBound)
    }

    /// Whether the adjustment lies beyond what the slider can show.
    static func isBeyondSlider(_ adjustment: UserExposureAdjustment) -> Bool {
        !range.contains(adjustment.ev)
    }

    /// The adjustment a slider write asks for, or `nil` when it asks for no
    /// change.
    ///
    /// Two writes are not changes:
    ///
    /// - **An echo of the displayed position.** A slider may write back the
    ///   value it was given. For a saved `+6 EV` that value is the `+4` end
    ///   stop, and treating the echo as a decision would silently rewrite the
    ///   saved exposure merely because it was displayed.
    /// - **A write that quantises to the current value.** Nothing to render.
    ///
    /// Anything else is quantised to the slider's step and returned.
    static func adjustment(
        forSliderValue value: Double,
        current: UserExposureAdjustment
    ) -> UserExposureAdjustment? {
        guard value.isFinite, value != sliderPosition(for: current) else { return nil }

        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let quantized = (clamped * stepsPerStop).rounded() / stepsPerStop
        guard quantized != current.ev else { return nil }

        // Within the slider range, which lies inside the supported range, so
        // this cannot refuse. `try?` rather than `try!`: a failure would be a
        // mistake in these constants, and doing nothing is the safe response.
        return try? UserExposureAdjustment(ev: quantized)
    }
}
