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
/// `DemosaicedProcessedRAWImage`, a `WorkingColorProcessedRAWImage` or an
/// `IRChannelMixedProcessedRAWImage` can only be obtained from the stage that
/// produced it. Swift has no way to
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

        // The whole chain is readable from the last wrapper alone.
        #expect(mixed.source.source.source.source.source.mosaic == decoded.mosaic)
        #expect(mixed.image.isGeometryConsistent)
        #expect(mixed.processing.whiteBalanceApplied)
        #expect(mixed.processing.channelMixApplied)
        #expect(mixed.processing.mixSource == .redBlueSwap)
        #expect(demosaiced.image.isGeometryConsistent)
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
    }
}
