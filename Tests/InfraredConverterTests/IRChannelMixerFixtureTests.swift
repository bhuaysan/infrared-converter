import Testing
import Foundation
@testable import InfraredConverter

/// The creative channel-mix stage against a real RAW file, through the
/// application-owned pipeline only:
///
/// ```text
/// RAW file → decodeMosaic → RAWMosaicNormalizer → RAWWhiteBalanceEstimator
///          → RAWWhiteBalancer → RAWDemosaicer → RAWWorkingColorConverter
///          → IRChannelMixer
/// ```
///
/// ## LibRaw is not the oracle here
///
/// `LibRawDecoder.decode()` is never called for anything asserted below, and
/// nothing is compared against its processed RGB output. That legacy path
/// applies a camera colour matrix, gamma and its own black/white handling, so
/// agreeing with it would mean this stage was doing more than it claims.
///
/// ## The camera-to-working step is the identity false-colour assignment
///
/// Deliberately, and for every test here: it keeps the creative stage's
/// fixture independent of the file's visible-light `rgbFromCamera`, whose
/// validity for an infrared capture is exactly the open question. What is
/// measured below is therefore the channel mix and nothing else.
///
/// ## Nothing here is a colour validation
///
/// A red/blue-swapped frame is the exact red/blue swap of its input. It is not
/// "correct infrared colour": no rendering available in this project is a
/// camera calibration, a filter calibration or a measurement, and every number
/// printed below is a diagnostic.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly without
/// it.
@Suite(
    "IRChannelMixer integration",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct IRChannelMixerFixtureTests {

    /// The same deterministic diagnostic region the estimator, demosaicer and
    /// working-colour suites measure.
    static let diagnosticRegion = RAWWhiteBalanceEstimatorFixtureTests.diagnosticRegion

    /// Everything up to but not including the channel mix, with the identity
    /// false-colour camera-to-working transform.
    private static func workingColorFixture() throws -> WorkingColorProcessedRAWImage {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: normalized.mosaic, region: diagnosticRegion)
        let balanced = try RAWWhiteBalancer().apply(to: normalized, estimate: estimate)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)
        return try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )
    }

    private static func channelReport(
        _ statistics: RGBImageStatistics,
        title: String
    ) -> String {
        var report = "\(title)\n"
        for channel in RAWLinearRGBChannel.allCases {
            let c = statistics[channel]
            report += "  \(channel): min \(c.minimum)  max \(c.maximum)  mean \(c.mean)  "
            report += "< 0: \(c.belowZeroCount)  > 1: \(c.aboveOneCount)\n"
        }
        report += "  non-finite: \(statistics.nonFiniteCount)\n"
        return report
    }

    // MARK: - Identity

    @Test("Identity: geometry, provenance, and the whole 148 MB buffer bit for bit")
    func identityIsBitIdenticalOnTheFixture() throws {
        let working = try Self.workingColorFixture()

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try IRChannelMixer().apply(to: working, mix: .identity)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let image = result.image

        // Geometry is untouched: this stage is per-pixel.
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
        #expect(processing.mixSource == .identity)
        #expect(processing.matrix == .identity)
        #expect(processing.channelMixApplied)
        #expect(processing.workingColorSpace == .extendedLinearSRGB)
        #expect(processing.workingColorSpace == working.image.processing.workingColorSpace)
        #expect(!processing.clamped)
        #expect(!processing.gammaApplied)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.displayEncodingApplied)
        #expect(!processing.orientationApplied)
        #expect(!processing.isValidatedInfraredCalibration)

        // The whole buffer, by bit pattern.
        var mismatches = 0
        var nonFinite = 0
        working.image.values.withUnsafeBufferPointer { source in
            image.values.withUnsafeBufferPointer { destination in
                for index in 0..<source.count {
                    if destination[index].bitPattern != source[index].bitPattern {
                        mismatches += 1
                    }
                    if !destination[index].isFinite { nonFinite += 1 }
                }
            }
        }
        #expect(mismatches == 0)
        #expect(nonFinite == 0)

        // Statistics are unchanged, because no number changed.
        let input = RGBImageStatistics(image: working.image)
        let output = RGBImageStatistics(image: image)
        for channel in RAWLinearRGBChannel.allCases {
            #expect(output[channel].minimum == input[channel].minimum)
            #expect(output[channel].maximum == input[channel].maximum)
            #expect(output[channel].mean == input[channel].mean)
            #expect(output[channel].belowZeroCount == input[channel].belowZeroCount)
            #expect(output[channel].aboveOneCount == input[channel].aboveOneCount)
        }
        #expect(output.nonFiniteCount == 0)
        #expect(output.valueCount == 36_990_720)

        let payloadBytes = 4056 * 3040 * 3 * MemoryLayout<Float>.stride
        #expect(payloadBytes == 147_962_880)

        var report = "\n--- IRChannelMix.identity (Olympus E-PL3 fixture) ---\n"
        report += "DIAGNOSTIC ONLY. An identity mix is a creative no-op inside extended linear\n"
        report += "sRGB; the stage was traversed and no number changed. Nothing here validates\n"
        report += "colour.\n"
        report += "camera-to-working transform: "
        report += "\(working.transform.source.diagnosticDescription)\n"
        report += "mix: \(processing.mixSource.diagnosticDescription)\n"
        report += "matrix: \(processing.matrix.rows)\n"
        report += "image: \(image.width) x \(image.height) (\(image.values.count) Float values)\n"
        report += "whole-buffer bit mismatches vs the pre-mix working image: \(mismatches)\n"
        report += "logical payload: \(payloadBytes) bytes "
        report += "(\(Double(payloadBytes) / 1_000_000) MB)\n"
        report += "identity mix: \(milliseconds) ms (debug build, -Onone)\n"
        report += Self.channelReport(output, title: "\nper channel, after the identity mix:")
        report += Self.channelReport(input, title: "per channel, pre-mix (must match exactly):")
        report += "the identity path shares its source's backing storage (copy-on-write), so\n"
        report += "the logical payload is not incremental physical allocation, and neither\n"
        report += "figure is process RSS.\n"
        report += "-----------------------------------------------------\n"
        print(report)
    }

    // MARK: - Red/blue swap

    @Test("Red/blue swap: every pixel's outer channels exchanged, bit for bit")
    func redBlueSwapIsExactOnTheFixture() throws {
        let working = try Self.workingColorFixture()

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try IRChannelMixer().apply(to: working, mix: .redBlueSwap)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let image = result.image

        #expect(image.width == 4056)
        #expect(image.height == 3040)
        #expect(image.values.count == 36_990_720)
        #expect(image.processing.mixSource == .redBlueSwap)
        #expect(image.processing.matrix.rows == [[0, 0, 1], [0, 1, 0], [1, 0, 0]])
        #expect(!image.processing.clamped)
        // The colour space did not change; only the coordinates moved.
        #expect(image.processing.workingColorSpace == working.image.processing.workingColorSpace)

        // The expected result is trivial and computed independently of the
        // production code, so the whole frame is checked rather than sampled.
        var redMismatches = 0
        var greenMismatches = 0
        var blueMismatches = 0
        working.image.values.withUnsafeBufferPointer { source in
            image.values.withUnsafeBufferPointer { destination in
                var base = 0
                while base < source.count {
                    if destination[base].bitPattern != source[base + 2].bitPattern {
                        redMismatches += 1
                    }
                    if destination[base + 1].bitPattern != source[base + 1].bitPattern {
                        greenMismatches += 1
                    }
                    if destination[base + 2].bitPattern != source[base].bitPattern {
                        blueMismatches += 1
                    }
                    base += 3
                }
            }
        }
        #expect(redMismatches == 0)
        #expect(greenMismatches == 0)
        #expect(blueMismatches == 0)

        // A permutation moves whole channels, so each output channel's
        // statistics must equal its source channel's exactly — including the
        // below-zero, above-one and non-finite counts.
        let input = RGBImageStatistics(image: working.image)
        let output = RGBImageStatistics(image: image)

        #expect(output[.red].minimum == input[.blue].minimum)
        #expect(output[.red].maximum == input[.blue].maximum)
        #expect(output[.red].mean == input[.blue].mean)
        #expect(output[.red].belowZeroCount == input[.blue].belowZeroCount)
        #expect(output[.red].aboveOneCount == input[.blue].aboveOneCount)

        #expect(output[.green].minimum == input[.green].minimum)
        #expect(output[.green].maximum == input[.green].maximum)
        #expect(output[.green].mean == input[.green].mean)
        #expect(output[.green].belowZeroCount == input[.green].belowZeroCount)
        #expect(output[.green].aboveOneCount == input[.green].aboveOneCount)

        #expect(output[.blue].minimum == input[.red].minimum)
        #expect(output[.blue].maximum == input[.red].maximum)
        #expect(output[.blue].mean == input[.red].mean)
        #expect(output[.blue].belowZeroCount == input[.red].belowZeroCount)
        #expect(output[.blue].aboveOneCount == input[.red].aboveOneCount)

        #expect(output.nonFiniteCount == input.nonFiniteCount)
        #expect(output.nonFiniteCount == 0)
        // The swap genuinely changed the buffer: the fixture's channels differ.
        #expect(image.values != working.image.values)

        var report = "\n--- IRChannelMix.redBlueSwap (Olympus E-PL3 fixture) ---\n"
        report += "DIAGNOSTIC ONLY. This is the exact red/blue-swap operation, not a claim of\n"
        report += "\"correct infrared colour\". No calibration, no measurement, no colour-space\n"
        report += "change — the same extended linear sRGB coordinates, remixed.\n"
        report += "whole-frame channel mismatches — R: \(redMismatches)  "
        report += "G: \(greenMismatches)  B: \(blueMismatches)\n"
        report += "red/blue swap: \(milliseconds) ms (debug build, -Onone)\n"
        report += "one new output buffer is allocated (147 962 880 bytes): the values are\n"
        report += "reordered, so copy-on-write cannot help here.\n"
        report += Self.channelReport(output, title: "\nper channel, after the swap:")
        report += Self.channelReport(input, title: "per channel, pre-mix:")
        report += "-------------------------------------------------------\n"
        print(report)
    }

    // MARK: - An explicit general matrix

    /// One non-trivial explicit matrix, spot-checked at fixed coordinates
    /// against arithmetic done here in the test.
    ///
    /// > The coefficients are **deterministic test values, not a recommended
    /// > look**. They were chosen so that a transposition, a channel-order
    /// > mistake, the wrong source buffer or an accidental clamp would all
    /// > change the answer — not for how the result looks.
    @Test("Diagnostic: an explicit general matrix, spot-checked and timed")
    func explicitMatrixOnTheFixture() throws {
        let working = try Self.workingColorFixture()

        let matrix = try RAWColorMatrix3x3(
            m00: 0.25, m01: -0.5, m02: 1.75,
            m10: 1.125, m11: 0.375, m12: -0.25,
            m20: -0.625, m21: 2.0, m22: 0.5
        )
        let mix = IRChannelMix.explicit(matrix: matrix)

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try IRChannelMixer().apply(to: working, mix: mix)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let image = result.image

        #expect(image.width == 4056)
        #expect(image.height == 3040)
        #expect(image.values.count == 36_990_720)
        #expect(image.isGeometryConsistent)
        #expect(image.processing.mixSource == .explicit)
        #expect(image.processing.matrix == matrix)
        #expect(!image.processing.clamped)

        // Deterministic pixels, recomputed here from the coefficients written
        // above, with no production helper involved.
        let coordinates = [(0, 0), (1, 1), (1500, 2000), (1501, 2001), (3039, 4055)]
        for (row, column) in coordinates {
            let source = try #require(working.image.pixel(row: row, column: column))
            let red = Double(source.red)
            let green = Double(source.green)
            let blue = Double(source.blue)
            let expected = (
                0.25 * red - 0.5 * green + 1.75 * blue,
                1.125 * red + 0.375 * green - 0.25 * blue,
                -0.625 * red + 2.0 * green + 0.5 * blue
            )
            let actual = try #require(image.pixel(row: row, column: column))

            // Double accumulation narrowed once to Float: the tolerance is one
            // Float ULP of the expected magnitude, not an arbitrary epsilon.
            func agrees(_ actual: Float, _ expected: Double) -> Bool {
                let expectedFloat = Float(expected)
                let tolerance = max(expectedFloat.ulp, Float.leastNormalMagnitude)
                return abs(actual - expectedFloat) <= tolerance
            }
            #expect(agrees(actual.red, expected.0), "red at (\(row), \(column))")
            #expect(agrees(actual.green, expected.1), "green at (\(row), \(column))")
            #expect(agrees(actual.blue, expected.2), "blue at (\(row), \(column))")
        }

        let statistics = RGBImageStatistics(image: image)
        #expect(statistics.nonFiniteCount == 0)
        // On this frame the matrix's negative and amplifying coefficients push
        // coordinates outside `0...1` in both directions, and both are
        // retained. Which channel they land in is a property of the exposure,
        // so it is not asserted; that they survive is.
        let hasNegative = RAWLinearRGBChannel.allCases.contains {
            statistics[$0].belowZeroCount > 0
        }
        let hasAboveOne = RAWLinearRGBChannel.allCases.contains {
            statistics[$0].aboveOneCount > 0
        }
        #expect(hasNegative)
        #expect(hasAboveOne)

        // Timing for all three paths on the same buffer, so their costs are
        // comparable.
        let mixer = IRChannelMixer()
        let identityStart = DispatchTime.now().uptimeNanoseconds
        _ = try mixer.apply(to: working.image, mix: .identity)
        let identityMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - identityStart) / 1_000_000
        let swapStart = DispatchTime.now().uptimeNanoseconds
        _ = try mixer.apply(to: working.image, mix: .redBlueSwap)
        let swapMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - swapStart) / 1_000_000

        var report = "\n--- IRChannelMix.explicit (Olympus E-PL3 fixture) ---\n"
        report += "DIAGNOSTIC ONLY. Deterministic test coefficients, chosen to catch\n"
        report += "transposition and channel-order mistakes — NOT a recommended look and not\n"
        report += "a colour claim.\n"
        report += "matrix: \(matrix.rows)\n"
        report += "provenance: \(image.processing.mixSource.diagnosticDescription)\n"
        report += "debug timings (-Onone), same 36 990 720-value buffer:\n"
        report += "  identity:      \(identityMilliseconds) ms (validate + copy-on-write share)\n"
        report += "  red/blue swap: \(swapMilliseconds) ms (validate + one reordered buffer)\n"
        report += "  general 3x3:   \(milliseconds) ms (nine multiplies, six adds per pixel)\n"
        report += "No optimised-build measurement has been taken; no performance claim is made.\n"
        report += Self.channelReport(statistics, title: "\nper channel, after the explicit mix:")
        report += "coordinates below zero and above one are retained, not clamped.\n"
        report += "-----------------------------------------------------\n"
        print(report)
    }

    // MARK: - Reprocessing on real data

    @Test("Changing the mix on the fixture restarts from the pre-mix working image")
    func reprocessingOnTheFixture() throws {
        let working = try Self.workingColorFixture()
        let mixer = IRChannelMixer()

        let swapped = try mixer.apply(to: working, mix: .redBlueSwap)
        let replaced = try mixer.apply(mix: .identity, replacing: swapped)

        // Identity applied to the ORIGINAL working image: bit-identical to it,
        // which it would not be if the swap had been chained.
        var mismatches = 0
        for index in 0..<working.image.values.count
        where replaced.image.values[index].bitPattern
            != working.image.values[index].bitPattern {
            mismatches += 1
        }
        #expect(mismatches == 0)
        #expect(replaced.image.processing.mixSource == .identity)
        #expect(replaced.workingColorImage.values == working.image.values)
        // And the earlier result is untouched.
        #expect(swapped.image.processing.mixSource == .redBlueSwap)
    }
}
