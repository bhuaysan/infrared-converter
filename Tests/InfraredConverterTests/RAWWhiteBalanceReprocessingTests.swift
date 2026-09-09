import Foundation
import Testing
@testable import InfraredConverter

/// Tests for the wrapper semantics that make interactive white balance safe:
/// re-balancing always restarts from the normalised mosaic, and no camera or
/// daylight multiplier can reach the result.
@Suite("RAWWhiteBalancer wrapper semantics")
struct RAWWhiteBalanceReprocessingTests {

    // MARK: - Fixtures

    /// A 2×2 RGBG mosaic carried all the way through the real pipeline types:
    /// a decoded `UInt16` mosaic, normalised by `RAWMosaicNormalizer`, ready
    /// for white balance.
    static func processed(
        samples: [UInt16] = [400, 800, 1200, 1600],
        color: RAWMetadata.ColorMetadata = .init()
    ) throws -> ProcessedRAWMosaic {
        let layout = RAWTestData.bayerLayout()
        let mosaic = samples.withUnsafeBufferPointer { buffer in
            RAWMosaic(
                width: 2,
                height: 2,
                bytesPerRow: 4,
                samples: Data(buffer: buffer),
                sampleFormat: .uint16,
                sourceRawBitDepth: 12,
                sensorColorLayout: layout
            )
        }
        var metadata = RAWTestData.metadata()
        metadata.sensor = layout
        metadata.levels = RAWMetadata.Levels(
            black: 0,
            perPlaneBlack: [64, 64, 64, 64],
            maximum: 4095
        )
        metadata.color = color

        let decoded = DecodedRAWMosaic(
            url: URL(fileURLWithPath: "/dev/null"),
            metadata: metadata,
            mosaic: mosaic,
            processing: RAWMosaicProcessing(
                decoderIdentifier: "Stub",
                sourceStorage: .singleChannel,
                sourceRowPitch: 4,
                destinationRowStride: 4
            )
        )
        return try RAWMosaicNormalizer().process(decoded)
    }

    static let gainsA = RAWWhiteBalanceGains(plane0: 2, plane1: 2, plane2: 2, plane3: 2)
    static let gainsB = RAWWhiteBalanceGains(plane0: 3, plane1: 3, plane2: 3, plane3: 3)

    // MARK: - The normalised source survives

    @Test("The normalised source is preserved, not mutated in place")
    func normalisedSourceIsPreserved() throws {
        let processed = try Self.processed()
        let before = processed.mosaic.values

        let balanced = try RAWWhiteBalancer().apply(to: processed, gains: Self.gainsA)

        #expect(balanced.linearMosaic.values == before)
        #expect(balanced.source.mosaic.values == before)
        // The original UInt16 mosaic is still reachable two levels down, so
        // nothing needs decoding again either.
        #expect(balanced.source.source.mosaic.sample(row: 0, column: 0) == 400)
        #expect(!balanced.linearMosaic.processing.whiteBalanceApplied)
        #expect(balanced.processing.whiteBalanceApplied)
    }

    // MARK: - New gains never compound

    @Test("New gains restart from the normalised mosaic and never compound")
    func gainsNeverCompound() throws {
        // Gains of 2 followed by gains of 3 must mean 3x the normalised
        // values, not 6x. This is the invariant interactive white balance
        // depends on.
        let processed = try Self.processed()
        let balancer = RAWWhiteBalancer()

        let resultA = try balancer.apply(to: processed, gains: Self.gainsA)
        let resultB = try balancer.apply(gains: Self.gainsB, replacing: resultA)
        let direct = try balancer.apply(to: processed, gains: Self.gainsB)

        #expect(resultB.mosaic.values == direct.mosaic.values)

        // And explicitly not the chained answer.
        let chained = resultA.mosaic.values.map { $0 * 3 }
        #expect(resultB.mosaic.values != chained)
        for (index, value) in resultB.mosaic.values.enumerated() {
            #expect(value == processed.mosaic.values[index] * 3)
            #expect(value != chained[index])
        }
    }

    @Test("Re-balancing repeatedly stays anchored to the same normalised source")
    func repeatedRebalancingIsStable() throws {
        let processed = try Self.processed()
        let balancer = RAWWhiteBalancer()

        var result = try balancer.apply(to: processed, gains: .identity)
        for gains: RAWWhiteBalanceGains in [Self.gainsA, Self.gainsB, .identity, Self.gainsA] {
            result = try balancer.apply(gains: gains, replacing: result)
        }

        // Five rounds later, gains of 2 still mean exactly 2.
        for (index, value) in result.mosaic.values.enumerated() {
            #expect(value == processed.mosaic.values[index] * 2)
        }
        #expect(result.processing.gains == Self.gainsA)
        #expect(result.linearMosaic.values == processed.mosaic.values)
    }

    @Test("Identity gains through the wrapper reproduce the normalised values exactly")
    func wrapperIdentityIsExact() throws {
        let processed = try Self.processed()
        let balanced = try RAWWhiteBalancer().apply(to: processed, gains: .identity)
        #expect(balanced.mosaic.values == processed.mosaic.values)
    }

    // MARK: - Camera and daylight multipliers are unused

    @Test("cam_mul and pre_mul do not affect the result")
    func cameraAndDaylightMultipliersAreUnused() throws {
        // Identical samples and levels, wildly different camera and daylight
        // multipliers. The explicit-gain result must be identical, byte for
        // byte, because the white-balance stage never sees metadata at all.
        let plausible = RAWMetadata.ColorMetadata(
            cameraMultipliers: [0.640625, 1.0, 5.5625, 0],
            daylightMultipliers: [2.2629104, 0.9284695, 1.2071348, 0]
        )
        let absurd = RAWMetadata.ColorMetadata(
            cameraMultipliers: [900, 0.0001, 42, 17],
            daylightMultipliers: [0.002, 1_000_000, 7, 3],
            asShotWhiteBalanceApplied: true
        )
        let none = RAWMetadata.ColorMetadata()

        let balancer = RAWWhiteBalancer()
        let gains = RAWWhiteBalanceGains(plane0: 2, plane1: 3, plane2: 4, plane3: 5)

        var results = [[Float]]()
        for color in [plausible, absurd, none] {
            let processed = try Self.processed(color: color)
            results.append(try balancer.apply(to: processed, gains: gains).mosaic.values)
        }

        #expect(results[0] == results[1])
        #expect(results[0] == results[2])

        // And the values are the literal products of the normalised source
        // and the supplied gains — nothing was rescaled against cam_mul.
        let processed = try Self.processed(color: absurd)
        for row in 0..<2 {
            for column in 0..<2 {
                let plane = try #require(processed.mosaic.colorPlaneIndex(row: row, column: column))
                let input = try #require(processed.mosaic.value(row: row, column: column))
                let gain = try #require(gains.gain(forColorPlane: plane))
                #expect(results[1][row * 2 + column] == input * gain)
            }
        }
    }

    @Test("The metadata carrying cam_mul stays reachable as a diagnostic")
    func metadataRemainsAvailable() throws {
        // Unused by processing, but not discarded: it is still the right
        // thing to show in a metadata panel.
        let color = RAWMetadata.ColorMetadata(
            cameraMultipliers: [0.640625, 1.0, 5.5625, 0],
            daylightMultipliers: [2.2629104, 0.9284695, 1.2071348, 0]
        )
        let processed = try Self.processed(color: color)
        let balanced = try RAWWhiteBalancer().apply(to: processed, gains: .identity)

        #expect(balanced.metadata.color.cameraMultipliers == color.cameraMultipliers)
        #expect(balanced.metadata.color.daylightMultipliers == color.daylightMultipliers)
        #expect(balanced.url == processed.url)
    }
}
