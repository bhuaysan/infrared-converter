import Testing
import Foundation
@testable import InfraredConverter

/// The orientation stage's processed wrapper: what it retains, and what
/// changing an orientation does and does not rerun.
///
/// Synthetic input throughout, built by running the whole application-owned
/// chain over a small mosaic — no fixture, so this runs everywhere.
@Suite("Orientation provenance")
struct ImageOrienterProvenanceTests {

    /// A 4×4 RGGB mosaic whose samples are all distinct, so a wrapper holding
    /// the wrong buffer cannot coincidentally match the right one.
    private static func decoded() -> DecodedRAWMosaic {
        let width = 4
        let height = 4
        var samples = [UInt16]()
        for index in 0..<(width * height) {
            samples.append(UInt16(250 + index * 131))
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
            url: URL(fileURLWithPath: "/tmp/orientation-provenance.orf"),
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

    // MARK: - The wrapper

    @Test("The orientation stage mints its wrapper over the exact state it consumed")
    func theStageMintsItsWrapper() throws {
        let mixed = try Self.mixed(mix: .redBlueSwap)
        let oriented = try ImageOrienter().apply(to: mixed, orientation: .transverse)

        // Each hop reaches the state that actually produced the next one.
        #expect(oriented.channelMixedImage == mixed.image)
        #expect(oriented.workingColorImage == mixed.workingColorImage)
        #expect(oriented.demosaicedImage == mixed.demosaicedImage)
        #expect(oriented.whiteBalancedMosaic == mixed.whiteBalancedMosaic)
        #expect(oriented.linearMosaic == mixed.linearMosaic)
        #expect(oriented.url == mixed.url)
        #expect(oriented.metadata == mixed.metadata)
        #expect(oriented.orientation == .transverse)

        // And the decoded UInt16 mosaic is reachable from the wrapper alone,
        // six sources down.
        #expect(oriented.source.source.source.source.source.source.mosaic
            == Self.decoded().mosaic)
    }

    @Test("A wrapper forwards its own image's provenance, never a second copy")
    func provenanceIsForwardedNotCopied() throws {
        let oriented = try ImageOrienter()
            .apply(to: try Self.mixed(), orientation: .rotated180)
        #expect(oriented.processing == oriented.image.processing)
        #expect(oriented.orientation == oriented.image.processing.orientation)
        #expect(oriented.orientation == oriented.image.orientation)
    }

    @Test("The whole upstream chain is readable back from the oriented result")
    func theChainIsReadableFromTheResult() throws {
        let oriented = try ImageOrienter()
            .apply(to: try Self.mixed(mix: .redBlueSwap), orientation: .rotated90Clockwise)
        let processing = oriented.processing

        #expect(processing.orientation == .rotated90Clockwise)
        #expect(processing.orientationApplied)
        #expect(processing.dimensionsSwapped)
        #expect(!processing.orientationIsMirrored)
        #expect(processing.mixSource == .redBlueSwap)
        #expect(processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
        #expect(processing.demosaicAlgorithm == .bilinearBayer)
        #expect(processing.whiteBalanceGains
            == RAWWhiteBalanceGains(plane0: 2, plane1: 1, plane2: 3, plane3: 1.5))
        #expect(processing.whiteBalanceApplied)
        #expect(processing.blackLevelSubtracted)
        #expect(processing.normalized)
        #expect(processing.demosaiced)
        #expect(processing.channelMixApplied)
        #expect(processing.workingColorRepresentationEstablished)
        #expect(processing.workingColorSpace == .extendedLinearSRGB)
        #expect(
            processing.channelMixProcessing.workingColorProcessing
                .demosaicProcessing.whiteBalanceProcessing.linearProcessing.whiteLevel == 4095
        )
        #expect(oriented.metadata.identity.model == "E-PL3")
        #expect(oriented.url.lastPathComponent == "orientation-provenance.orf")
    }

    /// Rearranging pixels cannot turn a false-colour placement into a
    /// calibration, and the record keeps saying so.
    @Test("Orientation never becomes a colour claim")
    func orientationIsNotAColourClaim() throws {
        for orientation in RAWImageOrientation.allCases {
            let oriented = try ImageOrienter()
                .apply(to: try Self.mixed(), orientation: orientation)
            #expect(!oriented.processing.isValidatedInfraredCalibration, "\(orientation)")
        }
    }

    // MARK: - Reprocessing

    /// Changing an orientation must restart from the unoriented image, not
    /// compose onto the previous one.
    ///
    /// The eight orientations are closed under composition, so a chained
    /// result is always *some* valid orientation and never looks malformed. It
    /// is simply not the one that was asked for, while provenance records the
    /// one that was — which is exactly why this is checked structurally rather
    /// than left to look right.
    @Test("Changing an orientation restarts from the channel-mixed image")
    func changingOrientationRestartsFromTheMixedImage() throws {
        let mixed = try Self.mixed()
        let orienter = ImageOrienter()

        let upright = try orienter.apply(to: mixed, orientation: .upright)
        let turned = try orienter.apply(orientation: .rotated90Clockwise, replacing: upright)
        let backToUpright = try orienter.apply(orientation: .upright, replacing: turned)

        // identity → rotate90 → identity is the original geometry and the
        // original numbers, not a second quarter turn applied to a rotated
        // buffer.
        #expect(backToUpright.image.width == mixed.image.width)
        #expect(backToUpright.image.height == mixed.image.height)
        #expect(backToUpright.image.values == mixed.image.values)
        for index in 0..<mixed.image.values.count
        where backToUpright.image.values[index].bitPattern
            != mixed.image.values[index].bitPattern {
            Issue.record("scene-linear element \(index) changed")
        }

        // Chaining would have produced a 180° result here; it did not.
        let halfTurn = try orienter.apply(to: mixed, orientation: .rotated180)
        #expect(backToUpright.image.values != halfTurn.image.values)

        // The turned result is untouched and still says what it is.
        #expect(turned.orientation == .rotated90Clockwise)
        #expect(turned.image.width == mixed.image.height)
        #expect(turned.image.height == mixed.image.width)
    }

    /// Two quarter turns in a row must not become a half turn.
    @Test("Replacing an orientation never composes with the previous one")
    func replacingNeverComposes() throws {
        let mixed = try Self.mixed()
        let orienter = ImageOrienter()

        let first = try orienter.apply(to: mixed, orientation: .rotated90Clockwise)
        let second = try orienter.apply(orientation: .rotated90Clockwise, replacing: first)
        let direct = try orienter.apply(to: mixed, orientation: .rotated90Clockwise)
        let composed = try orienter.apply(to: mixed, orientation: .rotated180)

        #expect(second.image.values == direct.image.values)
        #expect(second.image.width == direct.image.width)
        #expect(second.image.height == direct.image.height)
        #expect(second.image.values != composed.image.values)
        #expect(second.orientation == .rotated90Clockwise)
    }

    /// Nothing upstream reruns: the re-oriented result carries the identical
    /// upstream values, not equal-looking recomputed ones.
    @Test("Re-orienting reruns no upstream stage")
    func reOrientingRerunsNothingUpstream() throws {
        let mixed = try Self.mixed(mix: .redBlueSwap)
        let orienter = ImageOrienter()

        let first = try orienter.apply(to: mixed, orientation: .transposed)
        let second = try orienter.apply(orientation: .mirroredVertically, replacing: first)

        // The same channel-mixed buffer, bit for bit — not a remixed one.
        #expect(second.channelMixedImage.values == mixed.image.values)
        for index in 0..<mixed.image.values.count
        where second.channelMixedImage.values[index].bitPattern
            != mixed.image.values[index].bitPattern {
            Issue.record("channel-mixed element \(index) changed")
        }
        #expect(second.workingColorImage == mixed.workingColorImage)
        #expect(second.demosaicedImage == mixed.demosaicedImage)
        #expect(second.whiteBalancedMosaic == mixed.whiteBalancedMosaic)
        #expect(second.linearMosaic == mixed.linearMosaic)
        #expect(second.mix == .redBlueSwap)
        #expect(second.processing.demosaicAlgorithm == .bilinearBayer)
    }

    /// The mix and the orientation are separate decisions, changed
    /// independently, in either order.
    @Test("The creative mix and the orientation change independently")
    func theMixAndTheOrientationAreIndependent() throws {
        let mixed = try Self.mixed(mix: .identity)
        let orienter = ImageOrienter()

        let identityTurned = try orienter.apply(to: mixed, orientation: .rotated90Clockwise)
        #expect(identityTurned.mix == .identity)

        // A different mix, the same orientation.
        let swapped = try IRChannelMixer().apply(mix: .redBlueSwap, replacing: mixed)
        let swappedTurned = try orienter.apply(to: swapped, orientation: .rotated90Clockwise)

        #expect(swappedTurned.orientation == identityTurned.orientation)
        #expect(swappedTurned.mix == .redBlueSwap)
        #expect(swappedTurned.image.width == identityTurned.image.width)
        #expect(swappedTurned.image.height == identityTurned.image.height)

        // The two results are the same pixels with the red and blue channels
        // exchanged: the mix decided the colour and the orientation decided
        // the arrangement, with neither touching the other's job.
        for row in 0..<identityTurned.image.height {
            for column in 0..<identityTurned.image.width {
                let plain = try #require(identityTurned.image.pixel(row: row, column: column))
                let mixedPixel = try #require(
                    swappedTurned.image.pixel(row: row, column: column)
                )
                #expect(mixedPixel.red.bitPattern == plain.blue.bitPattern)
                #expect(mixedPixel.green.bitPattern == plain.green.bitPattern)
                #expect(mixedPixel.blue.bitPattern == plain.red.bitPattern)
            }
        }
    }
}
