import Testing
import Foundation
@testable import InfraredConverter

/// The first application-owned processing stage against a real RAW file:
/// `RAW file → unpack → RAWMosaic → black subtraction → normalisation →
/// LinearRAWMosaic`.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly
/// without it.
@Suite(
    "RAWMosaicNormalizer integration",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct RAWMosaicNormalizerFixtureTests {
    private static func processFixture() throws -> ProcessedRAWMosaic {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        return try RAWMosaicNormalizer().process(decoded)
    }

    @Test("Geometry and CFA mapping are unchanged by normalisation")
    func geometryAndLayoutAreUnchanged() throws {
        let processed = try Self.processFixture()
        let source = processed.source.mosaic
        let linear = processed.mosaic

        #expect(linear.width == 4056)
        #expect(linear.height == 3040)
        #expect(linear.width == source.width)
        #expect(linear.height == source.height)
        #expect(linear.values.count == 4056 * 3040)
        #expect(linear.isGeometryConsistent)
        #expect(linear.sensorColorLayout == source.sensorColorLayout)

        // The source stride was LibRaw's; the output is tightly packed.
        #expect(source.bytesPerRow == 4056 * 2)
        #expect(linear.valuesPerRow == 4056)

        // Every coordinate keeps its colour plane. Sampled across the frame
        // rather than exhaustively — the CFA period is 2, so a stride that is
        // coprime with it covers both phases everywhere.
        for row in stride(from: 0, to: linear.height, by: 97) {
            for column in stride(from: 0, to: linear.width, by: 101) {
                #expect(linear.colorPlaneIndex(row: row, column: column)
                    == source.colorPlaneIndex(row: row, column: column))
            }
        }
    }

    @Test("The white level used is the metadata maximum, 4095, not linearMaximum or the bit depth")
    func whiteLevelPolicyIsMetadataMaximum() throws {
        let processed = try Self.processFixture()
        let levels = processed.metadata.levels

        #expect(processed.processing.whiteLevelPolicy == .metadataMaximum)
        #expect(processed.processing.whiteLevel == 4095)
        #expect(processed.processing.whiteLevel == levels.maximum)

        // The two values that must not have been used, pinned so a
        // regression to either is visible here rather than as a subtly
        // mis-scaled image.
        #expect(levels.linearMaximum == [3680, 3680, 3680, 3680])
        #expect(processed.source.mosaic.sourceRawBitDepth == 12)
        #expect(processed.processing.whiteLevel != 3680)
    }

    @Test("The effective black level is 64 across all four planes, and the denominator is 4031")
    func effectiveBlackAndDenominator() throws {
        let processed = try Self.processFixture()
        let levels = processed.metadata.levels

        for plane in 0..<4 {
            #expect(levels.blackLevel(row: 0, column: 0, colorPlane: plane) == 64)
        }
        #expect(processed.processing.whiteLevel - 64 == 4031)
    }

    @Test("No white balance, demosaic, colour matrix, gamma, orientation or clamping happened")
    func nothingBeyondNormalizationHappened() throws {
        let processed = try Self.processFixture()

        #expect(processed.processing.blackLevelSubtracted == true)
        #expect(processed.processing.normalized == true)
        #expect(processed.processing.clamped == false)
        #expect(processed.processing.whiteBalanceApplied == false)
        #expect(processed.processing.demosaiced == false)
        #expect(processed.processing.cameraColorMatrixApplied == false)
        #expect(processed.processing.gammaApplied == false)
        #expect(processed.processing.orientationApplied == false)

        // The decoder stage's own facts are unchanged too — the original
        // mosaic was not mutated in place.
        #expect(processed.source.processing.blackLevelSubtracted == false)
        #expect(processed.source.processing.normalizedToFullRange == false)
    }

    @Test("Normalisation matches the formula exactly, sample by sample")
    func valuesMatchTheFormula() throws {
        let processed = try Self.processFixture()
        let source = processed.source.mosaic
        let levels = processed.metadata.levels
        let white = Float(processed.processing.whiteLevel)

        for row in stride(from: 0, to: source.height, by: 251) {
            for column in stride(from: 0, to: source.width, by: 257) {
                let sample = try #require(source.sample(row: row, column: column))
                let plane = try #require(source.colorPlaneIndex(row: row, column: column))
                let black = Float(levels.blackLevel(row: row, column: column, colorPlane: plane))
                let expected = (Float(sample) - black) / (white - black)
                #expect(try #require(processed.mosaic.value(row: row, column: column)) == expected)
            }
        }
    }

    @Test("Every value is finite, and negatives survive while nothing is clamped to 1")
    func negativesSurviveAndNothingIsClamped() throws {
        let processed = try Self.processFixture()
        let statistics = MosaicStatistics(mosaic: processed.mosaic)

        #expect(statistics.nonFiniteCount == 0)

        // The fixture has 11 samples below the effective black level (see
        // docs/raw-pipeline.md), so exactly that many values must be
        // negative. Nothing clamped them to zero.
        #expect(statistics.belowZeroCount == 11)
        #expect(statistics.minimum < 0)

        // (61 - 64) / 4031 ≈ -0.000744. Compared with a tolerance rather
        // than pinned bit-exactly: the assertion is that the minimum is the
        // normalisation of the minimum sample, not a magic constant.
        let expectedMinimum = (Float(61) - Float(64)) / Float(4031)
        #expect(abs(statistics.minimum - expectedMinimum) < 1e-6)

        // The largest sample in this file is 2187, well under the white
        // level, so nothing here exceeds 1 — which is a fact about this
        // frame, not a clamp. The synthetic suite proves >1 is preserved.
        #expect(statistics.aboveOneCount == 0)
        let expectedMaximum = (Float(2187) - Float(64)) / Float(4031)
        #expect(abs(statistics.maximum - expectedMaximum) < 1e-6)
    }

    /// Prints the concrete processed statistics this milestone asked for.
    @Test("Diagnostic: normalised statistics for the Olympus E-PL3 fixture")
    func diagnosticStatistics() throws {
        let processed = try Self.processFixture()
        let linear = processed.mosaic
        let levels = processed.metadata.levels
        let statistics = MosaicStatistics(mosaic: linear)
        let total = Double(linear.values.count)

        var report = "\n--- LinearRAWMosaic diagnostic (Olympus E-PL3 fixture) ---\n"
        report += "dimensions: \(linear.width) x \(linear.height) (\(linear.values.count) values)\n"
        report += "storage: [Float] tightly packed, \(linear.values.count * 4) bytes\n"
        report += "white-level policy: \(linear.processing.whiteLevelPolicy)\n"
        report += "white level used: \(linear.processing.whiteLevel)\n"
        report += "effective black (plane 0): \(levels.blackLevel(row: 0, column: 0, colorPlane: 0))\n"
        report += "linearMaximum (unused): \(String(describing: levels.linearMaximum))\n"
        report += "minimum: \(statistics.minimum)\n"
        report += "maximum: \(statistics.maximum)\n"
        report += "mean: \(statistics.mean)\n"
        report += "per-plane means: \(statistics.perPlaneMean.sorted { $0.key < $1.key })\n"
        report += "count < 0: \(statistics.belowZeroCount) "
        report += "(\(Double(statistics.belowZeroCount) / total * 100)%)\n"
        report += "count == 0: \(statistics.zeroCount)\n"
        report += "count > 1: \(statistics.aboveOneCount) "
        report += "(\(Double(statistics.aboveOneCount) / total * 100)%)\n"
        report += "non-finite: \(statistics.nonFiniteCount)\n"
        report += "----------------------------------------------------------\n"
        print(report)

        #expect(statistics.nonFiniteCount == 0)
    }
}
