import Foundation

/// How the workspace's contrast slider maps to the contrast adjustment.
///
/// A UI policy and nothing else: it decides what the slider offers and how a
/// slider position becomes a decision. It does no contrast arithmetic — the
/// adjustment carries an amount and `GlobalContrastCurve` applies it.
///
/// ## One range, unlike the exposure and levels controls
///
/// ```text
/// slider range      −100 … +100 display units
/// model range       −1 … +1 amount        (UserContrastAdjustment)
/// display = amount × 100
/// ```
///
/// The exposure slider reaches less than a record may hold, and the levels
/// sliders reach far less; this one reaches **exactly** the supported domain,
/// because that domain is the control's own definition rather than a
/// consequence of the arithmetic. There is therefore no pinned-thumb case and
/// no "beyond the slider" state — a value outside `−1 … +1` cannot exist in a
/// record at all, since `UserContrastAdjustment` refuses it.
///
/// What remains is the finer-value case, and it is handled the same way the
/// others are: a saved `0.355` is a perfectly valid decision, the slider shows
/// it where it falls, and **displaying it never rewrites it**. The step exists
/// to quantise what a drag produces, not to round what a sidecar holds.
///
/// ## The number shown is a control scale, not a percentage
///
/// `+35` means `amount = 0.35`, which means `k = 2^0.35`. It does not mean
/// 35 % of anything — not of slope, not of luminance, not of contrast in any
/// measurable sense. The label carries no `%` for exactly that reason.
///
/// Internal rather than private so the mapping is testable without SwiftUI.
enum ContrastControlScale {

    /// What the slider can reach, in display units.
    ///
    /// The whole supported domain, scaled by `unitsPerAmount`.
    static let range: ClosedRange<Double> = -100...100

    /// Display units per unit of amount.
    ///
    /// Expressed as a scale factor rather than as a step of `0.01`, because a
    /// position is quantised by rounding the display value to an integer and
    /// dividing by `100`: dividing an integer by an integer gives the closest
    /// `Double` to the intended decimal, where multiplying by `0.01`
    /// accumulates the binary error of `0.01` itself and would write
    /// `0.35000000000000003` to a sidecar.
    static let unitsPerAmount: Double = 100

    /// Where the slider's thumb sits for an adjustment.
    ///
    /// Always the value itself: the slider covers the whole supported domain,
    /// so there is nothing to pin. The clamp is kept as a total function
    /// rather than as a claim that it never binds.
    static func sliderPosition(for adjustment: UserContrastAdjustment) -> Double {
        clampToRange(adjustment.amount * unitsPerAmount)
    }

    /// The display value a control shows beside the slider: signed, integral.
    ///
    /// Rounded for **presentation only**. A saved `0.355` reads as `+36` and
    /// stays `0.355` in the record; nothing is written until the user moves
    /// the slider. That is the same rule the exposure and levels labels follow,
    /// and it is the reason this returns a string rather than a value anything
    /// could be tempted to store.
    static func displayValue(for adjustment: UserContrastAdjustment) -> String {
        // The negative-zero guard matters at the label, not in the model:
        // −0.0 × 100 formats as "-0" without it, and −0.0 is exactly the
        // neutral curve.
        String(format: "%+.0f", adjustment.isIdentity ? 0 : adjustment.amount * unitsPerAmount)
    }

    /// The adjustment a slider write asks for, or `nil` when it asks for no
    /// change.
    ///
    /// Two writes are not changes, for the reasons `ExposureControlScale`
    /// gives: an echo of the displayed position, and a write that quantises to
    /// the amount already in force.
    static func adjustment(
        forSliderValue value: Double,
        current: UserContrastAdjustment
    ) -> UserContrastAdjustment? {
        guard value.isFinite, value != sliderPosition(for: current) else { return nil }

        let quantized = clampToRange(value).rounded() / unitsPerAmount
        guard quantized != current.amount else { return nil }

        // Within the slider range, which is the supported range, so this
        // cannot refuse. `try?` rather than `try!`: a failure would be a
        // mistake in these constants, and doing nothing is the safe response.
        return try? UserContrastAdjustment(amount: quantized)
    }

    private static func clampToRange(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
