import Testing
import Foundation
@testable import InfraredConverter

/// The infrared white-balance stage against a real RAW file, through the
/// actual pipeline: `RAW file → unpack → RAWMosaic → RAWMosaicNormalizer →
/// LinearRAWMosaic → RAWWhiteBalancer → WhiteBalancedRAWMosaic`.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly
/// without it.
@Suite(
    "RAWWhiteBalancer integration",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct RAWWhiteBalancerFixtureTests {
    /// Deterministic gains for testing only.
    ///
    /// These are **not** an Olympus E-PL3 calibration, not a recommendation,
    /// not an IR filter profile, and not the output of any estimator. They
    /// are four distinct primes-apart numbers chosen so that every plane's
    /// contribution is individually identifiable in the output — in
    /// particular so that plane 3 and plane 1 cannot be confused.
    static let testGains = RAWWhiteBalanceGains(plane0: 2, plane1: 3, plane2: 4, plane3: 5)

    private static func processFixture() throws -> ProcessedRAWMosaic {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        return try RAWMosaicNormalizer().process(decoded)
    }

    // MARK: - Identity

    @Test("Identity gains reproduce the normalised mosaic exactly")
    func identityGainsAreExact() throws {
        let processed = try Self.processFixture()
        let balanced = try RAWWhiteBalancer().apply(to: processed, gains: .identity)

        // Bit-identical over all 12,330,240 values, not close.
        #expect(balanced.mosaic.values == processed.mosaic.values)
        #expect(balanced.mosaic.width == processed.mosaic.width)
        #expect(balanced.mosaic.height == processed.mosaic.height)
        #expect(balanced.mosaic.sensorColorLayout == processed.mosaic.sensorColorLayout)
    }

    // MARK: - Deterministic test gains

    @Test("Every sampled coordinate is its normalised value times its own plane's gain")
    func sampledCoordinatesMatchTheirPlaneGain() throws {
        let processed = try Self.processFixture()
        let linear = processed.mosaic
        let balanced = try RAWWhiteBalancer()
            .apply(to: processed, gains: Self.testGains).mosaic

        // Strides coprime with the CFA period so both phases are covered
        // everywhere, plus the four coordinates of the top-left cell so all
        // four plane indices are certainly represented.
        var coordinates: [(Int, Int)] = [(0, 0), (0, 1), (1, 0), (1, 1)]
        for row in stride(from: 0, to: linear.height, by: 251) {
            for column in stride(from: 0, to: linear.width, by: 257) {
                coordinates.append((row, column))
            }
        }

        var seenPlanes = Set<Int>()
        for (row, column) in coordinates {
            let plane = try #require(linear.colorPlaneIndex(row: row, column: column))
            seenPlanes.insert(plane)

            // The CFA plane is unchanged by white balance.
            #expect(balanced.colorPlaneIndex(row: row, column: column) == plane)

            let input = try #require(linear.value(row: row, column: column))
            let gain = try #require(Self.testGains.gain(forColorPlane: plane))
            #expect(try #require(balanced.value(row: row, column: column)) == input * gain)
        }

        // All four CFA plane indices really occur in this file, including
        // plane 3 despite colorCount being 3.
        #expect(seenPlanes == [0, 1, 2, 3])
        #expect(linear.sensorColorLayout.colorCount == 3)
        #expect(linear.sensorColorLayout.colorDescription == "RGBG")
    }

    @Test("Per-plane means scale by exactly that plane's gain")
    func perPlaneMeansScaleByTheirGain() throws {
        let processed = try Self.processFixture()
        let before = MosaicStatistics(mosaic: processed.mosaic)
        let after = MosaicStatistics(
            mosaic: try RAWWhiteBalancer().apply(to: processed, gains: Self.testGains).mosaic
        )

        for plane in 0..<4 {
            let mean = try #require(before.perPlaneMean[plane])
            let balancedMean = try #require(after.perPlaneMean[plane])
            let gain = Double(try #require(Self.testGains.gain(forColorPlane: plane)))
            // A relative tolerance: the means are summed over 3 million
            // Doubles each, so the two accumulations differ in the last bits.
            #expect(abs(balancedMean - mean * gain) < abs(mean * gain) * 1e-9)
        }

        // The two green planes were not forced to the same gain: plane 3's
        // mean grew by 5/3 more than plane 1's, relative to their inputs.
        let g1Ratio = try #require(after.perPlaneMean[1]) / #require(before.perPlaneMean[1])
        let g2Ratio = try #require(after.perPlaneMean[3]) / #require(before.perPlaneMean[3])
        #expect(abs(g1Ratio - 3) < 1e-6)
        #expect(abs(g2Ratio - 5) < 1e-6)
    }

    @Test("Strictly positive gains preserve the sign of every value")
    func signsArePreserved() throws {
        let processed = try Self.processFixture()
        let before = MosaicStatistics(mosaic: processed.mosaic)
        let after = MosaicStatistics(
            mosaic: try RAWWhiteBalancer().apply(to: processed, gains: Self.testGains).mosaic
        )

        // Multiplying by a positive number cannot change a sign, so the
        // negative count is unchanged: the 11 sub-black samples in this file
        // are still negative afterwards, and nothing was clamped to zero.
        #expect(before.belowZeroCount == 11)
        #expect(after.belowZeroCount == before.belowZeroCount)
        #expect(after.zeroCount == before.zeroCount)
        #expect(after.minimum < 0)
        #expect(after.nonFiniteCount == 0)
    }

    @Test("Nothing is clamped: values above one appear once gains push them there")
    func valuesAboveOneAreProduced() throws {
        let processed = try Self.processFixture()
        let before = MosaicStatistics(mosaic: processed.mosaic)
        // The normalised frame peaks at ~0.527, so no value exceeds 1 yet.
        #expect(before.aboveOneCount == 0)

        let after = MosaicStatistics(
            mosaic: try RAWWhiteBalancer().apply(to: processed, gains: Self.testGains).mosaic
        )

        // With gains of 2...5 the brighter half of the frame crosses 1, and
        // those values are kept rather than clipped.
        #expect(after.aboveOneCount > 0)
        #expect(after.maximum > 1)
        #expect(after.nonFiniteCount == 0)
    }

    @Test("Geometry, layout and provenance survive white balance")
    func geometryLayoutAndProvenance() throws {
        let processed = try Self.processFixture()
        let result = try RAWWhiteBalancer().apply(to: processed, gains: Self.testGains)
        let balanced = result.mosaic

        #expect(balanced.width == 4056)
        #expect(balanced.height == 3040)
        #expect(balanced.values.count == 4056 * 3040)
        #expect(balanced.isGeometryConsistent)
        #expect(balanced.valuesPerRow == 4056)

        // Exact gains, reproducible from provenance alone.
        #expect(balanced.processing.gains == Self.testGains)
        #expect(balanced.processing.gains.gainsByColorPlane == [2, 3, 4, 5])
        #expect(balanced.processing.gainSource == .explicit)
        #expect(balanced.processing.whiteBalanceApplied)
        #expect(!balanced.processing.clamped)
        #expect(!balanced.processing.demosaiced)
        #expect(!balanced.processing.cameraColorMatrixApplied)
        #expect(!balanced.processing.gammaApplied)
        #expect(!balanced.processing.orientationApplied)

        // The upstream normalisation record travelled with it.
        #expect(balanced.processing.linearProcessing.whiteLevel == 4095)
        #expect(balanced.processing.linearProcessing.whiteLevelPolicy == .metadataMaximum)

        // The normalised source is intact and untouched.
        #expect(result.linearMosaic.values.count == balanced.values.count)
        #expect(!result.linearMosaic.processing.whiteBalanceApplied)
    }

    @Test("The file's own cam_mul and pre_mul had no effect on the result")
    func cameraMultipliersHadNoEffect() throws {
        let processed = try Self.processFixture()
        // The fixture really does carry both, so this is not a vacuous check.
        let cameraMultipliers = try #require(processed.metadata.color.cameraMultipliers)
        let daylightMultipliers = try #require(processed.metadata.color.daylightMultipliers)
        #expect(cameraMultipliers.count >= 3)
        #expect(daylightMultipliers.count >= 3)

        let balanced = try RAWWhiteBalancer().apply(to: processed, gains: Self.testGains).mosaic

        // Had cam_mul been folded in, plane 0's ratio would not be exactly 2.
        for (row, column, plane) in [(0, 0, 0), (0, 1, 1), (1, 1, 2), (1, 0, 3)] {
            let input = try #require(processed.mosaic.value(row: row, column: column))
            let gain = try #require(Self.testGains.gain(forColorPlane: plane))
            #expect(try #require(balanced.value(row: row, column: column)) == input * gain)
        }
    }

    @Test("Changing gains restarts from the normalised source rather than compounding")
    func rebalancingDoesNotCompound() throws {
        let processed = try Self.processFixture()
        let balancer = RAWWhiteBalancer()

        let first = try balancer.apply(to: processed, gains: Self.testGains)
        let doubled = RAWWhiteBalanceGains(plane0: 4, plane1: 6, plane2: 8, plane3: 10)
        let second = try balancer.apply(gains: doubled, replacing: first)

        // 4x the normalised values, not 8x (which chaining would give).
        for (row, column) in [(0, 0), (100, 100), (3039, 4055)] {
            let input = try #require(processed.mosaic.value(row: row, column: column))
            let plane = try #require(processed.mosaic.colorPlaneIndex(row: row, column: column))
            let gain = try #require(doubled.gain(forColorPlane: plane))
            #expect(try #require(second.mosaic.value(row: row, column: column)) == input * gain)
        }
        #expect(second.linearMosaic.values == processed.mosaic.values)
    }

    // MARK: - Diagnostics

    /// Prints the concrete statistics this milestone asked for, and times the
    /// stage. Nothing here asserts a timing.
    @Test("Diagnostic: white-balanced statistics for the Olympus E-PL3 fixture")
    func diagnosticStatistics() throws {
        let processed = try Self.processFixture()
        let linear = processed.mosaic
        let balancer = RAWWhiteBalancer()

        let start = DispatchTime.now().uptimeNanoseconds
        let balanced = try balancer.apply(to: processed, gains: Self.testGains).mosaic
        let elapsedMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        let before = MosaicStatistics(mosaic: linear)
        let after = MosaicStatistics(mosaic: balanced)
        let total = Double(balanced.values.count)

        var report = "\n--- WhiteBalancedRAWMosaic diagnostic (Olympus E-PL3 fixture) ---\n"
        report += "dimensions: \(balanced.width) x \(balanced.height) (\(balanced.values.count) values)\n"
        report += "storage: [Float] tightly packed, \(balanced.values.count * 4) bytes\n"
        report += "gain source: \(balanced.processing.gainSource)\n"
        report += "gains (test-only, not a calibration): "
        report += "\(balanced.processing.gains.gainsByColorPlane)\n"
        report += "minimum: \(after.minimum)  (before WB: \(before.minimum))\n"
        report += "maximum: \(after.maximum)  (before WB: \(before.maximum))\n"
        report += "mean: \(after.mean)  (before WB: \(before.mean))\n"
        report += "per-plane means before WB: \(before.perPlaneMeansInOrder)\n"
        report += "per-plane means after WB:  \(after.perPlaneMeansInOrder)\n"
        report += "count < 0: \(after.belowZeroCount) (before WB: \(before.belowZeroCount))\n"
        report += "count == 0: \(after.zeroCount) (before WB: \(before.zeroCount))\n"
        report += "count > 1: \(after.aboveOneCount) "
        report += "(\(Double(after.aboveOneCount) / total * 100)%, before WB: \(before.aboveOneCount))\n"
        report += "non-finite: \(after.nonFiniteCount)\n"
        report += "apply time (debug build): \(elapsedMilliseconds) ms\n"
        report += "-----------------------------------------------------------------\n"
        print(report)

        #expect(after.nonFiniteCount == 0)
    }
}
