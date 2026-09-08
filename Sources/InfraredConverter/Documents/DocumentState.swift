import CoreGraphics
import Foundation
import Observation

/// Workspace state for a single RAW file.
///
/// This is the application layer between the UI and the RAW decoder: it owns
/// the decode task and the resulting state, and it is the only place that knows
/// a `RAWDecoder` exists. Views read `status` and never touch a decoder.
///
/// It is not `ImageDocument` yet — there are no adjustments here.
@MainActor
@Observable
final class DocumentState {
    /// What the workspace currently has for the selected file.
    enum Status {
        case empty
        case decoding(URL)
        case decoded(Loaded)
        case failed(URL, RAWDecodingError)
    }

    /// A successfully decoded file plus its display-only preview.
    struct Loaded {
        let decoded: DecodedRAW
        /// `nil` when the decoded buffer could not be wrapped for display.
        let preview: CGImage?

        var url: URL { decoded.url }
        var metadata: RAWMetadata { decoded.metadata }
    }

    private(set) var status: Status = .empty

    private let decoder: RAWDecoder
    private var decodeTask: Task<Void, Never>?

    init(decoder: RAWDecoder = LibRawDecoder()) {
        self.decoder = decoder
    }

    var selectedFileURL: URL? {
        switch status {
        case .empty: return nil
        case .decoding(let url): return url
        case .decoded(let loaded): return loaded.url
        case .failed(let url, _): return url
        }
    }

    /// Selects a file and starts decoding it, replacing any decode in flight.
    func open(_ url: URL) {
        decodeTask?.cancel()
        status = .decoding(url)

        let decoder = self.decoder
        // LibRaw decoding is a long, blocking C++ call. Detaching keeps it off
        // both the main actor and the caller's cooperative context.
        decodeTask = Task.detached(priority: .userInitiated) {
            let outcome = Self.decode(url, using: decoder)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.apply(outcome, for: url)
            }
        }
    }

    private nonisolated static func decode(
        _ url: URL,
        using decoder: RAWDecoder
    ) -> Result<Loaded, RAWDecodingError> {
        do {
            // A reduced-resolution decode is enough for the workspace preview and
            // avoids a full-resolution decode just to show that a file opened.
            // Metadata still describes the full-size image.
            let decoded = try decoder.decode(at: url, options: .init(halfSize: true))
            let preview = PreviewImageRenderer.makeCGImage(from: decoded.image)
            return .success(Loaded(decoded: decoded, preview: preview))
        } catch let error as RAWDecodingError {
            return .failure(error)
        } catch {
            return .failure(.invalidDecodedImage(url, reason: error.localizedDescription))
        }
    }

    private func apply(_ outcome: Result<Loaded, RAWDecodingError>, for url: URL) {
        // Ignore a result that a newer selection has already superseded.
        guard selectedFileURL == url else { return }

        switch outcome {
        case .success(let loaded):
            status = .decoded(loaded)
        case .failure(let error):
            Log.ui.error(
                """
                Failed to open \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            status = .failed(url, error)
        }
    }
}
