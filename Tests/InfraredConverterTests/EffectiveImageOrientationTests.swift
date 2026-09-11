import Testing
import Foundation
@testable import InfraredConverter

/// The derivation that keeps the file's orientation and the user's correction
/// apart, and the order in which they combine.
@Suite("EffectiveImageOrientation")
struct EffectiveImageOrientationTests {

    @Test("With no user adjustment, the effective orientation is the file's")
    func identityAdjustmentPreservesTheSource() {
        for source in RAWImageOrientation.allCases {
            let derived = EffectiveImageOrientation(source: source, userAdjustment: .identity)
            #expect(derived.applied == source)
            #expect(!derived.isUserAdjusted)
            #expect(!derived.differsFromSource)
        }
    }

    /// Reset means "the user asked for no correction", **not** "the image is
    /// upright". The two are only the same on a file that records upright,
    /// and every other source orientation proves the difference.
    @Test("Reset restores the file's orientation, which is not always upright")
    func resetIsNotMakeUpright() {
        for source in RAWImageOrientation.allCases where source != .upright {
            let adjusted = EffectiveImageOrientation(
                source: source, userAdjustment: .quarterTurnRight
            )
            #expect(adjusted.applied != source)

            let reset = EffectiveImageOrientation(
                source: source, userAdjustment: .reset
            )
            #expect(reset.applied == source)
            #expect(reset.applied != .upright, "\(source): reset must not mean upright")
        }

        // And on an upright file the two coincide, which is exactly why the
        // distinction is invisible if only that case is tested.
        let uprightFile = EffectiveImageOrientation(source: .upright, userAdjustment: .reset)
        #expect(uprightFile.applied == .upright)
    }

    /// A separate operation from reset, and deliberately named differently.
    @Test("Making the image upright is a different adjustment from resetting")
    func makingUprightIsNotResetting() {
        for source in RAWImageOrientation.allCases {
            let derived = EffectiveImageOrientation(source: source, userAdjustment: .identity)
            let makeUpright = derived.adjustmentMakingUpright
            let corrected = EffectiveImageOrientation(
                source: source, userAdjustment: makeUpright
            )
            #expect(corrected.applied == .upright)
            #expect((makeUpright == .identity) == (source == .upright))
        }
    }

    // MARK: - The composition order

    /// The convention: source first, then the user's correction. Reflections
    /// are what make it provable — rotations commute, so a test built only
    /// from them would pass either way round.
    @Test("The order is source-then-user, and reversing it gives a different result")
    func theOrderIsSourceThenUser() {
        // A file recording a reflection, corrected by a quarter turn right.
        let derived = EffectiveImageOrientation(
            source: .transposed, userAdjustment: .quarterTurnRight
        )
        #expect(derived.applied == .mirroredHorizontally)

        // The same two combined the other way round: a valid orientation, a
        // different one, and one that does not look broken.
        let reversed = RAWImageOrientation.rotated90Clockwise.composed(with: .transposed)
        #expect(reversed == .mirroredVertically)
        #expect(reversed != derived.applied)
    }

    /// Every source and every adjustment, against the composition the
    /// convention names — and checked as an actual pixel permutation, not
    /// only as algebra.
    @Test("All 64 source/adjustment pairs derive the documented composition")
    func everyPairDerivesTheDocumentedComposition() throws {
        for source in RAWImageOrientation.allCases {
            for adjustment in UserOrientationAdjustment.allCases {
                let derived = EffectiveImageOrientation(
                    source: source, userAdjustment: adjustment
                )
                #expect(derived.applied == source.composed(with: adjustment.transform))

                // The pixels agree: orienting by the source and then by the
                // adjustment gives the same arrangement as one permutation by
                // the effective orientation.
                let inTurn = try RAWImageOrientationCompositionTests
                    .appliedInTurn([source, adjustment.transform])
                let once = try RAWImageOrientationCompositionTests.applied(derived.applied)
                #expect(inTurn == once, "\(source) + \(adjustment.persistedToken)")
            }
        }
    }

    @Test("The three facts stay separate and readable")
    func theThreeFactsStaySeparate() {
        let derived = EffectiveImageOrientation(
            source: .rotated90Clockwise, userAdjustment: .quarterTurnRight
        )
        #expect(derived.source == .rotated90Clockwise)
        #expect(derived.userAdjustment == .quarterTurnRight)
        #expect(derived.applied == .rotated180)
        #expect(derived.isUserAdjusted)
        #expect(derived.differsFromSource)
        #expect(derived.diagnosticDescription.contains("rotated 90° clockwise"))
        #expect(derived.diagnosticDescription.contains("rotated 90° right"))
        #expect(derived.diagnosticDescription.contains("rotated 180°"))
    }

    /// Geometry follows the effective orientation, not either term on its own.
    @Test("Dimension swapping follows the effective orientation")
    func dimensionsFollowTheEffectiveOrientation() {
        // A sideways file corrected back: both terms swap, the result does not.
        let corrected = EffectiveImageOrientation(
            source: .rotated90Clockwise, userAdjustment: .quarterTurnLeft
        )
        #expect(corrected.applied == .upright)
        #expect(!corrected.applied.swapsDimensions)

        // An upright file turned by the user: only the adjustment swaps.
        let turned = EffectiveImageOrientation(
            source: .upright, userAdjustment: .quarterTurnRight
        )
        #expect(turned.applied.swapsDimensions)
        let output = turned.applied.outputDimensions(sourceWidth: 4056, sourceHeight: 3040)
        #expect(output.width == 3040)
        #expect(output.height == 4056)
    }
}
