import Testing
import Foundation
@testable import InfraredConverter

@Suite
@MainActor
struct DocumentStateTests {
    /// A decoder that never touches the filesystem, so state transitions can be
    /// tested without a RAW fixture.
    ///
    /// `decodeMosaic` fails by default, which exercises the case that matters
    /// most here: the application-owned preview failing must be **reported**,
    /// not quietly replaced by the LibRaw image that did decode.
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

    /// A small RGGB mosaic the whole owned chain can actually run over.
    private static func stubMosaic(url: URL) -> DecodedRAWMosaic {
        let width = 8
        let height = 8
        var samples = [UInt16]()
        for index in 0..<(width * height) {
            samples.append(UInt16(500 + index * 37))
        }
        var metadata = RAWTestData.metadata()
        metadata.levels = .init(black: 0, perPlaneBlack: [0, 0, 0, 0], maximum: 4095)
        return DecodedRAWMosaic(
            url: url,
            metadata: metadata,
            mosaic: RAWMosaic(
                width: width,
                height: height,
                bytesPerRow: width * 2,
                samples: samples.withUnsafeBufferPointer { Data(buffer: $0) },
                sampleFormat: .uint16,
                sourceRawBitDepth: 12,
                sensorColorLayout: RAWTestData.bayerLayout()
            ),
            processing: RAWMosaicProcessing(
                decoderIdentifier: "Stub",
                sourceStorage: .singleChannel,
                sourceRowPitch: width,
                destinationRowStride: width
            )
        )
    }

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
        let url = URL(fileURLWithPath: "/tmp/example.orf")
        let state = DocumentState(decoder: StubDecoder(result: .failure(.fileNotFound(url))))

        state.open(url)

        #expect(state.selectedFileURL == url)
        if case .decoding(let decoding) = state.status {
            #expect(decoding == url)
        } else {
            Issue.record("Expected .decoding, got \(state.status)")
        }
    }

    @Test
    func aFailedDecodeIsSurfaced() async throws {
        let url = URL(fileURLWithPath: "/tmp/example.orf")
        let state = DocumentState(decoder: StubDecoder(result: .failure(.fileNotFound(url))))

        state.open(url)
        try await Self.waitUntilSettled(state)

        guard case .failed(let failedURL, let error) = state.status else {
            Issue.record("Expected .failed, got \(state.status)")
            return
        }
        #expect(failedURL == url)
        #expect(error == .fileNotFound(url))
    }

    @Test
    func aSuccessfulDecodeIsSurfaced() async throws {
        let url = URL(fileURLWithPath: "/tmp/example.orf")
        let decoded = RAWTestData.decodedRAW(url: url)
        let state = DocumentState(decoder: StubDecoder(result: .success(decoded)))

        state.open(url)
        try await Self.waitUntilSettled(state)

        guard case .decoded(let loaded) = state.status else {
            Issue.record("Expected .decoded, got \(state.status)")
            return
        }
        #expect(loaded.url == url)
        #expect(loaded.metadata.identity.model == "E-PL3")
        // The legacy decode is still available as a diagnostic reference.
        #expect(loaded.legacyPreview != nil)
    }

    /// The requirement this test exists for: when the application-owned
    /// pipeline fails, the workspace says so. It does not fall back to the
    /// LibRaw image that decoded perfectly well, because a plausible picture
    /// from a different pipeline would look exactly like success.
    @Test
    func aFailedOwnedPreviewIsReportedRatherThanReplaced() async throws {
        let url = URL(fileURLWithPath: "/tmp/example.orf")
        let decoded = RAWTestData.decodedRAW(url: url)
        // `mosaic` is nil, so `decodeMosaic` throws.
        let state = DocumentState(decoder: StubDecoder(result: .success(decoded)))

        state.open(url)
        try await Self.waitUntilSettled(state)

        guard case .decoded(let loaded) = state.status else {
            Issue.record("Expected .decoded, got \(state.status)")
            return
        }
        guard case .unavailable(let reason) = loaded.owned else {
            Issue.record("Expected the owned preview to be unavailable")
            return
        }
        #expect(!reason.isEmpty)
        // The legacy decode succeeded, and is deliberately not standing in for
        // the owned result.
        #expect(loaded.legacyPreview != nil)
    }

    @Test
    func aSuccessfulOwnedPreviewBecomesTheWorkspaceImage() async throws {
        let url = URL(fileURLWithPath: "/tmp/example.orf")
        let state = DocumentState(
            decoder: StubDecoder(
                result: .success(RAWTestData.decodedRAW(url: url)),
                mosaic: .success(Self.stubMosaic(url: url))
            )
        )

        state.open(url)
        try await Self.waitUntilSettled(state)

        guard case .decoded(let loaded) = state.status else {
            Issue.record("Expected .decoded, got \(state.status)")
            return
        }
        guard case .rendered(let preview) = loaded.owned else {
            Issue.record("Expected the owned preview to be rendered")
            return
        }

        // The pixels are the owned pipeline's, at the mosaic's own geometry.
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
        #expect(!preview.processing.orientationApplied)
    }

    private static func waitUntilSettled(_ state: DocumentState) async throws {
        for _ in 0..<200 {
            if case .decoding = state.status {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                return
            }
        }
        Issue.record("Decode never settled")
    }
}
