import Testing
import Foundation
@testable import InfraredConverter

/// The workspace's two RAW paths and the four ways they can end.
///
/// ```text
/// owned prepared + rendered / legacy ok      → workspace image + reference
/// owned prepared + rendered / legacy fails   → workspace image, reference missing
/// owned fails at prepare    / legacy ok      → the owned failure; no fallback
/// owned fails at render     / legacy ok      → the owned failure; no fallback
/// owned fails at prepare    / legacy fails   → a typed open error
/// owned fails at render     / legacy fails   → a typed open error
/// ```
///
/// The owned path is split into its two halves because the boundary turns on
/// the difference. Preparing produces the expensive scene-linear state and
/// proves nothing about whether an image can be shown; only a completed
/// render does. An open used to succeed on a prepared source alone, which
/// meant a file could be reported as open with no displayable image anywhere.
@Suite
@MainActor
struct DocumentStateTests {
    /// A decoder whose two entry points fail independently, which is exactly
    /// the axis the four combinations vary along.
    private struct StubDecoder: RAWDecoder {
        let result: Result<DecodedRAW, RAWDecodingError>
        var mosaic: Result<DecodedRAWMosaic, RAWDecodingError>?

        func readMetadata(at url: URL) throws -> RAWMetadata {
            try result.get().metadata
        }

        func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
            try result.get()
        }

        func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
            guard let mosaic else {
                throw RAWDecodingError.unsupportedRawStorage(
                    url, reason: "StubDecoder does not implement decodeMosaic"
                )
            }
            return try mosaic.get()
        }
    }

    private static let url = URL(fileURLWithPath: "/tmp/example.orf")

    /// A small RGGB mosaic the whole owned chain can actually run over.
    private static func stubMosaic(url: URL) -> DecodedRAWMosaic {
        WorkspaceStubs.mosaic(url: url, width: 8, height: 8)
    }

    private static func state(
        ownedSucceeds: Bool,
        legacySucceeds: Bool
    ) -> DocumentState {
        DocumentState(
            decoder: StubDecoder(
                result: legacySucceeds
                    ? .success(RAWTestData.decodedRAW(url: url))
                    : .failure(.fileNotFound(url)),
                mosaic: ownedSucceeds ? .success(stubMosaic(url: url)) : nil
            ),
            // In-memory: this suite is about the two RAW paths, and must
            // neither read nor write a sidecar on the way.
            store: StubImageAdjustmentStore()
        )
    }

    /// A decoder whose mosaic prepares perfectly and whose metadata names an
    /// orientation this application does not model.
    ///
    /// `flip 9` is not one of LibRaw's eight values, so every stage up to and
    /// including the creative mix succeeds and the geometry stage refuses —
    /// which is the only way to reach "prepared but unrenderable" without
    /// inventing a broken stage.
    private static func unrenderableState(legacySucceeds: Bool) -> DocumentState {
        DocumentState(
            decoder: StubDecoder(
                result: legacySucceeds
                    ? .success(RAWTestData.decodedRAW(url: url))
                    : .failure(.fileNotFound(url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: url, flip: 9))
            ),
            store: StubImageAdjustmentStore()
        )
    }

    // MARK: - Selection

    @Test
    func startsWithNoSelection() {
        let state = DocumentState(
            decoder: StubDecoder(result: .failure(.decoderUnavailable)),
            store: StubImageAdjustmentStore()
        )
        #expect(state.selectedFileURL == nil)
        if case .empty = state.status {} else {
            Issue.record("Expected .empty, got \(state.status)")
        }
    }

    @Test
    func openingAFileImmediatelyReportsTheSelection() {
        let state = Self.state(ownedSucceeds: false, legacySucceeds: false)

        state.open(Self.url)

        #expect(state.selectedFileURL == Self.url)
        if case .decoding(let decoding) = state.status {
            #expect(decoding == Self.url)
        } else {
            Issue.record("Expected .decoding, got \(state.status)")
        }
    }

    // MARK: - Owned succeeds, legacy succeeds

    @Test("Both paths succeeding gives the workspace image and the reference")
    func bothPathsSucceed() async throws {
        let state = Self.state(ownedSucceeds: true, legacySucceeds: true)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let loaded = try Self.decoded(state)
        #expect(loaded.url == Self.url)
        #expect(loaded.metadata.identity.model == "E-PL3")
        #expect(loaded.legacy.decoded != nil)
        #expect(loaded.legacy.preview != nil)
        #expect(loaded.legacy.failure == nil)

        guard case .rendered(let preview) = loaded.owned else {
            Issue.record("Expected the owned preview to be rendered")
            return
        }

        // The pixels are the owned pipeline's, at the mosaic's own geometry —
        // which is also the oriented geometry here, because this stub's
        // metadata records `flip 0`.
        #expect(preview.sourceOrientation == .upright)
        #expect(preview.userOrientationAdjustment == .identity)
        #expect(preview.effectiveOrientation == .upright)
        #expect(preview.sourcePixelWidth == 8)
        #expect(preview.sourcePixelHeight == 8)
        #expect(preview.pixelWidth == 8)
        #expect(preview.pixelHeight == 8)
        #expect(preview.image.width == 8)
        #expect(preview.image.height == 8)
        #expect(preview.image.bitsPerPixel == 24)

        // And the choices the application layer made are visible in the
        // provenance rather than hidden in a renderer default.
        #expect(preview.processing.exposureEV == 0)
        #expect(preview.processing.rangePolicy == .hardClipToDisplayRange)
        #expect(preview.processing.encoding == .sRGB)
        #expect(preview.processing.mixSource == .identity)
        #expect(preview.processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
        #expect(preview.processing.demosaicAlgorithm == .bilinearBayer)
        #expect(preview.processing.whiteBalanceApplied)
        #expect(!preview.processing.isValidatedInfraredCalibration)

        // The orientation stage ran, and the orientation it applied is the
        // one the file's metadata named.
        #expect(preview.processing.orientationApplied)
        #expect(preview.processing.appliedOrientation == .upright)
        #expect(!preview.processing.orientationSwappedDimensions)
    }

    // MARK: - Owned succeeds, legacy fails

    /// The requirement this rework exists for: the diagnostic decode failing
    /// must not be able to close the workspace.
    @Test("The workspace image appears even when the LibRaw reference cannot decode")
    func ownedSucceedsWithoutTheLegacyReference() async throws {
        let state = Self.state(ownedSucceeds: true, legacySucceeds: false)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let loaded = try Self.decoded(state)

        guard case .rendered(let preview) = loaded.owned else {
            Issue.record("Expected the owned preview to be rendered")
            return
        }
        #expect(preview.image.width == 8)
        #expect(preview.image.height == 8)

        // Metadata came from the path that worked, so the inspector is not
        // empty either.
        #expect(loaded.metadata.identity.model == "E-PL3")

        // And the missing reference is reported as missing, with its reason.
        #expect(loaded.legacy.decoded == nil)
        #expect(loaded.legacy.preview == nil)
        let failure = try #require(loaded.legacy.failure)
        #expect(failure.decoding == .fileNotFound(Self.url))
        #expect(!failure.message.isEmpty)

        // The file is fully usable: the correction controls work, because the
        // owned pipeline rendered this source rather than merely prepared it.
        #expect(loaded.isAdjustable)
        #expect(loaded.adjustableSource != nil)
        #expect(state.canAdjustOrientation)
    }

    @Test("A file whose LibRaw reference is missing can still be corrected")
    func aFileWithoutALegacyReferenceIsStillAdjustable() async throws {
        let state = Self.state(ownedSucceeds: true, legacySucceeds: false)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.rotateOrientationRight()
        let preview = try #require(
            await WorkspaceStubs.waitForPreview(state, adjustment: .quarterTurnRight)
        )
        #expect(preview.effectiveOrientation == .rotated90Clockwise)
    }

    // MARK: - Owned fails, legacy succeeds

    /// When the application-owned pipeline fails, the workspace says so. It
    /// does not fall back to the LibRaw image that decoded perfectly well,
    /// because a plausible picture from a different pipeline would look
    /// exactly like success.
    @Test("An owned-pipeline failure is reported rather than replaced by the reference")
    func aFailedOwnedPreviewIsReportedRatherThanReplaced() async throws {
        let state = Self.state(ownedSucceeds: false, legacySucceeds: true)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let loaded = try Self.decoded(state)
        guard case .unavailable(let failure) = loaded.owned else {
            Issue.record("Expected the owned preview to be unavailable")
            return
        }
        #expect(!failure.message.isEmpty)
        // The refusal is the preparation half's, and says so.
        #expect(failure.stage == .ownedPreparation)
        #expect(
            failure.decoding
                == .unsupportedRawStorage(
                    Self.url, reason: "StubDecoder does not implement decodeMosaic"
                )
        )

        // The legacy decode succeeded, and is deliberately not standing in for
        // the owned result.
        #expect(loaded.legacy.decoded != nil)
        #expect(loaded.legacy.preview != nil)

        // Nothing to reprocess, and nothing pretending there is.
        #expect(loaded.source == nil)
        #expect(!loaded.isAdjustable)
        #expect(loaded.adjustableSource == nil)
        #expect(!state.canAdjustOrientation)
    }

    // MARK: - Prepare succeeds, the initial render fails

    /// The case the open boundary used to get wrong in the other direction: a
    /// prepared source is not an image, but the diagnostic reference is one,
    /// so the file still opens.
    @Test("A render failure with a working reference opens, reports, and never falls back")
    func anInitialRenderFailureWithALegacyReference() async throws {
        let state = Self.unrenderableState(legacySucceeds: true)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        let loaded = try Self.decoded(state)
        guard case .unavailable(let failure) = loaded.owned else {
            Issue.record("Expected the owned preview to be unavailable")
            return
        }

        // The real render error, typed, not a sentence about it.
        #expect(failure.stage == .ownedRender)
        #expect(failure.orientation == .unsupportedDecoderOrientation(flip: 9))
        #expect(!failure.message.isEmpty)

        // The reference is available and is deliberately not the workspace
        // image.
        #expect(loaded.legacy.decoded != nil)
        #expect(loaded.legacy.preview != nil)

        // The expensive preparation is kept, because it is the most
        // informative thing about this file...
        #expect(loaded.source != nil)
        // ...and it does not make the file adjustable. No correction can
        // derive an effective orientation from a flip we cannot read, so every
        // adjustment would refuse exactly as this one did.
        #expect(!loaded.isAdjustable)
        #expect(loaded.adjustableSource == nil)
        #expect(!state.canAdjustOrientation)
    }

    @Test("Orientation controls do nothing on a file whose orientation cannot be read")
    func adjustmentsAreInertWhenTheRenderCannotSucceed() async throws {
        let state = Self.unrenderableState(legacySucceeds: true)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.rotateOrientationRight()
        state.flipOrientationVertically()
        state.resetOrientation()

        // The record is untouched: a control that cannot work does not record
        // an intent it will never honour.
        #expect(state.orientationAdjustment == .identity)
        let loaded = try Self.decoded(state)
        #expect(loaded.adjustments.orientation == .identity)
        guard case .unavailable = loaded.owned else {
            Issue.record("Expected the owned preview to stay unavailable")
            return
        }
    }

    /// The case that was missing: everything expensive succeeded, and there is
    /// still no image anywhere.
    @Test("A render failure with no reference is a failed open, not a decoded one")
    func anInitialRenderFailureWithNoReferenceFailsTheOpen() async throws {
        let state = Self.unrenderableState(legacySucceeds: false)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        guard case .failed(let failedURL, let error) = state.status else {
            Issue.record("Expected .failed, got \(state.status)")
            return
        }
        #expect(failedURL == Self.url)
        #expect(error.url == Self.url)

        // The owned refusal is the render half's, with the geometry stage's
        // own error intact.
        #expect(error.owned.stage == .ownedRender)
        #expect(error.owned.orientation == .unsupportedDecoderOrientation(flip: 9))

        // The reference's refusal is kept separately, and is a different error
        // from a different stage.
        #expect(error.legacy.stage == .legacyReference)
        #expect(error.legacy.decoding == .fileNotFound(Self.url))

        #expect(error.errorDescription?.isEmpty == false)
        let reason = try #require(error.failureReason)
        #expect(reason.contains("render"))
        #expect(reason.contains("LibRaw"))

        // And nothing claims the file is open.
        #expect(!state.canAdjustOrientation)
    }

    // MARK: - Both fail

    @Test("Both paths failing is a typed open error naming both refusals")
    func bothPathsFailing() async throws {
        let state = Self.state(ownedSucceeds: false, legacySucceeds: false)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        guard case .failed(let failedURL, let error) = state.status else {
            Issue.record("Expected .failed, got \(state.status)")
            return
        }
        #expect(failedURL == Self.url)
        #expect(error.url == Self.url)

        // The owned pipeline's refusal is the one that matters, and it is the
        // decoder's own error rather than a flattened message.
        #expect(error.owned.stage == .ownedPreparation)
        #expect(
            error.owned.decoding
                == .unsupportedRawStorage(
                    Self.url, reason: "StubDecoder does not implement decodeMosaic"
                )
        )
        // The reference's refusal is kept beside it: two different reasons are
        // themselves the diagnosis.
        #expect(error.legacy.stage == .legacyReference)
        #expect(error.legacy.decoding == .fileNotFound(Self.url))

        #expect(error.errorDescription?.isEmpty == false)
        let reason = try #require(error.failureReason)
        #expect(reason.contains("image pipeline"))
        #expect(reason.contains("LibRaw"))
    }

    // MARK: - Helpers

    private static func decoded(_ state: DocumentState) throws -> DocumentState.Loaded {
        guard case .decoded(let loaded) = state.status else {
            Issue.record("Expected .decoded, got \(state.status)")
            throw CancellationError()
        }
        return loaded
    }

    private static func waitUntilSettled(_ state: DocumentState) async throws {
        for _ in 0..<400 {
            if case .decoding = state.status {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                return
            }
        }
        Issue.record("Decode never settled")
    }
}
