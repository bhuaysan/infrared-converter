import Testing
import Foundation
@testable import InfraredConverter

@Suite
@MainActor
struct DocumentStateTests {
    /// A decoder that never touches the filesystem, so state transitions can be
    /// tested without a RAW fixture.
    private struct StubDecoder: RAWDecoder {
        let result: Result<DecodedRAW, RAWDecodingError>

        func readMetadata(at url: URL) throws -> RAWMetadata {
            try result.get().metadata
        }

        func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
            try result.get()
        }

        func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
            throw RAWDecodingError.unsupportedRawStorage(url, reason: "StubDecoder does not implement decodeMosaic")
        }
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
        #expect(loaded.preview != nil)
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
