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

    /// The full-resolution active image area. Every claim about what the
    /// file *contains* is in these coordinates.
    static let sourceWidth = 4056
    static let sourceHeight = 3040

    /// The interactive preview the workspace actually re-renders, under
    /// `PreviewResolutionPolicy.workspace`: 2048 on the longest edge, and
    /// 3040 x 2048/4056 rounded to nearest on the other. Every claim about
    /// what the workspace *shows* is in these coordinates.
    ///
    /// They are written out rather than recomputed from the policy, so that a
    /// change to the default limit fails this suite loudly instead of silently
    /// re-deriving whatever the new limit produces.
    static let previewWidth = 2048
    static let previewHeight = 1535

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
        // What was prepared is the reduced preview, and it records what it
        // was reduced from.
        #expect(source.preview.width == Self.previewWidth)
        #expect(source.preview.height == Self.previewHeight)
        #expect(source.resolution.sourceWidth == Self.sourceWidth)
        #expect(source.resolution.sourceHeight == Self.sourceHeight)
        #expect(source.resolution.isReduced)
        #expect(source.resolution.method == .areaAverage)
        #expect(source.resolution.policy == .workspace)
    }

    // MARK: - 2. Identity preserves the sideways result

    @Test("With no correction the result is the metadata-derived one, unchanged")
    func identityPreservesTheSidewaysResult() throws {
        let source = try Self.prepared()
        let preview = try WorkspacePreviewPipeline().render(source, adjustments: .none)

        #expect(preview.sourceOrientation == .upright)
        #expect(preview.userOrientationAdjustment == .identity)
        #expect(preview.effectiveOrientation == .upright)
        #expect(preview.pixelWidth == Self.previewWidth)
        #expect(preview.pixelHeight == Self.previewHeight)
        #expect(preview.image.width == Self.previewWidth)
        #expect(preview.image.height == Self.previewHeight)

        // The whole chain below orientation is untouched by the adjustment
        // model. The clip counts are reference values for the **reduced**
        // frame and are lower than the 11 low samples the full-resolution
        // frame carried: an area-weighted mean of a slightly negative sample
        // and its non-negative neighbours is not itself negative, so those
        // few samples no longer reach the display stage as clipped. Nothing
        // was clamped to produce that — the reduction clamps nothing — the
        // samples simply averaged back into range.
        #expect(preview.processing.clippedLowSampleCount == 0)
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

        // 4. The dimensions exchange — the preview's, which is the only
        // buffer the turn touches. The full-resolution dimensions it was
        // reduced from are recorded unchanged and in sensor order.
        #expect(preview.sourcePixelWidth == Self.previewWidth)
        #expect(preview.sourcePixelHeight == Self.previewHeight)
        #expect(preview.pixelWidth == Self.previewHeight)
        #expect(preview.pixelHeight == Self.previewWidth)
        #expect(preview.image.width == Self.previewHeight)
        #expect(preview.image.height == Self.previewWidth)
        #expect(preview.resolution.sourceWidth == Self.sourceWidth)
        #expect(preview.resolution.sourceHeight == Self.sourceHeight)

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
    /// comes from source `(c, w − 1 − r)`. The source is the **reduced**
    /// preview, 2048 × 1535, so the corrected image is 1535 wide and 2048
    /// high. The permutation claim is independent of resolution: it is about
    /// where a pixel goes, and the preview is the buffer it goes in.
    @Test("Named destination coordinates map to the expected source pixels")
    func namedCoordinatesMapCorrectly() throws {
        let source = try Self.prepared()
        // The retained source is pre-mix, so the creative stage runs first.
        // `.identity` is bit-preserving, which is what makes it the right mix
        // for a test about where pixels go rather than what they are.
        let mixed = try IRChannelMixer().apply(to: source.preview, mix: .identity)
        let oriented = try ImageOrienter().apply(
            to: mixed, orientation: .rotated270Clockwise
        )

        #expect(oriented.width == Self.previewHeight)
        #expect(oriented.height == Self.previewWidth)

        let lastColumn = Self.previewWidth - 1   // 2047

        let coordinates: [(row: Int, column: Int)] = [
            (row: 0, column: 0),          // top-left of the corrected frame
            (row: 0, column: 1534),       // top-right
            (row: 2047, column: 0),       // bottom-left
            (row: 2047, column: 1534),    // bottom-right
            (row: 1000, column: 700),
            (row: 512, column: 1024),
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
                sourceWidth: Self.previewWidth,
                sourceHeight: Self.previewHeight
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
        let mixed = try IRChannelMixer().apply(to: source.preview, mix: .identity)
        let rotated = try ImageOrienter().apply(
            to: mixed, orientation: .rotated270Clockwise
        )
        let reflected = try ImageOrienter().apply(
            to: mixed, orientation: .transposed
        )

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
        let originalValues = source.preview.values

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
        #expect(source.preview.values.count == originalValues.count)
        #expect(
            zip(source.preview.values, originalValues)
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
        #expect(initial.pixelWidth == Self.previewWidth)
        #expect(initial.pixelHeight == Self.previewHeight)
        #expect(initial.resolution.sourceWidth == Self.sourceWidth)
        #expect(initial.resolution.sourceHeight == Self.sourceHeight)
        let initialBytes = try #require(WorkspaceStubs.pixelBytes(initial.image))

        state.rotateOrientationLeft()
        let corrected = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnLeft, timeout: .seconds(300))
        )
        #expect(corrected.effectiveOrientation == .rotated270Clockwise)
        #expect(corrected.pixelWidth == Self.previewHeight)
        #expect(corrected.pixelHeight == Self.previewWidth)

        state.resetOrientation()
        let reset = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .identity, timeout: .seconds(300))
        )
        #expect(reset.effectiveOrientation == .upright)
        #expect(WorkspaceStubs.pixelBytes(reset.image) == initialBytes)
    }
}
