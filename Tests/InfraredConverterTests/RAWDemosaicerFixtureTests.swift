import Testing
import Foundation
@testable import InfraredConverter

/// Bilinear Bayer demosaicing against a real RAW file, through the
/// application-owned mosaic pipeline only:
///
/// ```text
/// RAW file → decodeMosaic → RAWMosaicNormalizer → RAWWhiteBalanceEstimator
///          → RAWWhiteBalancer → RAWDemosaicer
/// ```
///
/// ## LibRaw is not the oracle here
///
/// `LibRawDecoder.decode()` is never called for anything asserted below, and
/// nothing is compared against its processed RGB output. That path applies a
/// camera colour matrix, gamma, its own black/white handling and a different
/// interpolation with different border behaviour, so agreeing with it would
/// mean this stage was doing more than it claims. The oracle is the documented
/// algorithm, checked here against the white-balanced source the stage
/// actually consumed.
///
/// ## The statistics are diagnostic, not colour validation
///
/// The gains come from the same central rectangle the estimator suite uses,
/// which is deterministic and contains all four CFA positions — and is **not**
/// a claim that the patch is neutral. Nothing below asserts that the image
/// looks right, that its colour is correct, or that these numbers are an
/// Olympus E-PL3 calibration. No camera matrix has been applied, so there is
/// no colour to be correct about yet.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly without
/// it.
@Suite(
    "RAWDemosaicer integration",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct RAWDemosaicerFixtureTests {

    /// The same deterministic diagnostic region the estimator suite measures.
    static let diagnosticRegion = RAWWhiteBalanceEstimatorFixtureTests.diagnosticRegion

    /// Decode, normalise, estimate from the diagnostic patch, and apply that
    /// estimate — everything up to but not including demosaicing.
    ///
    /// The estimated gains are diagnostic only, exactly as in the estimator
    /// suite. What matters here is that the mosaic reaching the demosaicer is
    /// genuinely white-balanced with four different per-plane gains, so a
    /// stage that confused colour planes could not pass unnoticed.
    private static func whiteBalancedFixture() throws -> WhiteBalancedProcessedRAWMosaic {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: normalized.mosaic, region: diagnosticRegion)
        return try RAWWhiteBalancer().apply(to: normalized, estimate: estimate)
    }

    // MARK: - An independent reference, written in the test

    /// The colour of a CFA position, derived from the decoder's own layout
    /// rather than from `RAWBayerCellPattern`.
    ///
    /// This is deliberately a second, separate derivation: it reads the
    /// colour-plane index and the colour description straight off the sensor
    /// layout and maps the letter itself. Nothing in the demosaicer is
    /// consulted, so a wrong Bayer phase, a red/blue swap or a mishandled
    /// second green in the production resolver cannot hide by being reused
    /// here.
    private static func referenceChannel(
        _ layout: RAWMetadata.SensorColorLayout,
        row: Int,
        column: Int
    ) -> RAWLinearRGBChannel? {
        guard let plane = layout.colorPlaneIndex(row: row, column: column) else { return nil }
        let letters = Array(layout.colorDescription)
        guard plane >= 0, plane < letters.count else { return nil }
        switch letters[plane] {
        case "R": return .red
        case "G": return .green
        case "B": return .blue
        default: return nil
        }
    }

    /// The expected RGB at one coordinate, computed here from the documented
    /// rules and the white-balanced source, with no production interpolation
    /// helper involved.
    private static func referencePixel(
        _ mosaic: WhiteBalancedRAWMosaic,
        row: Int,
        column: Int
    ) throws -> RAWLinearRGBPixel {
        let layout = mosaic.sensorColorLayout
        let centre = try #require(Self.referenceChannel(layout, row: row, column: column))
        let native = try #require(mosaic.value(row: row, column: column))

        let axial = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        let diagonal = [(-1, -1), (-1, 1), (1, -1), (1, 1)]

        func mean(of wanted: RAWLinearRGBChannel, over offsets: [(Int, Int)]) throws -> Float {
            var sum = 0.0
            var count = 0
            for (rowDelta, columnDelta) in offsets {
                let r = row + rowDelta
                let c = column + columnDelta
                guard r >= 0, r < mosaic.height, c >= 0, c < mosaic.width else { continue }
                guard Self.referenceChannel(layout, row: r, column: c) == wanted else { continue }
                sum += Double(try #require(mosaic.value(row: r, column: c)))
                count += 1
            }
            #expect(count > 0)
            return Float(sum / Double(count))
        }

        switch centre {
        case .red:
            return RAWLinearRGBPixel(
                red: native,
                green: try mean(of: .green, over: axial),
                blue: try mean(of: .blue, over: diagonal)
            )
        case .blue:
            return RAWLinearRGBPixel(
                red: try mean(of: .red, over: diagonal),
                green: try mean(of: .green, over: axial),
                blue: native
            )
        case .green:
            return RAWLinearRGBPixel(
                red: try mean(of: .red, over: axial),
                green: native,
                blue: try mean(of: .blue, over: axial)
            )
        }
    }

    // MARK: - Geometry, provenance and finiteness

    @Test("Geometry, storage, provenance and the retained upstream chain")
    func geometryProvenanceAndUpstream() throws {
        let balanced = try Self.whiteBalancedFixture()
        #expect(balanced.mosaic.width == 4056)
        #expect(balanced.mosaic.height == 3040)

        let result = try RAWDemosaicer().demosaic(balanced)
        let image = result.image

        // Every CFA location produced exactly one pixel: no crop, no
        // downsample, no border trimming.
        #expect(image.width == 4056)
        #expect(image.height == 3040)
        #expect(image.values.count == 4056 * 3040 * 3)
        #expect(image.values.count == 36_990_720)
        #expect(image.isGeometryConsistent)
        #expect(image.expectedValueCount == 36_990_720)
        #expect(image.pixelCount == 12_330_240)
        #expect(image.valuesPerRow == 4056 * 3)

        // What this stage did, and did not do.
        let processing = image.processing
        #expect(processing.algorithm == .bilinearBayer)
        #expect(processing.demosaiced)
        #expect(processing.whiteBalanceApplied)
        #expect(!processing.clamped)
        #expect(!processing.cameraColorMatrixApplied)
        #expect(!processing.gammaApplied)
        #expect(!processing.orientationApplied)
        #expect(processing.blackLevelSubtracted)
        #expect(processing.normalized)

        // The phase was discovered from this file's own layout.
        #expect(processing.sourcePattern.phaseDescription == "RGGB")
        #expect(balanced.mosaic.sensorColorLayout.colorDescription == "RGBG")
        #expect(balanced.mosaic.sensorColorLayout.colorCount == 3)

        // Upstream white-balance provenance travelled with it, estimate and
        // all.
        guard case .neutralPatch(let source) = processing.whiteBalanceProcessing.gainSource else {
            Issue.record("expected the estimate's neutral-patch provenance")
            return
        }
        #expect(source.region == Self.diagnosticRegion)
        #expect(source.scalePolicy == .preserveStrongestMeasuredPlane)
        #expect(processing.whiteBalanceGains == balanced.mosaic.processing.gains)
        #expect(processing.whiteBalanceProcessing.linearProcessing.whiteLevel == 4095)
        #expect(processing.whiteBalanceProcessing.linearProcessing.whiteLevelPolicy
                == .metadataMaximum)

        // And every earlier representation is still reachable, unmutated.
        #expect(result.whiteBalancedMosaic.values.count == 12_330_240)
        #expect(result.linearMosaic.values.count == 12_330_240)
        #expect(!result.linearMosaic.processing.whiteBalanceApplied)
        #expect(result.source.source.source.mosaic.width == 4056)
        #expect(result.metadata.identity.model?.isEmpty == false)
        #expect(result.url == balanced.url)
    }

    // MARK: - Spot checks against the white-balanced source

    @Test("Native CFA values are bit-identical in their own output channel")
    func nativeSpotChecksAreBitIdentical() throws {
        let balanced = try Self.whiteBalancedFixture()
        let mosaic = balanced.mosaic
        let layout = mosaic.sensorColorLayout
        let image = try RAWDemosaicer().demosaic(mosaic)

        // Deterministic interior coordinates covering all four CFA parities,
        // and therefore one R, one G1, one B and one G2 location.
        let coordinates = [(1500, 2000), (1500, 2001), (1501, 2000), (1501, 2001)]
        var seenPlanes = Set<Int>()

        for (row, column) in coordinates {
            let plane = try #require(layout.colorPlaneIndex(row: row, column: column))
            seenPlanes.insert(plane)
            let channel = try #require(Self.referenceChannel(layout, row: row, column: column))
            let native = try #require(mosaic.value(row: row, column: column))
            let output = try #require(image.value(row: row, column: column, channel: channel))

            #expect(output.bitPattern == native.bitPattern,
                    "plane \(plane), channel \(channel) at (\(row), \(column))")
        }

        // All four plane indices really occur, so G1 and G2 were both covered
        // — and both landed in the single output green channel.
        #expect(seenPlanes == [0, 1, 2, 3])
        for (row, column) in coordinates where [1, 3].contains(
            layout.colorPlaneIndex(row: row, column: column) ?? -1
        ) {
            #expect(Self.referenceChannel(layout, row: row, column: column) == .green)
        }

        // Sampled more widely, on strides coprime with the CFA period so both
        // phases are hit everywhere in the frame.
        for row in stride(from: 3, to: mosaic.height, by: 503) {
            for column in stride(from: 5, to: mosaic.width, by: 509) {
                let channel = try #require(Self.referenceChannel(layout, row: row, column: column))
                let native = try #require(mosaic.value(row: row, column: column))
                #expect(try #require(image.value(row: row, column: column, channel: channel))
                        .bitPattern == native.bitPattern)
            }
        }
    }

    @Test("Interpolated channels match an independently computed neighbourhood")
    func interpolatedSpotChecksMatchTheReference() throws {
        let balanced = try Self.whiteBalancedFixture()
        let mosaic = balanced.mosaic
        let image = try RAWDemosaicer().demosaic(mosaic)

        // Interior coordinates only, so every neighbourhood is complete, and
        // all four CFA parities are represented several times over.
        var coordinates: [(Int, Int)] = [
            (1500, 2000), (1500, 2001), (1501, 2000), (1501, 2001),
            (1, 1), (1, 2), (2, 1), (2, 2),
            (3038, 4054), (3038, 4053), (3037, 4054), (3037, 4053),
        ]
        for row in stride(from: 101, to: mosaic.height - 1, by: 701) {
            for column in stride(from: 103, to: mosaic.width - 1, by: 703) {
                coordinates.append((row, column))
                coordinates.append((row, column + 1))
                coordinates.append((row + 1, column))
                coordinates.append((row + 1, column + 1))
            }
        }

        for (row, column) in coordinates {
            let expected = try Self.referencePixel(mosaic, row: row, column: column)
            let actual = try #require(image.pixel(row: row, column: column))
            #expect(actual.red == expected.red, "red at (\(row), \(column))")
            #expect(actual.green == expected.green, "green at (\(row), \(column))")
            #expect(actual.blue == expected.blue, "blue at (\(row), \(column))")
        }
        #expect(coordinates.count > 50)
    }

    @Test("Border pixels average only their real contributors, on real data")
    func borderSpotChecks() throws {
        let balanced = try Self.whiteBalancedFixture()
        let mosaic = balanced.mosaic
        let image = try RAWDemosaicer().demosaic(mosaic)

        // The same independent reference, which applies the same one-sided
        // border rule, checked at every corner and on each edge.
        let coordinates = [
            (0, 0), (0, 1), (1, 0), (1, 1),
            (0, 2000), (0, 2001), (3039, 2000), (3039, 2001),
            (1500, 0), (1501, 0), (1500, 4055), (1501, 4055),
            (0, 4055), (3039, 0), (3039, 4055),
        ]
        for (row, column) in coordinates {
            let expected = try Self.referencePixel(mosaic, row: row, column: column)
            let actual = try #require(image.pixel(row: row, column: column))
            #expect(actual.red == expected.red, "red at (\(row), \(column))")
            #expect(actual.green == expected.green, "green at (\(row), \(column))")
            #expect(actual.blue == expected.blue, "blue at (\(row), \(column))")
        }
    }

    // MARK: - Diagnostics

    /// Reports the concrete numbers for the fixture, and times the stage.
    ///
    /// > Everything printed here is **diagnostic**. None of it validates
    /// > colour: no camera matrix has been applied at this stage, so these
    /// > values are camera-native sensor responses, not colour-space
    /// > coordinates. A mean or a maximum here says nothing about whether the
    /// > image looks right.
    @Test("Diagnostic: demosaiced statistics for the Olympus E-PL3 fixture")
    func diagnosticStatistics() throws {
        let balanced = try Self.whiteBalancedFixture()

        let start = DispatchTime.now().uptimeNanoseconds
        let image = try RAWDemosaicer().demosaic(balanced.mosaic)
        let elapsedMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        let statistics = RGBImageStatistics(image: image)
        let payloadBytes = 4056 * 3040 * 3 * MemoryLayout<Float>.stride

        var report = "\n--- DemosaicedRAWRGBImage diagnostic (Olympus E-PL3 fixture) ---\n"
        report += "DIAGNOSTIC ONLY: no camera matrix has been applied, so nothing here\n"
        report += "validates colour. These are linear camera-native sensor responses.\n"
        report += "algorithm: \(image.processing.algorithm)\n"
        report += "discovered Bayer phase: \(image.processing.sourcePattern.phaseDescription)\n"
        report += "input mosaic: \(balanced.mosaic.width) x \(balanced.mosaic.height) "
        report += "(\(balanced.mosaic.values.count) samples)\n"
        report += "output image: \(image.width) x \(image.height) "
        report += "(\(image.values.count) Float values)\n"
        report += "owned payload: \(payloadBytes) bytes "
        report += "(\(Double(payloadBytes) / 1_000_000) MB, "
        report += "\(MemoryLayout<Float>.stride) bytes per Float)\n"
        for channel in RAWLinearRGBChannel.allCases {
            let c = statistics[channel]
            report += "\(channel): min \(c.minimum)  max \(c.maximum)  mean \(c.mean)  "
            report += "< 0: \(c.belowZeroCount)  > 1: \(c.aboveOneCount)\n"
        }
        report += "non-finite: \(statistics.nonFiniteCount)\n"
        report += "demosaic time (debug build): \(elapsedMilliseconds) ms\n"
        // The owned payload above is this buffer alone. It is not process RSS,
        // and the pipeline deliberately still retains the white-balanced and
        // normalised mosaics (about 49 MB each) so gains and algorithm can be
        // changed without decoding again. See DemosaicedProcessedRAWImage.
        let upstreamBytes = 2 * 4056 * 3040 * MemoryLayout<Float>.stride
        report += "retained upstream Float32 mosaics: \(upstreamBytes) bytes "
        report += "(deliberate, for reprocessing; total working set is higher than either "
        report += "figure and neither is process RSS)\n"
        report += "----------------------------------------------------------------\n"
        print(report)

        // The only assertions: the stage produced finite values, kept the
        // out-of-range ones it was given, and allocated exactly three Floats
        // per pixel.
        #expect(statistics.nonFiniteCount == 0)
        #expect(statistics.valueCount == 36_990_720)
        #expect(payloadBytes == 147_962_880)
        #expect(MemoryLayout<Float>.stride == 4)
        #expect(!image.processing.clamped)
    }
}
