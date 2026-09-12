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
///
/// ## Two adjustments, one state
///
/// ```text
/// orientation    the eight discrete arrangements, composed onto the file's own
/// channelMix     the creative infrared remix: identity, red/blue swap, matrix
/// ```
///
/// They are fields of one `ImageAdjustments` record, and every render request
/// is that whole record. Nothing here renders "the new mix" or "the new
/// rotation": a burst of changes to either control collapses to one newest
/// complete state, and the sidecar receives that state or nothing. See
/// `docs/decisions/0016-interactive-channel-mixer.md`.
///
/// ## A decision is tracked from the press to the disk
///
/// ```text
/// user changes either     adjustments updated, persistence = .pending
/// render succeeds         preview installed, sidecar written, = .saved
/// render refuses          nothing written,                    = .renderRefused
/// write refuses           preview kept,                       = .saveFailed
/// ```
///
/// `.saved` is a claim about the adjustment currently on screen, never about
/// the last one that happened to be written. It stops being true the instant a
/// newer state is asked for.
///
/// ## Leaving a file does not throw a decision away
///
/// A render still running when the user opens the next file is not cancelled.
/// What it persists is the complete state it was asked for — both adjustments,
/// as one record.
/// It is handed over: the document keeps its render slot, loses its screen,
/// and may do exactly one thing more — write its own sidecar once its own
/// render succeeds. Everything a decision could not survive is recorded in
/// `unsavedAdjustments` rather than dropped.
///
/// Opening a **different** file therefore costs nothing. Opening the **same**
/// file waits, and only that case does:
///
/// ```text
/// A pending → open B      B opens at once; A settles behind it
/// A pending → reopen A    the reopen waits for A to settle, then reads its sidecar
/// ```
///
/// Two generations of one RAW file share one sidecar, so a reopen that read it
/// while an older generation still had a write to make would read a record
/// about to change — and that older write could then land on top of a newer
/// one. Two different files share nothing and race over nothing. See
/// `docs/decisions/0014-adjustment-lifecycle.md`.
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

    /// Where the **currently requested** adjustment stands with respect to the
    /// sidecar.
    ///
    /// One closed enum rather than a handful of booleans, because the states
    /// are mutually exclusive and a combination like `isSaved && isDirty` has
    /// no meaning that anyone should have to work out.
    ///
    /// The subject is always the adjustment the user has asked for **now**, not
    /// the last one that happened to be written. That distinction is the whole
    /// point of the type: `.saved` is a claim about the state on screen, so it
    /// must stop being true the moment a newer state is requested, and may not
    /// become true again until exactly that state is durable.
    ///
    /// ```text
    /// unchanged      nothing has been decided since the file opened
    /// pending        decided, not durable yet: its render has not delivered
    /// saved          decided and durable
    /// renderRefused  its render refused, so it was never eligible to be saved
    /// saveFailed     it rendered, and the write refused
    /// ```
    ///
    /// The last two both mean "not durable", and they are kept apart because
    /// the reasons differ and so does what a reader can do about them. In both,
    /// the sidecar still holds the last state that actually rendered and saved.
    ///
    /// Diagnostic state, deliberately small. There is no retry engine and no
    /// queue: a failure is reported and the next successful adjustment tries
    /// again, because that is what the user's next action does anyway.
    enum AdjustmentPersistence {
        /// Nothing has been adjusted since the file was opened, so there has
        /// been nothing to write. What is on screen is what the file opened
        /// with — the sidecar's record, or no record at all.
        case unchanged
        /// The current adjustment has been asked for and is not durable yet.
        /// Its render is running, or its result has not been delivered.
        case pending
        /// The current adjustment is the one in the sidecar.
        case saved
        /// The current adjustment's render refused it, so it never became
        /// eligible to be written. Persisting an unrenderable state would
        /// restore a broken workspace on the next launch.
        case renderRefused
        /// The current adjustment rendered and could not be written. The image
        /// is correct and the sidecar is not. Kept as a value so a reader can
        /// be told which file and why — and so the preview is not rolled back
        /// to pretend the edit never happened.
        case saveFailed(ImageAdjustmentPersistenceError)

        /// Whether what is on screen is what a reopen would restore.
        ///
        /// True for exactly two states: nothing was decided this session, or
        /// what was decided is in the sidecar.
        var isDurable: Bool {
            switch self {
            case .unchanged, .saved: return true
            case .pending, .renderRefused, .saveFailed: return false
            }
        }
    }

    /// A user decision that could not be made durable, kept so that leaving a
    /// file cannot make it disappear silently.
    ///
    /// `AdjustmentPersistence` reports this for the document on screen. Once
    /// the workspace moves to another file there is no `Loaded` left to carry
    /// it, and dropping it there is exactly the silent loss this milestone is
    /// about — so it is moved here instead.
    struct UnsavedAdjustment {
        /// Why it is not on disk.
        enum Reason {
            /// The state never rendered, so it was never eligible to be saved.
            case renderRefused
            /// It rendered, and the write refused.
            case saveRefused(ImageAdjustmentPersistenceError)
        }

        /// The RAW file the decision belongs to. Its sidecar still holds the
        /// last state that rendered and saved.
        let url: URL
        /// The decision itself, so it is described rather than merely counted.
        let adjustments: ImageAdjustments
        let reason: Reason

        /// The decision itself in one line, both adjustments named.
        ///
        /// Both, because the record that was not written is the complete state
        /// and reporting only the rotation would describe the wrong loss.
        var adjustmentDescription: String {
            """
            orientation \(adjustments.orientation.persistedToken), \
            mix \(adjustments.channelMix.kind.rawValue)
            """
        }

        /// One line for a log or a tooltip.
        var reasonDescription: String {
            switch reason {
            case .renderRefused:
                return "its render refused it, so it was never eligible to be saved"
            case .saveRefused(let error):
                return error.localizedDescription
            }
        }
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
        /// This is what makes an adjustment non-destructive: it is the
        /// **unmixed, unoriented** scene-linear image, so a new adjustment is
        /// always applied to it rather than to whatever is currently on
        /// screen. Its type says so — the mixer's output is a different one —
        /// so a mix cannot be composed onto a previous mix even by mistake.
        ///
        /// It is held at **preview resolution**, not the sensor's. Nothing
        /// full-resolution is reachable from it: the mosaics, the
        /// camera-native image and the working-colour image all go out of
        /// scope when `prepare` returns. A document's application-owned
        /// scene-linear buffer is therefore roughly 36 MB rather than the
        /// roughly 420 MB chain it replaced on the E-PL3 fixture, which is
        /// what makes it acceptable for two documents to hold one each during
        /// a file switch. Those numbers are that buffer alone: `legacy`, the
        /// preview `CGImage`s and the metadata are held beside it and are not
        /// counted. See
        /// `docs/decisions/0015-reduced-resolution-preview.md`.
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
        /// rotate, flip or a channel mix there would offer a control that
        /// cannot work. One fact gates all of them, for that reason.
        ///
        /// It is a stored fact rather than a reading of `owned` for a reason:
        /// a render that fails *after* the file is open must not disable the
        /// controls, or the user could not undo the adjustment that caused it.
        let isAdjustable: Bool

        /// The user's editing decisions — orientation and channel mix
        /// together: what the sidecar held when the file was opened, plus
        /// whatever has been asked for since.
        var adjustments: ImageAdjustments

        /// The application-owned pipeline's result, or the reason it failed.
        var owned: OwnedPreview

        /// Where `adjustments` stands with respect to the sidecar.
        ///
        /// It tracks the field above, not the last write: asking for a new
        /// adjustment makes this `.pending` in the same assignment, so there is
        /// no moment in which the workspace holds one state and claims another
        /// is saved.
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

    /// Decisions this workspace could not make durable, oldest first.
    ///
    /// Appended to only when a document leaves the screen with something at
    /// stake. Empty in normal operation: a successful save adds nothing.
    private(set) var unsavedAdjustments: [UnsavedAdjustment] = []

    private let decoder: RAWDecoder
    private let store: any ImageAdjustmentStore
    private let render: PreviewRender

    /// How large the interactive preview each opened file gets may be.
    ///
    /// Injected for the same reason `render` is: a test needs to exercise the
    /// reduction on an image far smaller than any production default, and the
    /// alternative — making test fixtures thousands of pixels wide — would put
    /// minutes of full-resolution work into suites that are about scheduling.
    /// Production passes the workspace policy and nothing else ever does.
    private let previewPolicy: PreviewResolutionPolicy
    private var decodeTask: Task<Void, Never>?

    /// Which open this is. Incremented by every `open(_:)`.
    ///
    /// A render's delivery is routed by the generation it was made for, not by
    /// its URL: the same file can be opened twice, and the second open's
    /// preview must never be replaced by the first open's late result.
    private var generation = 0

    /// The single slot every re-render goes through, rebuilt for each opened
    /// file because it closes over that file's retained scene-linear source.
    /// `nil` when nothing adjustable is open.
    private var renderer: CoalescingPreviewRenderer?

    /// A document the workspace has left while one of its adjustments was
    /// still being rendered.
    ///
    /// It has no screen and no controls. Its render slot is kept running for
    /// one reason only: the state it was asked for is a decision the user
    /// made, and the rule is that a state may be written **after** it has
    /// rendered. Cancelling it would satisfy the rule by losing the decision.
    private struct SettlingDocument {
        let url: URL
        /// The newest state this document was asked for, frozen at the moment
        /// the workspace left it. Nothing can change it afterwards: there is no
        /// UI attached to a settling document.
        let requested: ImageAdjustments
        /// Kept so the render is not deallocated mid-flight — and released as
        /// soon as it settles, because it holds that file's scene-linear
        /// source.
        let renderer: CoalescingPreviewRenderer
    }

    /// Documents that have left the screen and have not settled, by the
    /// generation they belonged to.
    ///
    /// Normally empty. An entry exists only between a file switch and the
    /// delivery of the render that was already running.
    ///
    /// At most one entry can exist per RAW file, and that is structural rather
    /// than checked: a second entry for a file would need that file to be on
    /// screen while an older generation of it is still settling, and a reopen
    /// of a settling file does not start until the settling one is gone.
    private var settling: [Int: SettlingDocument] = [:]

    /// An open that is waiting for an older generation of the **same** RAW
    /// file to finish writing.
    ///
    /// One slot, newest wins — the same shape the render slot uses for a burst
    /// of presses, and for the same reason: what a user wants now replaces what
    /// they wanted a moment ago, and nothing replays the states in between.
    private struct DeferredOpen {
        let url: URL
        /// The generation this open was given when it was requested. It is
        /// already `status`'s generation; if a newer open arrives, this one is
        /// obsolete and must never install anything.
        let generation: Int
    }

    private var deferredOpen: DeferredOpen?

    init(
        decoder: RAWDecoder = LibRawDecoder(),
        store: any ImageAdjustmentStore = JSONSidecarImageAdjustmentStore(),
        render: @escaping PreviewRender = DocumentState.pipelineRender,
        previewPolicy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy
    ) {
        self.decoder = decoder
        self.store = store
        self.render = render
        self.previewPolicy = previewPolicy
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

    /// The user's creative channel mix for the open file, or `.identity` when
    /// nothing is open.
    var channelMixAdjustment: UserChannelMixAdjustment {
        guard case .decoded(let loaded) = status else { return .identity }
        return loaded.adjustments.channelMix
    }

    /// Whether the adjustment controls can do anything right now.
    ///
    /// One fact, not one per control, because the thing it depends on is one
    /// fact: whether the owned pipeline rendered this file at least once. A
    /// file that prepares and then refuses at the geometry stage refuses for
    /// **every** adjustment equally — the effective orientation cannot be
    /// derived at all — so no control may be offered, not merely the rotate
    /// ones. See `Loaded.isAdjustable`.
    var canAdjust: Bool {
        guard case .decoded(let loaded) = status else { return false }
        return loaded.isAdjustable
    }

    /// Where the adjustment on screen stands with respect to its sidecar.
    var adjustmentPersistence: AdjustmentPersistence {
        guard case .decoded(let loaded) = status else { return .unchanged }
        return loaded.persistence
    }

    /// Why the current adjustment's save failed, or `nil` when none did.
    ///
    /// The image is correct either way; this says only whether it will still
    /// be there next time.
    var adjustmentSaveFailure: ImageAdjustmentPersistenceError? {
        guard case .saveFailed(let error) = adjustmentPersistence else { return nil }
        return error
    }

    /// Whether asynchronous persistence work is still in flight — a decision
    /// whose render has not been delivered, on the open document or on one the
    /// workspace has left.
    ///
    /// **This is not a close-safety predicate**, and the name says only what it
    /// means: work is still moving. Two other things are equally "not durable"
    /// and are deliberately not counted here, because nothing is in flight for
    /// them and waiting would never make them safe:
    ///
    /// ```text
    /// pending work        this property
    /// known unsaved work  .renderRefused, .saveFailed, unsavedAdjustments
    /// ```
    ///
    /// A future close guard has to consult both: the first says "wait", the
    /// second says "tell the user". There is no document lifecycle to hang one
    /// on today, so nothing consumes this yet. See
    /// `docs/decisions/0014-adjustment-lifecycle.md`.
    var hasPendingAdjustmentWork: Bool {
        if !settling.isEmpty { return true }
        if case .decoded(let loaded) = status, case .pending = loaded.persistence {
            return true
        }
        return false
    }

    /// Selects a file and starts decoding it, replacing any decode in flight.
    ///
    /// A **different** file appears as soon as it can: the document being left
    /// is never a reason to make a user wait, and it settles in the background.
    /// See `handOverCurrentDocument`.
    ///
    /// The **same** file is the exception, and the reason is the sidecar. Two
    /// generations of one RAW file share one persistence destination, so a
    /// reopen that read that file while an older generation of it still had a
    /// write to make would read a record that is about to change — and the
    /// older write could then land on top of a newer one. A reopen therefore
    /// waits for its own file to settle before it reads anything. Nothing else
    /// waits: two different RAW files have two different destinations and no
    /// race between them. See `docs/decisions/0014-adjustment-lifecycle.md`.
    func open(_ url: URL) {
        decodeTask?.cancel()
        handOverCurrentDocument()
        generation += 1
        status = .decoding(url)
        // At most one open is ever waiting, and it is always the newest one: a
        // superseded deferred open is simply replaced here, which is how
        // "newest user open wins" survives the wait.
        deferredOpen = nil

        guard !isSettling(url) else {
            deferredOpen = DeferredOpen(url: url, generation: generation)
            return
        }
        startDecoding(url, generation: generation)
    }

    /// Whether an older generation of this RAW file still has a write to make.
    private func isSettling(_ url: URL) -> Bool {
        settling.values.contains { $0.url == url }
    }

    /// Starts the decode for one open.
    ///
    /// Split from `open(_:)` because a same-URL reopen runs it later, after the
    /// older generation of that file has finished writing. Everything the work
    /// needs is passed in, so a deferred start is the same call as an immediate
    /// one.
    private func startDecoding(_ url: URL, generation: Int) {
        let decoder = self.decoder
        let store = self.store
        let render = self.render
        let previewPolicy = self.previewPolicy
        // LibRaw decoding is a long, blocking C++ call. Detaching keeps it off
        // both the main actor and the caller's cooperative context.
        decodeTask = Task.detached(priority: .userInitiated) {
            // `nil` means the open was superseded while it was running. There
            // is nothing to install and nothing to report: a cancelled open is
            // not a failed one.
            guard let outcome = Self.decode(
                url,
                using: decoder,
                store: store,
                render: render,
                previewPolicy: previewPolicy
            ) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.apply(outcome, generation: generation)
            }
        }
    }

    /// Starts the waiting open, if there is one and its file is now free.
    ///
    /// Called after a document settles. Two things can stop it, and both are
    /// ordinary: the file still has another older generation to finish, or the
    /// waiting open has been superseded by a newer one — in which case it is
    /// dropped here without ever touching `status`, because the generation it
    /// belongs to is no longer the one on screen.
    private func startDeferredOpenIfReady() {
        guard let deferred = deferredOpen else { return }
        guard deferred.generation == generation else {
            deferredOpen = nil
            return
        }
        guard !isSettling(deferred.url) else { return }

        deferredOpen = nil
        startDecoding(deferred.url, generation: deferred.generation)
    }

    /// Decides what happens to the document being replaced.
    ///
    /// ```text
    /// nothing decided, or decided and saved   the render slot is cancelled and dropped
    /// decided, render still running           the slot keeps running, to persist and nothing else
    /// decided, render refused it              recorded as unsaved; it can never be written
    /// decided, rendered, save refused         recorded as unsaved; the sidecar is older
    /// ```
    ///
    /// The second row is the one this exists for. A user who rotates a
    /// photograph and immediately opens the next one has made a decision, and
    /// cancelling its render — the only thing that can make that decision
    /// eligible to be written — would drop it without a word.
    ///
    /// What a settling document may still do is exactly one thing: **write its
    /// own sidecar, once its own render succeeds.** It cannot install a
    /// preview, it cannot touch `status`, and it writes under the URL captured
    /// with it, so it can never reach the new document's sidecar.
    ///
    /// The cost is stated rather than discovered: a settling document holds its
    /// scene-linear source until it settles, so a switch made mid-render
    /// briefly retains two of them. It is released the moment the render
    /// delivers — and each of them is now one reduced buffer rather than a
    /// whole sensor-resolution chain, so the overlap costs roughly 72 MB on
    /// the E-PL3 fixture rather than roughly 840 MB. That is the difference
    /// between an overlap worth arguing about and one worth allowing.
    private func handOverCurrentDocument() {
        defer { renderer = nil }
        guard case .decoded(let loaded) = status else {
            renderer?.cancelAll()
            return
        }

        switch loaded.persistence {
        case .pending:
            guard let renderer else { return }
            // Deliberately not cancelled. This is the whole hand-over.
            settling[generation] = SettlingDocument(
                url: loaded.url, requested: loaded.adjustments, renderer: renderer
            )

        case .renderRefused:
            renderer?.cancelAll()
            record(
                UnsavedAdjustment(
                    url: loaded.url, adjustments: loaded.adjustments, reason: .renderRefused
                )
            )

        case .saveFailed(let error):
            renderer?.cancelAll()
            record(
                UnsavedAdjustment(
                    url: loaded.url,
                    adjustments: loaded.adjustments,
                    reason: .saveRefused(error)
                )
            )

        case .unchanged, .saved:
            // Nothing is at stake. Any render still unwinding here is one whose
            // state was already superseded or already written.
            renderer?.cancelAll()
        }
    }

    /// Records a decision that did not reach disk, and says so in the log.
    private func record(_ unsaved: UnsavedAdjustment) {
        unsavedAdjustments.append(unsaved)
        Log.ui.error(
            """
            Left \(unsaved.url.lastPathComponent, privacy: .public) with an unsaved \
            adjustment \(unsaved.adjustmentDescription, privacy: .public): \
            \(unsaved.reasonDescription, privacy: .public)
            """
        )
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
        render: PreviewRender,
        previewPolicy: PreviewResolutionPolicy
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
            previewPolicy: previewPolicy,
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
        previewPolicy: PreviewResolutionPolicy,
        cancellation: ProcessingCancellation
    ) -> OwnedOutcome? {
        let pipeline = WorkspacePreviewPipeline()

        let source: WorkspacePreviewPipeline.Source
        do {
            source = try pipeline.prepare(
                decoding: url, using: decoder, policy: previewPolicy
            )
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
    ///
    /// It resets the **orientation** and nothing else. The creative channel
    /// mix is a separate decision and is left exactly as it was; there is
    /// deliberately no "reset everything" here, because a control that
    /// silently discarded a rendering choice along with a rotation would be
    /// the least recoverable button in the application.
    func resetOrientation() { adjustOrientation { _ in .reset } }

    /// Applies a transformation to the current orientation correction and
    /// re-renders.
    ///
    /// The new adjustment is the **canonical composition** of the old one and
    /// the operation, so pressing a button repeatedly never accumulates a
    /// history.
    private func adjustOrientation(
        _ transform: (UserOrientationAdjustment) -> UserOrientationAdjustment
    ) {
        adjust { $0.orientation = transform($0.orientation) }
    }

    // MARK: - Channel-mix adjustment

    /// Chooses the creative infrared channel mix and re-renders.
    ///
    /// The mix is a **state, not an operation**: this replaces whatever was
    /// asked for before rather than composing onto it, which is the editing
    /// model's half of "mixes never compose". The render that follows starts
    /// from the retained pre-mix preview, so the new matrix is applied to the
    /// working-colour values themselves and never to a previous mix's result.
    ///
    /// Asking for the mix that is already in force does nothing at all — no
    /// render, no write, no change of persistence state.
    ///
    /// - Parameter mix: the decision. `.identity` is a real choice and is
    ///   saved like any other; it is the mix control's way of undoing a swap,
    ///   and it does not touch the orientation.
    func setChannelMix(_ mix: UserChannelMixAdjustment) {
        adjust { $0.channelMix = mix }
    }

    // MARK: - Requesting a render of one complete state

    /// Records a change to the canonical adjustment state and asks for a
    /// render of **the whole of it**.
    ///
    /// The one path every control goes through, and the reason there is one:
    /// a render request is always one complete `ImageAdjustments`, never a
    /// field. A user who swaps the channels and immediately rotates has asked
    /// for one state, not two operations to be applied in order, so the burst
    /// collapses to that state and nothing in between is rendered, installed
    /// or written.
    ///
    /// Nothing is saved here, and the state says so: it becomes `.pending`
    /// until a render of exactly this adjustment has been delivered. A state
    /// that has not been rendered is not known to be renderable, and writing
    /// it would let a broken state be restored automatically on the next
    /// launch.
    private func adjust(_ change: (inout ImageAdjustments) -> Void) {
        guard case .decoded(var loaded) = status, loaded.isAdjustable,
              let renderer
        else { return }

        var updated = loaded.adjustments
        change(&updated)
        guard updated != loaded.adjustments else { return }

        // Record the intent immediately, so the controls reflect what the
        // user asked for even while the render is still running — and say, in
        // the same breath, that this state is not on disk. The state that was
        // saved a moment ago is no longer the state on screen, and reporting
        // it as saved would be a claim about the wrong adjustment.
        loaded.adjustments = updated
        loaded.persistence = .pending
        status = .decoded(loaded)

        // One slot, newest state wins. A burst of changes produces one
        // cancellation and one render, not a queue.
        renderer.request(loaded.adjustments)
    }

    /// Builds the single render slot for a freshly opened file.
    ///
    /// The closure captures that file's retained, **unmixed and unoriented**,
    /// preview-resolution scene-linear source, so every re-render starts from
    /// it rather than from whatever is on screen. Nothing upstream reruns: no
    /// reduction, no camera conversion, no demosaic, no white balance, no
    /// decode — and nothing full-resolution is reachable through the capture,
    /// which is what keeps the closure cheap to hold.
    ///
    /// The creative mix is inside the closure rather than above it, which is
    /// the whole of this milestone: a change of mix is a re-render of this
    /// source, not a re-preparation of the file.
    ///
    /// It also captures the file's URL and the generation of the open it
    /// belongs to. Those two are what let a delivery find its way back to the
    /// right document — or, when that document has been left, to its
    /// sidecar and nothing else.
    private func makeRenderer(
        for source: WorkspacePreviewPipeline.Source,
        url: URL,
        generation: Int
    ) -> CoalescingPreviewRenderer {
        let render = self.render
        return CoalescingPreviewRenderer(
            render: { adjustments, cancellation in
                try render(source, adjustments, cancellation)
            },
            deliver: { [weak self] outcome, adjustments in
                self?.deliver(outcome, adjustments: adjustments, url: url, generation: generation)
            }
        )
    }

    /// Routes a settled render to the document it was made for.
    ///
    /// ```text
    /// the document is still on screen   install it, then save it
    /// the document has been left        save it, and nothing else
    /// neither                           nothing; there is nowhere for it to go
    /// ```
    ///
    /// Routing is by **generation**, not by URL. The same file can be opened
    /// twice, and a late render from the first open must not touch the second
    /// one's preview merely because the paths match.
    private func deliver(
        _ outcome: Result<WorkspacePreview, Error>,
        adjustments: ImageAdjustments,
        url: URL,
        generation: Int
    ) {
        if generation == self.generation {
            applyReprocessed(outcome, adjustments: adjustments, for: url)
        } else if let document = settling[generation] {
            settle(document, generation: generation, outcome: outcome, adjustments: adjustments)
        }
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
            loaded.persistence = write(adjustments, for: url).map {
                AdjustmentPersistence.saveFailed($0)
            } ?? .saved
        case .failure(let error):
            Self.log(error, path: "Owned re-render", url: url)
            loaded.owned = .unavailable(RAWPathFailure(stage: .ownedRender, error))
            // Not eligible to be written, and the sidecar is untouched: it
            // still holds the last state that actually rendered.
            loaded.persistence = .renderRefused
        }
        status = .decoded(loaded)
    }

    /// Finishes a document the workspace has left.
    ///
    /// The only effect available here is a write to that document's own
    /// sidecar. There is no preview to install — the document has no screen —
    /// and `status` belongs to a different file entirely.
    ///
    /// A delivery for anything other than the frozen requested state is a
    /// superseded render inside the departed document: discarded, and the
    /// document stays open in `settling` because its newest state is still to
    /// come.
    private func settle(
        _ document: SettlingDocument,
        generation: Int,
        outcome: Result<WorkspacePreview, Error>,
        adjustments: ImageAdjustments
    ) {
        guard document.requested == adjustments else { return }

        switch outcome {
        case .success:
            if let failure = write(adjustments, for: document.url) {
                record(
                    UnsavedAdjustment(
                        url: document.url, adjustments: adjustments, reason: .saveRefused(failure)
                    )
                )
            }
        case .failure(let error):
            Self.log(error, path: "Owned re-render", url: document.url)
            record(
                UnsavedAdjustment(
                    url: document.url, adjustments: adjustments, reason: .renderRefused
                )
            )
        }

        // This document is done: its newest state has now either been written
        // or refused. Releasing the slot releases its scene-linear source with
        // it — and frees its file, which may be what an open is waiting for.
        //
        // The order matters and is the whole fix: the write above has already
        // returned, so an open released here reads a sidecar that no older
        // generation can still change.
        settling[generation] = nil
        startDeferredOpenIfReady()
    }

    /// Writes one rendered adjustment to its sidecar.
    ///
    /// Synchronous, on the main actor, and small on purpose: one atomic
    /// replacement of a few hundred bytes, ordered by construction because
    /// there is only one place that writes and it cannot interleave with
    /// itself. Moving it off the main actor would buy nothing measurable and
    /// would need its own ordering guard to stop an older save landing after a
    /// newer one.
    ///
    /// - Returns: the refusal, or `nil` when the record is on disk.
    private func write(
        _ adjustments: ImageAdjustments, for url: URL
    ) -> ImageAdjustmentPersistenceError? {
        do {
            try store.save(adjustments, for: url)
            return nil
        } catch {
            Self.log(error, path: "Saving adjustments", url: url)
            return error
        }
    }

    private func apply(_ outcome: Result<Loaded, OpenFailure>, generation: Int) {
        // Ignore a result that a newer selection has already superseded.
        guard generation == self.generation else { return }

        switch outcome {
        case .success(let loaded):
            // Only an adjustable file gets a render slot. A prepared source
            // nothing can be rendered from gets none, so there is no path by
            // which a control could request work that is known to fail.
            renderer = loaded.adjustableSource.map {
                makeRenderer(for: $0, url: loaded.url, generation: generation)
            }
            status = .decoded(loaded)

        case .failure(.raw(let error)):
            Log.ui.error(
                """
                Failed to open \(error.url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            status = .failed(error.url, error)

        case .failure(.adjustments(let error)):
            Log.ui.error(
                """
                Did not open \(error.url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            status = .adjustmentsUnreadable(error.url, error)
        }
    }
}
