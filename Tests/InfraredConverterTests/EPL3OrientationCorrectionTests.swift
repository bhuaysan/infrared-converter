import Testing
import CoreGraphics
import Foundation
@testable import InfraredConverter

/// The motivating case, end to end: correcting the Olympus E-PL3 fixture by
/// hand.
///
/// The photograph is a cityscape taken with the camera turned, and the body
/// wrote EXIF orientation `1` anyway — the tag is present with that value, as
/// `ImageOrienterFixtureTests.theFixtureCarriesExifTag274` proves from the
/// file's bytes. So metadata alone can never make it upright, and nothing in
/// this application tries: the correction is the user's.
///
/// ## Nothing here is camera-specific
///
/// No code path consults the camera model, and this suite chooses the
/// adjustment the way a person would — by looking at the picture. The sky is
/// along the right edge of the stored frame, so a quarter turn **left** puts
/// it at the top. Any other file gets whatever its own user chooses, through
/// exactly this path.
///
/// ## The oracle is coordinates, not a picture
///
/// Every geometric claim below names a destination coordinate, names the
/// source coordinate it must have come from, and compares `Float` bit
/// patterns. A visual check would pass for a mirrored result.
@Suite(
    "E-PL3 orientation correction",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct EPL3OrientationCorrectionTests {

    static let sourceWidth = 4056
    static let sourceHeight = 3040

    /// The adjustment that makes this particular photograph upright. Chosen
    /// by looking at it, not derived from the camera model.
    static let correction = UserOrientationAdjustment.quarterTurnLeft

    /// The expensive half, run once and shared by the whole suite.
    static func prepared() throws -> WorkspacePreviewPipeline.Source {
        let url = try #require(RAWFixtures.olympusORF)
        return try WorkspacePreviewPipeline().prepare(decoding: url, using: LibRawDecoder())
    }

    // MARK: - 1. The file loads with its own orientation

    @Test("The fixture loads with the orientation its metadata records")
    func theFixtureLoadsWithItsRecordedOrientation() throws {
        let source = try Self.prepared()

        #expect(source.metadata.geometry.flip == 0)
        #expect(source.metadata.geometry.orientation == .upright)
        #expect(source.channelMixed.image.width == Self.sourceWidth)
        #expect(source.channelMixed.image.height == Self.sourceHeight)
    }

    // MARK: - 2. Identity preserves the sideways result

    @Test("With no correction the result is the metadata-derived one, unchanged")
    func identityPreservesTheSidewaysResult() throws {
        let source = try Self.prepared()
        let preview = try WorkspacePreviewPipeline().render(source, adjustments: .none)

        #expect(preview.sourceOrientation == .upright)
        #expect(preview.userOrientationAdjustment == .identity)
        #expect(preview.effectiveOrientation == .upright)
        #expect(preview.pixelWidth == 4056)
        #expect(preview.pixelHeight == 3040)
        #expect(preview.image.width == 4056)
        #expect(preview.image.height == 3040)

        // The whole chain below orientation is untouched by the adjustment
        // model: these are the same reference values the earlier milestones
        // pinned.
        #expect(preview.processing.clippedLowSampleCount == 11)
        #expect(preview.processing.clippedHighSampleCount == 0)
        #expect(preview.processing.exposureEV == 0)
        #expect(preview.processing.mixSource == .identity)
    }

    // MARK: - 3 & 4. A quarter turn, and the geometry that follows

    @Test("A user quarter turn left produces the expected effective orientation")
    func theCorrectionProducesTheExpectedOrientation() throws {
        let source = try Self.prepared()
        let preview = try WorkspacePreviewPipeline().render(
            source, adjustments: ImageAdjustments(orientation: Self.correction)
        )

        // Three distinct facts, and the file's own is unchanged.
        #expect(preview.sourceOrientation == .upright)
        #expect(preview.userOrientationAdjustment == .quarterTurnLeft)
        #expect(preview.effectiveOrientation == .rotated270Clockwise)
        #expect(source.metadata.geometry.flip == 0)

        // 4. The dimensions exchange.
        #expect(preview.sourcePixelWidth == 4056)
        #expect(preview.sourcePixelHeight == 3040)
        #expect(preview.pixelWidth == 3040)
        #expect(preview.pixelHeight == 4056)
        #expect(preview.image.width == 3040)
        #expect(preview.image.height == 4056)

        // Provenance says all three, and agrees with the stage that ran.
        #expect(preview.orientationProvenance.isUserAdjusted)
        #expect(preview.orientationProvenance.isConsistent)
        #expect(preview.processing.appliedOrientation == .rotated270Clockwise)
        #expect(preview.processing.orientationSwappedDimensions)
    }

    // MARK: - 5. Named destination coordinates, by bit pattern

    /// Six destination coordinates in the corrected frame, each checked
    /// against the source coordinate the written-out formula gives.
    ///
    /// For `.rotated270Clockwise` on a `w × h` source, destination `(r, c)`
    /// comes from source `(c, w − 1 − r)`. The corrected image is 3040 wide
    /// and 4056 high.
    @Test("Named destination coordinates map to the expected source pixels")
    func namedCoordinatesMapCorrectly() throws {
        let source = try Self.prepared()
        let mixed = source.channelMixed.image
        let oriented = try ImageOrienter().apply(
            to: source.channelMixed, orientation: .rotated270Clockwise
        ).image

        #expect(oriented.width == 3040)
        #expect(oriented.height == 4056)

        let lastColumn = Self.sourceWidth - 1   // 4055

        let coordinates: [(row: Int, column: Int)] = [
            (row: 0, column: 0),          // top-left of the corrected frame
            (row: 0, column: 3039),       // top-right
            (row: 4055, column: 0),       // bottom-left
            (row: 4055, column: 3039),    // bottom-right
            (row: 2000, column: 1500),
            (row: 1024, column: 2048),
        ]

        for destination in coordinates {
            let expectedSource = (
                row: destination.column,
                column: lastColumn - destination.row
            )
            // The formula and the type agree about where the pixel comes from.
            let mapped = RAWImageOrientation.rotated270Clockwise.sourceCoordinate(
                row: destination.row,
                column: destination.column,
                sourceWidth: Self.sourceWidth,
                sourceHeight: Self.sourceHeight
            )
            #expect(mapped.row == expectedSource.row)
            #expect(mapped.column == expectedSource.column)

            let moved = try #require(
                oriented.pixel(row: destination.row, column: destination.column)
            )
            let original = try #require(
                mixed.pixel(row: expectedSource.row, column: expectedSource.column)
            )
            #expect(moved.red.bitPattern == original.red.bitPattern)
            #expect(moved.green.bitPattern == original.green.bitPattern)
            #expect(moved.blue.bitPattern == original.blue.bitPattern)
        }
    }

    /// A quarter turn is not a reflection, and on a real photograph the
    /// difference is invisible. It is checked numerically instead: the
    /// transposed arrangement of the same frame differs at a named
    /// coordinate.
    @Test("The correction is a rotation, not the reflection of the same dimensions")
    func theCorrectionIsNotAReflection() throws {
        let source = try Self.prepared()
        let rotated = try ImageOrienter().apply(
            to: source.channelMixed, orientation: .rotated270Clockwise
        ).image
        let reflected = try ImageOrienter().apply(
            to: source.channelMixed, orientation: .transposed
        ).image

        // Same geometry, different pixels.
        #expect(rotated.width == reflected.width)
        #expect(rotated.height == reflected.height)
        #expect(!RAWImageOrientation.rotated270Clockwise.isMirrored)
        #expect(RAWImageOrientation.transposed.isMirrored)

        let a = try #require(rotated.pixel(row: 0, column: 0))
        let b = try #require(reflected.pixel(row: 0, column: 0))
        #expect(a.red.bitPattern != b.red.bitPattern
            || a.green.bitPattern != b.green.bitPattern
            || a.blue.bitPattern != b.blue.bitPattern)
    }

    // MARK: - 6. Reset

    @Test("Resetting returns exactly to the metadata-derived result")
    func resettingReturnsToTheMetadataResult() throws {
        let source = try Self.prepared()
        let pipeline = WorkspacePreviewPipeline()

        let initial = try pipeline.render(source, adjustments: .none)
        let corrected = try pipeline.render(
            source, adjustments: ImageAdjustments(orientation: Self.correction)
        )
        let reset = try pipeline.render(
            source, adjustments: ImageAdjustments(orientation: .reset)
        )

        #expect(corrected.pixelWidth != initial.pixelWidth)
        #expect(reset.pixelWidth == initial.pixelWidth)
        #expect(reset.pixelHeight == initial.pixelHeight)
        #expect(reset.effectiveOrientation == .upright)

        // Bit-identical display bytes, which is the strongest statement
        // available: the reset render re-derived from the same channel-mixed
        // source rather than undoing anything.
        let before = try #require(WorkspaceStubs.pixelBytes(initial.image))
        let after = try #require(WorkspaceStubs.pixelBytes(reset.image))
        #expect(after == before)
    }

    // MARK: - Non-destructive reprocessing, on the real frame

    /// Two rotations and a reset, each derived from the same unoriented
    /// channel-mixed buffer — proved by the buffer being bit-identical
    /// throughout and by the results matching one-step renders.
    @Test("Repeated corrections never reprocess previously oriented pixels")
    func repeatedCorrectionsRestartFromTheSource() throws {
        let source = try Self.prepared()
        let pipeline = WorkspacePreviewPipeline()
        let originalValues = source.channelMixed.image.values

        var adjustment = UserOrientationAdjustment.identity
        var reached: [UserOrientationAdjustment] = []
        for _ in 0..<2 {
            adjustment = adjustment.rotatedRight()
            _ = try pipeline.render(
                source, adjustments: ImageAdjustments(orientation: adjustment)
            )
            reached.append(adjustment)
        }
        #expect(reached == [.quarterTurnRight, .halfTurn])

        // The retained source is untouched, bit for bit.
        #expect(source.channelMixed.image.values.count == originalValues.count)
        #expect(
            zip(source.channelMixed.image.values, originalValues)
                .allSatisfy { $0.bitPattern == $1.bitPattern }
        )

        // Two presses land exactly where one half turn does.
        let stepwise = try pipeline.render(
            source, adjustments: ImageAdjustments(orientation: adjustment)
        )
        let direct = try pipeline.render(
            source, adjustments: ImageAdjustments(orientation: .halfTurn)
        )
        #expect(WorkspaceStubs.pixelBytes(stepwise.image)
            == WorkspaceStubs.pixelBytes(direct.image))
    }

    // MARK: - The whole workflow through the application layer

    @MainActor
    @Test("The workspace performs the correction the user asks for")
    func theWorkspacePerformsTheCorrection() async throws {
        let url = try #require(RAWFixtures.olympusORF)
        // An in-memory store, deliberately: the production one would write a
        // sidecar beside the user's own RAW file, and a test must leave the
        // fixture directory exactly as it found it.
        let state = DocumentState(store: StubImageAdjustmentStore())
        state.open(url)

        let initial = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .identity, timeout: .seconds(300))
        )
        #expect(initial.pixelWidth == 4056)
        #expect(initial.pixelHeight == 3040)
        let initialBytes = try #require(WorkspaceStubs.pixelBytes(initial.image))

        state.rotateOrientationLeft()
        let corrected = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnLeft, timeout: .seconds(300))
        )
        #expect(corrected.effectiveOrientation == .rotated270Clockwise)
        #expect(corrected.pixelWidth == 3040)
        #expect(corrected.pixelHeight == 4056)

        state.resetOrientation()
        let reset = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .identity, timeout: .seconds(300))
        )
        #expect(reset.effectiveOrientation == .upright)
        #expect(WorkspaceStubs.pixelBytes(reset.image) == initialBytes)
    }
}
