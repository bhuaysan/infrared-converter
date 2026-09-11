import Testing
import Foundation
@testable import InfraredConverter

/// The processed-state wrappers — `ProcessedRAWMosaic`,
/// `WhiteBalancedProcessedRAWMosaic`, `DemosaicedProcessedRAWImage`,
/// `WorkingColorProcessedRAWImage`, `IRChannelMixedProcessedRAWImage` and
/// `DisplayPreviewProcessedRAWImage` — are pairings a stage minted, not
/// pairings a caller assembled.
///
/// Their initialisers are module-internal, so outside the module a source
/// from one processing run cannot be attached to a result from another. Swift
/// cannot assert that a line *fails* to compile, so this suite pins the other
/// half of the invariant, which is the half that could regress silently: the
/// producing stages still mint all three, and the chain each one asserts is
/// genuinely intact — every hop reaches the state that actually produced the
/// next one, unmutated.
///
/// `PublicProcessingSurfaceTests` is the compile-time companion: it imports
/// the module *without* `@testable` and therefore only ever sees the public
/// surface, and it obtains and fully reads every wrapper there without an
/// initialiser being available to it.
///
/// Synthetic input throughout — no fixture, so this runs everywhere.
@Suite("Processed wrapper provenance")
struct ProcessedWrapperProvenanceTests {

    /// A 4×4 RGGB mosaic whose samples are all distinct, so a wrapper holding
    /// the wrong buffer cannot coincidentally match the right one.
    private static func decoded() -> DecodedRAWMosaic {
        let width = 4
        let height = 4
        var samples = [UInt16]()
        for index in 0..<(width * height) {
            samples.append(UInt16(100 + index * 37))
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
            url: URL(fileURLWithPath: "/tmp/provenance.orf"),
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

    @Test("Every stage still mints its wrapper, and the chain hops are exact")
    func stagesStillMintTheirWrappers() throws {
        let decoded = Self.decoded()

        // Stage 1 mints ProcessedRAWMosaic.
        let normalized = try RAWMosaicNormalizer().process(decoded)
        #expect(normalized.source.mosaic == decoded.mosaic)
        #expect(normalized.url == decoded.url)
        #expect(normalized.metadata == decoded.metadata)
        #expect(normalized.processing.normalized)

        // Stage 2 mints WhiteBalancedProcessedRAWMosaic, and its source is
        // the exact ProcessedRAWMosaic it consumed.
        let gains = RAWWhiteBalanceGains(plane0: 2, plane1: 1, plane2: 3, plane3: 1.5)
        let balanced = try RAWWhiteBalancer().apply(to: normalized, gains: gains)
        #expect(balanced.linearMosaic == normalized.mosaic)
        #expect(balanced.source.source.mosaic == decoded.mosaic)
        #expect(balanced.processing.gains == gains)
        #expect(balanced.url == decoded.url)

        // Stage 3 mints DemosaicedProcessedRAWImage, over that same state.
        let demosaiced = try RAWDemosaicer().demosaic(balanced)
        #expect(demosaiced.whiteBalancedMosaic == balanced.mosaic)
        #expect(demosaiced.linearMosaic == normalized.mosaic)
        #expect(demosaiced.source.source.source.mosaic == decoded.mosaic)
        #expect(demosaiced.metadata == decoded.metadata)
        #expect(demosaiced.url == decoded.url)

        // Stage 4 mints WorkingColorProcessedRAWImage over that image.
        let working = try RAWWorkingColorConverter()
            .convert(demosaiced, using: .sensorRGBIdentityFalseColor)
        #expect(working.demosaicedImage == demosaiced.image)
        #expect(working.source.source.source.source.mosaic == decoded.mosaic)

        // Stage 5 mints IRChannelMixedProcessedRAWImage over that.
        let mixed = try IRChannelMixer().apply(to: working, mix: .redBlueSwap)
        #expect(mixed.workingColorImage == working.image)
        #expect(mixed.demosaicedImage == demosaiced.image)
        #expect(mixed.source.source.source.source.source.mosaic == decoded.mosaic)
        #expect(mixed.url == decoded.url)

        // Stage 6 mints OrientedProcessedRAWImage over that.
        let oriented = try ImageOrienter().apply(to: mixed, orientation: .rotated90Clockwise)
        #expect(oriented.channelMixedImage == mixed.image)
        #expect(oriented.workingColorImage == working.image)
        #expect(oriented.source.source.source.source.source.source.mosaic == decoded.mosaic)
        #expect(oriented.url == decoded.url)

        // Stage 7 mints DisplayPreviewProcessedRAWImage over that.
        let preview = try DisplayPreviewRenderer().render(
            oriented,
            settings: DisplayRenderSettings(
                exposureEV: 0, rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
            )
        )
        #expect(preview.orientedImage == oriented.image)
        #expect(preview.channelMixedImage == mixed.image)
        #expect(preview.workingColorImage == working.image)
        #expect(preview.source.source.source.source.source.source.source.mosaic
            == decoded.mosaic)
        #expect(preview.url == decoded.url)

        // The provenance record reaches back through all five stages upstream
        // of the display one, and the display record reaches through it.
        #expect(preview.processing.mixSource == .redBlueSwap)
        #expect(preview.processing.whiteBalanceGains == gains)
        #expect(preview.processing.exposureEV == 0)
        #expect(preview.processing.appliedOrientation == .rotated90Clockwise)
        #expect(preview.orientation == .rotated90Clockwise)

        let processing = mixed.processing
        #expect(processing.mixSource == .redBlueSwap)
        #expect(processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
        #expect(processing.demosaicAlgorithm == .bilinearBayer)
        #expect(processing.whiteBalanceGains == gains)
        #expect(processing.workingColorProcessing.demosaicProcessing
            .whiteBalanceProcessing.linearProcessing.whiteLevel == 4095)
    }

    @Test("A wrapper forwards its own image's provenance, never a second copy")
    func provenanceIsForwardedNotCopied() throws {
        let decoded = Self.decoded()
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let balanced = try RAWWhiteBalancer()
            .apply(to: normalized, gains: .identity)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)

        // Each wrapper's `processing` is its own buffer's record, read
        // through, so the two can never disagree.
        #expect(normalized.processing == normalized.mosaic.processing)
        #expect(balanced.processing == balanced.mosaic.processing)
        #expect(demosaiced.processing == demosaiced.image.processing)
    }

    @Test("Re-running a stage restarts from the retained source, never the result")
    func reprocessingRestartsFromTheSource() throws {
        let decoded = Self.decoded()
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let balancer = RAWWhiteBalancer()

        let doubled = try balancer.apply(
            to: normalized, gains: RAWWhiteBalanceGains(plane0: 2, plane1: 2, plane2: 2, plane3: 2)
        )
        let tripled = try balancer.apply(
            gains: RAWWhiteBalanceGains(plane0: 3, plane1: 3, plane2: 3, plane3: 3),
            replacing: doubled
        )
        let directlyTripled = try balancer.apply(
            to: normalized, gains: RAWWhiteBalanceGains(plane0: 3, plane1: 3, plane2: 3, plane3: 3)
        )

        // 3x, not 6x: the second run reached through `.source`.
        #expect(tripled.mosaic.values == directlyTripled.mosaic.values)
        #expect(tripled.linearMosaic == normalized.mosaic)
    }

    /// The bare value types stay publicly constructible on purpose: they are
    /// data representations, not provenance claims. Only the wrappers assert
    /// "this result came from that source".
    @Test("The bare value types remain constructible")
    func bareValueTypesRemainConstructible() throws {
        let linear = LinearRAWMosaic(
            width: 2,
            height: 1,
            values: [0.25, 0.5],
            sensorColorLayout: RAWTestData.bayerLayout(),
            processing: RAWLinearProcessing(whiteLevelPolicy: .metadataMaximum, whiteLevel: 4095)
        )
        #expect(linear.isGeometryConsistent)

        let balanced = WhiteBalancedRAWMosaic(
            width: 2,
            height: 1,
            values: [0.5, 1.0],
            sensorColorLayout: RAWTestData.bayerLayout(),
            processing: RAWWhiteBalanceProcessing(
                gains: .identity,
                gainSource: .explicit,
                linearProcessing: linear.processing
            )
        )
        #expect(balanced.isGeometryConsistent)

        let image = DemosaicedRAWRGBImage(
            width: 1,
            height: 1,
            values: [0.1, 0.2, 0.3],
            processing: RAWDemosaicProcessing(
                algorithm: .bilinearBayer,
                sourcePattern: try RAWBayerCellPattern.resolve(
                    from: RAWTestData.bayerLayout(), algorithm: .bilinearBayer
                ),
                whiteBalanceProcessing: balanced.processing
            )
        )
        #expect(image.isGeometryConsistent)
    }
}
