import Testing
import Foundation
@testable import InfraredConverter

/// Contrast in the interactive half of the pipeline, and its **order**.
///
/// ```text
/// retained pre-mix preview → mix → orientation → exposure → levels → CONTRAST
///                          → display
/// ```
///
/// `GlobalContrastCurveTests` owns the arithmetic and
/// `GlobalContrastApplierTests` owns the stage. What these tests establish is
/// that the **workspace** passes the user's amount to that stage unchanged, in
/// the right place — after the levels, before the range policy — and that the
/// order is observable in the pixels rather than only in provenance.
@Suite("Workspace contrast pipeline")
struct WorkspaceContrastPipelineTests {

    static func contrast(_ amount: Double) throws -> UserContrastAdjustment {
        try UserContrastAdjustment(amount: amount)
    }

    static func levels(_ black: Double, _ white: Double) throws -> UserLevelsAdjustment {
        try UserLevelsAdjustment(blackPoint: black, whitePoint: white)
    }

    static func exposure(_ ev: Double) throws -> UserExposureAdjustment {
        try UserExposureAdjustment(ev: ev)
    }

    /// Three pixels spanning below zero, inside the display range and above
    /// one. Every value is a binary fraction, so `× 2^n` is exact in `Float32`.
    static let values: [Float] = [
        0.125, 0.25, 0.375,
        0.0625, 0.75, 1.5,
        -0.25, 0.5, 0.03125,
    ]

    static func source(
        _ values: [Float], width: Int = 3, height: Int = 1
    ) -> WorkspacePreviewPipeline.Source {
        PreviewTestData.source(
            PreviewTestData.preview(width: width, height: height, values: values)
        )
    }

    /// The reference encoding, per component, computed from the
    /// specification: expose, level, curve, clip, encode, quantise.
    static func reference(
        _ values: [Float],
        exposureEV: Double = 0,
        black: Double = 0,
        white: Double = 1,
        contrast: Double = 0
    ) -> [UInt8] {
        values.map {
            DisplayPreviewTestData.referenceSample(
                sceneLinear: $0, exposureEV: exposureEV,
                blackPoint: black, whitePoint: white, contrastAmount: contrast
            )
        }
    }

    static func bytes(_ image: DisplayEncodedPreviewImage) -> [UInt8] { [UInt8](image.bytes) }

    /// The workspace's render stages, called one by one with the values the
    /// pipeline would derive for `adjustments`.
    static func byHand(
        _ source: WorkspacePreviewPipeline.Source,
        adjustments: ImageAdjustments
    ) throws -> DisplayEncodedPreviewImage {
        try DisplayPreviewRenderer().render(
            try GlobalContrastApplier().apply(
                to: try LinearLevelsApplier().apply(
                    to: try SceneLinearExposer().apply(
                        to: try ImageOrienter().apply(
                            to: try IRChannelMixer().apply(
                                to: source.preview, mix: adjustments.channelMix.mix
                            ),
                            orientation: .upright
                        ),
                        exposure: SceneLinearExposure(adjustments.exposure)
                    ),
                    levels: LinearLevels(adjustments.levels)
                ),
                curve: GlobalContrastCurve(adjustments.contrast)
            ),
            settings: WorkspacePreviewPipeline.displaySettings
        )
    }

    // MARK: - The workspace applies the user's amount

    @Test("The pipeline applies the user's contrast, and nothing else does")
    func thePipelineAppliesTheUsersContrast() throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)
        let adjustments = ImageAdjustments(contrast: try Self.contrast(0.6))

        let preview = try pipeline.render(source, adjustments: adjustments)

        #expect(preview.contrastAdjustment.amount == 0.6)
        #expect(preview.renderedContrastCurve.amount == 0.6)
        #expect(preview.renderedContrastCurve.exponent == exp2(0.6))
        #expect(preview.processing.contrastApplied)
        #expect(!preview.preservesLinearLightEncoding)

        // And the bytes are the specification's, computed without the
        // production curve.
        let byHand = try Self.byHand(source, adjustments: adjustments)
        #expect(
            WorkspaceStubs.pixelBytes(preview.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand)
                )
        )
        #expect(Self.bytes(byHand) == Self.reference(Self.values, contrast: 0.6))
    }

    @Test("Neutral contrast renders exactly what no contrast stage would have")
    func neutralContrastIsPixelNeutral() throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)

        let withStage = try pipeline.render(
            source, adjustments: ImageAdjustments(contrast: .neutral)
        )
        #expect(
            WorkspaceStubs.pixelBytes(withStage.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(
                        from: try DisplayPreviewRenderer().render(
                            try GlobalContrastApplier().apply(
                                to: try LinearLevelsApplier().apply(
                                    to: try SceneLinearExposer().apply(
                                        to: try ImageOrienter().apply(
                                            to: try IRChannelMixer()
                                                .apply(to: source.preview, mix: .identity),
                                            orientation: .upright
                                        ),
                                        exposure: .neutral
                                    ),
                                    levels: .neutral
                                ),
                                curve: .neutral
                            ),
                            settings: WorkspacePreviewPipeline.displaySettings
                        )
                    )
                )
        )
        // The stage was traversed even so.
        #expect(withStage.processing.contrastApplied)
        #expect(withStage.processing.contrastAmount == 0)
    }

    // MARK: - Contrast follows the levels

    /// Not by inspecting provenance: by choosing a sample for which the two
    /// orders give different numbers, and showing the workspace produces the
    /// one the pipeline claims.
    @Test("Contrast is applied after the levels, not before them")
    func contrastFollowsTheLevels() throws {
        let pipeline = WorkspacePreviewPipeline()
        // 0.125 with black 0 / white 0.5 becomes 0.25, which the curve then
        // pushes down. Curving first would curve 0.125 and then rescale it,
        // which lands somewhere else entirely.
        let values: [Float] = [0.125, 0.25, 0.375, 0.0625, 0.4375, 0.5, 0.1875, 0.3125, 0.25]
        let source = Self.source(values)
        let black = 0.0
        let white = 0.5
        let amount = 0.75

        let preview = try pipeline.render(
            source,
            adjustments: ImageAdjustments(
                levels: try Self.levels(black, white),
                contrast: try Self.contrast(amount)
            )
        )

        // The stated order, computed from the specification.
        let stated = Self.reference(values, black: black, white: white, contrast: amount)
        let byHand = try Self.byHand(
            source,
            adjustments: ImageAdjustments(
                levels: try Self.levels(black, white),
                contrast: try Self.contrast(amount)
            )
        )
        #expect(Self.bytes(byHand) == stated)
        #expect(
            WorkspaceStubs.pixelBytes(preview.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand)
                )
        )

        // The reversed order, computed here by hand: curve the exposed values
        // first, then level the result.
        let reversed = values.map { value -> UInt8 in
            let curved = DisplayPreviewTestData.referenceContrast(value, amount: amount)
            let leveled = Float((Double(curved) - black) * (1 / (white - black)))
            return DisplayPreviewTestData.referenceQuantize(
                DisplayPreviewTestData.referenceEncode(
                    min(max(Double(leveled), 0), 1)
                )
            )
        }

        // The two orders genuinely differ for this sample — otherwise the
        // test above would prove nothing.
        #expect(stated != reversed)
    }

    /// The same claim through the production stages rather than the reference:
    /// swapping the two stages changes the buffer.
    @Test("Swapping the levels and the curve changes the rendered values")
    func theOrderOfTheTwoStagesMatters() throws {
        let values: [Float] = [0.125, 0.25, 0.375, 0.0625, 0.4375, 0.5, 0.1875, 0.3125, 0.25]
        let oriented = DisplayPreviewTestData.image(width: 3, height: 1, values: values)
        let exposed = try SceneLinearExposer().apply(to: oriented, exposure: .neutral)
        let pair = LinearLevels(blackPoint: 0, whitePoint: 0.5)
        let curve = GlobalContrastCurve(amount: 0.75)

        // The pipeline's order.
        let stated = try GlobalContrastApplier().apply(
            to: try LinearLevelsApplier().apply(to: exposed, levels: pair),
            curve: curve
        )

        // The other order, run by hand through the same two stages.
        let curvedFirst = try GlobalContrastApplier().apply(
            to: DisplayPreviewTestData.leveledImage(
                width: 3, height: 1, values: exposed.values
            ),
            curve: curve
        )
        let reversed = try LinearLevelsApplier().apply(
            to: DisplayPreviewTestData.exposedImage(
                width: 3, height: 1, values: curvedFirst.values
            ),
            levels: pair
        )

        #expect(stated.values != reversed.values)
    }

    // MARK: - Exposure, levels and contrast in one chain

    /// The complete chain, compared against arithmetic computed
    /// independently — so the order of all three is pinned, not just the last
    /// pair.
    @Test("Exposure, then levels, then contrast, matches the specification")
    func theWholeChainMatchesTheSpecification() throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)
        let ev = -0.5
        let black = -0.125
        let white = 1.25
        let amount = -0.4

        let preview = try pipeline.render(
            source,
            adjustments: ImageAdjustments(
                exposure: try Self.exposure(ev),
                levels: try Self.levels(black, white),
                contrast: try Self.contrast(amount)
            )
        )

        let byHand = try Self.byHand(
            source,
            adjustments: ImageAdjustments(
                exposure: try Self.exposure(ev),
                levels: try Self.levels(black, white),
                contrast: try Self.contrast(amount)
            )
        )
        #expect(
            Self.bytes(byHand)
                == Self.reference(
                    Self.values, exposureEV: ev, black: black, white: white,
                    contrast: amount
                )
        )
        #expect(
            WorkspaceStubs.pixelBytes(preview.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand)
                )
        )

        // Each stage's own record still names its own decision.
        #expect(preview.renderedExposureEV == ev)
        #expect(preview.renderedLevels.blackPoint == black)
        #expect(preview.renderedLevels.whitePoint == white)
        #expect(preview.renderedContrastCurve.amount == amount)
    }

    // MARK: - No clipping before the destination

    @Test("Extended values survive the curve and are clipped only at the display")
    func nothingIsClippedBeforeTheDisplay() throws {
        // −0.25 and −0.5 both lie below zero and must stay distinct until the
        // display boundary destroys the distinction.
        let values: [Float] = [-0.25, -0.5, 1.7, 1.4, 0.5, 0.25, 0.75, 0.9, 0.1]
        let oriented = DisplayPreviewTestData.image(width: 3, height: 1, values: values)
        let curved = try GlobalContrastApplier().apply(
            to: try LinearLevelsApplier().apply(
                to: try SceneLinearExposer().apply(to: oriented, exposure: .neutral),
                levels: .neutral
            ),
            curve: GlobalContrastCurve(amount: 1)
        )

        #expect(curved.values[0] == -0.25)
        #expect(curved.values[1] == -0.5)
        #expect(curved.values[2] == 1.7)
        #expect(curved.values[3] == 1.4)
        #expect(!curved.processing.clamped)

        let encoded = try DisplayPreviewRenderer().render(
            curved, settings: WorkspacePreviewPipeline.displaySettings
        )
        // The clip is the display's, and it counts what it destroyed.
        #expect(encoded.processing.clippedLowSampleCount == 2)
        #expect(encoded.processing.clippedHighSampleCount == 2)
    }

    // MARK: - Preview and export share the stage

    /// The parity claim, made where it is strongest: at the **shared
    /// post-contrast value**, before either quantisation can hide a
    /// difference.
    ///
    /// Both encoders take a `ToneCurvedRGBImage`. Building one and handing it
    /// to each in turn is not a comparison of two pipelines but a comparison
    /// of two destinations, which is exactly what the architecture claims they
    /// are.
    @Test("Both destinations consume the same post-contrast value")
    func bothDestinationsShareThePostContrastValue() throws {
        let values: [Float] = [-0.25, 0, 0.125, 0.5, 0.9, 1, 1.5, 0.25, 0.75]
        let curved = try GlobalContrastApplier().apply(
            to: try LinearLevelsApplier().apply(
                to: try SceneLinearExposer().apply(
                    to: DisplayPreviewTestData.image(width: 3, height: 1, values: values),
                    exposure: SceneLinearExposure(ev: 0.5)
                ),
                levels: LinearLevels(blackPoint: 0.1, whitePoint: 0.9)
            ),
            curve: GlobalContrastCurve(amount: 0.5)
        )

        let preview = try DisplayPreviewRenderer().render(
            curved, settings: DisplayRenderSettings.standard
        )
        let exported = try ExportImageEncoder().encode(
            curved, settings: ExportRenderSettings.standard
        )

        // Each destination's samples correspond to the same Float values,
        // under its own quantisation — computed from the specification rather
        // than from the other destination.
        for (index, value) in curved.values.enumerated() {
            let clipped = min(max(Double(value), 0), 1)
            let encoded = DisplayPreviewTestData.referenceEncode(clipped)
            #expect(preview.bytes[index] == DisplayPreviewTestData.referenceQuantize(encoded))
            #expect(exported.samples[index] == ExportTestData.referenceQuantize(encoded))
        }

        // The same clip, counted identically: the two range policies differ in
        // name and destination, not in what they do to the unit range.
        #expect(preview.processing.clippedLowSampleCount
            == exported.processing.clippedLowSampleCount)
        #expect(preview.processing.clippedHighSampleCount
            == exported.processing.clippedHighSampleCount)

        // And both carry the same contrast provenance, from the one stage.
        #expect(preview.processing.contrastAmount == exported.processing.contrastAmount)
        #expect(preview.processing.contrastCurve == exported.processing.contrastCurve)
        #expect(preview.processing.contrastApplied)
        #expect(exported.processing.contrastApplied)
    }

}
