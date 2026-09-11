import Testing
import CoreGraphics
import Foundation
@testable import InfraredConverter

/// The orientation stage against the real Olympus E-PL3 fixture, through the
/// application-owned pipeline only.
///
/// ```text
/// RAW file → decodeMosaic → RAWMosaicNormalizer → RAWWhiteBalanceEstimator
///          → RAWWhiteBalancer → RAWDemosaicer → RAWWorkingColorConverter
///          → IRChannelMixer → ImageOrienter
/// ```
///
/// ## What this fixture's metadata actually says
///
/// The file records **EXIF orientation 1**, which LibRaw reports as `flip 0`
/// and this application maps to `.upright`. The photograph was taken with the
/// camera turned, and the body recorded nothing about it — so the correct
/// response to the metadata is to display it exactly as captured, and that is
/// what the owned pipeline does.
///
/// That makes the fixture a genuine test of the metadata path and a weak one
/// for the coordinate arithmetic, so this suite does both: it pins the upright
/// reading end to end, and it also applies non-identity orientations to the
/// same real, odd-dimensioned, 12-megapixel frame and checks named coordinates
/// numerically.
///
/// ## The numbers are the oracle, not a picture
///
/// Nothing here writes or compares an image file. Each check names a
/// destination coordinate, names the source coordinate it must have come from,
/// and compares the three `Float` bit patterns. A visual check would pass for
/// a mirrored result on a symmetrical subject.
@Suite(
    "ImageOrienter integration",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct ImageOrienterFixtureTests {

    /// The same deterministic diagnostic region every fixture suite measures.
    static let diagnosticRegion = RAWWhiteBalanceEstimatorFixtureTests.diagnosticRegion

    /// The active area's dimensions, before orientation.
    static let sourceWidth = 4056
    static let sourceHeight = 3040

    /// The whole owned chain up to and including the creative mix, with the
    /// identity false-colour camera-to-working transform — deliberately, so
    /// the fixture stays independent of the file's visible-light
    /// `rgbFromCamera`.
    static func channelMixedFixture() throws -> IRChannelMixedProcessedRAWImage {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: normalized.mosaic, region: diagnosticRegion)
        let balanced = try RAWWhiteBalancer().apply(to: normalized, estimate: estimate)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)
        let working = try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )
        return try IRChannelMixer().apply(to: working, mix: .identity)
    }

    // MARK: - What the file records

    @Test("The fixture's recorded orientation maps to upright, and says so")
    func theFixtureRecordsAnUprightOrientation() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let metadata = try LibRawDecoder().readMetadata(at: url)
        let geometry = metadata.geometry

        // The decoder's own value, stated rather than inferred.
        #expect(geometry.flip == 0)
        #expect(geometry.orientationIsRepresentable)

        // Its application-owned mapping, and the EXIF code it corresponds to.
        let orientation = try #require(geometry.orientation)
        #expect(orientation == .upright)
        #expect(orientation.exifOrientation == 1)
        #expect(orientation.decoderFlip == 0)
        #expect(orientation.isIdentity)
        #expect(!orientation.swapsDimensions)
        #expect(!orientation.isMirrored)

        // The active area, and therefore the oriented geometry, which is the
        // same because the orientation is the identity.
        #expect(geometry.visibleWidth == Self.sourceWidth)
        #expect(geometry.visibleHeight == Self.sourceHeight)
        let output = orientation.outputDimensions(
            sourceWidth: geometry.visibleWidth, sourceHeight: geometry.visibleHeight
        )
        #expect(output.width == 4056)
        #expect(output.height == 3040)

        // The workspace reads exactly this, with no camera-model special case
        // anywhere in the path.
        #expect(WorkspacePreviewPipeline.orientation(for: metadata) == .upright)
    }

    // MARK: - The whole owned pipeline

    @Test("The owned pipeline orients the fixture and reaches CoreGraphics")
    func theOwnedPipelineOrientsTheFixture() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let preview = try WorkspacePreviewPipeline()
            .render(decoding: url, using: LibRawDecoder())

        // The orientation the file named, applied by the stage that owns it.
        #expect(preview.orientation == .upright)
        #expect(preview.sourcePixelWidth == Self.sourceWidth)
        #expect(preview.sourcePixelHeight == Self.sourceHeight)
        #expect(preview.pixelWidth == 4056)
        #expect(preview.pixelHeight == 3040)

        // The record says the stage ran, which is a different fact from the
        // arrangement it applied.
        #expect(preview.processing.orientationApplied)
        #expect(preview.processing.appliedOrientation == .upright)
        #expect(!preview.processing.orientationSwappedDimensions)

        // The platform image is the oriented one, because the buffer is.
        // Nothing in the view layer rotates anything.
        #expect(preview.image.width == preview.pixelWidth)
        #expect(preview.image.height == preview.pixelHeight)
        #expect(preview.image.bitsPerComponent == 8)
        #expect(preview.image.bitsPerPixel == 24)
    }

    // MARK: - Coordinates, on real data

    /// Destination coordinates checked by hand, with the source coordinate
    /// each must have come from computed in the test from the written-out
    /// formula — not by calling the production mapping.
    ///
    /// All four corners are included, so a `w − 1` written where an `h − 1`
    /// belongs cannot hide, plus interior points on both parities of both
    /// axes.
    @Test("A quarter turn of the fixture moves named coordinates exactly")
    func aQuarterTurnMovesNamedCoordinatesExactly() throws {
        let mixed = try Self.channelMixedFixture()
        let source = mixed.image
        #expect(source.width == Self.sourceWidth)
        #expect(source.height == Self.sourceHeight)

        let oriented = try ImageOrienter()
            .apply(to: mixed, orientation: .rotated90Clockwise)

        // A quarter turn exchanges the dimensions: 4056 × 3040 → 3040 × 4056.
        #expect(oriented.image.width == 3040)
        #expect(oriented.image.height == 4056)
        #expect(oriented.image.values.count == source.values.count)
        #expect(oriented.image.isGeometryConsistent)

        // destination(r, c) = source(sourceHeight − 1 − c, r), written out
        // here rather than asked of the production mapping.
        let lastSourceRow = Self.sourceHeight - 1      // 3039
        let checks: [(row: Int, column: Int)] = [
            (0, 0),                 // destination top-left
            (0, 3039),              // destination top-right
            (4055, 0),              // destination bottom-left
            (4055, 3039),           // destination bottom-right
            (1, 1),
            (2000, 1500),
            (2001, 1501),
            (1024, 2048),
        ]

        var report = "\n--- Oriented coordinates (Olympus E-PL3 fixture) ---\n"
        report += "rotated 90° clockwise: 4056 × 3040 → 3040 × 4056\n"
        report += "destination(r, c) = source(3039 − c, r)\n"

        for check in checks {
            let expectedSourceRow = lastSourceRow - check.column
            let expectedSourceColumn = check.row

            let expected = try #require(
                source.pixel(row: expectedSourceRow, column: expectedSourceColumn),
                "source (\(expectedSourceRow), \(expectedSourceColumn))"
            )
            let actual = try #require(
                oriented.image.pixel(row: check.row, column: check.column),
                "destination (\(check.row), \(check.column))"
            )

            #expect(actual.red.bitPattern == expected.red.bitPattern,
                    "red at (\(check.row), \(check.column))")
            #expect(actual.green.bitPattern == expected.green.bitPattern,
                    "green at (\(check.row), \(check.column))")
            #expect(actual.blue.bitPattern == expected.blue.bitPattern,
                    "blue at (\(check.row), \(check.column))")

            report += """
                dest (\(check.row), \(check.column)) ← src \
                (\(expectedSourceRow), \(expectedSourceColumn)): \
                R \(actual.red) G \(actual.green) B \(actual.blue)\n
                """
        }

        // The four corners specifically: each destination corner comes from a
        // different source corner under a quarter turn, which is the property
        // a transposed-versus-rotated mistake breaks.
        let topLeft = try #require(oriented.image.pixel(row: 0, column: 0))
        let sourceBottomLeft = try #require(source.pixel(row: 3039, column: 0))
        #expect(topLeft.red.bitPattern == sourceBottomLeft.red.bitPattern)
        report += "corner check: destination (0, 0) is the source's bottom-left\n"
        report += "---------------------------------------------------\n"
        print(report)
    }

    /// The other family: a reflection, on the same real frame. Transpose and a
    /// quarter turn both swap the dimensions, so a suite that only checked a
    /// rotation would not notice the two being confused.
    @Test("A transpose of the fixture reflects across the main diagonal")
    func aTransposeReflectsAcrossTheMainDiagonal() throws {
        let mixed = try Self.channelMixedFixture()
        let source = mixed.image
        let orienter = ImageOrienter()

        let transposed = try orienter.apply(to: mixed, orientation: .transposed)
        #expect(transposed.image.width == 3040)
        #expect(transposed.image.height == 4056)
        #expect(transposed.processing.orientationIsMirrored)

        // destination(r, c) = source(c, r).
        for (row, column) in [(0, 0), (0, 3039), (4055, 0), (4055, 3039), (777, 1234)] {
            let expected = try #require(source.pixel(row: column, column: row))
            let actual = try #require(transposed.image.pixel(row: row, column: column))
            #expect(actual.red.bitPattern == expected.red.bitPattern,
                    "red at (\(row), \(column))")
            #expect(actual.green.bitPattern == expected.green.bitPattern,
                    "green at (\(row), \(column))")
            #expect(actual.blue.bitPattern == expected.blue.bitPattern,
                    "blue at (\(row), \(column))")
        }

        // The reflection's fixed points lie on the main diagonal, where a
        // quarter turn's do not — the numeric difference between the two.
        let turned = try orienter.apply(to: mixed, orientation: .rotated90Clockwise)
        let diagonal = try #require(transposed.image.pixel(row: 1000, column: 1000))
        let turnedSame = try #require(turned.image.pixel(row: 1000, column: 1000))
        let sourceDiagonal = try #require(source.pixel(row: 1000, column: 1000))
        #expect(diagonal.red.bitPattern == sourceDiagonal.red.bitPattern)
        #expect(turnedSame.red.bitPattern != sourceDiagonal.red.bitPattern)
    }

    /// The whole point of the stage being lossless: on 12 330 240 real pixels,
    /// the oriented buffer holds exactly the source's components.
    @Test("Orienting the fixture preserves every component, and loses none")
    func orientingTheFixturePreservesEveryComponent() throws {
        let mixed = try Self.channelMixedFixture()
        let oriented = try ImageOrienter().apply(to: mixed, orientation: .transverse)

        #expect(oriented.image.values.count == 36_990_720)
        #expect(oriented.image.pixelCount == 12_330_240)

        // Sum and extremes over the whole frame: a permutation cannot change
        // any of them, and a dropped or duplicated pixel would.
        func summary(_ values: [Float]) -> (sum: Double, min: Float, max: Float, count: Int) {
            var sum = 0.0
            var minimum = Float.greatestFiniteMagnitude
            var maximum = -Float.greatestFiniteMagnitude
            values.withUnsafeBufferPointer { buffer in
                for value in buffer {
                    sum += Double(value)
                    minimum = Swift.min(minimum, value)
                    maximum = Swift.max(maximum, value)
                }
            }
            return (sum, minimum, maximum, values.count)
        }

        let before = summary(mixed.image.values)
        let after = summary(oriented.image.values)
        #expect(after.count == before.count)
        #expect(after.min == before.min)
        #expect(after.max == before.max)
        // Summed in Double over the same multiset, in a different order:
        // floating-point addition is not associative, so this is compared with
        // a tolerance proportional to the magnitudes involved rather than
        // claimed exact.
        #expect(abs(after.sum - before.sum) <= abs(before.sum) * 1e-9)
    }
}
