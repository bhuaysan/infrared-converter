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

    @Test("The display stage mints its wrapper over the exact state it consumed")
    func theStageMintsItsWrapper() throws {
        let oriented = try Self.oriented(mix: .redBlueSwap, orientation: .rotated90Clockwise)
        let preview = try DisplayPreviewRenderer().render(
            oriented, settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )

        // Each hop reaches the state that actually produced the next one.
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
        // alone, seven sources down.
        #expect(preview.source.source.source.source.source.source.source.mosaic
            == Self.decoded().mosaic)
    }

    @Test("The whole chain is readable back from the rendered preview")
    func theChainIsReadableFromTheResult() throws {
        let oriented = try Self.oriented(mix: .redBlueSwap)
        let settings = DisplayPreviewTestData.settings(exposureEV: 1.5)
        let preview = try DisplayPreviewRenderer().render(oriented, settings: settings)
        let processing = preview.processing

        #expect(processing.settings == settings)
        #expect(preview.settings == settings)
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
        let oriented = try Self.oriented()
        let preview = try DisplayPreviewRenderer().render(
            oriented, settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        #expect(preview.processing == preview.image.processing)
        #expect(preview.settings == preview.image.processing.settings)
    }

    // MARK: - Reprocessing

    /// Changing settings must re-render from the scene-linear image, not from
    /// the previous preview. Rendering an encoded buffer again would apply the
    /// transfer function twice and could not recover a clipped highlight —
    /// and would look entirely plausible.
    @Test("Changing settings re-renders from the same scene-linear image")
    func changingSettingsRestartsFromTheMixedImage() throws {
        let oriented = try Self.oriented()
        let renderer = DisplayPreviewRenderer()

        let neutral = try renderer.render(
            oriented, settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        let brightened = try renderer.render(
            settings: DisplayPreviewTestData.settings(exposureEV: 1), replacing: neutral
        )
        let backToNeutral = try renderer.render(
            settings: DisplayPreviewTestData.settings(exposureEV: 0), replacing: brightened
        )

        // Round-tripping through +1 EV returns exactly the original bytes,
        // which chaining could not do.
        #expect(backToNeutral.image.bytes == neutral.image.bytes)
        #expect(brightened.image.bytes != neutral.image.bytes)

        // Going up a stop from the previous result is not the same as going up
        // two stops from the source, which is the other thing chaining would
        // break.
        let twoStops = try renderer.render(
            oriented, settings: DisplayPreviewTestData.settings(exposureEV: 2)
        )
        let secondStop = try renderer.render(
            settings: DisplayPreviewTestData.settings(exposureEV: 1), replacing: brightened
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

    /// Nothing upstream reruns: the re-rendered result carries the identical
    /// upstream values, not equal-looking recomputed ones.
    @Test("Re-rendering reruns no upstream stage")
    func reRenderingRerunsNothingUpstream() throws {
        let oriented = try Self.oriented(mix: .redBlueSwap)
        let renderer = DisplayPreviewRenderer()

        let first = try renderer.render(
            oriented, settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        let second = try renderer.render(
            settings: DisplayPreviewTestData.settings(exposureEV: -1), replacing: first
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
        let settings = DisplayPreviewTestData.settings(exposureEV: 0)

        let identityPreview = try renderer.render(
            try orienter.apply(to: mixed, orientation: .upright), settings: settings
        )
        #expect(identityPreview.mix == .identity)

        // A different mix is a different upstream result, oriented the same
        // way and rendered by the same renderer with the same settings.
        let swapped = try IRChannelMixer().apply(mix: .redBlueSwap, replacing: mixed)
        let swappedPreview = try renderer.render(
            try orienter.apply(to: swapped, orientation: .upright), settings: settings
        )

        #expect(swappedPreview.settings == identityPreview.settings)
        #expect(swappedPreview.mix == .redBlueSwap)
        #expect(swappedPreview.workingColorImage == identityPreview.workingColorImage)
        // The pixels differ because the mix differed, not because anything in
        // the display stage did.
        #expect(swappedPreview.image.bytes != identityPreview.image.bytes)
    }
}
