import Testing
import Foundation
@testable import InfraredConverter

/// The working-colour stage against a real RAW file, through the
/// application-owned pipeline only:
///
/// ```text
/// RAW file → decodeMosaic → RAWMosaicNormalizer → RAWWhiteBalanceEstimator
///          → RAWWhiteBalancer → RAWDemosaicer → RAWWorkingColorConverter
/// ```
///
/// ## LibRaw is not the oracle here
///
/// `LibRawDecoder.decode()` is never called for anything asserted below, and
/// nothing is compared against its processed RGB output. That legacy path
/// applies a camera colour matrix, gamma and its own black/white handling, so
/// agreeing with it would mean this stage was doing more than it claims.
///
/// ## Nothing here is a colour validation
///
/// The identity transform is a **deliberate false-colour axis assignment**,
/// not a camera calibration and not "correct colour" — see
/// `RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor`. Where the
/// visible-light metadata transform is exercised, it is a **diagnostic for
/// this infrared capture**: `rgbFromCamera` is visible-light calibrated vendor
/// or decoder data, and this camera is infrared-converted. It is not an IR
/// camera calibration, not an E-PL3 IR profile, not a filter profile, not a
/// recommendation, and not a claim of colourimetric accuracy.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly without
/// it.
@Suite(
    "RAWWorkingColorConverter integration",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct RAWWorkingColorConverterFixtureTests {

    /// The same deterministic diagnostic region the estimator and demosaicer
    /// suites measure.
    static let diagnosticRegion = RAWWhiteBalanceEstimatorFixtureTests.diagnosticRegion

    /// Decode, normalise, estimate from the diagnostic patch, apply that
    /// estimate, demosaic — everything up to but not including the
    /// working-colour conversion.
    ///
    /// The estimated gains are diagnostic only, exactly as in the upstream
    /// suites. What matters here is that a genuine camera-native RGB image
    /// with real provenance reaches this stage.
    private static func demosaicedFixture() throws -> DemosaicedProcessedRAWImage {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: normalized.mosaic, region: diagnosticRegion)
        let balanced = try RAWWhiteBalancer().apply(to: normalized, estimate: estimate)
        return try RAWDemosaicer().demosaic(balanced)
    }

    // MARK: - Identity false colour

    @Test("Identity false colour: geometry, provenance and the retained chain")
    func identityGeometryAndProvenance() throws {
        let demosaiced = try Self.demosaicedFixture()
        let result = try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )
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
        #expect(processing.workingColorSpace == .extendedLinearSRGB)
        #expect(processing.transformSource == .sensorRGBIdentityFalseColor)
        #expect(processing.matrix == .identity)
        #expect(processing.workingColorRepresentationEstablished)
        #expect(processing.cameraToWorkingTransformApplied)
        #expect(!processing.clamped)
        #expect(!processing.gammaApplied)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.displayEncodingApplied)
        #expect(!processing.orientationApplied)
        // A defined coordinate system is not a calibration claim.
        #expect(!processing.isValidatedInfraredCalibration)

        // Upstream demosaic provenance travelled with it.
        #expect(processing.demosaicAlgorithm == .bilinearBayer)
        #expect(processing.demosaicProcessing.sourcePattern.phaseDescription == "RGGB")
        #expect(processing.demosaiced)
        #expect(processing.whiteBalanceApplied)
        #expect(processing.blackLevelSubtracted)
        #expect(processing.normalized)

        // And the white-balance estimate's own provenance is still reachable.
        guard case .neutralPatch(let source) =
                processing.demosaicProcessing.whiteBalanceProcessing.gainSource else {
            Issue.record("expected the estimate's neutral-patch provenance")
            return
        }
        #expect(source.region == Self.diagnosticRegion)
        #expect(source.scalePolicy == .preserveStrongestMeasuredPlane)
        #expect(processing.whiteBalanceGains == demosaiced.processing.whiteBalanceGains)
        #expect(processing.demosaicProcessing.whiteBalanceProcessing
            .linearProcessing.whiteLevel == 4095)

        // Every earlier representation is still reachable, unmutated.
        #expect(result.demosaicedImage.values.count == 36_990_720)
        #expect(result.whiteBalancedMosaic.values.count == 12_330_240)
        #expect(result.linearMosaic.values.count == 12_330_240)
        #expect(!result.linearMosaic.processing.whiteBalanceApplied)
        #expect(result.source.source.source.source.mosaic.width == 4056)
        #expect(result.metadata.identity.model?.isEmpty == false)
        #expect(result.url == demosaiced.url)
    }

    @Test("Identity false colour is bit-identical across the whole 148 MB buffer")
    func identityIsBitIdenticalOnTheFixture() throws {
        let demosaiced = try Self.demosaicedFixture()
        let result = try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )

        let input = demosaiced.image.values
        let output = result.image.values
        #expect(output.count == input.count)

        var mismatches = 0
        var nonFinite = 0
        input.withUnsafeBufferPointer { source in
            output.withUnsafeBufferPointer { destination in
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
    }

    // MARK: - Diagnostics

    /// Reports the concrete numbers for the fixture, and times both paths.
    ///
    /// > Everything printed here is **diagnostic**. The identity result is a
    /// > false-colour axis assignment into extended linear sRGB, not a colour
    /// > calibration of this infrared-converted camera. A mean or a maximum
    /// > says nothing about whether the image looks right.
    @Test("Diagnostic: identity false-colour statistics for the Olympus E-PL3 fixture")
    func identityDiagnosticStatistics() throws {
        let demosaiced = try Self.demosaicedFixture()

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )
        let identityMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        // A general (non-identity) matrix, timed on the same buffer, so the
        // cost of the arithmetic path is visible next to the identity one.
        let generalMatrix = try RAWColorMatrix3x3(
            m00: 1.25, m01: -0.25, m02: 0.125,
            m10: -0.5, m11: 1.75, m12: -0.25,
            m20: 0.0625, m21: -0.375, m22: 1.5
        )
        let generalStart = DispatchTime.now().uptimeNanoseconds
        let general = try RAWWorkingColorConverter().convert(
            demosaiced.image, using: .explicit(matrix: generalMatrix)
        )
        let generalMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - generalStart) / 1_000_000

        let cameraNative = RGBImageStatistics(image: demosaiced.image)
        let working = RGBImageStatistics(image: result.image)
        let payloadBytes = 4056 * 3040 * 3 * MemoryLayout<Float>.stride

        var report = "\n--- WorkingColorRGBImage diagnostic (Olympus E-PL3 fixture) ---\n"
        report += "DIAGNOSTIC ONLY. The identity transform is a deliberate FALSE-COLOUR axis\n"
        report += "assignment into extended linear sRGB. It is NOT a camera calibration, not\n"
        report += "an IR profile, and nothing below validates colour.\n"
        report += "working colour space: "
        report += "\(result.image.processing.workingColorSpace.diagnosticDescription)\n"
        report += "transform source: "
        report += "\(result.image.processing.transformSource.diagnosticDescription)\n"
        report += "matrix: \(result.image.processing.matrix.rows)\n"
        report += "image: \(result.image.width) x \(result.image.height) "
        report += "(\(result.image.values.count) Float values)\n"
        report += "logical payload: \(payloadBytes) bytes "
        report += "(\(Double(payloadBytes) / 1_000_000) MB)\n"
        report += "identity conversion: \(identityMilliseconds) ms (debug build)\n"
        report += "general 3x3 conversion: \(generalMilliseconds) ms (debug build)\n"
        report += "\nper channel, working colour (identity false colour):\n"
        for channel in RAWLinearRGBChannel.allCases {
            let c = working[channel]
            report += "  \(channel): min \(c.minimum)  max \(c.maximum)  mean \(c.mean)  "
            report += "< 0: \(c.belowZeroCount)  > 1: \(c.aboveOneCount)\n"
        }
        report += "  non-finite: \(working.nonFiniteCount)\n"
        report += "\nper channel, camera-native source (must match exactly):\n"
        for channel in RAWLinearRGBChannel.allCases {
            let c = cameraNative[channel]
            report += "  \(channel): min \(c.minimum)  max \(c.maximum)  mean \(c.mean)  "
            report += "< 0: \(c.belowZeroCount)  > 1: \(c.aboveOneCount)\n"
        }
        report += "  non-finite: \(cameraNative.nonFiniteCount)\n"
        // The logical payload above is one buffer's worth of Floats. For the
        // identity path it is NOT incremental physical memory: Array's
        // copy-on-write means the working image shares its source's backing
        // storage, since both sides are immutable. Neither figure is process
        // RSS. A general matrix does allocate one new output buffer.
        report += "\nidentity path shares its source's backing storage (copy-on-write), so the\n"
        report += "logical payload is not incremental physical allocation. A general matrix\n"
        report += "allocates one new output buffer of that size.\n"
        report += "---------------------------------------------------------------\n"
        print(report)

        // The identity path changed no numbers, so every statistic matches.
        for channel in RAWLinearRGBChannel.allCases {
            #expect(working[channel].minimum == cameraNative[channel].minimum)
            #expect(working[channel].maximum == cameraNative[channel].maximum)
            #expect(working[channel].mean == cameraNative[channel].mean)
            #expect(working[channel].belowZeroCount == cameraNative[channel].belowZeroCount)
            #expect(working[channel].aboveOneCount == cameraNative[channel].aboveOneCount)
        }
        #expect(working.nonFiniteCount == 0)
        #expect(working.valueCount == 36_990_720)
        #expect(payloadBytes == 147_962_880)

        // The general path is a real transform on the same geometry, and it
        // is not the identity result.
        #expect(general.values.count == 36_990_720)
        #expect(general.isGeometryConsistent)
        #expect(general.values != result.image.values)
    }

    // MARK: - The visible-light metadata matrix, as this file actually carries it

    /// Inspects the fixture's own `rgbFromCamera` and takes whichever branch
    /// the real file requires.
    ///
    /// The fourth column is **not** assumed to be zero. If it is, the
    /// visible-light transform is constructed and checked against arithmetic
    /// done here in the test; if it is not, the typed rejection is asserted
    /// instead. Either outcome is correct — the implementation contract takes
    /// precedence over producing a metadata-transformed image.
    ///
    /// > Any result below is a **visible-light metadata transform, diagnostic
    /// > only for this IR capture**. It is not an IR camera calibration, not
    /// > an E-PL3 IR profile, not a filter profile, not a recommendation, and
    /// > not a claim of colourimetric accuracy.
    @Test("Diagnostic: the fixture's own rgbFromCamera, and what the adapter does with it")
    func visibleLightMetadataDiagnostic() throws {
        let demosaiced = try Self.demosaicedFixture()
        let color = demosaiced.metadata.color

        var report = "\n--- rgbFromCamera diagnostic (Olympus E-PL3 fixture) ---\n"
        report += "VISIBLE-LIGHT metadata, diagnostic only for this IR capture. Not an IR\n"
        report += "camera calibration, not an E-PL3 IR profile, not a filter profile, not a\n"
        report += "recommendation, and not a claim of colourimetric accuracy.\n"

        guard let rows = color.rgbFromCamera else {
            report += "rgbFromCamera: absent\n"
            report += "-------------------------------------------------------\n"
            print(report)
            #expect {
                _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(from: color)
            } throws: { error in
                guard case .missingVisibleLightCameraMatrix =
                        error as? RAWProcessingError else { return false }
                return true
            }
            return
        }

        report += "rgbFromCamera shape: \(rows.count) rows x "
        report += "\(Set(rows.map(\.count)).sorted()) columns\n"
        for (index, row) in rows.enumerated() {
            report += "  row \(index): \(row)\n"
        }
        let fourthColumn = rows.compactMap { $0.count >= 4 ? $0[3] : nil }
        report += "fourth column: \(fourthColumn)\n"

        let structurallyValid = rows.count == 3
            && rows.allSatisfy { $0.count == 4 }
            && rows.allSatisfy { $0.allSatisfy(\.isFinite) }
        let representable = structurallyValid && fourthColumn.allSatisfy { $0 == 0 }

        guard representable else {
            report += "representable as a 3x3 camera-native transform: NO\n"
            report += "the adapter refuses it rather than dropping the fourth component.\n"
            report += "-------------------------------------------------------\n"
            print(report)

            #expect(throws: RAWProcessingError.self) {
                _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(from: color)
            }
            do {
                _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(from: color)
                Issue.record("expected the adapter to refuse this matrix")
            } catch let error as RAWProcessingError {
                print("typed rejection: \(error)\n")
                switch error {
                case .malformedVisibleLightCameraMatrix, .incompatibleVisibleLightCameraMatrix:
                    break
                default:
                    Issue.record("unexpected error for a non-representable matrix: \(error)")
                }
            }
            return
        }

        let transform = try RAWCameraToWorkingColorTransform.visibleLightMetadata(from: color)
        report += "representable as a 3x3 camera-native transform: YES\n"
        report += "derived 3x3: \(transform.matrix.rows)\n"
        report += "determinant: \(transform.matrix.determinant)\n"

        #expect(transform.source == .visibleLightMetadataRGBFromCamera)
        #expect(transform.workingColorSpace == .extendedLinearSRGB)
        // Derived from the first three columns, in order, untransposed.
        for row in 0..<3 {
            for column in 0..<3 {
                #expect(transform.matrix.coefficient(row: row, column: column)
                        == Double(rows[row][column]))
            }
        }

        let converted = try RAWWorkingColorConverter().convert(
            demosaiced, using: transform
        )
        let image = converted.image
        #expect(image.width == 4056)
        #expect(image.height == 3040)
        #expect(image.values.count == 36_990_720)
        #expect(image.processing.transformSource == .visibleLightMetadataRGBFromCamera)
        #expect(!image.processing.isValidatedInfraredCalibration)

        // Deterministic pixels, recomputed here from the metadata rows, with
        // no production transform helper involved.
        let coordinates = [(0, 0), (1, 1), (1500, 2000), (1501, 2001), (3039, 4055)]
        for (row, column) in coordinates {
            let camera = try #require(demosaiced.image.pixel(row: row, column: column))
            let red = Double(camera.red)
            let green = Double(camera.green)
            let blue = Double(camera.blue)
            let expected = (
                Double(rows[0][0]) * red + Double(rows[0][1]) * green + Double(rows[0][2]) * blue,
                Double(rows[1][0]) * red + Double(rows[1][1]) * green + Double(rows[1][2]) * blue,
                Double(rows[2][0]) * red + Double(rows[2][1]) * green + Double(rows[2][2]) * blue
            )
            let actual = try #require(image.pixel(row: row, column: column))

            // Double arithmetic narrowed once to Float: the tolerance is one
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
        report += "\nper channel, visible-light metadata transform "
        report += "(DIAGNOSTIC, not IR calibration):\n"
        for channel in RAWLinearRGBChannel.allCases {
            let c = statistics[channel]
            report += "  \(channel): min \(c.minimum)  max \(c.maximum)  mean \(c.mean)  "
            report += "< 0: \(c.belowZeroCount)  > 1: \(c.aboveOneCount)\n"
        }
        report += "  non-finite: \(statistics.nonFiniteCount)\n"
        report += "negative and above-one coordinates are retained, not clamped.\n"
        report += "-------------------------------------------------------\n"
        print(report)

        #expect(statistics.nonFiniteCount == 0)
        #expect(!image.processing.clamped)
    }

    /// Even with this file's real metadata present, nothing selects it.
    @Test("The fixture's metadata does not reach the stage unless it is asked for")
    func fixtureMetadataIsNeverAutomatic() throws {
        let demosaiced = try Self.demosaicedFixture()
        let result = try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )

        // The metadata is right there on the retained chain, and had no effect.
        #expect(result.metadata.color.cameraMultipliers != nil)
        #expect(result.transform == .sensorRGBIdentityFalseColor)

        var mismatches = 0
        for index in 0..<demosaiced.image.values.count
        where result.image.values[index].bitPattern
            != demosaiced.image.values[index].bitPattern {
            mismatches += 1
        }
        #expect(mismatches == 0)
    }
}
