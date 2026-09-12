import Testing
import CoreGraphics
import Foundation
@testable import InfraredConverter

/// What the workspace holds open, and what an adjustment actually costs.
///
/// The pixel arithmetic is proved in `SceneLinearPreviewReducerTests` and the
/// scheduling in `CoalescingPreviewRendererTests`. These tests are about the
/// two claims only the application layer can make: that the retained source is
/// reduced, and that changing an adjustment touches nothing but it.
@Suite("Workspace preview resolution")
@MainActor
struct WorkspacePreviewResolutionTests {

    static let url = URL(fileURLWithPath: "/tmp/preview-resolution.orf")

    /// Small enough to run in milliseconds, large enough that the limit below
    /// genuinely reduces it. A deliberately non-square shape, so a dimension
    /// swap cannot hide.
    static let sourceWidth = 64
    static let sourceHeight = 48

    /// Injected rather than production's 2048, so the reduction is exercised
    /// without a multi-megapixel fixture.
    static let policy = PreviewResolutionPolicy(maximumLongestEdge: 16)
    static let previewWidth = 16
    static let previewHeight = 12

    static func opened(
        store: any ImageAdjustmentStore = StubImageAdjustmentStore()
    ) async throws -> DocumentState {
        let state = WorkspaceStubs.documentState(
            url: url,
            width: sourceWidth,
            height: sourceHeight,
            store: store,
            previewPolicy: policy
        )
        state.open(url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)
        return state
    }

    static func loaded(_ state: DocumentState) throws -> DocumentState.Loaded {
        guard case .decoded(let loaded) = state.status else {
            throw TestFailure("Expected an opened document")
        }
        return loaded
    }

    struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: - What is on screen

    @Test("The first preview after an open is already reduced")
    func theFirstPreviewIsReduced() async throws {
        let state = try await Self.opened()
        let loaded = try Self.loaded(state)
        guard case .rendered(let preview) = loaded.owned else {
            Issue.record("Expected a rendered preview")
            return
        }

        #expect(preview.pixelWidth == Self.previewWidth)
        #expect(preview.pixelHeight == Self.previewHeight)
        #expect(preview.image.width == Self.previewWidth)
        #expect(preview.image.height == Self.previewHeight)

        #expect(max(preview.pixelWidth, preview.pixelHeight)
            <= Self.policy.maximumLongestEdge)

        // It says what it was reduced from, rather than leaving that to be
        // guessed at from the sensor's dimensions.
        #expect(preview.resolution.sourceWidth == Self.sourceWidth)
        #expect(preview.resolution.sourceHeight == Self.sourceHeight)
        #expect(preview.resolution.isReduced)
        #expect(preview.resolution.method == .areaAverage)
        #expect(preview.resolution.policy == Self.policy)
        #expect(preview.fullResolutionSourcePixelWidth == Self.sourceWidth)
        #expect(preview.fullResolutionSourcePixelHeight == Self.sourceHeight)
    }

    @Test("The retained interactive source is reduced too")
    func theRetainedSourceIsReduced() async throws {
        let state = try await Self.opened()
        let source = try #require(try Self.loaded(state).source)

        #expect(source.preview.width == Self.previewWidth)
        #expect(source.preview.height == Self.previewHeight)
        #expect(max(source.preview.width, source.preview.height)
            <= Self.policy.maximumLongestEdge)
        #expect(source.resolution.sourceWidth == Self.sourceWidth)
        #expect(source.preview.isGeometryConsistent)
    }

    /// An image already within the limit is not resampled, and the record says
    /// `unreduced` rather than claiming an average that never happened.
    @Test("A file smaller than the limit is retained unreduced, and says so")
    func aSmallFileIsNotReduced() async throws {
        let state = WorkspaceStubs.documentState(url: Self.url, width: 8, height: 6)
        state.open(Self.url)
        _ = try await WorkspaceStubs.waitForPreview(state, adjustment: .identity)

        let source = try #require(try Self.loaded(state).source)
        #expect(source.preview.width == 8)
        #expect(source.preview.height == 6)
        #expect(!source.resolution.isReduced)
        #expect(source.resolution.method == .unreduced)
    }

    // MARK: - What an adjustment costs

    /// The claim this milestone exists to make: a rotation re-renders the
    /// reduced buffer and nothing else.
    ///
    /// `decodeMosaic` is the single door to every full-resolution stage —
    /// normalisation, the white-balance estimate, the white balance itself,
    /// demosaicing, the camera transform and the reduction are all reachable
    /// only through `prepare`, which begins with it. One call across an open
    /// and four rotations therefore proves that none of them ran again.
    @Test("Rotating never decodes, demosaics or reduces again")
    func rotationRerunsNothingUpstream() async throws {
        let (state, decoder) = WorkspaceStubs.countingDocumentState(
            url: Self.url,
            width: Self.sourceWidth,
            height: Self.sourceHeight,
            previewPolicy: Self.policy
        )
        state.open(Self.url)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))
        #expect(decoder.mosaicDecodeCount == 1)

        var expected = UserOrientationAdjustment.identity
        for _ in 0..<4 {
            state.rotateOrientationRight()
            expected = expected.rotatedRight()
            _ = try #require(
                await WorkspaceStubs.waitForPreview(state, adjustment: expected)
            )
        }

        // Four rotations, still one read of the file.
        #expect(decoder.mosaicDecodeCount == 1)
        // And the LibRaw diagnostic reference was not re-read either.
        #expect(decoder.processedDecodeCount == 1)
    }

    /// The re-render works on the reduced buffer, and the reduced buffer only:
    /// a quarter turn exchanges the preview's dimensions, never the sensor's,
    /// and never rescales.
    @Test("A quarter turn exchanges the preview dimensions and rescales nothing")
    func aQuarterTurnOnlyExchangesPreviewDimensions() async throws {
        let state = try await Self.opened()
        state.rotateOrientationRight()
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )

        #expect(preview.sourcePixelWidth == Self.previewWidth)
        #expect(preview.sourcePixelHeight == Self.previewHeight)
        #expect(preview.pixelWidth == Self.previewHeight)
        #expect(preview.pixelHeight == Self.previewWidth)

        // The reduction record is unchanged by the turn: it describes what was
        // reduced, in sensor order, and a rotation is not a reduction.
        #expect(preview.resolution.sourceWidth == Self.sourceWidth)
        #expect(preview.resolution.sourceHeight == Self.sourceHeight)
        #expect(preview.resolution.width == Self.previewWidth)
        #expect(preview.resolution.height == Self.previewHeight)

        // Still within the limit, whichever way round it is.
        #expect(max(preview.pixelWidth, preview.pixelHeight)
            <= Self.policy.maximumLongestEdge)
    }

    @Test("The retained reduced source survives a burst of rotations untouched")
    func theRetainedSourceSurvivesABurst() async throws {
        let state = try await Self.opened()
        let before = try #require(try Self.loaded(state).source).preview.values

        state.rotateOrientationRight()
        state.flipOrientationVertically()
        state.rotateOrientationHalfTurn()
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustment: state.orientationAdjustment
            )
        )

        let after = try #require(try Self.loaded(state).source).preview.values
        #expect(after.count == before.count)
        #expect(zip(after, before).allSatisfy { $0.bitPattern == $1.bitPattern })
    }

    // MARK: - What is retained, structurally

    /// A buffer-size comparison rather than a resident-memory measurement.
    /// Peak RSS is a property of the whole process and of whatever else the
    /// test runner is doing; the number of samples a document holds open is a
    /// property of this code.
    @Test("The retained source holds far fewer samples than the full image")
    func theRetainedSourceHoldsFewerSamples() async throws {
        let state = try await Self.opened()
        let source = try #require(try Self.loaded(state).source)

        let channels = SceneLinearPreviewImage.channelCount
        let fullSamples = Self.sourceWidth * Self.sourceHeight * channels
        let previewSamples = source.preview.width * source.preview.height * channels

        #expect(source.preview.values.count == previewSamples)
        #expect(previewSamples < fullSamples)

        // The policy reduces each axis by four here, so the sample count falls
        // by about sixteen. Checked as a range rather than an exact
        // percentage, because the shorter edge is rounded to an integer.
        let factor = Double(fullSamples) / Double(previewSamples)
        #expect(factor > 15)
        #expect(factor < 17)

        // Stated in bytes too, which is the number that matters for a document
        // left open.
        let bytesPerSample = MemoryLayout<Float>.size
        #expect(previewSamples * bytesPerSample < fullSamples * bytesPerSample / 15)
    }

    /// The shape of the retained value, pinned.
    ///
    /// The saving is real only if nothing full-resolution is reachable from
    /// what the workspace keeps. That is a property of the type rather than of
    /// any run, so it is checked as one: a future change that re-attached a
    /// `source` chain — the mosaics, the camera-native image, the
    /// working-colour image — would fail here rather than quietly restoring
    /// hundreds of megabytes per open document.
    @Test("The retained source holds one buffer and reaches no full-resolution chain")
    func theRetainedSourceReachesNothingUpstream() async throws {
        let state = try await Self.opened()
        let source = try #require(try Self.loaded(state).source)

        let labels = Mirror(reflecting: source).children.compactMap(\.label)
        #expect(labels == ["preview", "metadata", "url", "neutralPatch"])

        // The one buffer it does hold is the reduced one.
        let previewLabels = Mirror(reflecting: source.preview).children.compactMap(\.label)
        #expect(previewLabels == ["width", "height", "values", "processing"])
        #expect(source.preview.values.count
            == Self.previewWidth * Self.previewHeight * 3)
    }

    // MARK: - Leaving a document mid-render

    /// ADR 0014 lets a document the workspace has left keep its render slot
    /// until the state it was asked for has settled, which means two documents
    /// briefly hold a scene-linear source each. This checks that both of them
    /// are reduced — the overlap is two preview buffers, not two chains.
    @Test("A settling document and the new one each hold only a reduced source")
    func aFileSwitchOverlapsTwoReducedSources() async throws {
        let first = URL(fileURLWithPath: "/tmp/preview-switch-a.orf")
        let second = URL(fileURLWithPath: "/tmp/preview-switch-b.orf")

        let state = WorkspaceStubs.documentState(
            url: first,
            width: Self.sourceWidth,
            height: Self.sourceHeight,
            previewPolicy: Self.policy
        )
        state.open(first)
        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))

        let leaving = try #require(try Self.loaded(state).source)
        #expect(leaving.preview.width == Self.previewWidth)
        #expect(leaving.preview.values.count
            == Self.previewWidth * Self.previewHeight * 3)

        // Rotate, then leave immediately: the decision is at stake, so the
        // document settles rather than being cancelled.
        state.rotateOrientationRight()
        state.open(second)

        _ = try #require(await WorkspaceStubs.waitForPreview(state, adjustment: .identity))
        let arrived = try #require(try Self.loaded(state).source)
        #expect(arrived.url == second)
        #expect(arrived.preview.width == Self.previewWidth)
        #expect(arrived.preview.values.count
            == Self.previewWidth * Self.previewHeight * 3)

        // Whatever the overlap was, it settled: nothing is left in flight.
        #expect(!state.hasPendingAdjustmentWork)
    }
}
