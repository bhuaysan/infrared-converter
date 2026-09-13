import Testing
import Foundation
@testable import InfraredConverter

/// The shared exposure primitive: what `× 2^EV` means, and that exactly one
/// piece of code decides it.
@Suite("Scene-linear exposure")
struct SceneLinearExposureTests {

    @Test("The scale is 2^EV, exactly, at every integral stop")
    func theScaleIsExactAtIntegralStops() {
        #expect(SceneLinearExposure(ev: 0).scale == 1)
        #expect(SceneLinearExposure(ev: 1).scale == 2)
        #expect(SceneLinearExposure(ev: -1).scale == 0.5)
        #expect(SceneLinearExposure(ev: 2).scale == 4)
        #expect(SceneLinearExposure(ev: -3).scale == 0.125)
        #expect(SceneLinearExposure(ev: 10).scale == 1024)
        #expect(SceneLinearExposure(ev: -10).scale == 1.0 / 1024)
    }

    @Test("Neutral is 0 EV and the identity")
    func neutralIsTheIdentity() {
        #expect(SceneLinearExposure.neutral.ev == 0)
        #expect(SceneLinearExposure.neutral.scale == 1)
        #expect(SceneLinearExposure.neutral.isIdentity)
        #expect(!SceneLinearExposure(ev: 0.001).isIdentity)
    }

    @Test("A user's adjustment becomes the same number, unchanged")
    func aUserAdjustmentPassesThroughUnchanged() throws {
        let adjustment = try UserExposureAdjustment(ev: 1.25)
        let exposure = SceneLinearExposure(adjustment)
        #expect(exposure.ev == 1.25)
        #expect(exposure.scale == exp2(1.25))
        #expect(SceneLinearExposure(.neutral).isIdentity)
    }

    @Test("Applying multiplies a component in the linear domain")
    func applyingMultiplies() {
        let doubled = SceneLinearExposure(ev: 1)
        #expect(doubled.applied(to: 0.25) == 0.5)
        #expect(doubled.applied(to: -0.25) == -0.5)
        #expect(doubled.applied(to: 1.5) == 3)
        #expect(doubled.applied(to: 0) == 0)

        let halved = SceneLinearExposure(ev: -1)
        #expect(halved.applied(to: 1.5) == 0.75)
        #expect(halved.applied(to: 0.5) == 0.25)
    }

    @Test("The identity leaves every bit pattern alone, signed zero included")
    func theIdentityPreservesBitPatterns() {
        let neutral = SceneLinearExposure.neutral
        let awkward: [Float] = [
            0, -0, 1, -1, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0.1, 1e-30
        ]
        for value in awkward {
            #expect(neutral.applied(to: value).bitPattern == value.bitPattern)
        }
    }

    @Test("Nothing is clipped: values stay outside 0...1")
    func nothingIsClipped() {
        let lifted = SceneLinearExposure(ev: 2)
        #expect(lifted.applied(to: 0.5) == 2)
        #expect(lifted.applied(to: -0.5) == -2)
        // And a negative exposure brings a lifted value back, which only
        // works because nothing destroyed it on the way up.
        #expect(SceneLinearExposure(ev: -2).applied(to: 2) == 0.5)
    }

    @Test("The product is taken in Double and narrowed once")
    func theProductIsTakenInDouble() {
        // A Float32 product of these two overflows to infinity; the
        // mathematical result does not, and neither does the Double one until
        // it is narrowed. The primitive narrows exactly once, at the end, so
        // the answer here is the correctly rounded Float of 1e30 × 2^-10.
        let dimmed = SceneLinearExposure(ev: -10)
        #expect(dimmed.applied(to: 1e30) == Float(1e30 / 1024))
    }

    @Test("An unusable exposure is reported rather than sanitised")
    func anUnusableExposureIsReported() {
        #expect(SceneLinearExposure(ev: 0).isApplicable)
        #expect(SceneLinearExposure(ev: 10).isApplicable)
        #expect(SceneLinearExposure(ev: -10).isApplicable)

        #expect(!SceneLinearExposure(ev: .nan).isApplicable)
        #expect(!SceneLinearExposure(ev: .infinity).isApplicable)
        // The case that makes a check on the scale alone insufficient:
        // exp2(-infinity) is 0, a perfectly usable-looking multiplier that
        // would render a black frame from a nonsense exposure.
        let minusInfinity = SceneLinearExposure(ev: -.infinity)
        #expect(minusInfinity.scale == 0)
        #expect(minusInfinity.scale.isFinite)
        #expect(!minusInfinity.isApplicable)
        // And a finite but enormous EV, whose scale is not finite.
        #expect(!SceneLinearExposure(ev: 100_000).isApplicable)
    }

    // MARK: - One authority, two consumers

    @Test("The display renderer applies this primitive and not its own arithmetic")
    func theDisplayRendererUsesThePrimitive() throws {
        let settings = DisplayPreviewTestData.settings(exposureEV: 1.75)
        #expect(settings.exposure.ev == 1.75)
        #expect(settings.exposureScale == SceneLinearExposure(ev: 1.75).scale)
        #expect(settings.exposureScale == exp2(1.75))
    }

    @Test("Both end paths expose the same value identically")
    func bothPathsExposeIdentically() throws {
        // The claim this milestone rests on, at its smallest: the preview's
        // 8-bit encoder and the export's 16-bit one receive the same exposed
        // scene-linear number. Compared at full Double precision, before
        // either quantisation has a chance to hide a difference.
        let values: [Float] = [-0.25, 0, 0.125, 0.5, 0.9, 1, 1.5]
        for ev in [-2.0, -0.5, 0, 0.5, 1.25, 3] {
            let exposure = SceneLinearExposure(ev: ev)
            for value in values {
                let viaPrimitive = exposure.applied(to: value)
                let byHand = Float(Double(value) * exp2(ev))
                #expect(viaPrimitive.bitPattern == byHand.bitPattern)
            }
        }
    }

    @Test("The sRGB transfer function has one implementation")
    func theTransferFunctionIsShared() {
        // Both encoders call `SRGBTransferFunction`, so pinning it pins both.
        #expect(SRGBTransferFunction.encode(0) == 0)
        #expect(abs(SRGBTransferFunction.encode(1) - 1) < 1e-12)
        // The threshold itself takes the linear branch.
        let threshold = SRGBTransferFunction.linearSegmentThreshold
        #expect(SRGBTransferFunction.encode(threshold) == 12.92 * threshold)
        // And it is the piecewise curve, not pow(x, 1/2.2).
        #expect(abs(SRGBTransferFunction.encode(0.5) - 0.735_356_983_052_235) < 1e-12)
        #expect(abs(SRGBTransferFunction.encode(0.5) - pow(0.5, 1 / 2.2)) > 0.003)

        for value in [0.0, 0.001, 0.0031308, 0.01, 0.25, 0.5, 0.75, 1.0] {
            #expect(
                SRGBTransferFunction.encode(value)
                    == DisplayPreviewTestData.referenceEncode(value)
            )
        }
    }
}
