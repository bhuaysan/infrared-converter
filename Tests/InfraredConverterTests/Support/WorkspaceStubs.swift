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
            samples.append(UInt16(500 + index * 37))
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
    @MainActor
    static func documentState(
        url: URL,
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0
    ) -> DocumentState {
        DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: url)),
                mosaic: .success(mosaic(url: url, width: width, height: height, flip: flip))
            )
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
