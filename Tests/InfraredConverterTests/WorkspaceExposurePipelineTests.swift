import Testing
import Foundation
@testable import InfraredConverter

/// Exposure in the interactive half of the pipeline.
///
/// ```text
/// retained pre-mix preview → mix → orientation → display (× 2^EV, clip, encode)
/// ```
///
/// Exposure has no stage of its own: it is `DisplayRenderSettings.exposureEV`,
/// and `DisplayPreviewRenderer` — whose own suites own the arithmetic — applies
/// it. What these tests establish is that the **workspace** passes the user's
/// value to that stage, unchanged and with nothing clamped in front of it, and
/// that the preview's provenance says so.
///
/// The pixels are compared two ways: against the same stages called by hand,
/// and against `DisplayPreviewTestData`'s reference arithmetic, which is written
/// from the specification rather than by calling production code.
@Suite("Workspace exposure pipeline")
struct WorkspaceExposurePipelineTests {

    static func exposure(_ ev: Double) throws -> UserExposureAdjustment {
        try UserExposureAdjustment(ev: ev)
    }

    /// One row of three pixels, with values below zero, inside the display
    /// range and above one. Every value is a binary fraction, so `× 2^n` is
    /// exact in `Float32`.
    static let values: [Float] = [
        0.125, 0.25, 0.375,
        0.0625, 0.75, 1.5,
        -0.25, 0.5, 0.03125,
    ]

    static func source(_ values: [Float], width: Int = 3, height: Int = 1) -> WorkspacePreviewPipeline.Source {
        PreviewTestData.source(PreviewTestData.preview(width: width, height: height, values: values))
    }

    /// The workspace stages, called one by one, with the settings the
    /// pipeline derives for `adjustments`.
    static func byHand(
        _ source: WorkspacePreviewPipeline.Source,
        mix: IRChannelMix = .identity,
        orientation: RAWImageOrientation = .upright,
        adjustments: ImageAdjustments
    ) throws -> DisplayEncodedPreviewImage {
        try DisplayPreviewRenderer().render(
            try ImageOrienter().apply(
                to: try IRChannelMixer().apply(to: source.preview, mix: mix),
                orientation: orientation
            ),
            settings: WorkspacePreviewPipeline.displaySettings(for: adjustments)
        )
    }

    /// The reference encoding, per component, computed from the specification.
    static func reference(_ values: [Float], exposureEV: Double) -> [UInt8] {
        values.map { DisplayPreviewTestData.referenceSample(sceneLinear: $0, exposureEV: exposureEV) }
    }

    static func bytes(_ image: DisplayEncodedPreviewImage) -> [UInt8] {
        [UInt8](image.bytes)
    }

    // MARK: - The multiplication

    /// `× 2^EV`, shown as an equivalence rather than asserted from a formula:
    /// rendering the source at `EV` is byte-identical — clip counts included —
    /// to rendering the source multiplied by `2^EV` at `0 EV`. Only a linear
    /// multiplication before the range policy has that property.
    @Test(
        "Exposure multiplies linear light by 2^EV before anything else",
        arguments: [(0.0, Float(1)), (1.0, Float(2)), (-1.0, Float(0.5)), (2.0, Float(4))]
    )
    func exposureMultipliesLinearLight(ev: Double, factor: Float) throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)
        let adjustments = ImageAdjustments(exposure: try Self.exposure(ev))

        let exposed = try pipeline.render(source, adjustments: adjustments)
        let scaled = try pipeline.render(
            Self.source(Self.values.map { $0 * factor }), adjustments: .none
        )

        #expect(WorkspaceStubs.pixelBytes(exposed.image) == WorkspaceStubs.pixelBytes(scaled.image))
        #expect(exposed.processing.clippedHighSampleCount == scaled.processing.clippedHighSampleCount)
        #expect(exposed.processing.clippedLowSampleCount == scaled.processing.clippedLowSampleCount)

        // The stage was asked for exactly the user's value, and applied its
        // scale.
        #expect(exposed.processing.settings.exposureEV == ev)
        #expect(exposed.processing.settings.exposureScale == Double(factor))

        // And the bytes are the specification's, not merely self-consistent.
        let byHand = try Self.byHand(source, adjustments: adjustments)
        #expect(Self.bytes(byHand) == Self.reference(Self.values, exposureEV: ev))
        #expect(Self.bytes(byHand) == Self.reference(Self.values.map { $0 * factor }, exposureEV: 0))
        #expect(
            WorkspaceStubs.pixelBytes(exposed.image)
                == WorkspaceStubs.pixelBytes(try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand))
        )
    }

    @Test("0 EV renders the input exactly as it is")
    func zeroEVIsTheInput() throws {
        let source = Self.source(Self.values)
        let preview = try WorkspacePreviewPipeline().render(source, adjustments: .none)
        let byHand = try Self.byHand(source, adjustments: .none)

        #expect(Self.bytes(byHand) == Self.reference(Self.values, exposureEV: 0))
        #expect(preview.processing.settings.exposureScale == 1)
        // One component above 1 and one below 0 in the input, and nothing
        // else crosses the range at ×1.
        #expect(preview.processing.clippedHighSampleCount == 1)
        #expect(preview.processing.clippedLowSampleCount == 1)
    }

    // MARK: - Extended range

    /// Scene-linear values stay unclamped until the range policy. A clamp
    /// before exposure would be visible in two ways: `0.75 × 2` would never
    /// reach the high clip, and `1.5 × 0.5` would come out as `0.5`.
    @Test("Exposure applies to unclamped scene-linear values, and only the range policy clips")
    func thereIsNoClampBeforeTheRangePolicy() throws {
        // One pixel: R = 0.75, G = 1.5, B = −0.25.
        let pixel: [Float] = [0.75, 1.5, -0.25]
        let source = Self.source(pixel, width: 1, height: 1)
        let pipeline = WorkspacePreviewPipeline()

        let up = try pipeline.render(source, adjustments: ImageAdjustments(exposure: try Self.exposure(1)))
        // 1.5, 3 and −0.5: two clipped high, one clipped low, by the policy.
        #expect(up.processing.clippedHighSampleCount == 2)
        #expect(up.processing.clippedLowSampleCount == 1)
        let upBytes = Self.bytes(try Self.byHand(source, adjustments: ImageAdjustments(exposure: try Self.exposure(1))))
        #expect(upBytes == [255, 255, 0])

        let down = try pipeline.render(source, adjustments: ImageAdjustments(exposure: try Self.exposure(-1)))
        // 0.375, 0.75 and −0.125: the value above 1 came back into range.
        #expect(down.processing.clippedHighSampleCount == 0)
        #expect(down.processing.clippedLowSampleCount == 1)
        let downBytes = Self.bytes(try Self.byHand(source, adjustments: ImageAdjustments(exposure: try Self.exposure(-1))))
        #expect(downBytes[1] == DisplayPreviewTestData.referenceSample(sceneLinear: 0.75, exposureEV: 0))
        // What a clamp to 1 before exposure would have produced instead.
        #expect(downBytes[1] != DisplayPreviewTestData.referenceSample(sceneLinear: 0.5, exposureEV: 0))

        #expect(
            WorkspaceStubs.pixelBytes(down.image)
                == WorkspaceStubs.pixelBytes(try DisplayPreviewCGImageAdapter.makeCGImage(
                    from: try Self.byHand(source, adjustments: ImageAdjustments(exposure: try Self.exposure(-1)))
                ))
        )

        // And the retained source is the unclamped, unexposed input still.
        #expect(zip(source.preview.values, pixel).allSatisfy { $0.bitPattern == $1.bitPattern })
    }

    // MARK: - Clipping provenance

    @Test("More exposure clips more, and the preview's provenance counts it")
    func exposureChangesTheClipCounts() throws {
        // Twelve components, all inside 0.3 … 0.9.
        let values: [Float] = [
            0.3, 0.4, 0.5,   0.6, 0.7, 0.8,
            0.9, 0.35, 0.45, 0.55, 0.65, 0.85,
        ]
        let source = Self.source(values, width: 2, height: 2)
        let pipeline = WorkspacePreviewPipeline()

        let neutral = try pipeline.render(source, adjustments: .none)
        let plusOne = try pipeline.render(source, adjustments: ImageAdjustments(exposure: try Self.exposure(1)))
        let plusTwo = try pipeline.render(source, adjustments: ImageAdjustments(exposure: try Self.exposure(2)))

        #expect(neutral.processing.clippedHighSampleCount == 0)
        // Above 0.5: 0.6, 0.7, 0.8, 0.9, 0.55, 0.65, 0.85. Exactly 0.5 becomes
        // exactly 1 and is not clipped.
        #expect(plusOne.processing.clippedHighSampleCount == 7)
        // Above 0.25: all twelve.
        #expect(plusTwo.processing.clippedHighSampleCount == 12)
        #expect(plusTwo.processing.clippedHighSampleCount > neutral.processing.clippedHighSampleCount)
        #expect(plusTwo.processing.clippedLowSampleCount == 0)
    }

    // MARK: - Requested and rendered

    @Test(
        "The preview names the exposure requested and the exposure rendered, and they agree",
        arguments: [-10.0, -0.3, 0, 0.05, 1.25, 10]
    )
    func requestedAndRenderedAgree(ev: Double) throws {
        let preview = try WorkspacePreviewPipeline().render(
            Self.source(Self.values), adjustments: ImageAdjustments(exposure: try Self.exposure(ev))
        )
        #expect(preview.exposureAdjustment.ev == ev)
        #expect(preview.renderedExposureEV == ev)
        #expect(preview.processing.exposureApplied)
        #expect(!preview.processing.automaticExposureApplied)
        #expect(!preview.processing.toneMappingApplied)
        #expect(!preview.processing.highlightReconstructionApplied)
    }

    @Test("Rendering at several exposures leaves the retained source bit-identical")
    func theSourceSurvivesEveryExposure() throws {
        let source = Self.source(Self.values)
        let before = source.preview.values
        for ev in [-2.0, 0.5, 3, 0] {
            _ = try WorkspacePreviewPipeline().render(
                source, adjustments: ImageAdjustments(exposure: try Self.exposure(ev))
            )
        }
        #expect(zip(source.preview.values, before).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(!source.preview.processing.channelMixApplied)
    }

    // MARK: - All three adjustments together

    /// Channels, geometry and exposure, each checked against numbers computed
    /// independently of the stages that produced them.
    @Test("Mix, orientation and exposure together each do their own part")
    func allThreeTogether() throws {
        let width = 4
        let height = 3
        // Unique per pixel and channel; every value a binary fraction, and
        // doubled still below 1, so nothing clips and each byte is checkable.
        let preview = PreviewTestData.preview(width: width, height: height) { row, column, channel in
            Float(row * 16 + column * 4 + channel) / 128
        }
        let source = PreviewTestData.source(preview)
        let adjustments = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try Self.exposure(1)
        )

        let rendered = try WorkspacePreviewPipeline().render(source, adjustments: adjustments)

        // Geometry.
        #expect(rendered.pixelWidth == height)
        #expect(rendered.pixelHeight == width)
        #expect(rendered.effectiveOrientation == .rotated90Clockwise)

        // Provenance names all three decisions.
        #expect(rendered.userOrientationAdjustment == .quarterTurnRight)
        #expect(rendered.channelMixAdjustment == .redBlueSwap)
        #expect(rendered.processing.mixSource == .redBlueSwap)
        #expect(rendered.exposureAdjustment.ev == 1)
        #expect(rendered.renderedExposureEV == 1)
        #expect(rendered.processing.clippedSampleCount == 0)

        // The pixels, against a reference built from the source values alone:
        // destination (r, c) comes from source (h − 1 − c, r), red and blue
        // exchanged, doubled, then encoded at 0 EV.
        var expected: [UInt8] = []
        for row in 0..<width {
            for column in 0..<height {
                let original = try #require(preview.pixel(row: height - 1 - column, column: row))
                for value in [original.blue, original.green, original.red] {
                    expected.append(DisplayPreviewTestData.referenceSample(sceneLinear: value * 2, exposureEV: 0))
                }
            }
        }
        let byHand = try Self.byHand(
            source, mix: .redBlueSwap, orientation: .rotated90Clockwise, adjustments: adjustments
        )
        #expect(Self.bytes(byHand) == expected)
        #expect(
            WorkspaceStubs.pixelBytes(rendered.image)
                == WorkspaceStubs.pixelBytes(try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand))
        )
    }
}
