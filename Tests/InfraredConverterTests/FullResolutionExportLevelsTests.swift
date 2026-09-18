import Testing
import Foundation
@testable import InfraredConverter

/// Levels on the full-resolution export path.
///
/// The claim under test is that preview and export are the **same rendering**:
/// the export applies the user's black and white points through the same
/// stage, in the same place, with the same arithmetic, and diverges only at
/// resolution, range policy, bit depth and destination.
///
/// The expectations are computed here from the specification rather than by
/// calling `LinearLevels` twice.
@Suite("Full-resolution export levels")
struct FullResolutionExportLevelsTests {

    private static let url = URL(fileURLWithPath: "/tmp/synthetic-export-levels.orf")

    /// One ULP of `Float32` at unit magnitude, give or take. The arithmetic is
    /// carried in `Double` and narrowed once, so an exact decimal endpoint is
    /// already an approximation before the stage sees it.
    private static let tolerance: Float = 1e-6

    private static func decoder(
        width: Int = 8, height: Int = 6
    ) -> WorkspaceStubDecoder {
        WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url, width: width, height: height))
        )
    }

    private static func render(
        _ adjustments: ImageAdjustments, width: Int = 8, height: Int = 6
    ) throws -> FullResolutionExportRender {
        try FullResolutionExportPipeline().render(
            ExportRequest(rawURL: url, adjustments: adjustments),
            using: decoder(width: width, height: height)
        )
    }

    private static func levels(
        _ black: Double, _ white: Double
    ) throws -> UserLevelsAdjustment {
        try UserLevelsAdjustment(blackPoint: black, whitePoint: white)
    }

    // MARK: - The pre-encoding values

    /// The proof the milestone asks for: with black `0.1` and white `0.9`, the
    /// exported values **before any encoding** are exactly the levels equation
    /// applied to the exposed values.
    ///
    /// Both sides come from the same export request, so the exposed image is
    /// not re-derived here — only the equation is.
    @Test("The exported pre-encoding values are exactly the levels equation")
    func preEncodingValuesFollowTheEquation() throws {
        let pair = try Self.levels(0.1, 0.9)
        let exposedOnly = try Self.render(ImageAdjustments())
        let levelled = try Self.render(ImageAdjustments(levels: pair))

        #expect(levelled.image.values.count == exposedOnly.image.values.count)
        #expect(levelled.image.width == exposedOnly.image.width)
        #expect(levelled.image.height == exposedOnly.image.height)

        for (offset, exposed) in exposedOnly.image.values.enumerated() {
            // Written out from the specification, not from `LinearLevels`.
            let expected = Float((Double(exposed) - 0.1) * (1 / 0.8))
            #expect(
                abs(levelled.image.values[offset] - expected) <= Self.tolerance,
                "element \(offset)"
            )
        }
    }

    /// Nothing clips before the encoder. A black point of `0.1` on a frame
    /// with values below it produces negative scene values in the render, and
    /// they survive with their magnitudes.
    @Test("Out-of-range levelled values reach the encoder intact")
    func outOfRangeValuesSurviveToTheEncoder() throws {
        let rendered = try Self.render(
            ImageAdjustments(levels: try Self.levels(0.25, 0.5))
        )
        #expect(!rendered.image.processing.clamped)
        // A white point of 0.5 on values that reach beyond it, and a black
        // point of 0.25 on values below it, must put something outside 0…1 in
        // at least one direction — otherwise this test proves nothing.
        let outside = rendered.image.values.filter { $0 < 0 || $0 > 1 }
        #expect(!outside.isEmpty)
        #expect(outside.allSatisfy { $0.isFinite })
    }

    // MARK: - The encoded samples

    /// The encoded samples then follow the existing destination policy — the
    /// export's own clip, the shared transfer function and 16-bit
    /// quantisation — with the levels already in the value.
    @Test("The encoded samples follow the export's own clipping and encoding")
    func encodedSamplesFollowTheDestinationPolicy() throws {
        let pipeline = FullResolutionExportPipeline()
        let pair = try Self.levels(0.1, 0.9)
        let rendered = try pipeline.render(
            ExportRequest(rawURL: Self.url, adjustments: ImageAdjustments(levels: pair)),
            using: Self.decoder()
        )
        let encoded = try pipeline.encode(rendered)

        // Computed from the specification, from the levelled values.
        for (offset, levelled) in rendered.image.values.enumerated() {
            #expect(
                encoded.samples[offset]
                    == ExportTestData.referenceSample(sceneLinear: levelled),
                "sample \(offset)"
            )
        }
        #expect(encoded.processing.levelsApplied)
        #expect(encoded.processing.blackPoint == 0.1)
        #expect(encoded.processing.whitePoint == 0.9)
        #expect(encoded.processing.rangePolicy == .hardClipToExportRange)
        #expect(encoded.processing.encoding == .sRGB)
        #expect(!encoded.processing.reducedForPreview)
    }

    /// And end to end from the scene-linear source, in one expression: expose,
    /// level, clip, encode, quantise, all written from the specification.
    @Test("The whole per-component chain matches the specification end to end")
    func theWholeChainMatchesTheSpecification() throws {
        let pipeline = FullResolutionExportPipeline()
        let adjustments = ImageAdjustments(
            exposure: try UserExposureAdjustment(ev: 0.5),
            levels: try Self.levels(0.05, 1.2)
        )
        // The scene-linear source, at 0 EV and neutral levels — both of which
        // are the identity, so these are the values the working-colour stage
        // produced.
        let scene = try pipeline.render(
            ExportRequest(rawURL: Self.url, adjustments: .none), using: Self.decoder()
        )
        let encoded = try pipeline.encode(
            try pipeline.render(
                ExportRequest(rawURL: Self.url, adjustments: adjustments),
                using: Self.decoder()
            )
        )

        for (offset, sceneLinear) in scene.image.values.enumerated() {
            #expect(
                encoded.samples[offset]
                    == ExportTestData.referenceSample(
                        sceneLinear: sceneLinear,
                        exposureEV: 0.5,
                        blackPoint: 0.05,
                        whitePoint: 1.2
                    ),
                "sample \(offset)"
            )
        }
    }

    // MARK: - Neutrality

    /// Neutral levels export byte-identically to the pre-milestone behaviour.
    /// The buffers are compared, not merely the settings.
    @Test("Neutral levels export exactly what no levels stage would have exported")
    func neutralLevelsAreTheIdentity() throws {
        let pipeline = FullResolutionExportPipeline()
        let base = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 0.75)
        )
        var explicit = base
        explicit.levels = .neutral

        let a = try pipeline.render(
            ExportRequest(rawURL: Self.url, adjustments: base), using: Self.decoder()
        )
        let b = try pipeline.render(
            ExportRequest(rawURL: Self.url, adjustments: explicit), using: Self.decoder()
        )

        #expect(a.image.values == b.image.values)
        for index in 0..<a.image.values.count
        where a.image.values[index].bitPattern != b.image.values[index].bitPattern {
            Issue.record("element \(index) differs bit for bit")
        }
        #expect(try pipeline.encode(a).samples == (try pipeline.encode(b).samples))

        // The neutral pair is the identity on the exposed values themselves,
        // which is the claim the migration rests on.
        let exposed = try SceneLinearExposer().apply(
            to: DisplayPreviewTestData.image(
                width: 2, height: 1, values: [-0.25, 0, 0.5, 1, 1.5, 3]
            ),
            exposure: .neutral
        )
        let levelled = try LinearLevelsApplier().apply(to: exposed, levels: .neutral)
        #expect(levelled.values == exposed.values)
    }

    // MARK: - No special path for any mix

    /// Levels apply identically after identity, a red/blue swap, an arbitrary
    /// explicit matrix and a monochrome explicit matrix. There is no infrared
    /// path and no monochrome path: each case is checked against the equation
    /// applied to *that* mix's own exposed output.
    @Test(
        "Levels apply identically after every kind of channel mix",
        arguments: [0, 1, 2, 3]
    )
    func levelsAreIndependentOfTheMix(index: Int) throws {
        let mixes: [UserChannelMixAdjustment] = [
            .identity,
            .redBlueSwap,
            .explicit(
                try RAWColorMatrix3x3(
                    m00: 1.5, m01: -0.25, m02: 0.125,
                    m10: 0.25, m11: 0.75, m12: 0.5,
                    m20: -0.5, m21: 0.25, m22: 1.25
                )
            ),
            // Monochrome: three identical rows, which is what makes the result
            // achromatic by arithmetic rather than by a mode.
            .explicit(
                try RAWColorMatrix3x3(
                    m00: 0.5, m01: 0.25, m02: 0.25,
                    m10: 0.5, m11: 0.25, m12: 0.25,
                    m20: 0.5, m21: 0.25, m22: 0.25
                )
            ),
        ]
        let mix = mixes[index]
        let pair = try Self.levels(0.1, 0.9)

        let unlevelled = try Self.render(ImageAdjustments(channelMix: mix))
        let levelled = try Self.render(ImageAdjustments(channelMix: mix, levels: pair))

        for (offset, exposed) in unlevelled.image.values.enumerated() {
            let expected = Float((Double(exposed) - 0.1) * (1 / 0.8))
            #expect(
                abs(levelled.image.values[offset] - expected) <= Self.tolerance,
                "mix \(index), element \(offset)"
            )
        }
        #expect(levelled.image.processing.mix == mix.mix)
        #expect(levelled.blackPoint == 0.1)
    }

    // MARK: - Provenance

    @Test("The export records the levels it applied, and what it did not do")
    func provenanceRecordsTheLevels() throws {
        let rendered = try Self.render(
            ImageAdjustments(levels: try Self.levels(0.05, 1.2))
        )

        #expect(rendered.blackPoint == 0.05)
        #expect(rendered.whitePoint == 1.2)
        #expect(rendered.levels == LinearLevels(blackPoint: 0.05, whitePoint: 1.2))
        #expect(rendered.image.processing.levelsApplied)
        // The rendered image is now the contrast stage's output, and a tone
        // curve has been evaluated on it — so it makes no linear-light claim.
        // The levels stage's own record, one link upstream, still does.
        #expect(!rendered.image.processing.linearLightEncoded)
        #expect(rendered.image.processing.levelsProcessing.linearLightEncoded)
        // Not scene-linear any more, and the record says so rather than
        // leaving it to be inferred from the black point.
        #expect(!rendered.image.processing.sceneLinear)
        #expect(!rendered.image.processing.preservesProportionalityToSceneRadiance)
        #expect(!rendered.image.processing.clamped)
        #expect(!rendered.image.processing.toneMappingApplied)
        #expect(!rendered.image.processing.automaticLevelsApplied)
        #expect(!rendered.image.processing.perChannelLevelsApplied)
        #expect(!rendered.image.processing.reducedForPreview)
        // And the request's own record still names the pair.
        #expect(rendered.request.adjustments.levels.blackPoint == 0.05)
        #expect(rendered.request.state.adjustments.levels.whitePoint == 1.2)
    }

    /// The levels stage has its own case in the export's error type, so a
    /// failure there is distinguishable from a failure in the mix, the
    /// orientation or the exposure.
    ///
    /// It is asserted as a surface rather than provoked. `UserLevelsAdjustment`
    /// refuses every inapplicable pair at construction, and `ImageAdjustments`
    /// can only hold one of those — so there is no honest way to reach the
    /// stage's refusal through the public adjustment type, and manufacturing
    /// one would be testing a state the application cannot be in.
    @Test("The export error type names the levels stage")
    func theErrorSurfaceNamesTheLevelsStage() {
        let stage = FullResolutionExportError.AdjustmentStage.levels
        #expect(stage.rawValue == "levels")
        #expect(stage.diagnosticDescription.isEmpty == false)

        let error = FullResolutionExportError.adjustmentProcessingFailed(
            stage: .levels,
            underlying: LinearLevelsError.nonApplicableLevels(
                blackPoint: 1, whitePoint: 0, span: -1, scale: -1
            )
        )
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.failureReason?.contains(stage.diagnosticDescription) == true)

        // Written as an exhaustive switch, so adding a stage without deciding
        // what it is called fails to compile here.
        func describe(_ stage: FullResolutionExportError.AdjustmentStage) -> String {
            switch stage {
            case .channelMix: return "mix"
            case .orientation: return "orientation"
            case .exposure: return "exposure"
            case .levels: return "levels"
            case .contrast: return "contrast"
            }
        }
        #expect(describe(.levels) == "levels")
    }

    // MARK: - Preview and export share the stage

    /// The parity claim, made where it is strongest: at the **shared
    /// pre-destination value**, before either quantisation can hide a
    /// difference.
    ///
    /// Both encoders take a `ToneCurvedRGBImage`. Building one and handing it
    /// to each in turn is not a comparison of two pipelines but a comparison
    /// of two destinations, which is exactly what the architecture claims they
    /// are.
    @Test("Both destinations consume the same levelled value, and only encode it differently")
    func bothDestinationsShareTheLevelledValue() throws {
        let values: [Float] = [-0.25, 0, 0.125, 0.5, 0.9, 1, 1.5, 0.25, 0.75]
        let levelled = try GlobalContrastApplier().apply(
            to: try LinearLevelsApplier().apply(
                to: try SceneLinearExposer().apply(
                    to: DisplayPreviewTestData.image(width: 3, height: 1, values: values),
                    exposure: SceneLinearExposure(ev: 0.5)
                ),
                levels: LinearLevels(blackPoint: 0.1, whitePoint: 0.9)
            ),
            curve: .neutral
        )

        let preview = try DisplayPreviewRenderer().render(
            levelled, settings: DisplayRenderSettings.standard
        )
        let exported = try ExportImageEncoder().encode(
            levelled, settings: ExportRenderSettings.standard
        )

        // The same clip, counted identically: the two range policies differ in
        // name and destination, not in what they do to the unit range.
        #expect(preview.processing.clippedLowSampleCount
            == exported.processing.clippedLowSampleCount)
        #expect(preview.processing.clippedHighSampleCount
            == exported.processing.clippedHighSampleCount)

        // The same levels, read from each destination's own record.
        #expect(preview.processing.blackPoint == exported.processing.blackPoint)
        #expect(preview.processing.whitePoint == exported.processing.whitePoint)
        #expect(preview.processing.exposureEV == exported.processing.exposureEV)

        // And each sample follows its own bit depth's quantisation of the same
        // encoded value, computed here from the specification.
        for (offset, value) in levelled.values.enumerated() {
            #expect(
                preview.bytes[offset]
                    == DisplayPreviewTestData.referenceSample(sceneLinear: value, exposureEV: 0)
            )
            #expect(
                exported.samples[offset]
                    == ExportTestData.referenceSample(sceneLinear: value)
            )
        }
    }
}
