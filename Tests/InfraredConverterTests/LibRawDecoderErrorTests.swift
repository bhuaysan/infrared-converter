import Testing
import Foundation
@testable import InfraredConverter

/// Decoder behaviour that needs no RAW fixture.
@Suite("LibRawDecoder errors")
struct LibRawDecoderErrorTests {
    private let decoder = LibRawDecoder()

    @Test("The vendored LibRaw reports its version")
    func reportsVersion() {
        #expect(LibRawDecoder.libRawVersion.hasPrefix("0.22"))
    }

    @Test("A nonexistent file fails before the decoder is involved")
    func nonexistentFile() {
        let url = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).orf")

        #expect(throws: RAWDecodingError.fileNotFound(url)) {
            try decoder.decode(at: url)
        }
        #expect(throws: RAWDecodingError.fileNotFound(url)) {
            _ = try decoder.readMetadata(at: url)
        }
    }

    @Test("A non-file URL is rejected")
    func nonFileURL() throws {
        let url = try #require(URL(string: "https://example.com/image.orf"))

        #expect(throws: RAWDecodingError.fileNotReadable(url)) {
            try decoder.decode(at: url)
        }
    }

    @Test("A file that is not RAW is rejected without leaking decoder codes",
          arguments: [Data("this is plainly not a RAW file".utf8),
                      Data((0..<65536).map { UInt8($0 % 251) })])
    func nonRAWFile(contents: Data) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-raw-\(UUID().uuidString).orf")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try decoder.decode(at: url)
            Issue.record("Expected the decoder to reject a non-RAW file")
        } catch let error as RAWDecodingError {
            // Which of these LibRaw reports depends on how far it gets before
            // giving up; both must reach the caller as a described failure.
            switch error {
            case .unsupportedFormat, .openFailed:
                break
            default:
                Issue.record("Expected .unsupportedFormat or .openFailed, got \(error)")
                return
            }
            // The underlying diagnostic is preserved for logging, and the
            // user-facing message never exposes an integer code.
            let diagnostic = try #require(error.diagnostic)
            #expect(diagnostic.message.isEmpty == false)
            #expect(diagnostic.code != 0)

            // Every user-facing surface must be free of the integer code...
            let description = try #require(error.errorDescription)
            let codeText = "\(diagnostic.code)"
            #expect(description.contains(codeText) == false)
            let reason = error.failureReason
            #expect((reason?.contains(codeText) ?? false) == false)
            #expect(diagnostic.userFacingSummary.contains(codeText) == false)
            #expect(diagnostic.description.contains(codeText) == false)
            #expect("\(diagnostic)".contains(codeText) == false)

            // ...while the logging surface still carries both the code and
            // the message, so debugging is not degraded.
            #expect(diagnostic.logDescription.contains(codeText))
            #expect(diagnostic.logDescription.contains(diagnostic.message))
        }
    }

    @Test("An empty file is rejected")
    func emptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).orf")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: RAWDecodingError.self) {
            try decoder.decode(at: url)
        }
    }

    @Test("Every error has a user-facing description")
    func errorDescriptions() {
        let url = URL(fileURLWithPath: "/tmp/example.orf")
        let diagnostic = RAWDecodingError.DecoderDiagnostic(code: -100002, message: "Unsupported")
        let errors: [RAWDecodingError] = [
            .fileNotFound(url),
            .fileNotReadable(url),
            .unsupportedFormat(url, diagnostic),
            .openFailed(url, diagnostic),
            .unpackFailed(url, diagnostic),
            .processingFailed(url, diagnostic),
            .imageExtractionFailed(url, diagnostic),
            .invalidDecodedImage(url, reason: "geometry"),
            .outOfMemory(url),
            .decoderUnavailable
        ]

        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            // No user-facing surface may contain the LibRaw integer code,
            // including the negative sign LibRaw uses for its error codes.
            #expect((error.errorDescription?.contains("-100002") ?? false) == false)
            #expect((error.failureReason?.contains("-100002") ?? false) == false)
        }
    }

    @Test("DecoderDiagnostic separates user-facing text from the loggable form")
    func diagnosticSurfaceSplit() {
        let diagnostic = RAWDecodingError.DecoderDiagnostic(code: -100002, message: "Unsupported file")

        // User-facing: message only, never the code.
        #expect(diagnostic.userFacingSummary == "Unsupported file")
        #expect(diagnostic.description == "Unsupported file")
        #expect("\(diagnostic)" == "Unsupported file")

        // Loggable: both the message and the code, for debugging.
        #expect(diagnostic.logDescription.contains("Unsupported file"))
        #expect(diagnostic.logDescription.contains("-100002"))
        #expect(diagnostic.code == -100002)
        #expect(diagnostic.message == "Unsupported file")
    }
}

@Suite("Preview rendering")
struct PreviewImageRendererTests {
    @Test("A 16-bit RGB buffer becomes a CGImage")
    func makesImage() throws {
        let image = RAWTestData.image(width: 8, height: 5)
        let cgImage = try #require(PreviewImageRenderer.makeCGImage(from: image))

        #expect(cgImage.width == 8)
        #expect(cgImage.height == 5)
        #expect(cgImage.bitsPerComponent == 16)
    }

    @Test("An inconsistent buffer produces no image")
    func rejectsInconsistentBuffer() {
        let good = RAWTestData.image()
        let bad = RAWImage(
            width: good.width,
            height: good.height,
            channelCount: good.channelCount,
            bitsPerChannel: good.bitsPerChannel,
            bytesPerRow: good.bytesPerRow,
            samples: Data(),
            encoding: good.encoding,
            colorSpace: good.colorSpace
        )

        #expect(PreviewImageRenderer.makeCGImage(from: bad) == nil)
    }
}
