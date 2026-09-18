import Foundation
import Testing
@testable import InfraredConverter

/// The contrast curve's mathematical contract.
///
/// Every expected value here is computed from the **specification**, written
/// out in `reference` below, and never by calling `GlobalContrastCurve`
/// itself. A test that asked the implementation what it does would pass for
/// any implementation.
@Suite("Global contrast curve")
struct GlobalContrastCurveTests {

    /// The curve, written from the specification:
    ///
    /// ```text
    /// k = 2^amount
    /// f(x) = x                          x <= 0 or x >= 1
    /// f(x) = x^k / (x^k + (1-x)^k)      otherwise
    /// ```
    static func reference(_ value: Float, amount: Double) -> Float {
        guard value > 0, value < 1 else { return value }
        let k = exp2(amount)
        let x = Double(value)
        let a = pow(x, k)
        let b = pow(1 - x, k)
        return Float(a / (a + b))
    }

    /// Amounts spanning the supported domain, including both endpoints.
    static let amounts: [Double] = [-1, -0.75, -0.5, -0.25, 0.25, 0.5, 0.75, 1]

    /// Values that exercise every branch: below zero, the endpoints, inside,
    /// above one, and the awkward Float32 cases.
    static let probes: [Float] = [
        -1e30, -5, -0.25, -0.001, -0.0, 0, .leastNonzeroMagnitude,
        .leastNormalMagnitude, 1e-10, 0.001, 0.1, 0.25, 0.5, 0.75, 0.9, 0.999,
        Float(1).nextDown, 1, Float(1).nextUp, 1.0001, 1.4, 5, 1e30,
        .greatestFiniteMagnitude,
    ]

    // MARK: - Neutral is the identity

    /// Not "close to" the identity: the same bit pattern, for every probe.
    @Test("Neutral contrast returns every value's exact bit pattern")
    func neutralIsBitExactIdentity() {
        let curve = GlobalContrastCurve.neutral
        #expect(curve.isIdentity)
        #expect(curve.exponent == 1)

        for value in Self.probes {
            let result = curve.applied(to: value)
            #expect(
                result.bitPattern == value.bitPattern,
                "neutral changed \(value) to \(result)"
            )
        }
    }

    /// Including the sign of zero, which an arithmetic identity path would
    /// quietly lose: `(−0.0)^1 / ((−0.0)^1 + 1^1)` is `+0.0`.
    @Test("Neutral contrast preserves a negative zero's sign")
    func neutralPreservesNegativeZero() {
        let result = GlobalContrastCurve.neutral.applied(to: -0.0)
        #expect(result.sign == .minus)
        #expect(result.bitPattern == Float(-0.0).bitPattern)
    }

    @Test("A neutral curve built from the adjustment is the same curve")
    func theAdjustmentBuildsTheNeutralCurve() {
        #expect(GlobalContrastCurve(UserContrastAdjustment.neutral) == .neutral)
    }

    // MARK: - The three fixed points

    @Test(
        "Zero, one half and one are fixed for every contrast amount",
        arguments: [-1.0, -0.5, 0.0, 0.5, 1.0]
    )
    func theFixedPointsHold(amount: Double) {
        let curve = GlobalContrastCurve(amount: amount)
        #expect(curve.applied(to: 0).bitPattern == Float(0).bitPattern)
        #expect(curve.applied(to: 0.5) == 0.5)
        #expect(curve.applied(to: 1) == 1)
    }

    /// `0.5` is exact rather than approximate, and that is not luck: `x` and
    /// `1 − x` are the same number there, so `a / (a + b)` is `a / 2a`.
    @Test(
        "The midpoint is exactly one half, not approximately",
        arguments: [-1.0, -0.9, -0.5, -0.1, 0.1, 0.5, 0.9, 1.0]
    )
    func theMidpointIsExact(amount: Double) {
        let result = GlobalContrastCurve(amount: amount).applied(to: 0.5)
        #expect(result == 0.5)
        #expect(result.bitPattern == Float(0.5).bitPattern)
    }

    // MARK: - Direction

    @Test(
        "Positive contrast pushes shadows down and highlights up",
        arguments: [0.05, 0.25, 0.5, 0.75, 1.0]
    )
    func positiveContrastSeparates(amount: Double) {
        let curve = GlobalContrastCurve(amount: amount)
        #expect(curve.applied(to: 0.25) < 0.25)
        #expect(curve.applied(to: 0.75) > 0.75)
        #expect(curve.applied(to: 0.1) < 0.1)
        #expect(curve.applied(to: 0.9) > 0.9)
    }

    @Test(
        "Negative contrast pulls both toward the midpoint",
        arguments: [-0.05, -0.25, -0.5, -0.75, -1.0]
    )
    func negativeContrastConverges(amount: Double) {
        let curve = GlobalContrastCurve(amount: amount)
        #expect(curve.applied(to: 0.25) > 0.25)
        #expect(curve.applied(to: 0.75) < 0.75)
        #expect(curve.applied(to: 0.1) > 0.1)
        #expect(curve.applied(to: 0.9) < 0.9)
        // Toward, not past: the midpoint is a fixed point, so nothing crosses.
        #expect(curve.applied(to: 0.25) < 0.5)
        #expect(curve.applied(to: 0.75) > 0.5)
    }

    // MARK: - Symmetry

    /// `f(1 − x) = 1 − f(x)`, subject only to floating-point rounding.
    @Test("The curve is symmetric about the midpoint")
    func theCurveIsSymmetric() {
        let inputs: [Float] = [
            0.001, 0.01, 0.05, 0.1, 0.2, 0.25, 0.3, 0.4, 0.45, 0.49, 0.5,
        ]
        for amount in Self.amounts {
            let curve = GlobalContrastCurve(amount: amount)
            for x in inputs {
                let mirrored = curve.applied(to: 1 - x)
                let expected = 1 - curve.applied(to: x)
                #expect(
                    abs(Double(mirrored) - Double(expected)) < 1e-6,
                    "f(1-\(x)) = \(mirrored), 1-f(\(x)) = \(expected) at \(amount)"
                )
            }
        }
    }

    // MARK: - Monotonicity

    /// A dense deterministic sweep, not three hand-picked samples: a curve
    /// that folded over, flattened or inverted anywhere inside the interval
    /// would be caught here and nowhere else.
    @Test(
        "The curve is non-decreasing across a dense sweep of the unit interval",
        arguments: [-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0]
    )
    func theCurveIsMonotone(amount: Double) {
        let curve = GlobalContrastCurve(amount: amount)
        let steps = 20_000

        var previousInput = Float(0)
        var previous = curve.applied(to: previousInput)
        var strictIncreases = 0

        for step in 1...steps {
            let x = Float(Double(step) / Double(steps))
            let y = curve.applied(to: x)

            #expect(y >= previous, "f(\(x)) = \(y) < f(\(previousInput)) = \(previous)")
            if y > previous { strictIncreases += 1 }
            // The curve never leaves the unit interval for an input inside it.
            #expect(y >= 0 && y <= 1, "f(\(x)) = \(y) left 0...1")

            previousInput = x
            previous = y
        }

        // Strictly increasing wherever Float32 resolution permits. At ±1 the
        // curve is shallow near the endpoints, so a handful of steps can land
        // on the same Float; the overwhelming majority must still separate.
        #expect(
            strictIncreases > steps * 9 / 10,
            "only \(strictIncreases) of \(steps) steps increased at \(amount)"
        )
    }

    @Test("A steeper amount is steeper everywhere off the midpoint")
    func largerAmountsAreStronger() {
        let gentle = GlobalContrastCurve(amount: 0.25)
        let strong = GlobalContrastCurve(amount: 1)
        for x in [Float(0.05), 0.2, 0.35, 0.45] {
            #expect(strong.applied(to: x) < gentle.applied(to: x))
            #expect(strong.applied(to: 1 - x) > gentle.applied(to: 1 - x))
        }
    }

    // MARK: - The extended domain

    @Test("Values at or below zero and at or above one pass through untouched")
    func theExtendedDomainPassesThrough() {
        let outside: [Float] = [
            -1e30, -5, -1.4, -0.25, -0.001, -0.0, 0, 1, 1.0001, 1.4, 5, 1e30,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        ]
        for amount in Self.amounts {
            let curve = GlobalContrastCurve(amount: amount)
            for value in outside {
                let result = curve.applied(to: value)
                #expect(
                    result.bitPattern == value.bitPattern,
                    "\(value) became \(result) at amount \(amount)"
                )
            }
        }
    }

    /// The point of the previous test, said as the thing that would break: two
    /// out-of-range values that a clamp would merge stay distinguishable.
    @Test("Out-of-range values stay distinct rather than collapsing")
    func outOfRangeValuesStayDistinct() {
        for amount in Self.amounts {
            let curve = GlobalContrastCurve(amount: amount)
            #expect(curve.applied(to: -0.25) != curve.applied(to: -0.5))
            #expect(curve.applied(to: 1.4) != curve.applied(to: 1.7))
            #expect(curve.applied(to: -0.25) == -0.25)
            #expect(curve.applied(to: 1.7) == 1.7)
        }
    }

    @Test("No extrapolation is invented past the endpoints")
    func nothingIsExtrapolated() {
        let curve = GlobalContrastCurve(amount: 1)
        // A sign-preserving power, an `abs`, or a reflection would each give a
        // different number here. Passing through gives exactly the input.
        #expect(curve.applied(to: -0.25) == -0.25)
        #expect(curve.applied(to: -0.25) != 0.25)
        #expect(curve.applied(to: -0.25) != -Self.reference(0.25, amount: 1))
        #expect(curve.applied(to: 1.5) == 1.5)
    }

    // MARK: - Against the specification

    @Test("Every value matches the specification, computed independently")
    func theCurveMatchesTheSpecification() {
        for amount in Self.amounts + [0] {
            let curve = GlobalContrastCurve(amount: amount)
            for value in Self.probes {
                let expected = Self.reference(value, amount: amount)
                let actual = curve.applied(to: value)
                if amount == 0 {
                    // The production identity branches rather than computing,
                    // which the reference does not — so they agree to within
                    // the rounding the reference performs, and the bit-exact
                    // claim is the separate test above.
                    #expect(abs(Double(actual) - Double(expected)) < 1e-6)
                } else {
                    #expect(
                        actual.bitPattern == expected.bitPattern,
                        "f(\(value), \(amount)) = \(actual), expected \(expected)"
                    )
                }
            }
        }
    }

    @Test(
        "The exponent is 2^amount, computed once per curve",
        arguments: [-1.0, -0.5, -0.25, 0.0, 0.25, 0.5, 1.0]
    )
    func theExponentIsTwoToTheAmount(amount: Double) {
        let curve = GlobalContrastCurve(amount: amount)
        #expect(curve.exponent == exp2(amount))
        #expect(curve.amount == amount)
    }

    @Test("The endpoints of the domain give exactly 0.5 and 2")
    func theEndpointExponentsAreExact() {
        #expect(GlobalContrastCurve(amount: -1).exponent == 0.5)
        #expect(GlobalContrastCurve(amount: 1).exponent == 2)
    }

    // MARK: - Applicability

    @Test("A curve with a usable exponent is applicable")
    func applicableCurves() {
        for amount in Self.amounts + [0, -50, 50] {
            #expect(GlobalContrastCurve(amount: amount).isApplicable)
        }
    }

    /// Deliberately not a restatement of `−1 … +1`: that is the adjustment's
    /// rule, refused where a person's decision is validated. This is the
    /// arithmetic's own floor.
    @Test("A curve with a non-finite or non-positive exponent is not applicable")
    func inapplicableCurves() {
        #expect(!GlobalContrastCurve(amount: .nan).isApplicable)
        #expect(!GlobalContrastCurve(amount: .infinity).isApplicable)
        #expect(!GlobalContrastCurve(amount: -.infinity).isApplicable)
        // 2^2000 overflows to infinity; 2^-2000 underflows to exactly zero.
        #expect(!GlobalContrastCurve(amount: 2000).isApplicable)
        #expect(!GlobalContrastCurve(amount: -2000).isApplicable)
        // And an amount far outside the control's range is still arithmetically
        // fine — the two rules are genuinely different.
        #expect(GlobalContrastCurve(amount: 10).isApplicable)
    }

    @Test("The diagnostic description names the amount and the exponent")
    func theDiagnosticIsInformative() {
        let text = GlobalContrastCurve(amount: 0.5).diagnosticDescription
        #expect(text.contains("0.5"))
        #expect(text.contains("per component"))
        #expect(text.contains("global RGB tone curve"))
    }
}
