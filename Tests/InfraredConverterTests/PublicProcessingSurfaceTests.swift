import Testing
import Foundation

// Deliberately NOT `@testable`. This file sees exactly what code outside the
// module sees, and nothing else — which is the point of it existing.
import InfraredConverter

/// The application-owned pipeline as an external consumer sees it.
///
/// ## Why this file imports without `@testable`
///
/// Every processed-state wrapper has a module-internal initialiser, so outside
/// the module a `ProcessedRAWMosaic`, a `WhiteBalancedProcessedRAWMosaic`, a
/// `DemosaicedProcessedRAWImage`, a `WorkingColorProcessedRAWImage`, an
/// `IRChannelMixedProcessedRAWImage` or a `DisplayPreviewProcessedRAWImage`
/// can only be obtained from the stage that produced it. Swift has no way to
/// assert that a given line *fails* to compile, so absence cannot be tested
/// directly. What can be pinned, and is pinned here, is the consequence that
/// matters: with only the public surface available, the whole chain is still
/// runnable and every wrapper still fully readable. Nothing external needs the
/// initialisers — and this file would stop compiling if a public accessor the
/// chain depends on were removed or narrowed.
///
/// Everything below is built from public initialisers on the decoder-boundary
/// and bare value types, which stay public on purpose: `DecodedRAWMosaic` so a
/// mock decoder is possible, `LinearRAWMosaic` and friends because they are
/// data representations rather than provenance claims.
///
/// Nothing here reads a fixture, so it runs everywhere.
@Suite("Public processing surface")
struct PublicProcessingSurfaceTests {

    /// A synthetic 4×4 RGGB decoder output, assembled entirely from public
    /// initialisers.
    private static func decoded() -> DecodedRAWMosaic {
        let width = 4
        let height = 4
        var samples = [UInt16]()
        for index in 0..<(width * height) {
            samples.append(UInt16(200 + index * 41))
        }
        let layout = RAWMetadata.SensorColorLayout(
            pattern: .bayer,
            filters: 0xB4B4_B4B4,
            colorDescription: "RGBG",
            colorCount: 3,
            sourceRawBitDepth: 12
        )
        let metadata = RAWMetadata(
            identity: .init(make: "Olympus", model: "E-PL3"),
            geometry: .init(
                rawWidth: width,
                rawHeight: height,
                visibleWidth: width,
                visibleHeight: height,
                topMargin: 0,
                leftMargin: 0,
                outputWidth: width,
                outputHeight: height,
                flip: 0,
                pixelAspect: 1
            ),
            sensor: layout,
            levels: .init(black: 0, perPlaneBlack: [0, 0, 0, 0], maximum: 4095),
            color: .init(),
            exposure: .init()
        )
        let mosaic = RAWMosaic(
            width: width,
            height: height,
            bytesPerRow: width * 2,
            samples: samples.withUnsafeBufferPointer { Data(buffer: $0) },
            sampleFormat: .uint16,
            sourceRawBitDepth: 12,
            sensorColorLayout: layout
        )
        return DecodedRAWMosaic(
            url: URL(fileURLWithPath: "/tmp/public-surface.orf"),
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

    @Test("An external caller can run every stage and read every wrapper")
    func externalCallerCanRunTheChain() throws {
        let decoded = Self.decoded()

        let normalized: ProcessedRAWMosaic = try RAWMosaicNormalizer().process(decoded)
        _ = normalized.source
        _ = normalized.mosaic
        _ = normalized.processing
        _ = normalized.metadata
        #expect(normalized.url == decoded.url)

        let estimate = try RAWWhiteBalanceEstimator().estimateNeutralPatch(
            in: normalized.mosaic,
            region: RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 4, height: 4)
        )
        _ = estimate.statistics
        _ = estimate.region
        _ = estimate.scalePolicy
        _ = estimate.targetMean

        let balanced: WhiteBalancedProcessedRAWMosaic =
            try RAWWhiteBalancer().apply(to: normalized, estimate: estimate)
        _ = balanced.source
        _ = balanced.mosaic
        _ = balanced.linearMosaic
        _ = balanced.processing
        _ = balanced.metadata
        #expect(balanced.url == decoded.url)

        let demosaiced: DemosaicedProcessedRAWImage = try RAWDemosaicer().demosaic(balanced)
        _ = demosaiced.source
        _ = demosaiced.image
        _ = demosaiced.whiteBalancedMosaic
        _ = demosaiced.linearMosaic
        _ = demosaiced.processing
        _ = demosaiced.metadata
        #expect(demosaiced.url == decoded.url)

        let working: WorkingColorProcessedRAWImage = try RAWWorkingColorConverter()
            .convert(demosaiced, using: .sensorRGBIdentityFalseColor)
        _ = working.source
        _ = working.image
        _ = working.demosaicedImage
        _ = working.whiteBalancedMosaic
        _ = working.linearMosaic
        _ = working.processing
        _ = working.transform
        _ = working.metadata
        #expect(working.url == decoded.url)

        let mixed: IRChannelMixedProcessedRAWImage = try IRChannelMixer()
            .apply(to: working, mix: .redBlueSwap)
        _ = mixed.source
        _ = mixed.image
        _ = mixed.workingColorImage
        _ = mixed.demosaicedImage
        _ = mixed.whiteBalancedMosaic
        _ = mixed.linearMosaic
        _ = mixed.processing
        _ = mixed.mix
        _ = mixed.cameraToWorkingTransform
        _ = mixed.metadata
        #expect(mixed.url == decoded.url)

        // The settings are spelled out here, because there is no default on
        // the public API to fall back on — which is the point.
        let settings = DisplayRenderSettings(
            exposureEV: 0,
            rangePolicy: .hardClipToDisplayRange,
            encoding: .sRGB
        )
        let oriented: OrientedProcessedRAWImage = try ImageOrienter()
            .apply(to: mixed, orientation: .rotated270Clockwise)
        _ = oriented.source
        _ = oriented.image
        _ = oriented.channelMixedImage
        _ = oriented.workingColorImage
        _ = oriented.demosaicedImage
        _ = oriented.whiteBalancedMosaic
        _ = oriented.linearMosaic
        _ = oriented.processing
        _ = oriented.orientation
        _ = oriented.mix
        _ = oriented.cameraToWorkingTransform
        _ = oriented.metadata
        #expect(oriented.url == decoded.url)

        let preview: DisplayPreviewProcessedRAWImage = try DisplayPreviewRenderer()
            .render(oriented, settings: settings)
        _ = preview.source
        _ = preview.image
        _ = preview.orientedImage
        _ = preview.channelMixedImage
        _ = preview.workingColorImage
        _ = preview.demosaicedImage
        _ = preview.whiteBalancedMosaic
        _ = preview.linearMosaic
        _ = preview.processing
        _ = preview.settings
        _ = preview.orientation
        _ = preview.mix
        _ = preview.cameraToWorkingTransform
        _ = preview.metadata
        #expect(preview.url == decoded.url)

        // The whole chain is readable from the last wrapper alone.
        #expect(preview.source.source.source.source.source.source.source.mosaic
            == decoded.mosaic)
        #expect(mixed.image.isGeometryConsistent)
        #expect(mixed.processing.whiteBalanceApplied)
        #expect(mixed.processing.channelMixApplied)
        #expect(mixed.processing.mixSource == .redBlueSwap)
        #expect(demosaiced.image.isGeometryConsistent)

        // And the preview's own record is fully readable externally.
        #expect(preview.image.isGeometryConsistent)
        #expect(preview.processing.exposureEV == 0)
        #expect(preview.processing.rangePolicy == .hardClipToDisplayRange)
        #expect(preview.processing.encoding == .sRGB)
        #expect(preview.processing.displayRangeClippingApplied)
        #expect(!preview.processing.sceneLinear)
        #expect(!preview.processing.toneMappingApplied)
        #expect(preview.processing.mixSource == .redBlueSwap)
        #expect(preview.processing.orientationApplied)
        #expect(preview.processing.appliedOrientation == .rotated270Clockwise)
        #expect(preview.processing.orientationSwappedDimensions)
        #expect(preview.image.width == mixed.image.height)
        #expect(preview.image.height == mixed.image.width)
        #expect(preview.processing.clippedSampleCount
            == preview.processing.clippedLowSampleCount
                + preview.processing.clippedHighSampleCount)
    }

    @Test("The bare value types remain publicly constructible")
    func bareValueTypesAreStillPublic() {
        let layout = RAWMetadata.SensorColorLayout(
            pattern: .bayer,
            filters: 0xB4B4_B4B4,
            colorDescription: "RGBG",
            colorCount: 3
        )
        let linearProcessing = RAWLinearProcessing(
            whiteLevelPolicy: .metadataMaximum, whiteLevel: 4095
        )
        let linear = LinearRAWMosaic(
            width: 2,
            height: 2,
            values: [0, 0.25, 0.5, 0.75],
            sensorColorLayout: layout,
            processing: linearProcessing
        )
        #expect(linear.isGeometryConsistent)

        let balanced = WhiteBalancedRAWMosaic(
            width: 2,
            height: 2,
            values: [0, 0.5, 1, 1.5],
            sensorColorLayout: layout,
            processing: RAWWhiteBalanceProcessing(
                gains: .identity, gainSource: .explicit, linearProcessing: linearProcessing
            )
        )
        #expect(balanced.isGeometryConsistent)

        // The display representation is a data type too, for the same reason.
        let preview = DisplayEncodedPreviewImage(
            width: 2,
            height: 2,
            bytes: Data(count: 12),
            processing: DisplayPreviewProcessing(
                settings: DisplayRenderSettings(
                    exposureEV: 0, rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
                ),
                orientationProcessing: ImageOrientationProcessing(
                    orientation: .upright,
                    channelMixProcessing: IRChannelMixProcessing(
                        mix: .identity,
                        workingColorProcessing: RAWWorkingColorProcessing(
                            transform: .sensorRGBIdentityFalseColor,
                            demosaicProcessing: RAWDemosaicProcessing(
                                algorithm: .bilinearBayer,
                                sourcePattern: RAWBayerCellPattern(
                                    topLeft: .red,
                                    topRight: .green,
                                    bottomLeft: .green,
                                    bottomRight: .blue
                                ),
                                whiteBalanceProcessing: RAWWhiteBalanceProcessing(
                                    gains: .identity,
                                    gainSource: .explicit,
                                    linearProcessing: linearProcessing
                                )
                            )
                        )
                    )
                ),
                clippedLowSampleCount: 0,
                clippedHighSampleCount: 0
            )
        )
        #expect(preview.isGeometryConsistent)
        #expect(preview.bytesPerRow == 6)
    }
}
