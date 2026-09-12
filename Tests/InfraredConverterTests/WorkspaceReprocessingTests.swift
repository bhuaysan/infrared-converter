import Testing
import CoreGraphics
import Foundation
@testable import InfraredConverter

/// What the workspace does when adjustments arrive faster than it can render
/// them.
///
/// The scheduling claims themselves are proven against instrumentation in
/// `CoalescingPreviewRendererTests`; these tests check that the workspace is
/// wired to that scheduler and that a burst settles on exactly the state the
/// user asked for last.
@Suite("Workspace reprocessing")
@MainActor
struct WorkspaceReprocessingTests {

    static let url = URL(fileURLWithPath: "/tmp/example.orf")

    static func opened() async throws -> DocumentState {
        let state = WorkspaceStubs.documentState(url: url)
        state.open(url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        return state
    }

    /// A one-shot render of one adjustment, produced independently of the
    /// workspace, as the oracle for what the burst should settle on.
    static func referencePixels(
        _ adjustment: UserOrientationAdjustment
    ) throws -> Data? {
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url))
        )
        let preview = try WorkspacePreviewPipeline().render(
            decoding: url,
            using: decoder,
            adjustments: ImageAdjustments(orientation: adjustment)
        )
        return WorkspaceStubs.pixelBytes(preview.image)
    }

    // MARK: - A burst settles on the newest state

    @Test("Five presses in a burst settle on the one canonical state they compose to")
    func aBurstSettlesOnTheNewestState() async throws {
        let state = try await Self.opened()

        // Faster than any render can finish: no await between them.
        state.rotateOrientationRight()
        state.rotateOrientationRight()
        state.flipOrientationHorizontally()
        state.rotateOrientationLeft()
        state.rotateOrientationHalfTurn()

        let expected = UserOrientationAdjustment.identity
            .rotatedRight()
            .rotatedRight()
            .flippedHorizontally()
            .rotatedLeft()
            .rotatedHalfTurn()

        // The record follows the presses immediately: the controls never lag
        // behind what was pressed.
        #expect(state.orientationAdjustment == expected)

        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: expected)
        )
        #expect(preview.userOrientationAdjustment == expected)
        #expect(
            WorkspaceStubs.pixelBytes(preview.image) == (try Self.referencePixels(expected))
        )
    }

    /// The failure this milestone is about, seen from the workspace: a
    /// superseded render must never be the one on screen.
    @Test("The settled preview is never one of the superseded states")
    func supersededStatesNeverReachTheScreen() async throws {
        let state = try await Self.opened()

        state.rotateOrientationRight()
        state.rotateOrientationRight()
        state.rotateOrientationRight()

        let expected = UserOrientationAdjustment.quarterTurnLeft
        #expect(state.orientationAdjustment == expected)

        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: expected)
        )

        // Not the first press, not the second, and not the file's own
        // orientation.
        #expect(preview.userOrientationAdjustment != .quarterTurnRight)
        #expect(preview.userOrientationAdjustment != .halfTurn)
        #expect(preview.userOrientationAdjustment != .identity)

        // And the preview and the controls agree, which is the property a late
        // superseded result would break.
        #expect(preview.userOrientationAdjustment == state.orientationAdjustment)
    }

    @Test("A burst never re-renders from an already oriented image")
    func aBurstAlwaysRestartsFromTheUnorientedSource() async throws {
        let state = try await Self.opened()

        // Four quarter turns compose to the identity. If any render had been
        // applied on top of a previous result, the pixels would be a different
        // orientation of the photograph — always a valid-looking one, and
        // always the wrong one.
        state.rotateOrientationRight()
        state.rotateOrientationRight()
        state.rotateOrientationRight()
        state.rotateOrientationRight()

        #expect(state.orientationAdjustment == .identity)

        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        )
        #expect(preview.effectiveOrientation == .upright)
        #expect(
            WorkspaceStubs.pixelBytes(preview.image) == (try Self.referencePixels(.identity))
        )
    }

    // MARK: - The retained source

    @Test("The retained scene-linear source survives a burst untouched")
    func theRetainedSourceIsUnchangedByABurst() async throws {
        let state = try await Self.opened()

        guard case .decoded(let before) = state.status, let source = before.source else {
            Issue.record("Expected an adjustable file")
            return
        }
        let originalValues = source.preview.values
        let originalWidth = source.preview.width
        let originalHeight = source.preview.height

        state.rotateOrientationRight()
        state.flipOrientationVertically()
        state.rotateOrientationHalfTurn()
        state.flipOrientationHorizontally()

        let expected = state.orientationAdjustment
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: expected))

        guard case .decoded(let after) = state.status, let settled = after.source else {
            Issue.record("Expected the source to still be retained")
            return
        }
        #expect(settled.preview.values == originalValues)
        #expect(settled.preview.width == originalWidth)
        #expect(settled.preview.height == originalHeight)
        // And the file's own recorded orientation is still a fact about the
        // file, not a record of what the user pressed.
        #expect(settled.metadata.geometry.flip == before.metadata.geometry.flip)
    }

    // MARK: - The ordinary path

    @Test("A single adjustment still renders exactly as it did")
    func aSingleAdjustmentIsUnchanged() async throws {
        let state = try await Self.opened()

        state.rotateOrientationRight()
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        #expect(preview.userOrientationAdjustment == .quarterTurnRight)
        #expect(preview.sourceOrientation == .upright)
        #expect(preview.effectiveOrientation == .rotated90Clockwise)
        #expect(preview.pixelWidth == 6)
        #expect(preview.pixelHeight == 8)
        #expect(
            WorkspaceStubs.pixelBytes(preview.image)
                == (try Self.referencePixels(.quarterTurnRight))
        )
    }

    @Test("Opening another file abandons the first file's pending renders")
    func openingAnotherFileAbandonsTheBurst() async throws {
        let state = try await Self.opened()
        state.rotateOrientationRight()
        state.rotateOrientationHalfTurn()

        let other = URL(fileURLWithPath: "/tmp/other.orf")
        state.open(other)

        #expect(state.selectedFileURL == other)
        // The new file starts from no correction at all: an adjustment belongs
        // to the file it was made for.
        #expect(state.orientationAdjustment == .identity)
    }
}
