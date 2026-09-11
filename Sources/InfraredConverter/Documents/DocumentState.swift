import CoreGraphics
import Foundation
import Observation

/// Workspace state for a single RAW file.
///
/// This is the application layer between the UI and the RAW decoder: it owns
/// the decode task and the resulting state, and it is the only place that knows
/// a `RAWDecoder` exists. Views read `status` and never touch a decoder.
///
/// It is not `ImageDocument` yet, but it is closer: it now owns an
/// `ImageAdjustments` record alongside the decoded state, and the preview is
/// derived from `source + adjustments` rather than from the source alone.
///
/// ## Where the adjustment lives, and for how long
///
/// **In memory, here, for as long as the file is open.** `ImageAdjustments` is
/// `Codable` and round-trips, and that is a different fact from being saved:
/// nothing writes it to disk, there is no sidecar, no document format and no
/// restore on relaunch. Opening the same file again starts from
/// `ImageAdjustments.none`.
///
/// The three layers are deliberately separate, and only the first two exist:
///
/// ```text
/// 1. a serialisable adjustment model     ImageAdjustments — exists, tested
/// 2. in-memory ownership                 here, per open file — exists
/// 3. durable on-disk persistence         does not exist
/// ```
///
/// ## Re-rendering is coalesced, and superseded work is stopped
///
/// Adjustment changes go through one `CoalescingPreviewRenderer`: at most one
/// full-frame render works at a time, a burst collapses to its newest state,
/// and the render being replaced is cancelled inside its pass rather than left
/// to finish work nobody will see.
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
        /// The retained scene-linear state every reprocess starts from, or
        /// `nil` when the owned pipeline could not get that far.
        ///
        /// This is what makes an orientation change non-destructive: it is
        /// the **unoriented** channel-mixed image, so a new adjustment is
        /// always applied to it rather than to whatever is currently on
        /// screen.
        let source: WorkspacePreviewPipeline.Source?
        /// The user's editing decisions. In memory only; see the note on the
        /// type.
        var adjustments: ImageAdjustments
        /// The application-owned pipeline's result, or the reason it failed.
        var owned: OwnedPreview

        var url: URL { decoded.url }
        var metadata: RAWMetadata { decoded.metadata }

        /// Whether the workspace can reprocess this file with a different
        /// adjustment. False when the owned pipeline never produced a
        /// scene-linear state to start from.
        var isAdjustable: Bool { source != nil }
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

    /// The single slot every re-render goes through, rebuilt for each opened
    /// file because it closes over that file's retained scene-linear source.
    /// `nil` when nothing adjustable is open.
    private var renderer: CoalescingPreviewRenderer?

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

    /// The user's orientation correction for the open file, or `.identity`
    /// when nothing is open.
    var orientationAdjustment: UserOrientationAdjustment {
        guard case .decoded(let loaded) = status else { return .identity }
        return loaded.adjustments.orientation
    }

    /// Whether the orientation controls can do anything right now.
    var canAdjustOrientation: Bool {
        guard case .decoded(let loaded) = status else { return false }
        return loaded.isAdjustable
    }

    /// Selects a file and starts decoding it, replacing any decode in flight.
    func open(_ url: URL) {
        decodeTask?.cancel()
        renderer?.cancelAll()
        renderer = nil
        status = .decoding(url)

        let decoder = self.decoder
        // LibRaw decoding is a long, blocking C++ call. Detaching keeps it off
        // both the main actor and the caller's cooperative context.
        decodeTask = Task.detached(priority: .userInitiated) {
            // `nil` means the open was superseded while it was running. There
            // is nothing to install and nothing to report: a cancelled open is
            // not a failed one.
            guard let outcome = Self.decode(url, using: decoder) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.apply(outcome, for: url)
            }
        }
    }

    /// - Returns: the opened file, the reason it could not be opened, or
    ///   `nil` when the open was cancelled before it finished.
    private nonisolated static func decode(
        _ url: URL,
        using decoder: RAWDecoder
    ) -> Result<Loaded, RAWDecodingError>? {
        do {
            // The legacy processed-RGB decode, at half resolution: it is the
            // diagnostic reference and the source of the inspector's decoder
            // facts, and it is no longer what the workspace displays. Metadata
            // still describes the full-size image.
            let decoded = try decoder.decode(at: url, options: .init(halfSize: true))
            let legacyPreview = PreviewImageRenderer.makeCGImage(from: decoded.image)
            let adjustments = ImageAdjustments.none
            let prepared = Result {
                try WorkspacePreviewPipeline().prepare(decoding: url, using: decoder)
            }
            guard let owned = ownedPreview(
                prepared, adjustments: adjustments, url: url, cancellation: .enclosingTask
            ) else { return nil }
            return .success(
                Loaded(
                    decoded: decoded,
                    legacyPreview: legacyPreview,
                    source: try? prepared.get(),
                    adjustments: adjustments,
                    owned: owned
                )
            )
        } catch let error as RAWDecodingError {
            return .failure(error)
        } catch {
            return .failure(.invalidDecodedImage(url, reason: error.localizedDescription))
        }
    }

    /// Orients and encodes a prepared source, and reports rather than hides a
    /// failure.
    ///
    /// Every error type the chain can raise is `LocalizedError`, so the
    /// message a user sees names the stage that actually refused — a
    /// non-finite coordinate, an unusable exposure, an unsupported sensor
    /// layout, an orientation code we do not model — instead of a generic
    /// "preview failed".
    ///
    /// A failure in the expensive half arrives here as a failed `Result` and
    /// is reported with its own message, so "the mosaic would not decode" and
    /// "the orientation would not apply" stay distinguishable.
    /// - Returns: the preview or the reason there is none, or `nil` when the
    ///   render was cancelled. Cancellation is not a failure and must never be
    ///   shown as one.
    private nonisolated static func ownedPreview(
        _ prepared: Result<WorkspacePreviewPipeline.Source, Error>,
        adjustments: ImageAdjustments,
        url: URL,
        cancellation: ProcessingCancellation
    ) -> OwnedPreview? {
        do {
            let source = try prepared.get()
            return .rendered(
                try WorkspacePreviewPipeline().render(
                    source, adjustments: adjustments, cancellation: cancellation
                )
            )
        } catch is CancellationError {
            return nil
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

    // MARK: - Orientation adjustment

    /// Turns the displayed photograph a quarter turn clockwise.
    func rotateOrientationRight() { adjustOrientation { $0.rotatedRight() } }

    /// Turns the displayed photograph a quarter turn counter-clockwise.
    func rotateOrientationLeft() { adjustOrientation { $0.rotatedLeft() } }

    /// Turns the displayed photograph a half turn.
    func rotateOrientationHalfTurn() { adjustOrientation { $0.rotatedHalfTurn() } }

    /// Exchanges left and right in the displayed photograph.
    func flipOrientationHorizontally() { adjustOrientation { $0.flippedHorizontally() } }

    /// Exchanges top and bottom in the displayed photograph.
    func flipOrientationVertically() { adjustOrientation { $0.flippedVertically() } }

    /// Discards the user's correction and returns to the orientation the file
    /// records.
    ///
    /// Not "make upright": a file whose metadata records a rotation gets that
    /// rotation back.
    func resetOrientation() { adjustOrientation { _ in .reset } }

    /// Applies a transformation to the current adjustment and re-renders.
    ///
    /// The new adjustment is the **canonical composition** of the old one and
    /// the operation, so pressing a button repeatedly never accumulates a
    /// history — and the render that follows always starts from the retained,
    /// unoriented channel-mixed image, never from what is on screen.
    private func adjustOrientation(
        _ transform: (UserOrientationAdjustment) -> UserOrientationAdjustment
    ) {
        guard case .decoded(var loaded) = status, loaded.isAdjustable,
              let renderer
        else { return }

        let updated = transform(loaded.adjustments.orientation)
        guard updated != loaded.adjustments.orientation else { return }

        // Record the intent immediately, so the controls reflect what the
        // user pressed even while the render is still running.
        loaded.adjustments.orientation = updated
        status = .decoded(loaded)

        // One slot, newest state wins. A burst of presses produces one
        // cancellation and one render, not a queue.
        renderer.request(loaded.adjustments)
    }

    /// Builds the single render slot for a freshly opened file.
    ///
    /// The closure captures that file's retained, **unoriented** scene-linear
    /// source, so every re-render starts from it rather than from whatever is
    /// on screen. Nothing upstream reruns: no channel mix, no camera
    /// conversion, no demosaic, no white balance, no decode.
    private func makeRenderer(
        for source: WorkspacePreviewPipeline.Source,
        url: URL
    ) -> CoalescingPreviewRenderer {
        CoalescingPreviewRenderer(
            render: { adjustments, cancellation in
                try WorkspacePreviewPipeline().render(
                    source, adjustments: adjustments, cancellation: cancellation
                )
            },
            deliver: { [weak self] outcome, adjustments in
                self?.applyReprocessed(outcome, adjustments: adjustments, for: url)
            }
        )
    }

    /// Installs a re-rendered preview, unless a newer adjustment has already
    /// superseded it.
    ///
    /// The guard compares the adjustment the render was made for with the one
    /// currently requested. `CoalescingPreviewRenderer` already declines to
    /// deliver a cancelled render, so this is the second line of defence, for
    /// the render that finished before it noticed: a late result from a
    /// superseded adjustment would otherwise put the wrong geometry on screen
    /// while the controls showed the right one.
    private func applyReprocessed(
        _ outcome: Result<WorkspacePreview, Error>,
        adjustments: ImageAdjustments,
        for url: URL
    ) {
        guard case .decoded(var loaded) = status,
              loaded.url == url,
              loaded.adjustments == adjustments
        else { return }

        switch outcome {
        case .success(let preview):
            loaded.owned = .rendered(preview)
        case .failure(let error):
            Log.raw.error(
                """
                Owned preview failed for \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            loaded.owned = .unavailable(reason: error.localizedDescription)
        }
        status = .decoded(loaded)
    }

    private func apply(_ outcome: Result<Loaded, RAWDecodingError>, for url: URL) {
        // Ignore a result that a newer selection has already superseded.
        guard selectedFileURL == url else { return }

        switch outcome {
        case .success(let loaded):
            renderer = loaded.source.map { makeRenderer(for: $0, url: loaded.url) }
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
