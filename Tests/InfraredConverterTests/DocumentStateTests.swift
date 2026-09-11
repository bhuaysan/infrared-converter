import Testing
import Foundation
@testable import InfraredConverter

/// The workspace's two RAW paths and the four ways they can end.
///
/// ```text
/// owned ok    / legacy ok      → workspace image + diagnostic reference
/// owned ok    / legacy fails   → workspace image, reference reported missing
/// owned fails / legacy ok      → the owned failure, reported; never a fallback
/// owned fails / legacy fails   → a typed open error naming both refusals
/// ```
///
/// The second row is the one this suite exists for. The legacy
/// processed-RGB decode used to run first and throw, which closed the file
/// before the application-owned pipeline — the actual workspace image — was
/// ever asked.
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
            )
        )
    }

    // MARK: - Selection

    @Test
    func startsWithNoSelection() {
        let state = DocumentState(decoder: StubDecoder(result: .failure(.decoderUnavailable)))
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

        // The file is fully usable: the correction controls work.
        #expect(loaded.isAdjustable)
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
        guard case .unavailable(let reason) = loaded.owned else {
            Issue.record("Expected the owned preview to be unavailable")
            return
        }
        #expect(!reason.isEmpty)

        // The legacy decode succeeded, and is deliberately not standing in for
        // the owned result.
        #expect(loaded.legacy.decoded != nil)
        #expect(loaded.legacy.preview != nil)

        // Nothing to reprocess, and nothing pretending there is.
        #expect(loaded.source == nil)
        #expect(!loaded.isAdjustable)
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
        #expect(
            error.owned.decoding
                == .unsupportedRawStorage(
                    Self.url, reason: "StubDecoder does not implement decodeMosaic"
                )
        )
        // The reference's refusal is kept beside it: two different reasons are
        // themselves the diagnosis.
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
