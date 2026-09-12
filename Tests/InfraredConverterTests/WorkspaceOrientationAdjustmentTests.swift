import Testing
import CoreGraphics
import Foundation
@testable import InfraredConverter

/// The user-facing orientation workflow at the application layer: what the
/// controls do to the adjustment record, and what the pipeline does with it.
///
/// The stub mosaic is 8 × 6 and every sample differs, so a dimension swap
/// cannot hide and no two orientations produce the same pixels.
@Suite("Workspace orientation adjustment")
@MainActor
struct WorkspaceOrientationAdjustmentTests {

    static let url = URL(fileURLWithPath: "/tmp/example.orf")

    static func opened(flip: Int = 0) async throws -> DocumentState {
        let state = WorkspaceStubs.documentState(url: url, flip: flip)
        state.open(url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        return state
    }

    static func preview(_ state: DocumentState) throws -> WorkspacePreview {
        guard case .decoded(let loaded) = state.status,
              case .rendered(let preview) = loaded.owned
        else {
            Issue.record("Expected a rendered preview, got \(state.status)")
            throw CancellationError()
        }
        return preview
    }

    // MARK: - The starting state

    @Test("A freshly opened file has no user correction")
    func aFreshFileHasNoCorrection() async throws {
        let state = try await Self.opened()
        let preview = try Self.preview(state)

        #expect(state.orientationAdjustment == .identity)
        #expect(state.canAdjustOrientation)
        #expect(preview.userOrientationAdjustment == .identity)
        #expect(preview.sourceOrientation == .upright)
        #expect(preview.effectiveOrientation == .upright)
        #expect(preview.pixelWidth == 8)
        #expect(preview.pixelHeight == 6)
    }

    // MARK: - What the controls do

    @Test("Rotating right changes the effective orientation and the geometry")
    func rotatingRightChangesTheGeometry() async throws {
        let state = try await Self.opened()

        state.rotateOrientationRight()
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        #expect(preview.userOrientationAdjustment == .quarterTurnRight)
        // The file still records upright. A user correction is not metadata.
        #expect(preview.sourceOrientation == .upright)
        #expect(preview.effectiveOrientation == .rotated90Clockwise)
        #expect(preview.sourcePixelWidth == 8)
        #expect(preview.sourcePixelHeight == 6)
        #expect(preview.pixelWidth == 6)
        #expect(preview.pixelHeight == 8)
        #expect(preview.image.width == 6)
        #expect(preview.image.height == 8)
    }

    @Test("Rotating left is the other quarter turn, and the two cancel")
    func rotatingLeftIsTheOtherQuarterTurn() async throws {
        let state = try await Self.opened()

        state.rotateOrientationLeft()
        let left = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnLeft)
        )
        #expect(left.effectiveOrientation == .rotated270Clockwise)

        state.rotateOrientationRight()
        let back = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        )
        #expect(back.effectiveOrientation == .upright)
    }

    @Test("Flipping horizontally and vertically are reflections, not rotations")
    func flipsAreReflections() async throws {
        let state = try await Self.opened()

        state.flipOrientationHorizontally()
        let flipped = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .horizontalFlip)
        )
        #expect(flipped.effectiveOrientation == .mirroredHorizontally)
        #expect(flipped.effectiveOrientation.isMirrored)
        #expect(flipped.pixelWidth == 8)
        #expect(flipped.pixelHeight == 6)

        state.flipOrientationVertically()
        let both = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .halfTurn)
        )
        // Two perpendicular reflections make a half turn — a rotation.
        #expect(both.effectiveOrientation == .rotated180)
        #expect(!both.effectiveOrientation.isMirrored)
    }

    // MARK: - Canonical state, not a history

    @Test("Four rotate-rights return to the identity adjustment")
    func fourRotationsReturnToIdentity() async throws {
        let state = try await Self.opened()
        let original = try #require(WorkspaceStubs.pixelBytes(try Self.preview(state).image))

        let expected: [UserOrientationAdjustment] =
            [.quarterTurnRight, .halfTurn, .quarterTurnLeft, .identity]
        for step in expected {
            state.rotateOrientationRight()
            _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: step))
            #expect(state.orientationAdjustment == step)
        }

        // The persisted state is one canonical adjustment, not four commands.
        #expect(state.orientationAdjustment == .identity)
        #expect(state.orientationAdjustment.persistedToken == "none")

        // And the pixels are bit-identical to the first render, which they
        // could not be if each rotation had been applied to the previous
        // displayed buffer with any loss at all.
        let after = try #require(WorkspaceStubs.pixelBytes(try Self.preview(state).image))
        #expect(after == original)
    }

    // MARK: - Non-destructive reprocessing

    /// The requirement this suite exists for: every render starts from the
    /// retained channel-mixed image, never from the previous displayed one.
    ///
    /// Reset is the decisive case. Composing the identity onto an
    /// already-rotated buffer would leave it rotated while every record
    /// claimed no correction — a well-formed picture that is simply the wrong
    /// one.
    @Test("Reset returns to exactly the metadata-derived pixels")
    func resetReturnsToTheMetadataResult() async throws {
        let state = try await Self.opened()
        let original = try #require(WorkspaceStubs.pixelBytes(try Self.preview(state).image))

        state.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )
        state.rotateOrientationRight()
        let rotated = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .halfTurn)
        )
        let rotatedBytes = try #require(WorkspaceStubs.pixelBytes(rotated.image))
        #expect(rotatedBytes != original)

        state.resetOrientation()
        let reset = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        )
        #expect(reset.effectiveOrientation == .upright)
        #expect(WorkspaceStubs.pixelBytes(reset.image) == original)
    }

    /// A sequence of presses ending at a state must be bit-identical to
    /// reaching that state directly from a fresh load — which is only true if
    /// nothing accumulated along the way.
    @Test("A sequence of presses equals one canonical adjustment applied once")
    func aSequenceEqualsTheCanonicalAdjustment() async throws {
        let sequence = try await Self.opened()
        sequence.rotateOrientationRight()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(sequence, adjustment: .quarterTurnRight)
        )
        sequence.flipOrientationHorizontally()
        let combined = try #require(
            await WorkspaceStubs.waitForPreview(sequence, adjustment: .diagonalFlip)
        )
        #expect(combined.effectiveOrientation == .transposed)

        // The same state reached in one step, from a completely separate load.
        let direct = try await Self.opened()
        direct.flipOrientationHorizontally()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(direct, adjustment: .horizontalFlip)
        )
        direct.rotateOrientationLeft()
        let once = try #require(
            await WorkspaceStubs.waitForPreview(direct, adjustment: .diagonalFlip)
        )

        #expect(WorkspaceStubs.pixelBytes(combined.image)
            == WorkspaceStubs.pixelBytes(once.image))
    }

    /// The retained scene-linear source is the thing every render reads, so
    /// it must survive every render untouched — bit for bit.
    @Test("The retained channel-mixed source is never mutated")
    func theRetainedSourceIsNeverMutated() async throws {
        let state = try await Self.opened()
        guard case .decoded(let first) = state.status, let source = first.source else {
            Issue.record("Expected a retained source")
            return
        }
        let originalValues = source.preview.values
        let originalWidth = source.preview.width
        let originalHeight = source.preview.height

        for step in [UserOrientationAdjustment.quarterTurnRight, .halfTurn, .quarterTurnLeft] {
            state.rotateOrientationRight()
            _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: step))
        }

        guard case .decoded(let later) = state.status, let retained = later.source else {
            Issue.record("Expected the source to still be retained")
            return
        }
        #expect(retained.preview.width == originalWidth)
        #expect(retained.preview.height == originalHeight)
        #expect(retained.preview.values.count == originalValues.count)
        // Bit patterns, not approximate equality: a permutation that wrote
        // back into its input would show here even if the values looked
        // plausible.
        #expect(
            zip(retained.preview.values, originalValues)
                .allSatisfy { $0.bitPattern == $1.bitPattern }
        )
    }

    // MARK: - Metadata stays metadata

    @Test("A user correction never rewrites the file's recorded orientation")
    func metadataIsNeverRewritten() async throws {
        let state = try await Self.opened(flip: 6)  // the file records a quarter turn

        state.rotateOrientationRight()
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        #expect(preview.sourceOrientation == .rotated90Clockwise)
        #expect(preview.effectiveOrientation == .rotated180)

        guard case .decoded(let loaded) = state.status else {
            Issue.record("Expected a decoded file")
            return
        }
        #expect(loaded.source?.metadata.geometry.flip == 6)
        #expect(loaded.source?.metadata.geometry.orientation == .rotated90Clockwise)
    }

    /// Reset on a file whose metadata records a rotation restores **that
    /// rotation**, not upright.
    @Test("Reset on a rotated file restores the file's rotation, not upright")
    func resetOnARotatedFileRestoresTheRotation() async throws {
        let state = try await Self.opened(flip: 6)
        let recorded = try #require(WorkspaceStubs.pixelBytes(try Self.preview(state).image))
        #expect(try Self.preview(state).effectiveOrientation == .rotated90Clockwise)

        state.rotateOrientationLeft()
        let corrected = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnLeft)
        )
        #expect(corrected.effectiveOrientation == .upright)

        state.resetOrientation()
        let reset = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        )
        #expect(reset.effectiveOrientation == .rotated90Clockwise)
        #expect(reset.effectiveOrientation != .upright)
        #expect(WorkspaceStubs.pixelBytes(reset.image) == recorded)
    }

    // MARK: - Provenance

    @Test("The preview's provenance answers all three orientation questions")
    func provenanceAnswersAllThree() async throws {
        let state = try await Self.opened(flip: 4)  // transposed
        state.rotateOrientationRight()
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        let provenance = preview.orientationProvenance
        #expect(provenance.sourceOrientation == .transposed)
        #expect(provenance.userAdjustment == .quarterTurnRight)
        #expect(provenance.effectiveOrientation == .mirroredHorizontally)
        #expect(provenance.isUserAdjusted)
        // The derivation and the stage that ran agree.
        #expect(provenance.isConsistent)
        #expect(provenance.stageOrientation == .mirroredHorizontally)

        // The upstream chain is reachable, and not duplicated.
        #expect(provenance.channelMixProcessing.mixSource == .identity)
        #expect(provenance.channelMixProcessing.demosaicAlgorithm == .bilinearBayer)
        #expect(!provenance.channelMixProcessing.isValidatedInfraredCalibration)

        // And the display record still agrees about what was applied.
        #expect(preview.processing.appliedOrientation == .mirroredHorizontally)
        #expect(preview.processing.orientationApplied)
    }

    // MARK: - Refusals

    @Test("A file with an unmodelled orientation reports rather than renders")
    func anUnmodelledOrientationIsReported() async throws {
        let state = WorkspaceStubs.documentState(url: Self.url, flip: 9)
        state.open(Self.url)

        for _ in 0..<400 {
            if case .decoded(let loaded) = state.status, case .unavailable = loaded.owned {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard case .decoded(let loaded) = state.status,
              case .unavailable(let failure) = loaded.owned
        else {
            Issue.record("Expected the owned preview to be unavailable")
            return
        }
        #expect(!failure.message.isEmpty)
        #expect(failure.stage == .ownedRender)
        #expect(failure.orientation == .unsupportedDecoderOrientation(flip: 9))
        // The prepare phase succeeded, so the source is retained — the
        // refusal is the orientation stage's, and only that.
        #expect(loaded.source != nil)
        // Retained is not adjustable. Nothing can derive an effective
        // orientation from a flip this application cannot read, so the
        // controls stay inert rather than offering a button that must fail.
        #expect(!loaded.isAdjustable)
        #expect(!state.canAdjustOrientation)
        #expect(state.orientationAdjustment.isIdentity)
    }
}
