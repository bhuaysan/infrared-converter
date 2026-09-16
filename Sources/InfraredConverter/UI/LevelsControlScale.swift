import Foundation

/// How the workspace's black- and white-point sliders map to the levels
/// adjustment.
///
/// A UI policy and nothing else: it decides what the sliders offer and how a
/// slider position becomes a decision. It does no levels arithmetic — the
/// adjustment carries the pair and `LinearLevels` applies it.
///
/// ## Two ranges, deliberately different
///
/// ```text
/// slider range      −0.5 … +1.5     what a drag can reach
/// valid values      any finite pair whose interval is representable
///                   (UserLevelsAdjustment)
/// ```
///
/// The slider's range is a **control** range and not a validity rule. A saved
/// pair outside it — from a hand-edited sidecar, or a future recipe — is a
/// perfectly valid decision and is **never altered by being displayed**: the
/// slider pins to its end stop, the numeric label shows the real value, and
/// nothing is written until the user actually moves the slider.
///
/// Two stops of travel either side of the unit interval is chosen from what
/// the pipeline produces rather than from habit. Working coordinates run
/// outside `0…1` in both directions — black-subtracted noise straddles zero,
/// and a creative mix with negative coefficients or a white balance with a
/// large gain pushes highlights well above one — so a black point below `0`
/// and a white point above `1` are ordinary settings, not edge cases.
///
/// ## The pair is kept ordered
///
/// A slider cannot produce `black >= white`: each is limited by the other,
/// minus one step. That is a **control** courtesy, not the model's rule —
/// `UserLevelsAdjustment` refuses such a pair outright rather than repairing
/// it, and this type simply never asks it to.
///
/// Internal rather than private so the mapping is testable without SwiftUI.
enum LevelsControlScale {

    /// What either slider can reach.
    static let range: ClosedRange<Double> = -0.5...1.5

    /// The sliders move in thousandths.
    ///
    /// Expressed as steps per unit rather than as `0.001`, because a position
    /// is quantised by rounding `value × 1000` and dividing by `1000`:
    /// dividing an integer by an integer gives the closest `Double` to the
    /// intended decimal, where multiplying by `0.001` accumulates the binary
    /// error of `0.001` itself and would write `0.30000000000000004` to a
    /// sidecar.
    static let stepsPerUnit: Double = 1000

    /// The smallest interval the sliders will leave between the two points.
    ///
    /// One step. It exists so a drag cannot reach an equal pair, which the
    /// adjustment would refuse; it is not a claim about what a valid interval
    /// is.
    static var minimumSpan: Double { 1 / stepsPerUnit }

    /// Where the black-point thumb sits: the value itself, or the nearer end
    /// stop when the value lies beyond the slider.
    static func blackSliderPosition(for adjustment: UserLevelsAdjustment) -> Double {
        clampToRange(adjustment.blackPoint)
    }

    /// Where the white-point thumb sits, by the same rule.
    static func whiteSliderPosition(for adjustment: UserLevelsAdjustment) -> Double {
        clampToRange(adjustment.whitePoint)
    }

    /// Whether either point lies beyond what the sliders can show.
    static func isBeyondSliders(_ adjustment: UserLevelsAdjustment) -> Bool {
        !range.contains(adjustment.blackPoint) || !range.contains(adjustment.whitePoint)
    }

    /// The adjustment a black-point slider write asks for, or `nil` when it
    /// asks for no change.
    ///
    /// Two writes are not changes, for the reasons `ExposureControlScale`
    /// gives: an echo of the displayed position — which for a saved value
    /// beyond the slider is the end stop, and treating that as a decision
    /// would silently rewrite the saved levels merely because they were shown
    /// — and a write that quantises to the value already in force.
    ///
    /// The result is held one step below the current white point, so the pair
    /// stays ordered and the adjustment never has to refuse a slider.
    static func adjustment(
        forBlackSliderValue value: Double,
        current: UserLevelsAdjustment
    ) -> UserLevelsAdjustment? {
        guard value.isFinite, value != blackSliderPosition(for: current) else { return nil }
        let quantized = min(
            quantize(clampToRange(value)), current.whitePoint - minimumSpan
        )
        guard quantized != current.blackPoint else { return nil }
        return try? UserLevelsAdjustment(
            blackPoint: quantized, whitePoint: current.whitePoint
        )
    }

    /// The adjustment a white-point slider write asks for, or `nil` when it
    /// asks for no change. The mirror of the black-point rule.
    static func adjustment(
        forWhiteSliderValue value: Double,
        current: UserLevelsAdjustment
    ) -> UserLevelsAdjustment? {
        guard value.isFinite, value != whiteSliderPosition(for: current) else { return nil }
        let quantized = max(
            quantize(clampToRange(value)), current.blackPoint + minimumSpan
        )
        guard quantized != current.whitePoint else { return nil }
        return try? UserLevelsAdjustment(
            blackPoint: current.blackPoint, whitePoint: quantized
        )
    }

    private static func clampToRange(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func quantize(_ value: Double) -> Double {
        (value * stepsPerUnit).rounded() / stepsPerUnit
    }
}
