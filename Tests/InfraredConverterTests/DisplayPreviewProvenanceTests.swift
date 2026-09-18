import Testing
import Foundation
@testable import InfraredConverter

/// The display stage's processed wrapper: what it retains, and what changing
/// settings does and does not rerun.
///
/// Synthetic input throughout, built by running the whole application-owned
/// chain over a small mosaic — no fixture, so this runs everywhere.
@Suite("Display preview provenance")
struct DisplayPreviewProvenanceTests {

    /// A 4×4 RGGB mosaic whose samples are all distinct, so a wrapper holding
    /// the wrong buffer cannot coincidentally match the right one.
    private static func decoded() -> DecodedRAWMosaic {
        let width = 4
        let height = 4
        var samples = [UInt16]()
        for index in 0..<(width * height) {
            samples.append(UInt16(300 + index * 113))
        }
        let mosaic = RAWMosaic(
            width: width,
            height: height,
            bytesPerRow: width * 2,
            samples: samples.withUnsafeBufferPointer { Data(buffer: $0) },
            sampleFormat: .uint16,
            sourceRawBitDepth: 12,
            sensorColorLayout: RAWTestData.bayerLayout()
        )
        var metadata = RAWTestData.metadata()
        metadata.levels = .init(black: 0, perPlaneBlack: [0, 0, 0, 0], maximum: 4095)
        return DecodedRAWMosaic(
            url: URL(fileURLWithPath: "/tmp/display-provenance.orf"),
            metadata: metadata,
            mosaic: mosaic,
            processing: RAWMosaicProcessing(
                decoderIdentifier: "Stub",
                sourceStorage: .singleChannel,
                sourceRowPitch: width,
                destinationRowStride: width
            )
        )
    }

    /// The whole owned chain up to and including the creative mix.
    private static func mixed(
        mix: IRChannelMix = .identity
    ) throws -> IRChannelMixedProcessedRAWImage {
        let decoded = decoded()
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let balanced = try RAWWhiteBalancer().apply(
            to: normalized,
            gains: RAWWhiteBalanceGains(plane0: 2, plane1: 1, plane2: 3, plane3: 1.5)
        )
        let demosaiced = try RAWDemosaicer().demosaic(balanced)
        let working = try RAWWorkingColorConverter()
            .convert(demosaiced, using: .sensorRGBIdentityFalseColor)
        return try IRChannelMixer().apply(to: working, mix: mix)
    }

    /// The display stage's actual input: a mixed image that has been through
    /// the orientation stage. `.upright` is the default so the scene-linear
    /// values stay bit-identical to the mixed ones and the display assertions
    /// below are about the display stage alone.
    static func oriented(
        mix: IRChannelMix = .identity,
        orientation: RAWImageOrientation = .upright
    ) throws -> OrientedProcessedRAWImage {
        try ImageOrienter().apply(to: try mixed(mix: mix), orientation: orientation)
    }

    /// The display stage's actual input, as a wrapper: oriented, exposed and
    /// levelled, with every upstream state still reachable.
    static func leveled(
        mix: IRChannelMix = .identity,
        orientation: RAWImageOrientation = .upright,
        exposureEV: Double = 0,
        blackPoint: Double = 0,
        whitePoint: Double = 1
    ) throws -> LeveledProcessedRAWImage {
        try LinearLevelsApplier().apply(
            to: try SceneLinearExposer().apply(
                to: try oriented(mix: mix, orientation: orientation),
                exposure: SceneLinearExposure(ev: exposureEV)
            ),
            levels: LinearLevels(blackPoint: blackPoint, whitePoint: whitePoint)
        )
    }

    /// The display stage's actual input now: the levelled wrapper with the
    /// contrast curve applied over it.
    static func curved(
        mix: IRChannelMix = .identity,
        orientation: RAWImageOrientation = .upright,
        exposureEV: Double = 0,
        blackPoint: Double = 0,
        whitePoint: Double = 1,
        contrastAmount: Double = 0
    ) throws -> ToneCurvedProcessedRAWImage {
        try GlobalContrastApplier().apply(
            to: try leveled(
                mix: mix, orientation: orientation, exposureEV: exposureEV,
                blackPoint: blackPoint, whitePoint: whitePoint
            ),
            curve: GlobalContrastCurve(amount: contrastAmount)
        )
    }

    @Test("The display stage mints its wrapper over the exact state it consumed")
    func theStageMintsItsWrapper() throws {
        let curved = try Self.curved(
            mix: .redBlueSwap, orientation: .rotated90Clockwise
        )
        let oriented = curved.source.source.source
        let preview = try DisplayPreviewRenderer().render(
            curved, settings: DisplayPreviewTestData.settings
        )

        // Each hop reaches the state that actually produced the next one.
        #expect(preview.toneCurvedImage == curved.image)
        #expect(preview.leveledImage == curved.leveledImage)
        #expect(preview.exposedImage == curved.exposedImage)
        #expect(preview.orientedImage == oriented.image)
        #expect(preview.channelMixedImage == oriented.channelMixedImage)
        #expect(preview.workingColorImage == oriented.workingColorImage)
        #expect(preview.demosaicedImage == oriented.demosaicedImage)
        #expect(preview.whiteBalancedMosaic == oriented.whiteBalancedMosaic)
        #expect(preview.linearMosaic == oriented.linearMosaic)
        #expect(preview.url == oriented.url)
        #expect(preview.metadata == oriented.metadata)

        // The orientation is readable from the preview, and it is the geometry
        // stage's fact, not the display stage's.
        #expect(preview.orientation == .rotated90Clockwise)
        #expect(preview.processing.appliedOrientation == .rotated90Clockwise)
        #expect(preview.image.width == oriented.channelMixedImage.height)
        #expect(preview.image.height == oriented.channelMixedImage.width)

        // And the decoded UInt16 mosaic is reachable from the last wrapper
        // alone — now ten sources down, because exposure, levels and the
        // contrast curve each added a link to the chain.
        #expect(
            preview.source.source.source.source.source.source.source.source.source
                .source.mosaic == Self.decoded().mosaic
        )
    }

    @Test("The whole chain is readable back from the rendered preview")
    func theChainIsReadableFromTheResult() throws {
        let curved = try Self.curved(
            mix: .redBlueSwap, exposureEV: 1.5, contrastAmount: 0.25
        )
        let settings = DisplayPreviewTestData.settings
        let preview = try DisplayPreviewRenderer().render(curved, settings: settings)
        let processing = preview.processing

        #expect(processing.settings == settings)
        #expect(preview.settings == settings)
        // The exposure and the levels are readable from the preview, and they
        // are the upstream stages' facts rather than the display stage's.
        #expect(processing.exposureEV == 1.5)
        #expect(processing.exposureApplied)
        #expect(processing.levelsApplied)
        #expect(processing.blackPoint == 0)
        #expect(processing.whitePoint == 1)
        // And so is the contrast curve, one stage further down.
        #expect(processing.contrastApplied)
        #expect(processing.toneCurveApplied)
        #expect(processing.contrastAmount == 0.25)
        #expect(!processing.preservesLinearLightEncoding)
        #expect(!processing.histogramRead)
        #expect(!processing.automaticContrastApplied)
        #expect(!processing.localContrastApplied)
        #expect(processing.mixSource == .redBlueSwap)
        #expect(preview.mix == .redBlueSwap)
        #expect(processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
        #expect(preview.cameraToWorkingTransform == .sensorRGBIdentityFalseColor)
        #expect(processing.demosaicAlgorithm == .bilinearBayer)
        #expect(processing.whiteBalanceGains
            == RAWWhiteBalanceGains(plane0: 2, plane1: 1, plane2: 3, plane3: 1.5))
        #expect(processing.blackLevelSubtracted)
        #expect(processing.normalized)
        #expect(processing.orientationApplied)
        #expect(processing.appliedOrientation == .upright)
        #expect(!processing.orientationSwappedDimensions)
        #expect(
            processing.channelMixProcessing.workingColorProcessing
                .demosaicProcessing.whiteBalanceProcessing.linearProcessing.whiteLevel == 4095
        )
        #expect(preview.metadata.identity.model == "E-PL3")
        #expect(preview.url.lastPathComponent == "display-provenance.orf")
    }

    @Test("A wrapper forwards its own image's provenance, never a second copy")
    func provenanceIsForwardedNotCopied() throws {
        let preview = try DisplayPreviewRenderer().render(
            try Self.curved(), settings: DisplayPreviewTestData.settings
        )
        #expect(preview.processing == preview.image.processing)
        #expect(preview.settings == preview.image.processing.settings)
    }

    // MARK: - Reprocessing

    /// Changing an adjustment must re-render from the state above it, not from
    /// the previous preview. Rendering an encoded buffer again would apply the
    /// transfer function twice and could not recover a clipped highlight —
    /// and would look entirely plausible.
    ///
    /// The exposure is the adjustment that moved: it used to be a display
    /// setting, so "re-render with new settings" was how it was changed. It is
    /// now a stage of its own, so the wrapper that replaces it is the
    /// exposer's, and it reaches through to the **oriented** image.
    @Test("Changing the exposure re-renders from the same oriented image")
    func changingTheExposureRestartsFromTheOrientedImage() throws {
        let oriented = try Self.oriented()
        let exposer = SceneLinearExposer()
        let leveler = LinearLevelsApplier()
        let renderer = DisplayPreviewRenderer()
        let settings = DisplayPreviewTestData.settings

        func preview(
            _ exposed: ExposedProcessedRAWImage
        ) throws -> DisplayPreviewProcessedRAWImage {
            try renderer.render(
                try GlobalContrastApplier().apply(
                    to: try leveler.apply(to: exposed, levels: .neutral),
                    curve: .neutral
                ),
                settings: settings
            )
        }

        let neutralExposure = try exposer.apply(to: oriented, exposure: .neutral)
        let brightExposure = try exposer.apply(
            exposure: SceneLinearExposure(ev: 1), replacing: neutralExposure
        )
        let backToNeutralExposure = try exposer.apply(
            exposure: .neutral, replacing: brightExposure
        )

        let neutral = try preview(neutralExposure)
        let brightened = try preview(brightExposure)
        let backToNeutral = try preview(backToNeutralExposure)

        // Round-tripping through +1 EV returns exactly the original bytes,
        // which chaining could not do.
        #expect(backToNeutral.image.bytes == neutral.image.bytes)
        #expect(brightened.image.bytes != neutral.image.bytes)

        // Going up a stop from the previous result is not the same as going up
        // two stops from the source, which is the other thing chaining would
        // break.
        let twoStops = try preview(
            try exposer.apply(to: oriented, exposure: SceneLinearExposure(ev: 2))
        )
        let secondStop = try preview(
            try exposer.apply(
                exposure: SceneLinearExposure(ev: 1), replacing: brightExposure
            )
        )
        #expect(secondStop.image.bytes == brightened.image.bytes)
        #expect(secondStop.image.bytes != twoStops.image.bytes)

        // The earlier result is untouched, and every source is still the same
        // buffer.
        #expect(neutral.processing.exposureEV == 0)
        #expect(brightened.channelMixedImage == neutral.channelMixedImage)
        #expect(backToNeutral.channelMixedImage == oriented.channelMixedImage)
        #expect(backToNeutral.orientedImage == oriented.image)
    }

    /// The same claim for the levels, through their own replacing overload:
    /// `L2` after `L1` renders `L2(exposed)`, never `L2(L1(exposed))`.
    @Test("Changing the levels re-renders from the same exposed image")
    func changingTheLevelsRestartsFromTheExposedImage() throws {
        let exposed = try SceneLinearExposer().apply(
            to: try Self.oriented(), exposure: .neutral
        )
        let leveler = LinearLevelsApplier()
        let renderer = DisplayPreviewRenderer()
        let settings = DisplayPreviewTestData.settings

        // The renderer's input is the curved wrapper; the curve is neutral
        // throughout, so this suite's subject stays the levels.
        func rendered(_ leveled: LeveledProcessedRAWImage) throws
            -> DisplayPreviewProcessedRAWImage {
            try renderer.render(
                try GlobalContrastApplier().apply(to: leveled, curve: .neutral),
                settings: settings
            )
        }

        let neutral = try leveler.apply(to: exposed, levels: .neutral)
        let lifted = try leveler.apply(
            levels: LinearLevels(blackPoint: 0.1, whitePoint: 0.9), replacing: neutral
        )
        let back = try leveler.apply(levels: .neutral, replacing: lifted)

        #expect(try rendered(back).image.bytes == (try rendered(neutral)).image.bytes)
        #expect(try rendered(lifted).image.bytes != (try rendered(neutral)).image.bytes)

        // A second levels setting applied to the first result is the second
        // setting over the exposed image, not the composition of the two.
        let second = LinearLevels(blackPoint: 0.2, whitePoint: 1.5)
        let fromFirst = try leveler.apply(levels: second, replacing: lifted)
        let fromExposed = try leveler.apply(to: exposed, levels: second)
        #expect(fromFirst.image.values == fromExposed.image.values)

        // And the exposed buffer underneath was never touched.
        #expect(back.exposedImage.values == exposed.image.values)
        #expect(lifted.exposedImage.values == exposed.image.values)
    }

    /// Nothing upstream reruns: the re-rendered result carries the identical
    /// upstream values, not equal-looking recomputed ones.
    @Test("Re-rendering reruns no upstream stage")
    func reRenderingRerunsNothingUpstream() throws {
        let oriented = try Self.oriented(mix: .redBlueSwap)
        let exposer = SceneLinearExposer()

        let first = try exposer.apply(to: oriented, exposure: .neutral)
        let second = try exposer.apply(
            exposure: SceneLinearExposure(ev: -1), replacing: first
        )

        // The same oriented buffer, bit for bit — not a re-oriented one.
        #expect(second.orientedImage.values == oriented.image.values)
        for index in 0..<oriented.image.values.count
        where second.orientedImage.values[index].bitPattern
            != oriented.image.values[index].bitPattern {
            Issue.record("scene-linear element \(index) changed")
        }
        // And every upstream state is the identical value, not a rebuilt one.
        #expect(second.channelMixedImage == oriented.channelMixedImage)
        #expect(second.workingColorImage == oriented.workingColorImage)
        #expect(second.demosaicedImage == oriented.demosaicedImage)
        #expect(second.whiteBalancedMosaic == oriented.whiteBalancedMosaic)
        #expect(second.linearMosaic == oriented.linearMosaic)
        #expect(second.mix == .redBlueSwap)
        #expect(second.processing.demosaicAlgorithm == .bilinearBayer)
    }

    /// The mix stays where it belongs: changing a display setting does not
    /// touch it, and changing the mix does not require a new renderer.
    @Test("Display settings and the creative mix change independently")
    func displaySettingsAndTheMixAreIndependent() throws {
        let mixed = try Self.mixed(mix: .identity)
        let orienter = ImageOrienter()
        let renderer = DisplayPreviewRenderer()
        let settings = DisplayPreviewTestData.settings

        func preview(
            _ mixed: IRChannelMixedProcessedRAWImage
        ) throws -> DisplayPreviewProcessedRAWImage {
            try renderer.render(
                try GlobalContrastApplier().apply(
                    to: try LinearLevelsApplier().apply(
                        to: try SceneLinearExposer().apply(
                            to: try orienter.apply(to: mixed, orientation: .upright),
                            exposure: .neutral
                        ),
                        levels: .neutral
                    ),
                    curve: .neutral
                ),
                settings: settings
            )
        }

        let identityPreview = try preview(mixed)
        #expect(identityPreview.mix == .identity)

        // A different mix is a different upstream result, oriented the same
        // way and rendered by the same renderer with the same settings.
        let swappedPreview = try preview(
            try IRChannelMixer().apply(mix: .redBlueSwap, replacing: mixed)
        )

        #expect(swappedPreview.settings == identityPreview.settings)
        #expect(swappedPreview.mix == .redBlueSwap)
        #expect(swappedPreview.workingColorImage == identityPreview.workingColorImage)
        // The pixels differ because the mix differed, not because anything in
        // the display stage did.
        #expect(swappedPreview.image.bytes != identityPreview.image.bytes)
    }
}
