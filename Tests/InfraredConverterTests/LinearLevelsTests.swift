import Testing
import Foundation
@testable import InfraredConverter

/// The arithmetic of the black and white points, and the boundary of what
/// counts as a usable interval.
///
/// Every expectation here is written from the specification —
/// `(x − black) / (white − black)` — and never by calling the production code
/// twice. A test that compared the primitive against itself would pass
/// whatever it did.
@Suite("LinearLevels")
struct LinearLevelsTests {

    /// One ULP of `Float32` at unit magnitude, give or take: the arithmetic is
    /// carried in `Double` and narrowed to `Float` exactly once, so an exact
    /// decimal like `0.1` is already a `Float` approximation before the stage
    /// sees it. These tolerances describe that narrowing and nothing else.
    static let tolerance: Float = 1e-6

    // MARK: - Identity

    /// Black `0`, white `1` is a scale of exactly `1` and an offset of exactly
    /// `0`, so every finite value comes back bit for bit — not merely within a
    /// tolerance.
    @Test(
        "Neutral levels return every representative value exactly",
        arguments: [
            Float(-3), -0.25, -1e-30, 0, 1e-30, 0.1, 0.25, 0.5, 0.9, 1, 1.5, 12,
            .leastNonzeroMagnitude, .greatestFiniteMagnitude,
        ]
    )
    func neutralLevelsAreTheIdentity(value: Float) {
        let result = LinearLevels.neutral.applied(to: value)
        #expect(result == value)
        #expect(result.bitPattern == value.bitPattern)
    }

    @Test("Neutral levels are the identity, and say so")
    func neutralIsRecognised() {
        #expect(LinearLevels.neutral.blackPoint == 0)
        #expect(LinearLevels.neutral.whitePoint == 1)
        #expect(LinearLevels.neutral.span == 1)
        #expect(LinearLevels.neutral.scale == 1)
        #expect(LinearLevels.neutral.isIdentity)
        #expect(LinearLevels.neutral.isApplicable)
        #expect(LinearLevels(blackPoint: 0, whitePoint: 1) == .neutral)
        #expect(!LinearLevels(blackPoint: 0, whitePoint: 2).isIdentity)
        #expect(!LinearLevels(blackPoint: -0.1, whitePoint: 1).isIdentity)
    }

    /// Signed zero survives, which is what "bit for bit" is worth stating
    /// about: `(−0 − 0) × 1` is `−0`, not `+0`.
    @Test("A negative zero stays a negative zero")
    func negativeZeroSurvives() {
        let result = LinearLevels.neutral.applied(to: -0.0)
        #expect(result == 0)
        #expect(result.sign == .minus)
    }

    // MARK: - The mapping

    /// The worked example from the decision record, every value of it.
    ///
    /// ```text
    /// black 0.1, white 0.9   →   scale 1.25
    /// 0.1 → 0        0.5 → 0.5      0.9 → 1
    /// 0.0 → −0.125   1.0 → 1.125
    /// ```
    @Test(
        "black 0.1 / white 0.9 maps the documented values",
        arguments: [
            (Float(0.1), Float(0)),
            (0.5, 0.5),
            (0.9, 1),
            (0.0, -0.125),
            (1.0, 1.125),
        ]
    )
    func theDocumentedMapping(input: Float, expected: Float) {
        let levels = LinearLevels(blackPoint: 0.1, whitePoint: 0.9)
        #expect(levels.scale == 1.25)
        let result = levels.applied(to: input)
        #expect(abs(result - expected) <= Self.tolerance, "\(input) → \(result)")
    }

    /// The endpoints land exactly where the names say, for an interval whose
    /// numbers are exactly representable — so the mapping is pinned without a
    /// tolerance at least once.
    @Test("Exactly representable endpoints map exactly to 0 and 1")
    func exactEndpointsAreExact() {
        let levels = LinearLevels(blackPoint: 0.25, whitePoint: 0.75)
        #expect(levels.scale == 2)
        #expect(levels.applied(to: 0.25) == 0)
        #expect(levels.applied(to: 0.75) == 1)
        #expect(levels.applied(to: 0.5) == 0.5)
    }

    /// The operation is affine, so equal input steps produce equal output
    /// steps — everywhere, including outside the interval. A curve, a
    /// contrast S-shape or a gamma would break this.
    @Test("Equal input steps produce equal output steps, inside and outside")
    func theMappingIsAffine() {
        let levels = LinearLevels(blackPoint: -0.2, whitePoint: 1.4)
        let step: Float = 0.1
        var previous: Float?
        for index in -10...20 {
            let input = Float(index) * step
            let output = levels.applied(to: input)
            if let previous {
                let delta = output - previous
                let expected = Float(Double(step) * levels.scale)
                #expect(abs(delta - expected) <= Self.tolerance, "step at \(input)")
            }
            previous = output
        }
    }

    // MARK: - Applicability

    @Test(
        "A non-finite endpoint makes the levels inapplicable",
        arguments: [Double.nan, .infinity, -.infinity]
    )
    func nonFiniteEndpointsAreRefused(poison: Double) {
        #expect(!LinearLevels(blackPoint: poison, whitePoint: 1).isApplicable)
        #expect(!LinearLevels(blackPoint: 0, whitePoint: poison).isApplicable)
        #expect(!LinearLevels(blackPoint: poison, whitePoint: poison).isApplicable)
    }

    @Test("Equal endpoints are inapplicable, and are not quietly nudged apart")
    func equalEndpointsAreRefused() {
        let levels = LinearLevels(blackPoint: 0.5, whitePoint: 0.5)
        #expect(levels.span == 0)
        #expect(!levels.scale.isFinite)
        #expect(!levels.isApplicable)
        // The values are kept exactly as given: nothing repaired them.
        #expect(levels.blackPoint == 0.5)
        #expect(levels.whitePoint == 0.5)
    }

    @Test("Reversed endpoints are inapplicable, and are not swapped")
    func reversedEndpointsAreRefused() {
        let levels = LinearLevels(blackPoint: 0.9, whitePoint: 0.1)
        #expect(!levels.isApplicable)
        // Not reordered. Swapping them would invert the photograph, which is a
        // decision nobody made — and the scale here is perfectly finite, so
        // only the ordering check catches it.
        #expect(levels.blackPoint == 0.9)
        #expect(levels.whitePoint == 0.1)
        #expect(levels.scale.isFinite)
    }

    /// The two failures a magnitude check would miss, and the reason the
    /// validity rule is stated in terms of representability rather than
    /// photography.
    @Test("An interval that overflows the subtraction is inapplicable")
    func anOverflowingSpanIsRefused() {
        let levels = LinearLevels(
            blackPoint: -.greatestFiniteMagnitude, whitePoint: .greatestFiniteMagnitude
        )
        #expect(!levels.span.isFinite)
        // The scale is a perfectly ordinary-looking zero, which would render
        // every pixel black while every number involved stayed finite.
        #expect(levels.scale == 0)
        #expect(levels.scale.isFinite)
        #expect(!levels.isApplicable)
    }

    @Test("An interval whose reciprocal overflows is inapplicable")
    func aVanishingSpanIsRefused() {
        let levels = LinearLevels(
            blackPoint: 0, whitePoint: .leastNonzeroMagnitude
        )
        #expect(levels.span.isFinite)
        #expect(!levels.scale.isFinite)
        #expect(!levels.isApplicable)
    }

    // MARK: - The extended domain

    /// Values outside `0…1` are ordinary in this pipeline, in both directions,
    /// so an interval outside it is an ordinary setting rather than an error.
    @Test("Endpoints outside 0...1 are accepted and mean what they say")
    func theDomainIsNotTheUnitInterval() {
        let levels = LinearLevels(blackPoint: -0.25, whitePoint: 2.0)
        #expect(levels.isApplicable)
        #expect(levels.span == 2.25)
        #expect(abs(levels.applied(to: -0.25) - 0) <= Self.tolerance)
        #expect(abs(levels.applied(to: 2.0) - 1) <= Self.tolerance)
        #expect(abs(levels.applied(to: 0.875) - 0.5) <= Self.tolerance)
    }

    /// Enormous but representable endpoints give the mathematically right
    /// answer rather than garbage — which is why no magnitude limit is
    /// imposed.
    @Test("Enormous but representable endpoints still compute correctly")
    func enormousEndpointsAreStillCorrect() {
        let levels = LinearLevels(blackPoint: -1e300, whitePoint: 1e300)
        #expect(levels.isApplicable)
        #expect(abs(levels.applied(to: 0) - 0.5) <= Self.tolerance)
        #expect(abs(levels.applied(to: 1) - 0.5) <= Self.tolerance)
    }

    // MARK: - No clipping

    /// The property the whole design rests on: values the arithmetic pushes
    /// outside `0…1` survive with their magnitudes intact, so the destination
    /// can own clipping — and so a later levels change can bring them back.
    @Test("Out-of-range results survive with their magnitudes")
    func nothingIsClipped() {
        let levels = LinearLevels(blackPoint: 0.1, whitePoint: 0.9)

        let below = levels.applied(to: -0.2)
        #expect(below < 0)
        #expect(abs(below - Float(-0.375)) <= Self.tolerance)

        let above = levels.applied(to: 2.0)
        #expect(above > 1)
        #expect(abs(above - Float(2.375)) <= Self.tolerance)

        // And exactly the two values the milestone names.
        #expect(LinearLevels(blackPoint: 0.2, whitePoint: 1.2).applied(to: 0) < 0)
        #expect(LinearLevels(blackPoint: 0, whitePoint: 0.5).applied(to: 0.7) > 1)
    }

    // MARK: - Proportionality to scene radiance

    /// The honest half of the semantic claim: a zero black point makes the map
    /// a pure gain, which preserves proportionality; any other black point
    /// subtracts an offset, which destroys it.
    @Test("Proportionality survives exactly when the black point is zero")
    func proportionalityIsDerivedFromTheBlackPoint() {
        #expect(LinearLevels.neutral.preservesProportionalityToSceneRadiance)
        #expect(
            LinearLevels(blackPoint: 0, whitePoint: 2.5)
                .preservesProportionalityToSceneRadiance
        )
        #expect(
            !LinearLevels(blackPoint: 0.001, whitePoint: 1)
                .preservesProportionalityToSceneRadiance
        )
        #expect(
            !LinearLevels(blackPoint: -0.001, whitePoint: 1)
                .preservesProportionalityToSceneRadiance
        )

        // And the claim is arithmetic, not a label: with black 0, doubling the
        // input doubles the output; with a black point, it does not.
        let gain = LinearLevels(blackPoint: 0, whitePoint: 2)
        #expect(abs(gain.applied(to: 0.6) - 2 * gain.applied(to: 0.3)) <= Self.tolerance)

        let affine = LinearLevels(blackPoint: 0.1, whitePoint: 2)
        #expect(abs(affine.applied(to: 0.6) - 2 * affine.applied(to: 0.3)) > Self.tolerance)
    }

    // MARK: - From the adjustment

    @Test("The adjustment maps to this primitive and to nothing else")
    func theAdjustmentMapsToThePrimitive() throws {
        let adjustment = try UserLevelsAdjustment(blackPoint: 0.05, whitePoint: 1.2)
        let levels = LinearLevels(adjustment)
        #expect(levels.blackPoint == 0.05)
        #expect(levels.whitePoint == 1.2)
        #expect(levels == LinearLevels(blackPoint: 0.05, whitePoint: 1.2))
        #expect(LinearLevels(UserLevelsAdjustment.neutral) == .neutral)
    }

    @Test("The diagnostic description cannot be read as tone mapping")
    func theDescriptionIsHonest() {
        let text = LinearLevels(blackPoint: 0.1, whitePoint: 0.9).diagnosticDescription
        #expect(text.contains("black 0.1"))
        #expect(text.contains("white 0.9"))
        #expect(text.contains("affine"))
        #expect(text.contains("not tone mapping"))
    }
}
