import CoreGraphics
import Foundation
import Observation

/// Workspace state for a single RAW file.
///
/// This is the application layer between the UI and the RAW decoder: it owns
/// the decode task and the resulting state, and it is the only place that knows
/// a `RAWDecoder` exists. Views read `status` and never touch a decoder.
///
/// It is not `ImageDocument` yet, but it is closer: it owns an
/// `ImageAdjustments` record alongside the decoded state, the preview is
/// derived from `source + adjustments` rather than from the source alone, and
/// that record now outlives the session.
///
/// ## Where the adjustment lives, and for how long
///
/// **In memory here while the file is open, and in a sidecar beside the RAW
/// file between sessions.** All three layers now exist:
///
/// ```text
/// 1. a serialisable adjustment model     ImageAdjustments
/// 2. in-memory ownership                 here, per open file
/// 3. durable on-disk persistence         ImageAdjustmentStore — one sidecar per photograph
/// ```
///
/// The RAW file is not one of them. It is an immutable input: nothing here
/// writes to it, appends to it, re-tags it or replaces it, and the sidecar is
/// the only place a user's decisions are ever recorded. See
/// `docs/decisions/0013-adjustment-sidecar.md`.
///
/// ## Opening reads the saved adjustments before it renders anything
///
/// ```text
/// load sidecar → prepare RAW → initial render WITH the loaded adjustments → .decoded
/// ```
///
/// Not prepare, render the identity, show it, then load. A saved rotation is
/// part of the document's opening state, not a later UI event: rendering the
/// unadjusted image first would put a photograph on screen that the user did
/// not ask for, and pay for a full-frame render to do it.
///
/// A sidecar that exists and cannot be read stops the open instead
/// (`Status.adjustmentsUnreadable`), because the alternative — rendering with
/// no adjustments — looks exactly like success while silently discarding the
/// user's decisions.
///
/// ## Two RAW paths, and only one of them is the photograph
///
/// Opening a file runs both, independently:
///
/// ```text
/// WorkspacePreviewPipeline (decodeMosaic → … → display)   the workspace image
/// RAWDecoder.decode(at:)   (LibRaw processed RGB)         a diagnostic reference
/// ```
///
/// Neither gates the other. The file is open when either produced something,
/// and the reference never substitutes for the image: an owned-pipeline
/// failure is reported as a failure even when the LibRaw decode succeeded,
/// because a plausible picture from a different pipeline would look exactly
/// like success. Only both refusing gives a `DocumentOpenError`.
///
/// ## Re-rendering is coalesced, and superseded work is stopped
///
/// Adjustment changes go through one `CoalescingPreviewRenderer`: at most one
/// full-frame render works at a time, a burst collapses to its newest state,
/// and the render being replaced is cancelled inside its pass rather than left
/// to finish work nobody will see.
///
/// Saving rides on exactly the same guard. A render is persisted only where it
/// is installed — after it has succeeded, and only while the adjustment it was
/// made for is still the one the user wants — so a superseded render can no
/// more write the sidecar than it can reach the screen.
@MainActor
@Observable
final class DocumentState {
    /// What the workspace currently has for the selected file.
    enum Status {
        case empty
        case decoding(URL)
        case decoded(Loaded)
        /// Neither RAW path could produce an image.
        case failed(URL, DocumentOpenError)
        /// The photograph was never decoded, because its saved adjustments
        /// exist and could not be read. A separate case from `failed` because
        /// it is a separate problem with a separate remedy — one small file
        /// the user owns, rather than the RAW file or its support.
        case adjustmentsUnreadable(URL, DocumentAdjustmentError)
    }

    /// Whether the user's current adjustments are safely on disk.
    ///
    /// Diagnostic state, deliberately small. There is no retry engine and no
    /// queue: a failure is reported and the next successful adjustment tries
    /// again, because that is what the user's next action does anyway.
    enum AdjustmentPersistence {
        /// Nothing has been adjusted since the file was opened, so there has
        /// been nothing to write. The sidecar, if any, still holds what was
        /// loaded from it.
        case unchanged
        /// The adjustment currently on screen is the one on disk.
        case saved
        /// The image is correct and the sidecar is not. Kept as a value so a
        /// reader can be told which file and why — and so the preview is not
        /// rolled back to pretend the edit never happened.
        case failed(ImageAdjustmentPersistenceError)
    }

    /// A successfully opened file: the application-owned preview the
    /// workspace shows, and the legacy LibRaw decode kept beside it as a
    /// diagnostic reference **when there is one**.
    ///
    /// The two paths are independent. A file is open when either one of them
    /// produced something, and neither ever substitutes for the other.
    struct Loaded {
        let url: URL

        /// The decoder's facts about the file, read through whichever path
        /// opened it. Both paths read the same file with the same decoder, and
        /// the owned pipeline's copy is preferred because that is the image
        /// the workspace shows.
        let metadata: RAWMetadata

        /// The legacy processed-RGB decode, or the reason there is none. It
        /// supplies the inspector's decoder facts and a labelled reference
        /// thumbnail — **not** the workspace image.
        let legacy: LegacyReference

        /// The retained scene-linear state every reprocess starts from, or
        /// `nil` when the owned pipeline could not get that far.
        ///
        /// This is what makes an orientation change non-destructive: it is
        /// the **unoriented** channel-mixed image, so a new adjustment is
        /// always applied to it rather than to whatever is currently on
        /// screen.
        ///
        /// It is retained even when the initial render refused it, because a
        /// prepared source is genuinely useful for diagnosis — but its
        /// presence is **not** what makes the file adjustable. See
        /// `isAdjustable`.
        let source: WorkspacePreviewPipeline.Source?

        /// Whether the workspace can reprocess this file with a different
        /// adjustment.
        ///
        /// Established once, when the file was opened, and never revised.
        ///
        /// The rule is: **the owned pipeline rendered this source at least
        /// once.** A retained source alone says only that the expensive
        /// preparation exists; it says nothing about whether anything can be
        /// shown. A file whose metadata names an orientation this application
        /// does not model prepares perfectly well and then refuses at the
        /// geometry stage — for every adjustment equally, because the
        /// effective orientation cannot be derived at all — so offering
        /// rotate and flip there would offer a button that cannot work.
        ///
        /// It is a stored fact rather than a reading of `owned` for a reason:
        /// a render that fails *after* the file is open must not disable the
        /// controls, or the user could not undo the adjustment that caused it.
        let isAdjustable: Bool

        /// The user's editing decisions: what the sidecar held when the file
        /// was opened, plus whatever has been asked for since.
        var adjustments: ImageAdjustments

        /// The application-owned pipeline's result, or the reason it failed.
        var owned: OwnedPreview

        /// Whether the current adjustments have reached the sidecar.
        ///
        /// Independent of `owned` on purpose: a render that succeeded and a
        /// save that failed are two different facts, and the image is not
        /// withdrawn because the file system refused.
        var persistence: AdjustmentPersistence = .unchanged

        /// The retained source, but only when re-rendering from it can
        /// actually work. The one thing a render slot may be built from.
        var adjustableSource: WorkspacePreviewPipeline.Source? {
            isAdjustable ? source : nil
        }
    }

    /// The LibRaw processed-RGB decode kept beside the workspace image.
    ///
    /// Optional by construction, because that is the architectural claim: a
    /// diagnostic reference that cannot read the file is a missing reference,
    /// not a failed open. Before this was modelled, the legacy decode ran
    /// first and threw, and the owned pipeline — the actual workspace image —
    /// was never asked.
    enum LegacyReference {
        case decoded(DecodedRAW, preview: CGImage?)
        /// No reference is available, and why. The workspace still works.
        case unavailable(RAWPathFailure)

        /// The legacy decode's own facts, for the inspector's diagnostic
        /// section only.
        var decoded: DecodedRAW? {
            if case .decoded(let decoded, _) = self { return decoded }
            return nil
        }

        /// The legacy path's own pixels, display-only. Shown small and
        /// labelled, so a reader can compare the two paths without either
        /// being mistaken for the other. `nil` when there is no decode, or
        /// when its buffer could not be wrapped for display.
        var preview: CGImage? {
            if case .decoded(_, let preview) = self { return preview }
            return nil
        }

        /// Why there is no reference, or `nil` when there is one.
        var failure: RAWPathFailure? {
            if case .unavailable(let failure) = self { return failure }
            return nil
        }
    }

    /// The outcome of the application-owned pipeline for one file.
    ///
    /// A failure is reported, never replaced by the LibRaw image. A visually
    /// plausible picture from a different pipeline is the worst possible
    /// response to our own being broken: it would look like success.
    enum OwnedPreview {
        case rendered(WorkspacePreview)
        /// The stage that refused, kept as a value. The UI shows its message;
        /// the application layer can still ask what kind of refusal it was.
        case unavailable(RAWPathFailure)
    }

    /// What the application-owned pipeline achieved for one file, as one
    /// value.
    ///
    /// The distinction the open boundary turns on is between *prepared* and
    /// *rendered*. Preparing produces the expensive scene-linear state and
    /// demonstrates nothing about whether an image can be shown; only a
    /// completed render does. Modelling the two halves as one outcome is what
    /// stops "prepare succeeded" from being mistaken for "the file opened".
    private enum OwnedOutcome {
        /// Prepared and rendered. This is the only success.
        case rendered(WorkspacePreviewPipeline.Source, WorkspacePreview)
        /// Prepared, then refused by the orientation or display stage. The
        /// source is kept for diagnosis; nothing can be re-rendered from it.
        case unrenderable(WorkspacePreviewPipeline.Source, RAWPathFailure)
        /// Never reached a scene-linear state at all.
        case unprepared(RAWPathFailure)
    }

    /// Why an open ended without a document. Two unrelated problems, kept
    /// apart all the way to `Status`.
    private enum OpenFailure: Error {
        /// Neither RAW path produced an image.
        case raw(DocumentOpenError)
        /// The saved adjustments could not be read, so nothing was decoded.
        case adjustments(DocumentAdjustmentError)
    }

    /// Orients a prepared source and encodes it for display.
    ///
    /// Injected so a test can count the renders an open performs and can make
    /// one refuse; production passes `pipelineRender` and nothing else ever
    /// does.
    typealias PreviewRender = @Sendable (
        WorkspacePreviewPipeline.Source, ImageAdjustments, ProcessingCancellation
    ) throws -> WorkspacePreview

    /// The real thing: the second half of `WorkspacePreviewPipeline`.
    nonisolated static let pipelineRender: PreviewRender = { source, adjustments, cancellation in
        try WorkspacePreviewPipeline().render(
            source, adjustments: adjustments, cancellation: cancellation
        )
    }

    private(set) var status: Status = .empty

    private let decoder: RAWDecoder
    private let store: any ImageAdjustmentStore
    private let render: PreviewRender
    private var decodeTask: Task<Void, Never>?

    /// The single slot every re-render goes through, rebuilt for each opened
    /// file because it closes over that file's retained scene-linear source.
    /// `nil` when nothing adjustable is open.
    private var renderer: CoalescingPreviewRenderer?

    init(
        decoder: RAWDecoder = LibRawDecoder(),
        store: any ImageAdjustmentStore = JSONSidecarImageAdjustmentStore(),
        render: @escaping PreviewRender = DocumentState.pipelineRender
    ) {
        self.decoder = decoder
        self.store = store
        self.render = render
    }

    var selectedFileURL: URL? {
        switch status {
        case .empty: return nil
        case .decoding(let url): return url
        case .decoded(let loaded): return loaded.url
        case .failed(let url, _): return url
        case .adjustmentsUnreadable(let url, _): return url
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

    /// Whether what is on screen has been written to the sidecar.
    var adjustmentPersistence: AdjustmentPersistence {
        guard case .decoded(let loaded) = status else { return .unchanged }
        return loaded.persistence
    }

    /// Why the last save failed, or `nil` when none did.
    ///
    /// The image is correct either way; this says only whether it will still
    /// be there next time.
    var adjustmentSaveFailure: ImageAdjustmentPersistenceError? {
        guard case .failed(let error) = adjustmentPersistence else { return nil }
        return error
    }

    /// Selects a file and starts decoding it, replacing any decode in flight.
    func open(_ url: URL) {
        decodeTask?.cancel()
        renderer?.cancelAll()
        renderer = nil
        status = .decoding(url)

        let decoder = self.decoder
        let store = self.store
        let render = self.render
        // LibRaw decoding is a long, blocking C++ call. Detaching keeps it off
        // both the main actor and the caller's cooperative context.
        decodeTask = Task.detached(priority: .userInitiated) {
            // `nil` means the open was superseded while it was running. There
            // is nothing to install and nothing to report: a cancelled open is
            // not a failed one.
            guard let outcome = Self.decode(
                url, using: decoder, store: store, render: render
            ) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.apply(outcome, for: url)
            }
        }
    }

    /// Reads the saved adjustments, then runs both RAW paths independently,
    /// and decides what the six possible pairings mean.
    ///
    /// The saved adjustments come **first**, before anything is decoded. They
    /// are part of the document's opening state, so the initial render is made
    /// with them: there is no window in which the unadjusted image exists, and
    /// no second full-frame render to replace it. A sidecar that cannot be
    /// read ends the open here, before the expensive work, rather than
    /// producing a photograph nobody asked for.
    ///
    /// The order of the two RAW paths is deliberate and so is the absence of a
    /// `try` around the pair. The application-owned pipeline runs first
    /// because it is the workspace image; the legacy processed-RGB decode runs
    /// beside it, never in front of it. Each is allowed to fail on its own.
    ///
    /// The open succeeds when **an image exists**. A prepared scene-linear
    /// state is not an image: if the initial render refused it and the
    /// diagnostic decode refused the file too, there is nothing to show and
    /// the open failed, however much expensive work succeeded on the way.
    ///
    /// - Returns: the opened file, the reason it could not be opened, or
    ///   `nil` when the open was cancelled before it finished.
    private nonisolated static func decode(
        _ url: URL,
        using decoder: RAWDecoder,
        store: any ImageAdjustmentStore,
        render: PreviewRender
    ) -> Result<Loaded, OpenFailure>? {
        let adjustments: ImageAdjustments
        do {
            // `nil` is the ordinary case: no sidecar, so no saved decisions,
            // so the identity record. It is the only thing that becomes
            // `.none` — a record that exists and cannot be read never does.
            adjustments = try store.load(for: url) ?? .none
        } catch {
            log(error, path: "Saved adjustments", url: url)
            return .failure(.adjustments(DocumentAdjustmentError(url: url, failure: error)))
        }

        guard let owned = ownedOutcome(
            for: url,
            using: decoder,
            adjustments: adjustments,
            render: render,
            cancellation: .enclosingTask
        ) else { return nil }
        let legacy = legacyReference(for: url, using: decoder)

        // The six cases, written out as the six cases. Metadata comes from
        // whichever path read it — both paths read the same file with the same
        // decoder — and the owned one is preferred because it belongs to the
        // image the workspace shows.
        switch (owned, legacy) {
        case (.rendered(let source, let preview), _):
            return .success(
                Loaded(
                    url: url,
                    metadata: source.metadata,
                    legacy: legacy,
                    source: source,
                    isAdjustable: true,
                    adjustments: adjustments,
                    owned: .rendered(preview)
                )
            )

        case (.unrenderable(let source, let failure), .decoded):
            // The expensive half worked and the cheap half refused. The source
            // is kept — it is the most informative thing about this file — but
            // nothing can be rendered from it, so nothing offers to.
            return .success(
                Loaded(
                    url: url,
                    metadata: source.metadata,
                    legacy: legacy,
                    source: source,
                    isAdjustable: false,
                    adjustments: adjustments,
                    owned: .unavailable(failure)
                )
            )

        case (.unprepared(let failure), .decoded(let decoded, _)):
            return .success(
                Loaded(
                    url: url,
                    metadata: decoded.metadata,
                    legacy: legacy,
                    source: nil,
                    isAdjustable: false,
                    adjustments: adjustments,
                    owned: .unavailable(failure)
                )
            )

        case (.unrenderable(_, let ownedFailure), .unavailable(let legacyFailure)),
             (.unprepared(let ownedFailure), .unavailable(let legacyFailure)):
            return .failure(
                .raw(DocumentOpenError(url: url, owned: ownedFailure, legacy: legacyFailure))
            )
        }
    }

    /// Prepares and renders the application-owned pipeline, keeping the two
    /// halves distinguishable in the result.
    ///
    /// A failure is reported, never replaced by the LibRaw image. Every error
    /// the chain can raise is `LocalizedError`, so the message a user sees
    /// names the stage that actually refused — an unsupported sensor layout,
    /// an unusable exposure, an orientation code we do not model — instead of
    /// a generic "preview failed". The error value itself is kept too, which
    /// is what lets the caller tell a preparation refusal from a render one.
    ///
    /// Exactly one render happens here, with the adjustments the caller
    /// loaded. There is no unadjusted first pass.
    ///
    /// - Returns: the outcome, or `nil` when the work was cancelled.
    ///   Cancellation is not a failure and must never be shown as one.
    private nonisolated static func ownedOutcome(
        for url: URL,
        using decoder: RAWDecoder,
        adjustments: ImageAdjustments,
        render: PreviewRender,
        cancellation: ProcessingCancellation
    ) -> OwnedOutcome? {
        let pipeline = WorkspacePreviewPipeline()

        let source: WorkspacePreviewPipeline.Source
        do {
            source = try pipeline.prepare(decoding: url, using: decoder)
        } catch is CancellationError {
            // `prepare` polls nothing today, so this is defensive rather than
            // reachable; it is here so that adding a poll cannot turn a
            // cancelled open into a reported failure.
            return nil
        } catch {
            log(error, path: "Owned preparation", url: url)
            return .unprepared(RAWPathFailure(stage: .ownedPreparation, error))
        }

        do {
            let preview = try render(source, adjustments, cancellation)
            return .rendered(source, preview)
        } catch is CancellationError {
            return nil
        } catch {
            log(error, path: "Owned render", url: url)
            return .unrenderable(source, RAWPathFailure(stage: .ownedRender, error))
        }
    }

    /// The legacy processed-RGB decode, at half resolution, and never a reason
    /// to abandon the file.
    ///
    /// It is the diagnostic reference and the source of the inspector's
    /// LibRaw facts. Its metadata still describes the full-size image.
    private nonisolated static func legacyReference(
        for url: URL,
        using decoder: RAWDecoder
    ) -> LegacyReference {
        do {
            let decoded = try decoder.decode(at: url, options: .init(halfSize: true))
            return .decoded(decoded, preview: PreviewImageRenderer.makeCGImage(from: decoded.image))
        } catch {
            log(error, path: "LibRaw reference decode", url: url)
            return .unavailable(RAWPathFailure(stage: .legacyReference, error))
        }
    }

    /// Logs one path's refusal.
    ///
    /// `path` names the thing that refused, in full. It used to be a stage
    /// name with "Owned" prefixed to it here, which labelled the LibRaw
    /// reference decode — the one path that is emphatically not ours — as
    /// "Owned LibRaw reference decode failed".
    private nonisolated static func log(_ error: Error, path: String, url: URL) {
        Log.raw.error(
            """
            \(path, privacy: .public) failed for \
            \(url.lastPathComponent, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """
        )
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
    /// rotation back. The reset is itself a decision, and it is saved like any
    /// other once it has rendered.
    func resetOrientation() { adjustOrientation { _ in .reset } }

    /// Applies a transformation to the current adjustment and re-renders.
    ///
    /// The new adjustment is the **canonical composition** of the old one and
    /// the operation, so pressing a button repeatedly never accumulates a
    /// history — and the render that follows always starts from the retained,
    /// unoriented channel-mixed image, never from what is on screen.
    ///
    /// Nothing is saved here. A state that has not been rendered is not known
    /// to be renderable, and writing it would let a broken state be restored
    /// automatically on the next launch.
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
        let render = self.render
        return CoalescingPreviewRenderer(
            render: { adjustments, cancellation in
                try render(source, adjustments, cancellation)
            },
            deliver: { [weak self] outcome, adjustments in
                self?.applyReprocessed(outcome, adjustments: adjustments, for: url)
            }
        )
    }

    /// Installs a re-rendered preview, unless a newer adjustment has already
    /// superseded it — and saves the adjustment that produced it.
    ///
    /// The guard compares the adjustment the render was made for with the one
    /// currently requested. `CoalescingPreviewRenderer` already declines to
    /// deliver a cancelled render, so this is the second line of defence, for
    /// the render that finished before it noticed: a late result from a
    /// superseded adjustment would otherwise put the wrong geometry on screen
    /// while the controls showed the right one.
    ///
    /// Persistence sits **inside** that guard, and inside the success branch,
    /// which is what makes the two rules true at once:
    ///
    /// ```text
    /// a superseded render        neither installs nor saves
    /// a failed render            neither installs nor saves; the sidecar keeps
    ///                            the last state that did render
    /// ```
    ///
    /// A save that fails does not withdraw the image. The render succeeded;
    /// the file system is a separate question, and rolling the preview back
    /// would answer it by lying about the first.
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
            loaded.persistence = persist(adjustments, for: url)
        case .failure(let error):
            Self.log(error, path: "Owned re-render", url: url)
            loaded.owned = .unavailable(RAWPathFailure(stage: .ownedRender, error))
            // `persistence` is deliberately untouched: the last successfully
            // saved state is still what is on disk, and it is still correct.
        }
        status = .decoded(loaded)
    }

    /// Writes one rendered adjustment to its sidecar.
    ///
    /// Synchronous, on the main actor, and small on purpose: one atomic write
    /// of a few hundred bytes, ordered by construction because there is only
    /// one place that writes and it cannot interleave with itself. Moving it
    /// off the main actor would buy nothing measurable and would need its own
    /// ordering guard to stop an older save landing after a newer one.
    private func persist(
        _ adjustments: ImageAdjustments, for url: URL
    ) -> AdjustmentPersistence {
        do {
            try store.save(adjustments, for: url)
            return .saved
        } catch {
            Self.log(error, path: "Saving adjustments", url: url)
            return .failed(error)
        }
    }

    private func apply(_ outcome: Result<Loaded, OpenFailure>, for url: URL) {
        // Ignore a result that a newer selection has already superseded.
        guard selectedFileURL == url else { return }

        switch outcome {
        case .success(let loaded):
            // Only an adjustable file gets a render slot. A prepared source
            // nothing can be rendered from gets none, so there is no path by
            // which a control could request work that is known to fail.
            renderer = loaded.adjustableSource.map { makeRenderer(for: $0, url: loaded.url) }
            status = .decoded(loaded)

        case .failure(.raw(let error)):
            Log.ui.error(
                """
                Failed to open \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            status = .failed(url, error)

        case .failure(.adjustments(let error)):
            Log.ui.error(
                """
                Did not open \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            status = .adjustmentsUnreadable(url, error)
        }
    }
}
