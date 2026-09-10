import Testing
import Foundation
@testable import InfraredConverter

/// The application layer's initial choices for a freshly opened file.
///
/// These are **product decisions**, not mathematics, and they are tested here
/// for the same reason they live in the application layer: so that changing
/// one is a deliberate act with a visible diff, rather than a renderer default
/// drifting.
@Suite("WorkspacePreviewPipeline")
struct WorkspacePreviewPipelineTests {

    @Test("The initial choices are the documented ones")
    func initialChoicesAreStated() {
        // Identity, not the red/blue swap: the application cannot know that a
        // file is an infrared capture, and swapping a visible-light frame's
        // channels would simply be wrong.
        #expect(WorkspacePreviewPipeline.initialMix == .identity)
        #expect(WorkspacePreviewPipeline.initialMix.source == .identity)

        // The IR-safe placement, never the file's visible-light matrix.
        #expect(WorkspacePreviewPipeline.initialTransform == .sensorRGBIdentityFalseColor)
        #expect(!WorkspacePreviewPipeline.initialTransform.source
            .isValidatedInfraredCalibration)

        // Neutral exposure, chosen rather than defaulted.
        #expect(WorkspacePreviewPipeline.initialSettings.exposureEV == 0)
        #expect(WorkspacePreviewPipeline.initialSettings.exposureScale == 1)
        #expect(WorkspacePreviewPipeline.initialSettings.rangePolicy == .hardClipToDisplayRange)
        #expect(WorkspacePreviewPipeline.initialSettings.encoding == .sRGB)
    }

    /// Even sides matter: a region of even width and height contains whole
    /// 2×2 CFA cells whatever its origin's parity, so every colour plane is
    /// measured and the estimator cannot fail for want of samples.
    @Test(
        "The neutral patch is centred, even-sided and inside the frame",
        arguments: [
            (4056, 3040), (2028, 1520), (100, 100), (37, 41), (4, 4), (2, 3), (1, 1),
        ]
    )
    func neutralPatchIsWellFormed(width: Int, height: Int) {
        let region = WorkspacePreviewPipeline.centredNeutralPatch(
            width: width, height: height
        )

        #expect(region.width > 0)
        #expect(region.height > 0)
        #expect(region.originRow >= 0)
        #expect(region.originColumn >= 0)
        #expect(region.originRow + region.height <= height)
        #expect(region.originColumn + region.width <= width)

        // Even sides, unless the image itself is smaller than two samples
        // across — in which case the region is the image and the estimator's
        // own refusal is the right outcome, not a silently invented patch.
        if width >= 2 && height >= 2 {
            #expect(region.width % 2 == 0)
            #expect(region.height % 2 == 0)
        }

        // Centred to within one sample on each axis.
        let rowGapBefore = region.originRow
        let rowGapAfter = height - (region.originRow + region.height)
        #expect(abs(rowGapBefore - rowGapAfter) <= 1)
        let columnGapBefore = region.originColumn
        let columnGapAfter = width - (region.originColumn + region.width)
        #expect(abs(columnGapBefore - columnGapAfter) <= 1)
    }

    @Test("The E-PL3's active area gets a 190-sample square in the middle")
    func neutralPatchOnTheReferenceGeometry() throws {
        let region = WorkspacePreviewPipeline.centredNeutralPatch(width: 4056, height: 3040)
        #expect(region.width == 190)
        #expect(region.height == 190)
        #expect(region.originRow == 1425)
        #expect(region.originColumn == 1933)

        // 190 × 190 on a 2×2 CFA: 9025 samples of every plane, so no plane can
        // be missed.
        #expect(region.sampleCount == 36_100)
        #expect((region.width / 2) * (region.height / 2) == 9_025)
    }

    /// The patch validates against the geometry it was computed for, on every
    /// size the estimator could be handed.
    @Test("The computed patch is always a valid region of its own mosaic")
    func neutralPatchValidatesAgainstItsMosaic() throws {
        for (width, height) in [(8, 8), (64, 48), (4056, 3040), (33, 2)] {
            let region = WorkspacePreviewPipeline.centredNeutralPatch(
                width: width, height: height
            )
            try region.validate(inWidth: width, height: height)
        }
    }
}
