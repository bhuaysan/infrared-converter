import Testing
import Foundation
@testable import InfraredConverter

/// What the channel-mix stage keeps, what it refuses to recompute, and what it
/// cannot see at all.
///
/// The arithmetic is `IRChannelMixerTests`' subject. This suite is about the
/// boundary: that replacing a mix restarts from the pre-mix working image
/// rather than composing matrices, that the upstream chain stays readable and
/// unmodified, and that no metadata and no white-balance mathematics reaches
/// this stage.
///
/// Synthetic input throughout — no fixture, so this runs everywhere.
@Suite("IRChannelMixer provenance")
struct IRChannelMixerProvenanceTests {

    /// The whole application-owned pipeline on a synthetic 4×4 mosaic, up to
    /// and including the working-colour conversion.
    ///
    /// The camera-to-working transform is the identity false-colour
    /// assignment, so anything this suite observes downstream is the channel
    /// mix's doing and not a camera matrix's.
    static func workingColorFixture(
        color: RAWMetadata.ColorMetadata = .init()
    ) throws -> WorkingColorProcessedRAWImage {
        let demosaiced = try RAWWorkingColorConverterTests.processedFixture(color: color)
        return try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )
    }

    /// An amplifying, non-symmetric mix.
    static func mixOne() throws -> IRChannelMix {
        IRChannelMix.explicit(matrix: try RAWColorMatrix3x3(
            m00: 2, m01: 0.5, m02: 0,
            m10: 0, m11: 3, m12: 0.25,
            m20: 0.125, m21: 0, m22: 4
        ))
    }

    /// A different one, chosen so that composing it with `mixOne` cannot
    /// coincidentally equal applying it alone.
    static func mixTwo() throws -> IRChannelMix {
        IRChannelMix.explicit(matrix: try RAWColorMatrix3x3(
            m00: -1, m01: 0.75, m02: 0.5,
            m10: 0.25, m11: -2, m12: 1.5,
            m20: 1, m21: 0.125, m22: -0.5
        ))
    }

    // MARK: - Reprocessing

    @Test("Replacing a mix restarts from the pre-mix working image, never the result")
    func replacingAMixDoesNotCompose() throws {
        let working = try Self.workingColorFixture()
        let mixer = IRChannelMixer()

        let mixTwo = try Self.mixTwo()
        let first = try mixer.apply(to: working, mix: Self.mixOne())
        let replaced = try mixer.apply(mix: mixTwo, replacing: first)
        let direct = try mixer.apply(to: working, mix: mixTwo)

        // M2 × original, exactly.
        #expect(replaced.image.values == direct.image.values)
        #expect(replaced.image.processing.mix == mixTwo)

        // And emphatically not M2 × (M1 × original): applying M2 to the
        // already-mixed buffer gives different numbers, which is what the
        // structural reach through `.source` prevents.
        let composed = try mixer.apply(
            to: WorkingColorRGBImage(
                width: first.image.width,
                height: first.image.height,
                values: first.image.values,
                processing: working.image.processing
            ),
            mix: mixTwo
        )
        #expect(composed.values != direct.image.values)

        // The retained source is still the pre-mix working image itself.
        #expect(replaced.workingColorImage.values == working.image.values)
        #expect(first.workingColorImage.values == working.image.values)
    }

    @Test("Two red/blue swaps in a row would cancel, so the stage must not chain")
    func repeatedSwapsWouldCancel() throws {
        let working = try Self.workingColorFixture()
        let mixer = IRChannelMixer()

        let swapped = try mixer.apply(to: working, mix: .redBlueSwap)
        let again = try mixer.apply(mix: .redBlueSwap, replacing: swapped)

        // Still one swap, not two — a chained implementation would have
        // returned the original values here.
        #expect(again.image.values == swapped.image.values)
        #expect(again.image.values != working.image.values)
    }

    // MARK: - The upstream chain

    @Test("Every earlier representation stays reachable and unmodified")
    func upstreamChainIsIntact() throws {
        let working = try Self.workingColorFixture()
        let mixed = try IRChannelMixer().apply(to: working, mix: .redBlueSwap)

        // The mix itself.
        #expect(mixed.mix == .redBlueSwap)
        #expect(mixed.processing.mixSource == .redBlueSwap)
        #expect(mixed.processing.channelMixApplied)

        // The camera-to-working transform, still a separate fact.
        #expect(mixed.cameraToWorkingTransform == .sensorRGBIdentityFalseColor)
        #expect(mixed.processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
        #expect(mixed.processing.cameraToWorkingTransformApplied)
        #expect(mixed.processing.workingColorRepresentationEstablished)
        #expect(!mixed.processing.isValidatedInfraredCalibration)

        // Demosaicing, white balance and normalisation, read through the
        // upstream record rather than copied into this one.
        #expect(mixed.processing.demosaicAlgorithm == .bilinearBayer)
        #expect(mixed.processing.demosaiced)
        #expect(mixed.processing.whiteBalanceApplied)
        #expect(mixed.processing.blackLevelSubtracted)
        #expect(mixed.processing.normalized)
        #expect(mixed.processing.whiteBalanceGains
            == RAWWhiteBalanceGains(plane0: 2, plane1: 1, plane2: 3, plane3: 1.5))
        #expect(mixed.processing.workingColorProcessing == working.image.processing)
        #expect(mixed.processing.workingColorProcessing.demosaicProcessing
            .whiteBalanceProcessing.gainSource == .explicit)
        #expect(mixed.processing.workingColorProcessing.demosaicProcessing
            .whiteBalanceProcessing.linearProcessing.whiteLevel == 4095)

        // Every earlier buffer, unmutated.
        #expect(mixed.workingColorImage == working.image)
        #expect(mixed.demosaicedImage == working.demosaicedImage)
        #expect(mixed.whiteBalancedMosaic == working.whiteBalancedMosaic)
        #expect(mixed.linearMosaic == working.linearMosaic)
        #expect(!mixed.linearMosaic.processing.whiteBalanceApplied)
        #expect(mixed.source.source.source.source.source.mosaic.width == 4)
        #expect(mixed.metadata == working.metadata)
        #expect(mixed.url == working.url)

        // The wrapper forwards its own image's record rather than a second
        // copy, so the two cannot disagree.
        #expect(mixed.processing == mixed.image.processing)
    }

    // MARK: - Metadata independence

    /// The core entry point is `WorkingColorRGBImage + IRChannelMix` and has
    /// no parameter a `RAWMetadata` could arrive through. This is the
    /// behavioural half of that structural fact: two runs whose metadata
    /// differs in every colour field produce byte-identical output.
    @Test("Camera colour metadata cannot change a single output value")
    func metadataDoesNotReachTheStage() throws {
        let plain = try Self.workingColorFixture()
        let loaded = try Self.workingColorFixture(color: RAWMetadata.ColorMetadata(
            cameraMultipliers: [0.640625, 1.0, 5.5625, 0.0],
            daylightMultipliers: [2.2629104, 0.9284695, 1.2071348, 0.0],
            rgbFromCamera: [
                [1.7544682, -0.5938559, -0.16061233, 0.0],
                [-0.25168633, 1.8621225, -0.61043614, 0.0],
                [0.05752118, -0.69685745, 1.6393362, 0.0],
            ],
            cameraFromXYZ: [
                [0.7328, -0.1916, -0.1085, 0.0],
                [-0.3603, 1.1205, 0.2333, 0.0],
                [0.0084, 0.1571, 0.5734, 0.0],
            ],
            asShotWhiteBalanceApplied: true
        ))

        // Same pre-mix pixels — the working-colour stage did not read the
        // metadata either.
        #expect(plain.image.values == loaded.image.values)

        let mixer = IRChannelMixer()
        for mix in [IRChannelMix.identity, .redBlueSwap, try Self.mixOne()] {
            let fromPlain = try mixer.apply(to: plain, mix: mix)
            let fromLoaded = try mixer.apply(to: loaded, mix: mix)
            var mismatches = 0
            for index in 0..<fromPlain.image.values.count
            where fromPlain.image.values[index].bitPattern
                != fromLoaded.image.values[index].bitPattern {
                mismatches += 1
            }
            #expect(mismatches == 0, "mix \(mix.source)")
        }

        // The metadata is right there on the retained chain, and had no
        // effect on anything above.
        let mixed = try mixer.apply(to: loaded, mix: .redBlueSwap)
        #expect(mixed.metadata.color.cameraMultipliers != nil)
        #expect(mixed.metadata.color.rgbFromCamera != nil)
    }

    /// White balance happened per CFA plane in the mosaic domain and does not
    /// happen again here. There are no CFA planes at this stage — the image is
    /// three full channels — so the gains are provenance, not an input.
    @Test("White balance is not reapplied, whatever the recorded gains say")
    func whiteBalanceDoesNotRunAgain() throws {
        let working = try Self.workingColorFixture()
        let extreme = WorkingColorRGBImage(
            width: working.image.width,
            height: working.image.height,
            values: working.image.values,
            processing: RAWWorkingColorProcessing(
                transform: working.image.processing.transform,
                demosaicProcessing: RAWDemosaicProcessing(
                    algorithm: working.image.processing.demosaicAlgorithm,
                    sourcePattern: working.image.processing.demosaicProcessing.sourcePattern,
                    whiteBalanceProcessing: RAWWhiteBalanceProcessing(
                        // Wildly different from the real run's gains.
                        gains: RAWWhiteBalanceGains(
                            plane0: 100, plane1: 0.01, plane2: 50, plane3: 7
                        ),
                        gainSource: .explicit,
                        linearProcessing: working.image.processing.demosaicProcessing
                            .whiteBalanceProcessing.linearProcessing
                    )
                )
            )
        )

        let mixer = IRChannelMixer()
        let fromReal = try mixer.apply(to: working.image, mix: .redBlueSwap)
        let fromExtreme = try mixer.apply(to: extreme, mix: .redBlueSwap)

        #expect(fromReal.values == fromExtreme.values)
        // The gains are still recorded, and still only recorded.
        #expect(fromExtreme.processing.whiteBalanceGains.plane0 == 100)
        #expect(fromExtreme.processing.whiteBalanceApplied)
    }

    // MARK: - Working colour space

    /// The mismatch check cannot be exercised today, and this is the
    /// compile-time reminder of why.
    ///
    /// `RAWWorkingColorSpace` has exactly one case, so no public or
    /// module-internal construction can produce a mix authored for a different
    /// space than the image. Rather than adding a fake case to the production
    /// enum to make a test possible, the invariant is pinned two ways: this
    /// exhaustive switch stops compiling the day a second space is added, and
    /// the error case itself is asserted to exist and to say something useful.
    @Test("A mismatch is unconstructible today; the check stays for the day it is not")
    func workingColorSpaceMismatchIsFutureFacing() throws {
        let space = IRChannelMix.identity.workingColorSpace
        switch space {
        case .extendedLinearSRGB:
            // When a second working colour space is implemented, this switch
            // fails to compile. At that point write the real mismatch test:
            // build an image in one space, a mix in the other, and require
            // `channelMixWorkingColorSpaceMismatch`.
            break
        }

        let working = try Self.workingColorFixture()
        #expect(working.image.processing.workingColorSpace == IRChannelMix.redBlueSwap
            .workingColorSpace)

        let error = IRProcessingError.channelMixWorkingColorSpaceMismatch(
            image: .extendedLinearSRGB, mix: .extendedLinearSRGB
        )
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.failureReason?.contains("does not convert") == true)
    }
}
