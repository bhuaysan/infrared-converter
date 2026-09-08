import Testing
import Foundation
@testable import InfraredConverter

/// Integration tests for the direct-mosaic-access path against a real RAW
/// file: `RAW file → open → unpack → RAW-state metadata snapshot → RAWMosaic`,
/// with `dcraw_process` never called.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly
/// without it.
@Suite("LibRawDecoder mosaic integration", .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)"))
struct LibRawDecoderMosaicFixtureTests {
    @Test("Mosaic dimensions equal the active area, tightly packed, 16 bits per stored sample")
    func mosaicDimensionsMatchActiveArea() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)

        // Regression pin: the Olympus E-PL3's active area is 4056 x 3040.
        // Chosen deliberately as a concrete regression value for this known
        // fixture; see the diagnostic test below for the full measured
        // geometry if this ever needs re-deriving.
        #expect(decoded.mosaic.width == 4056)
        #expect(decoded.mosaic.height == 3040)
        #expect(decoded.mosaic.width == decoded.metadata.geometry.visibleWidth)
        #expect(decoded.mosaic.height == decoded.metadata.geometry.visibleHeight)

        #expect(decoded.mosaic.bytesPerRow == decoded.mosaic.width * 2)
        #expect(decoded.mosaic.samples.count == decoded.mosaic.bytesPerRow * decoded.mosaic.height)
        #expect(decoded.mosaic.isGeometryConsistent)
    }

    @Test("The source RAW bit depth is the E-PL3's 12 bits, and it is not used as a white level")
    func sourceRawBitDepthAndRange() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)

        #expect(decoded.mosaic.sourceRawBitDepth == 12)

        let statistics = MosaicStatistics(mosaic: decoded.mosaic)
        #expect(statistics.maximum > statistics.minimum)

        // Samples do happen to fit the source depth's range for this camera,
        // but that is an observation about this file, not a guarantee the
        // type makes — `unpack()` may linearise, and the depth describes the
        // file rather than what came out. So the white level a later stage
        // will use comes from the level metadata, and the two are asserted
        // separately here precisely so they are not conflated.
        let depth = try #require(decoded.mosaic.sourceRawBitDepth)
        #expect(depth == 12)
        #expect(Int(statistics.maximum) <= (1 << depth) - 1)

        // The authoritative white level. For the E-PL3 it coincides with
        // 2^12 - 1; the point is that it is read, not derived.
        #expect(decoded.metadata.levels.maximum == 4095)
    }

    @Test("The mosaic is Bayer, and the plane at active (0,0) matches the metadata's own lookup")
    func bayerPlaneAtOrigin() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)

        #expect(decoded.metadata.sensor.pattern == .bayer)

        // Deliberately not assumed to be red: ask the metadata's own layout
        // what plane (0,0) is, and require the mosaic to agree.
        let expectedPlane = decoded.metadata.sensor.colorPlaneIndex(row: 0, column: 0)
        #expect(decoded.mosaic.colorPlaneIndex(row: 0, column: 0) == expectedPlane)
        #expect(expectedPlane != nil)
    }

    @Test("No processing beyond unpack has happened")
    func processingFactsAreAllFalse() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)

        #expect(decoded.processing.blackLevelSubtracted == false)
        #expect(decoded.processing.normalizedToFullRange == false)
        #expect(decoded.processing.whiteBalanceApplied == false)
        #expect(decoded.processing.demosaiced == false)
        #expect(decoded.processing.cameraColorMatrixApplied == false)
        #expect(decoded.processing.gammaApplied == false)
        #expect(decoded.processing.orientationApplied == false)
        #expect(decoded.processing.sourceStorage == .singleChannel)
    }

    @Test("Black is not subtracted from the mosaic: the metadata reports the post-unpack RAW-state levels")
    func blackLevelsUntouched() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)

        // These deliberately differ from the processed-RGB path's pinned
        // values (black 0, per-plane [64, 64, 64, 64]), which are read from
        // LibRaw's live state *before* unpack. `unpack()` canonicalises the
        // common component of cblack into black — i = min(cblack[0...3]) = 64
        // moves across — so the post-unpack RAW state this path snapshots
        // reports the same levels split the other way round. See
        // LibRawShimLifecycleFixtureTests.blackMetadataAcrossUnpack.
        #expect(decoded.metadata.levels.black == 64)
        #expect(decoded.metadata.levels.perPlaneBlack == [0, 0, 0, 0])

        // The split changed; the effective black level did not. This is the
        // number a later subtraction stage will actually use.
        for plane in 0..<4 {
            #expect(decoded.metadata.levels.blackLevel(row: 0, column: 0, colorPlane: plane) == 64)
        }

        // And nothing has been subtracted from the samples themselves.
        #expect(decoded.processing.blackLevelSubtracted == false)
    }

    /// Prints the concrete diagnostic numbers requested for this milestone:
    /// raw readout dimensions, active mosaic dimensions, LibRaw's raw_pitch,
    /// the copied row stride, sample storage type, bit depth, min/max/mean,
    /// per-CFA-plane means, counts below the effective black level and
    /// at/above maximum, and dataMaximum.
    @Test("Diagnostic: concrete numbers for the Olympus E-PL3 fixture")
    func diagnosticNumbers() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        let mosaic = decoded.mosaic
        let metadata = decoded.metadata

        let statistics = MosaicStatistics(mosaic: mosaic, metadata: metadata)

        var report = "\n--- RAWMosaic diagnostic (Olympus E-PL3 fixture) ---\n"
        report += "raw readout: \(metadata.geometry.rawWidth) x \(metadata.geometry.rawHeight)\n"
        report += "active mosaic: \(mosaic.width) x \(mosaic.height)\n"
        report += "top/left margin: \(metadata.geometry.topMargin) / \(metadata.geometry.leftMargin)\n"
        report += "LibRaw raw_pitch (bytes): \(decoded.processing.sourceRowPitch)\n"
        report += "copied row stride (bytes): \(decoded.processing.destinationRowStride)\n"
        report += "sample storage: \(decoded.processing.sourceStorage), format: \(mosaic.sampleFormat)\n"
        report += "source RAW bit depth: \(mosaic.sourceRawBitDepth.map(String.init) ?? "unreported")\n"
        report += "min: \(statistics.minimum), max: \(statistics.maximum), mean (sparse sample): \(statistics.mean)\n"
        report += "per-CFA-plane means (sparse sample): \(statistics.perPlaneMean)\n"
        report += "count below effective black level (full buffer): \(statistics.belowBlackCount)\n"
        report += "count at/above metadata.levels.maximum (full buffer): \(statistics.atOrAboveMaximumCount)\n"
        report += "metadata.levels.maximum: \(metadata.levels.maximum)\n"
        report += "metadata.levels.dataMaximum: \(String(describing: metadata.levels.dataMaximum))\n"
        report += "metadata.levels.black: \(metadata.levels.black)\n"
        report += "metadata.levels.perPlaneBlack: \(metadata.levels.perPlaneBlack)\n"
        report += "metadata.levels.linearMaximum: \(String(describing: metadata.levels.linearMaximum))\n"
        report += "-----------------------------------------------------\n"

        // swift-testing has no first-class "print for the record" API in
        // this codebase yet; Swift.print is the same mechanism the existing
        // fixture tests' debug logging relies on, and this is the vehicle
        // the milestone asked for to surface these numbers.
        print(report)

        #expect(statistics.maximum > 0)
    }

    /// Statistics over a decoded `RAWMosaic`, computed directly from its
    /// tightly packed sample buffer and the sensor colour layout it carries.
    ///
    /// min/max/counts are computed over the **full buffer**; the mean and
    /// per-plane means are sampled sparsely (documented here, as required),
    /// since a full scan is not needed for a sanity/diagnostic statistic.
    private struct MosaicStatistics {
        let minimum: UInt16
        let maximum: UInt16
        let mean: Double
        /// Mean per colour-plane index (0..<colorCount), sparse-sampled.
        let perPlaneMean: [Int: Double]
        let belowBlackCount: Int
        let atOrAboveMaximumCount: Int

        init(mosaic: RAWMosaic, metadata: RAWMetadata? = nil) {
            var minimum = UInt16.max
            var maximum = UInt16.min
            var sparseTotal = 0.0
            var sparseCount = 0
            var perPlaneTotal: [Int: Double] = [:]
            var perPlaneCount: [Int: Int] = [:]
            var belowBlack = 0
            var atOrAboveMax = 0

            let effectiveMaximum = metadata?.levels.maximum

            // Full-buffer pass for min/max/counts, sparse for the means.
            var sampledRows = 0
            for row in stride(from: 0, to: mosaic.height, by: 1) {
                let sampleThisRow = (row % 31 == 0) // sparse row sampling for means
                if sampleThisRow { sampledRows += 1 }
                for column in 0..<mosaic.width {
                    guard let value = mosaic.sample(row: row, column: column) else { continue }
                    minimum = Swift.min(minimum, value)
                    maximum = Swift.max(maximum, value)
                    if let maximumLevel = effectiveMaximum, value >= maximumLevel {
                        atOrAboveMax += 1
                    }
                    if let metadata,
                       let plane = mosaic.colorPlaneIndex(row: row, column: column) {
                        let black = metadata.levels.blackLevel(row: row, column: column, colorPlane: plane)
                        if value < black { belowBlack += 1 }
                    }

                    if sampleThisRow, column % 37 == 0 {
                        sparseTotal += Double(value)
                        sparseCount += 1
                        if let plane = mosaic.colorPlaneIndex(row: row, column: column) {
                            perPlaneTotal[plane, default: 0] += Double(value)
                            perPlaneCount[plane, default: 0] += 1
                        }
                    }
                }
            }

            self.minimum = minimum
            self.maximum = maximum
            self.mean = sparseCount > 0 ? sparseTotal / Double(sparseCount) : 0
            self.perPlaneMean = perPlaneTotal.reduce(into: [:]) { result, entry in
                let count = perPlaneCount[entry.key] ?? 0
                result[entry.key] = count > 0 ? entry.value / Double(count) : 0
            }
            self.belowBlackCount = belowBlack
            self.atOrAboveMaximumCount = atOrAboveMax
        }
    }
}
