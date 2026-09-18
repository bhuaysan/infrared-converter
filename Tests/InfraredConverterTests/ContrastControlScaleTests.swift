import Foundation
import Testing
@testable import InfraredConverter

/// The contrast slider's mapping: what it offers, what a write means, and what
/// it must never do to a saved value.
@Suite("Contrast control scale")
struct ContrastControlScaleTests {

    static func contrast(_ amount: Double) throws -> UserContrastAdjustment {
        try UserContrastAdjustment(amount: amount)
    }

    // MARK: - The two ranges are the same range

    /// Unlike the exposure and levels controls, this slider reaches exactly
    /// the supported domain — because that domain is the control's own
    /// definition rather than a consequence of the arithmetic.
    @Test("The slider covers exactly the supported domain, scaled by 100")
    func theSliderCoversTheWholeDomain() {
        #expect(ContrastControlScale.range == -100...100)
        #expect(ContrastControlScale.unitsPerAmount == 100)
        #expect(
            ContrastControlScale.range.lowerBound / ContrastControlScale.unitsPerAmount
                == UserContrastAdjustment.supportedRange.lowerBound
        )
        #expect(
            ContrastControlScale.range.upperBound / ContrastControlScale.unitsPerAmount
                == UserContrastAdjustment.supportedRange.upperBound
        )
    }

    @Test(
        "The thumb sits at the amount times one hundred",
        arguments: [-1.0, -0.5, -0.01, 0.0, 0.01, 0.35, 0.5, 1.0]
    )
    func theThumbFollowsTheAmount(amount: Double) throws {
        let adjustment = try Self.contrast(amount)
        #expect(ContrastControlScale.sliderPosition(for: adjustment) == amount * 100)
    }

    // MARK: - A write becomes a decision

    @Test(
        "A slider write quantises to one display unit",
        arguments: [
            (35.0, 0.35), (35.4, 0.35), (35.6, 0.36), (-20.0, -0.2),
            // A tie rounds away from zero, which is symmetric about neutral:
            // -20.5 and +20.5 move the same distance in opposite directions.
            (-20.5, -0.21), (20.5, 0.21),
            (100.0, 1.0), (-100.0, -1.0), (0.4, 0.0),
        ]
    )
    func aWriteQuantisesToOneUnit(written: Double, expected: Double) throws {
        let requested = ContrastControlScale.adjustment(
            forSliderValue: written, current: .neutral
        )
        if expected == 0 {
            // Quantising to the value already in force asks for no change.
            #expect(requested == nil)
        } else {
            #expect(requested?.amount == expected)
        }
    }

    /// Dividing an integer by an integer, rather than multiplying by `0.01` —
    /// so what reaches a sidecar is the closest `Double` to the intended
    /// decimal.
    @Test("Quantised amounts are the closest double to the intended decimal")
    func quantisationIsExact() throws {
        let requested = try #require(
            ContrastControlScale.adjustment(forSliderValue: 35, current: .neutral)
        )
        #expect(requested.amount == 35.0 / 100.0)
        #expect(requested.amount == 0.35)
        // The error a `× 0.01` implementation would accumulate.
        #expect(requested.amount != 35 * 0.01 || 35 * 0.01 == 0.35)
    }

    @Test("A write that echoes the displayed position asks for no change")
    func anEchoIsNotADecision() throws {
        for amount in [-1.0, -0.35, 0.0, 0.35, 1.0] {
            let current = try Self.contrast(amount)
            let position = ContrastControlScale.sliderPosition(for: current)
            #expect(
                ContrastControlScale.adjustment(forSliderValue: position, current: current)
                    == nil
            )
        }
    }

    /// The rule that matters for a hand-edited sidecar: **displaying a finer
    /// value must never rewrite it**.
    @Test("A finer saved value is not rounded merely by being displayed")
    func displayingAFinerValueDoesNotRewriteIt() throws {
        let saved = try Self.contrast(0.355)
        let position = ContrastControlScale.sliderPosition(for: saved)
        #expect(position == 35.5)

        // The control echoing the position it was given asks for nothing.
        #expect(
            ContrastControlScale.adjustment(forSliderValue: position, current: saved) == nil
        )
        // And the value itself is untouched.
        #expect(saved.amount == 0.355)
        // Only an actual move produces a decision.
        #expect(
            ContrastControlScale.adjustment(forSliderValue: 36, current: saved)?.amount
                == 0.36
        )
    }

    @Test("A non-finite write asks for no change")
    func aNonFiniteWriteIsIgnored() {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(
                ContrastControlScale.adjustment(forSliderValue: value, current: .neutral)
                    == nil
            )
        }
    }

    /// The slider cannot leave the supported domain, so it can never make the
    /// adjustment refuse.
    @Test("No slider position produces a value the adjustment would refuse")
    func noPositionCanBeRefused() {
        for step in -200...200 {
            let written = Double(step) / 2
            guard let requested = ContrastControlScale.adjustment(
                forSliderValue: written, current: .neutral
            ) else { continue }
            #expect(UserContrastAdjustment.supportedRange.contains(requested.amount))
        }
        // Even a position outside the slider's own range is clamped to it
        // rather than refused — a control cannot ask for the impossible.
        #expect(
            ContrastControlScale.adjustment(forSliderValue: 500, current: .neutral)?.amount
                == 1
        )
        #expect(
            ContrastControlScale.adjustment(forSliderValue: -500, current: .neutral)?.amount
                == -1
        )
    }

    // MARK: - The label

    @Test("The display value is a signed integer with no percent sign")
    func theDisplayValueIsSignedAndUnitless() throws {
        #expect(ContrastControlScale.displayValue(for: .neutral) == "+0")
        #expect(ContrastControlScale.displayValue(for: try Self.contrast(0.35)) == "+35")
        #expect(ContrastControlScale.displayValue(for: try Self.contrast(-0.2)) == "-20")
        #expect(ContrastControlScale.displayValue(for: try Self.contrast(1)) == "+100")
        #expect(ContrastControlScale.displayValue(for: try Self.contrast(-1)) == "-100")
        // A negative zero reads as neutral, because it is.
        #expect(ContrastControlScale.displayValue(for: try Self.contrast(-0.0)) == "+0")

        for amount in [-1.0, -0.35, 0.0, 0.35, 1.0] {
            #expect(
                !ContrastControlScale.displayValue(for: try Self.contrast(amount))
                    .contains("%")
            )
        }
    }

    @Test("The label rounds for display and the model keeps the exact value")
    func theLabelRoundsButTheModelDoesNot() throws {
        let saved = try Self.contrast(0.355)
        #expect(ContrastControlScale.displayValue(for: saved) == "+36")
        #expect(saved.amount == 0.355)
    }
}
