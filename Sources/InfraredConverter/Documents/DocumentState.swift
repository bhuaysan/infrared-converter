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

    /// A successfully opened file: the application-owned preview the
    /// workspace shows, and the legacy LibRaw decode kept beside it as a
    /// diagnostic reference.
    struct Loaded {
        /// The legacy processed-RGB decode. It supplies the inspector's
        /// decoder facts and a labelled reference thumbnail — **not** the
        /// workspace image.
        let decoded: DecodedRAW
        /// The legacy path's own pixels, display-only. Shown small and
        /// labelled, so a reader can compare the two paths without either
        /// being mistaken for the other. `nil` when that buffer could not be
        /// wrapped for display.
        let legacyPreview: CGImage?
        /// The application-owned pipeline's result, or the reason it failed.
        let owned: OwnedPreview

        var url: URL { decoded.url }
        var metadata: RAWMetadata { decoded.metadata }
    }

    /// The outcome of the application-owned pipeline for one file.
    ///
    /// A failure is reported, never replaced by the LibRaw image. A visually
    /// plausible picture from a different pipeline is the worst possible
    /// response to our own being broken: it would look like success.
    enum OwnedPreview {
        case rendered(WorkspacePreview)
        case unavailable(reason: String)
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
            // The legacy processed-RGB decode, at half resolution: it is the
            // diagnostic reference and the source of the inspector's decoder
            // facts, and it is no longer what the workspace displays. Metadata
            // still describes the full-size image.
            let decoded = try decoder.decode(at: url, options: .init(halfSize: true))
            let legacyPreview = PreviewImageRenderer.makeCGImage(from: decoded.image)
            return .success(
                Loaded(
                    decoded: decoded,
                    legacyPreview: legacyPreview,
                    owned: ownedPreview(url, using: decoder)
                )
            )
        } catch let error as RAWDecodingError {
            return .failure(error)
        } catch {
            return .failure(.invalidDecodedImage(url, reason: error.localizedDescription))
        }
    }

    /// Runs the application-owned pipeline, and reports rather than hides a
    /// failure.
    ///
    /// Every error type the chain can raise is `LocalizedError`, so the
    /// message a user sees names the stage that actually refused — a
    /// non-finite coordinate, an unusable exposure, an unsupported sensor
    /// layout — instead of a generic "preview failed".
    private nonisolated static func ownedPreview(
        _ url: URL,
        using decoder: RAWDecoder
    ) -> OwnedPreview {
        do {
            return .rendered(
                try WorkspacePreviewPipeline().render(decoding: url, using: decoder)
            )
        } catch {
            Log.raw.error(
                """
                Owned preview failed for \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .unavailable(reason: error.localizedDescription)
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
