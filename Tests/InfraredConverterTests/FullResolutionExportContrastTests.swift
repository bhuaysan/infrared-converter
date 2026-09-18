import Testing
import Foundation
@testable import InfraredConverter

/// Contrast on the full-resolution export path.
///
/// The claim under test is that preview and export are the **same rendering**:
/// the export applies the user's contrast through the same stage, in the same
/// place, with the same arithmetic, and diverges only at resolution, range
/// policy, bit depth and destination.
///
/// The expectations are computed here from the specification rather than by
/// calling `GlobalContrastCurve` twice.
@Suite("Full-resolution export contrast")
struct FullResolutionExportContrastTests {

    private static let url = URL(fileURLWithPath: "/tmp/synthetic-export-contrast.orf")

    /// One ULP of `Float32` at unit magnitude, give or take. The arithmetic is
    /// carried in `Double` and narrowed once.
    private static let tolerance: Float = 1e-6

    /// The curve, from the specification.
    private static func reference(_ value: Float, amount: Double) -> Float {
        guard value > 0, value < 1 else { return value }
        let k = exp2(amount)
        let x = Double(value)
        return Float(pow(x, k) / (pow(x, k) + pow(1 - x, k)))
    }

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

    private static func contrast(_ amount: Double) throws -> UserContrastAdjustment {
        try UserContrastAdjustment(amount: amount)
    }

    // MARK: - The pre-encoding values

    /// The proof the milestone asks for: the exported values **before any
    /// encoding** are exactly the curve applied to the levelled values.
    ///
    /// Both sides come from the same export request, so the levelled image is
    /// not re-derived here — only the equation is.
    @Test(
        "The exported pre-encoding values are exactly the curve equation",
        arguments: [-1.0, -0.5, 0.35, 1.0]
    )
    func preEncodingValuesFollowTheEquation(amount: Double) throws {
        let levelledOnly = try Self.render(ImageAdjustments())
        let curved = try Self.render(
            ImageAdjustments(contrast: try Self.contrast(amount))
        )

        #expect(curved.image.values.count == levelledOnly.image.values.count)
        #expect(curved.image.width == levelledOnly.image.width)
        #expect(curved.image.height == levelledOnly.image.height)

        for (offset, levelled) in levelledOnly.image.values.enumerated() {
            let expected = Self.reference(levelled, amount: amount)
            #expect(
                abs(curved.image.values[offset] - expected) <= Self.tolerance,
                "element \(offset)"
            )
        }
    }

    /// Nothing clips before the encoder: values the curve leaves outside the
    /// unit interval reach it with their magnitudes.
    @Test("Out-of-range values reach the encoder intact")
    func outOfRangeValuesSurviveToTheEncoder() throws {
        // A black point above the frame's darkest values guarantees negatives,
        // and a white point below its brightest guarantees values above one.
        let rendered = try Self.render(
            ImageAdjustments(
                levels: try UserLevelsAdjustment(blackPoint: 0.2, whitePoint: 0.6),
                contrast: try Self.contrast(1)
            )
        )

        #expect(rendered.image.values.contains { $0 < 0 })
        #expect(rendered.image.values.contains { $0 > 1 })
        #expect(!rendered.image.processing.clamped)
        // Distinct out-of-range values are still distinct.
        let negatives = Set(rendered.image.values.filter { $0 < 0 })
        #expect(negatives.count > 1)
    }

    // MARK: - Provenance

    @Test("The export records the contrast it applied, and what it did not do")
    func theExportRecordsTheContrast() throws {
        let rendered = try Self.render(
            ImageAdjustments(contrast: try Self.contrast(0.35))
        )

        #expect(rendered.contrastAmount == 0.35)
        #expect(rendered.contrastExponent == exp2(0.35))
        #expect(rendered.contrastCurve == GlobalContrastCurve(amount: 0.35))
        #expect(rendered.image.processing.contrastApplied)
        #expect(rendered.image.processing.toneCurveApplied)

        // No longer linear-light, and the record says so rather than leaving
        // it to be inferred from the amount.
        #expect(!rendered.image.processing.linearLightEncoded)
        #expect(!rendered.image.processing.preservesLinearLightEncoding)
        #expect(!rendered.image.processing.sceneLinear)
        // The levels stage's own record, one link upstream, still claims it.
        #expect(rendered.image.processing.levelsProcessing.linearLightEncoded)

        // What it is not.
        #expect(!rendered.image.processing.clamped)
        #expect(!rendered.image.processing.histogramRead)
        #expect(!rendered.image.processing.automaticContrastApplied)
        #expect(!rendered.image.processing.localContrastApplied)
        #expect(!rendered.image.processing.perChannelCurveApplied)
        #expect(!rendered.image.processing.toneMappingApplied)
        #expect(!rendered.image.processing.gammaApplied)
        #expect(!rendered.image.processing.displayEncodingApplied)
        #expect(!rendered.image.processing.quantized)
        #expect(!rendered.image.processing.reducedForPreview)

        // And the request's own record still names the amount.
        #expect(rendered.request.adjustments.contrast.amount == 0.35)
        #expect(rendered.request.state.adjustments.contrast.amount == 0.35)
    }

    @Test("The encoded export carries the contrast provenance through")
    func theEncodedExportCarriesTheContrast() throws {
        let rendered = try Self.render(
            ImageAdjustments(contrast: try Self.contrast(-0.6))
        )
        let encoded = try FullResolutionExportPipeline().encode(rendered)

        #expect(encoded.processing.contrastApplied)
        #expect(encoded.processing.toneCurveApplied)
        #expect(encoded.processing.contrastAmount == -0.6)
        #expect(encoded.processing.contrastExponent == exp2(-0.6))
        #expect(!encoded.processing.preservesLinearLightEncoding)
        #expect(!encoded.processing.histogramRead)
        #expect(!encoded.processing.automaticContrastApplied)
        #expect(!encoded.processing.localContrastApplied)
        // The levels beneath it are still readable.
        #expect(encoded.processing.levelsApplied)
    }

    // MARK: - Neutral contrast is the pre-milestone export

    /// The migration's claim, checked on the export path: a photograph with
    /// neutral contrast exports the samples it exported before this milestone.
    @Test("Neutral contrast exports exactly the pre-milestone samples")
    func neutralContrastIsPixelNeutral() throws {
        let adjustments = ImageAdjustments(
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 0.5),
            levels: try UserLevelsAdjustment(blackPoint: 0.05, whitePoint: 0.95)
        )
        let rendered = try Self.render(adjustments)
        let encoded = try FullResolutionExportPipeline().encode(rendered)

        // The same chain, stopping at the levels — what a build with no
        // contrast stage produced.
        let prepared = try RAWWorkingImagePipeline().prepare(
            decoding: Self.url,
            using: Self.decoder(),
            whiteBalance: adjustments.whiteBalance,
            cameraToWorkingTransform: IRCaptureProfile.builtinUncalibrated
                .cameraToWorkingTransform
        )
        let mixed = try IRChannelMixer().apply(
            to: prepared.image, mix: adjustments.channelMix.mix
        )
        let oriented = try ImageOrienter().apply(
            to: mixed,
            orientation: try RAWWorkingImagePipeline.effectiveOrientation(
                for: prepared.metadata, adjustments: adjustments
            ).applied
        )
        let exposed = try SceneLinearExposer().apply(
            to: oriented, exposure: SceneLinearExposure(adjustments.exposure)
        )
        let levelled = try LinearLevelsApplier().apply(
            to: exposed, levels: LinearLevels(adjustments.levels)
        )

        // The contrast stage handed the buffer straight through, bit for bit.
        #expect(rendered.image.values == levelled.values)
        for index in 0..<levelled.values.count
        where rendered.image.values[index].bitPattern != levelled.values[index].bitPattern {
            Issue.record("element \(index) changed bit pattern at neutral contrast")
        }

        let preMilestone = try ExportImageEncoder().encode(
            try GlobalContrastApplier().apply(to: levelled, curve: .neutral),
            settings: FullResolutionExportPipeline.settings
        )
        #expect(encoded.samples == preMilestone.samples)
    }

    // MARK: - Contrast applies after every mix, uniformly

    /// No special path for any channel mix: the curve is applied after all of
    /// them, identically.
    @Test(
        "The curve follows every kind of mix, with no special case",
        arguments: [
            UserChannelMixAdjustment.identity,
            UserChannelMixAdjustment.redBlueSwap,
        ]
    )
    func theCurveFollowsEveryMix(mix: UserChannelMixAdjustment) throws {
        let amount = 0.5
        let withoutCurve = try Self.render(ImageAdjustments(channelMix: mix))
        let withCurve = try Self.render(
            ImageAdjustments(channelMix: mix, contrast: try Self.contrast(amount))
        )

        for (offset, value) in withoutCurve.image.values.enumerated() {
            #expect(
                abs(withCurve.image.values[offset] - Self.reference(value, amount: amount))
                    <= Self.tolerance,
                "element \(offset)"
            )
        }
        #expect(withCurve.mix == withoutCurve.mix)
    }

    /// An explicit authored matrix and a monochrome mix are the same case —
    /// both are `.explicit` — and the curve follows them the same way.
    @Test("The curve follows an authored and a monochrome matrix identically")
    func theCurveFollowsAnAuthoredMatrix() throws {
        let authored = UserChannelMixAdjustment.explicit(
            try RAWColorMatrix3x3(
                m00: 0.2, m01: 0.7, m02: 0.1,
                m10: 0.1, m11: 0.8, m12: 0.1,
                m20: 0.3, m21: 0.3, m22: 0.4
            )
        )
        let monochrome = UserChannelMixAdjustment.explicit(
            try IRMonochromeMix(red: 1.0 / 3, green: 1.0 / 3, blue: 1.0 / 3).matrix()
        )
        let amount = -0.45

        for mix in [authored, monochrome] {
            let withoutCurve = try Self.render(ImageAdjustments(channelMix: mix))
            let withCurve = try Self.render(
                ImageAdjustments(channelMix: mix, contrast: try Self.contrast(amount))
            )
            for (offset, value) in withoutCurve.image.values.enumerated() {
                #expect(
                    abs(withCurve.image.values[offset]
                        - Self.reference(value, amount: amount)) <= Self.tolerance,
                    "element \(offset)"
                )
            }
        }
    }

    // MARK: - The error surface

    /// The contrast stage has its own case in the export's error type, so a
    /// failure there is distinguishable from a failure in the mix, the
    /// orientation, the exposure or the levels.
    ///
    /// Asserted as a surface rather than provoked, for the reason the levels
    /// case is: `UserContrastAdjustment` refuses every inapplicable amount at
    /// construction, and `ImageAdjustments` can only hold one of those.
    @Test("The export error type names the contrast stage")
    func theErrorSurfaceNamesTheContrastStage() {
        let stage = FullResolutionExportError.AdjustmentStage.contrast
        #expect(stage.rawValue == "contrast")
        #expect(stage.diagnosticDescription.isEmpty == false)

        let error = FullResolutionExportError.adjustmentProcessingFailed(
            stage: .contrast,
            underlying: GlobalContrastError.nonApplicableContrast(
                amount: .infinity, exponent: .infinity
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
        #expect(describe(.contrast) == "contrast")
    }

    // MARK: - Preview and export agree

    /// The parity claim end to end: the same RAW file and the same complete
    /// adjustments, rendered both ways, agree about the contrast that was
    /// applied — and differ only where the architecture says they may.
    @Test("Preview and export apply the same curve to the same file")
    func previewAndExportAgree() throws {
        let adjustments = ImageAdjustments(
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: -0.25),
            levels: try UserLevelsAdjustment(blackPoint: 0.02, whitePoint: 0.98),
            contrast: try Self.contrast(0.4)
        )

        let exported = try Self.render(adjustments)
        let preview = try WorkspacePreviewPipeline().render(
            decoding: Self.url,
            using: Self.decoder(),
            adjustments: adjustments
        )

        #expect(preview.renderedContrastCurve == exported.contrastCurve)
        #expect(preview.processing.contrastAmount == exported.contrastAmount)
        #expect(preview.processing.contrastExponent == exported.contrastExponent)
        #expect(preview.contrastAdjustment == adjustments.contrast)
        // And the export is not a preview: it is full resolution, and says so.
        #expect(!exported.image.processing.reducedForPreview)
        #expect(exported.image.width == preview.fullResolutionSourcePixelWidth)
    }
}
