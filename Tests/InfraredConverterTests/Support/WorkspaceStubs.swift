import CoreGraphics
import Foundation
@testable import InfraredConverter

/// A decoder that never touches the filesystem, so the application layer can
/// be tested without a RAW fixture.
struct WorkspaceStubDecoder: RAWDecoder {
    var result: Result<DecodedRAW, RAWDecodingError>
    var mosaic: Result<DecodedRAWMosaic, RAWDecodingError>?

    func readMetadata(at url: URL) throws -> RAWMetadata { try result.get().metadata }

    func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
        try result.get()
    }

    func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
        guard let mosaic else {
            throw RAWDecodingError.unsupportedRawStorage(
                url, reason: "WorkspaceStubDecoder does not implement decodeMosaic"
            )
        }
        return try mosaic.get()
    }
}

/// A decoder that counts what it is asked to do.
///
/// The point is the count. Asserting that an orientation change produces the
/// right picture says nothing about what it cost; asserting that
/// `decodeMosaic` ran exactly once across an open and five rotations says that
/// nothing below the retained preview source ran again — no decode, and
/// therefore no normalisation, no white-balance estimate, no demosaic, no
/// camera conversion and no reduction, because every one of those is reachable
/// only through `WorkspacePreviewPipeline.prepare`, which begins with this
/// call.
final class CountingStubDecoder: RAWDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var mosaicDecodes = 0
    private var processedDecodes = 0

    private let result: Result<DecodedRAW, RAWDecodingError>
    private let mosaicResult: Result<DecodedRAWMosaic, RAWDecodingError>

    init(
        result: Result<DecodedRAW, RAWDecodingError>,
        mosaic: Result<DecodedRAWMosaic, RAWDecodingError>
    ) {
        self.result = result
        self.mosaicResult = mosaic
    }

    /// How many times the application-owned pipeline read the file.
    var mosaicDecodeCount: Int { withLock { mosaicDecodes } }
    /// How many times the LibRaw diagnostic reference read it.
    var processedDecodeCount: Int { withLock { processedDecodes } }

    func readMetadata(at url: URL) throws -> RAWMetadata { try result.get().metadata }

    func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
        withLock { processedDecodes += 1 }
        return try result.get()
    }

    func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
        withLock { mosaicDecodes += 1 }
        return try mosaicResult.get()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum WorkspaceStubs {
    /// A deliberately **non-square** RGGB mosaic whose samples all differ, so
    /// every one of the eight orientations produces a distinguishable result
    /// and a dimension swap cannot hide.
    static func mosaic(
        url: URL,
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0
    ) -> DecodedRAWMosaic {
        var samples = [UInt16]()
        for index in 0..<(width * height) {
            // Wrapped into the 12-bit range the metadata's white level
            // declares, so a mosaic large enough to be worth reducing does not
            // run past what a `UInt16` sample may legitimately hold. The
            // stride is coprime with the modulus, so neighbouring samples
            // still differ and every orientation stays distinguishable.
            samples.append(UInt16((500 + index * 37) % 4096))
        }
        var metadata = RAWTestData.metadata()
        metadata.levels = .init(black: 0, perPlaneBlack: [0, 0, 0, 0], maximum: 4095)
        metadata.geometry.flip = flip
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

    /// A `DocumentState` wired to the stub, with the owned pipeline able to
    /// run end to end.
    ///
    /// The adjustment store is in-memory and fresh for every call, and that is
    /// not incidental. The production store writes a sidecar beside the RAW
    /// file, so a test using it would leave a file next to a real photograph
    /// and — because these suites share stand-in URLs — would hand one test's
    /// saved rotation to the next test's open. A test that wants persistence
    /// asks for it explicitly.
    @MainActor
    static func documentState(
        url: URL,
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0,
        store: any ImageAdjustmentStore = StubImageAdjustmentStore(),
        previewPolicy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy
    ) -> DocumentState {
        DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: url)),
                mosaic: .success(mosaic(url: url, width: width, height: height, flip: flip))
            ),
            store: store,
            previewPolicy: previewPolicy
        )
    }

    /// A `DocumentState` whose decoder counts, so a test can prove what an
    /// adjustment did **not** rerun.
    @MainActor
    static func countingDocumentState(
        url: URL,
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0,
        store: any ImageAdjustmentStore = StubImageAdjustmentStore(),
        previewPolicy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy
    ) -> (DocumentState, CountingStubDecoder) {
        let decoder = CountingStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(mosaic(url: url, width: width, height: height, flip: flip))
        )
        return (
            DocumentState(decoder: decoder, store: store, previewPolicy: previewPolicy),
            decoder
        )
    }

    /// The display-encoded bytes behind a preview's `CGImage`, for
    /// bit-pattern comparison.
    static func pixelBytes(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }

    /// Waits until the workspace has a rendered preview for `adjustment`.
    ///
    /// Polls rather than observes, because the render is detached and the
    /// point of the test is the settled result rather than the transition.
    @MainActor
    static func waitForPreview(
        _ state: DocumentState,
        adjustment: UserOrientationAdjustment,
        timeout: Duration = .seconds(2)
    ) async throws -> WorkspacePreview? {
        let attempts = max(1, Int(timeout / .milliseconds(5)))
        for _ in 0..<attempts {
            if case .decoded(let loaded) = state.status,
               case .rendered(let preview) = loaded.owned,
               preview.userOrientationAdjustment == adjustment {
                return preview
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}
