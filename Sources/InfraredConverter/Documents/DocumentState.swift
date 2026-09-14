import CoreGraphics
import Foundation
import Observation

/// Workspace state for a single RAW file.
///
/// This is the application layer between the UI and the RAW decoder: it owns
/// the decode task and the resulting state, and it is the only place that knows
/// a `RAWDecoder` exists. Views read `status` and never touch a decoder.
///
/// It is not `ImageDocument` yet, but it is closer: it owns a
/// `PhotographProcessingState` alongside the decoded state, the preview is
/// derived from `source + state` rather than from the source alone, and that
/// record now outlives the session.
///
/// ## Where the photograph's state lives, and for how long
///
/// **In memory here while the file is open, and in a sidecar beside the RAW
/// file between sessions.** All three layers now exist:
///
/// ```text
/// 1. a serialisable model    PhotographProcessingState
///                              ├── captureProfile   a reusable configuration, by identity
///                              └── adjustments      this photograph's own decisions
/// 2. in-memory ownership     here, per open file
/// 3. durable persistence     PhotographProcessingStore — one sidecar per photograph
/// ```
///
/// The two halves are kept apart deliberately: a capture profile describes how
/// the photograph was **captured** and is shared by every frame shot that way;
/// an adjustment is a decision about **this** frame. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`.
///
/// The RAW file is not one of them. It is an immutable input: nothing here
/// writes to it, appends to it, re-tags it or replaces it, and the sidecar is
/// the only place a user's decisions are ever recorded. See
/// `docs/decisions/0013-adjustment-sidecar.md`.
///
/// ## Opening reads the saved state before it renders anything
///
/// ```text
/// load sidecar → resolve the capture profile → prepare RAW → check the profile
///   applies to this camera → initial render WITH the loaded state → .decoded
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
/// ## Four adjustments and a profile, one state
///
/// ```text
/// captureProfile which camera-to-working processing the photograph gets
/// whiteBalance   which samples the infrared white balance is measured from
/// orientation    the eight discrete arrangements, composed onto the file's own
/// channelMix     the creative infrared remix: identity, red/blue swap, matrix
/// exposure       compensation in EV, applied as × 2^EV by the display stage
/// ```
///
/// The profile is a **selection**, not an adjustment, and it is the other half
/// of `PhotographProcessingState` rather than a fifth field of
/// `ImageAdjustments`. It travels the same road: one complete state per
/// request, persisted only after that state has rendered.
///
/// ## Profile definitions come from elsewhere, and can change underfoot
///
/// This type consumes an `IRCaptureProfileRegistry` and never reads the profile
/// folder: `IRCaptureProfileLibrary` owns the definitions and hands a new
/// registry here through `updateCaptureProfiles(_:)` when one is created,
/// edited or deleted. Two things follow, and both are deliberate.
///
/// ```text
/// the profile ID changed          a decision — .pending, rendered, then written
/// the profile DEFINITION changed  not this photograph's decision — re-rendered
///                                 for provenance, and no sidecar write at all
/// ```
///
/// A render therefore writes the sidecar only when it settles a `.pending`
/// decision. Renaming a profile must not rewrite a single photograph's record,
/// and editing one must not touch a single adjustment. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
///
/// They are fields of one `ImageAdjustments` record, and every request is that
/// whole record. Nothing here renders "the new mix", "the new rotation" or
/// "the new exposure": a burst of changes to any control — a slider drag is
/// exactly such a burst — collapses to one newest complete state, and the
/// sidecar receives that state or nothing. Exposure is the first continuous
/// control, and it deliberately has no scheduler, debounce or queue of its
/// own. See `docs/decisions/0016-interactive-channel-mixer.md` and
/// `docs/decisions/0017-interactive-exposure.md`.
///
/// ## Two costs, two slots, one canonical state
///
/// The white balance is the first adjustment that is **upstream of
/// demosaicing**, so it cannot be applied to the retained reduced preview the
/// way the other three are. It re-prepares that preview from the retained
/// normalised mosaic:
///
/// ```text
/// fast    reduced pre-mix preview → mix → orientation → exposure/display
/// heavy   normalised mosaic → estimate the patch → balance → demosaic
///         → camera → working → reduce → THEN the fast path, for the latest state
/// ```
///
/// Each has its own `CoalescingRenderSlot`, because "at most one at a time,
/// newest wins" is a claim each has to make about itself: a patch being
/// prepared must not stop the exposure from re-rendering once it lands, and a
/// render must not stop a newer patch from starting.
///
/// Neither changes the editing model. A heavy preparation is still requested
/// for one complete `ImageAdjustments`; when it lands, the fast path renders
/// the **latest** complete state that still names that white balance, so an
/// exposure changed while a patch was being prepared is in the result rather
/// than a stop behind it. See
/// `docs/decisions/0019-interactive-white-balance.md`.
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
/// What it persists is the complete state it was asked for — every adjustment,
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
        /// The photograph was never decoded, or was decoded and then refused,
        /// because the capture profile its saved state names could not be
        /// used: no profile has that identity, or the profile describes a
        /// different camera.
        ///
        /// A third refusal rather than a branch of the second, for the same
        /// reason the second exists: a different problem with a different
        /// remedy. Nothing was substituted, repaired or rewritten — the
        /// alternative, rendering under some other profile that happens to be
        /// installed, would change the photograph and report success. See
        /// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 5.
        case captureProfileUnusable(URL, DocumentCaptureProfileError)
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
        case saveFailed(PhotographProcessingPersistenceError)

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
            case saveRefused(PhotographProcessingPersistenceError)
        }

        /// The RAW file the decision belongs to. Its sidecar still holds the
        /// last state that rendered and saved.
        let url: URL
        /// The decision itself, so it is described rather than merely counted.
        ///
        /// The complete record: the capture profile the user had selected as
        /// well as every adjustment, because the sidecar is written as one
        /// record and half a decision is not one.
        let state: PhotographProcessingState
        let reason: Reason

        /// The adjustments half, for callers that only want that.
        var adjustments: ImageAdjustments { state.adjustments }

        /// The decision itself in one line, every adjustment named.
        ///
        /// All of them, because the record that was not written is the
        /// complete state and reporting only the rotation would describe the
        /// wrong loss.
        var adjustmentDescription: String { state.diagnosticDescription }

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

        /// The retained **normalised mosaic** — decoded, black-subtracted and
        /// scaled, still a CFA mosaic, at the sensor's own resolution — or
        /// `nil` when this file will never be re-balanced.
        ///
        /// The one full-resolution buffer a document holds, and the exception
        /// that makes an interactive white balance possible: a new neutral
        /// patch is estimated and applied from these samples, so moving the
        /// patch costs a balance, a demosaic, a conversion and a reduction,
        /// and no decode at all.
        ///
        /// It is present only for a file the owned pipeline actually rendered.
        /// A document with no image has no controls to spend the largest
        /// retained cost in the application on.
        ///
        /// Roughly 49 MB on the E-PL3 fixture — 4056 × 3040 `Float32` — beside
        /// the roughly 36 MB reduced preview below. The heavy slot's closure
        /// holds the same value; `LinearRAWMosaic` is a value type over one
        /// immutable `[Float]`, so that is one buffer with two references and
        /// not two buffers. See
        /// `docs/decisions/0019-interactive-white-balance.md`.
        let base: NormalizedRAWSource?

        /// The retained scene-linear state every fast reprocess starts from,
        /// or `nil` when the owned pipeline could not get that far.
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
        ///
        /// It is a `var` because one adjustment can replace it: a new white
        /// balance is estimated and applied upstream of demosaicing, so its
        /// result is a **new** reduced pre-mix preview rather than a different
        /// rendering of this one. Every other adjustment renders from whatever
        /// this currently holds and leaves it exactly as it is. The
        /// replacement is installed in one place, under one guard — the white
        /// balance it was prepared for must still be the one the user wants.
        var source: WorkspacePreviewPipeline.Source?

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

        /// Everything this application owns about the photograph: the capture
        /// profile it is processed under, and the user's editing decisions —
        /// white balance, orientation, channel mix and exposure. What the
        /// sidecar held when the file was opened, plus whatever has been asked
        /// for since.
        ///
        /// This is the **requested** state, and it is what the controls show.
        /// While a render is pending it is ahead of `owned`, whose preview —
        /// and whose provenance, which the inspector reads — describes the
        /// state that was actually rendered. The two are not reconciled by
        /// moving a control back.
        var state: PhotographProcessingState

        /// The capture profile `state.captureProfile` names, resolved once when
        /// the file was opened or when the user selected another one.
        ///
        /// Held beside the identity rather than looked up on demand, so that
        /// nothing deep in the rendering path performs a registry lookup — and
        /// so that an export snapshot can carry a resolved value rather than a
        /// reference it would have to resolve while running. The invariant is
        /// `captureProfile.id == state.captureProfile`, and the two are only
        /// ever assigned together.
        var captureProfile: IRCaptureProfile

        /// The user's editing decisions alone.
        ///
        /// A projection of `state`, not a second authority: reading and writing
        /// it goes straight through. It exists because most of this type's
        /// callers care about one half of the record and nothing is gained by
        /// making them say so twice.
        var adjustments: ImageAdjustments {
            get { state.adjustments }
            set { state.adjustments = newValue }
        }

        /// The application-owned pipeline's result, or the reason it failed.
        var owned: OwnedPreview

        /// Where `state` stands with respect to the sidecar.
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
        /// actually work. The one thing a render request may be built from.
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

    /// Where one export has got to.
    ///
    /// One closed enum rather than several booleans, for the reason
    /// `AdjustmentPersistence` is one: "running", "finished" and "failed" are
    /// mutually exclusive states of a single thing, and a pair of flags can
    /// represent combinations that cannot happen.
    ///
    /// It is **not** part of the adjustment state and is not persisted.
    /// Exporting is producing an artefact, not editing a photograph: nothing
    /// here is written to the sidecar, and a failed export leaves the
    /// document exactly as it was. See
    /// `docs/decisions/0018-full-resolution-tiff-export.md`, Decision 9.
    enum ExportStatus {
        /// Nothing has been exported, or the last one has been acknowledged.
        case idle
        /// A full-resolution render and write is running, for this snapshot.
        case exporting(ExportRequest, destination: URL)
        /// A file was written.
        case succeeded(TIFFExportResult)
        /// It was not. The error is kept as a value, not as a sentence.
        case failed(ExportFailure)

        var isRunning: Bool {
            if case .exporting = self { return true }
            return false
        }
    }

    /// An export that did not produce a file.
    struct ExportFailure {
        /// The snapshot that was being exported — its own copy, so it still
        /// describes what was asked for however the document has changed
        /// since.
        let request: ExportRequest
        /// Where the file would have gone. Nothing was written there.
        let destination: URL
        /// What went wrong, kept typed.
        let error: any Error

        /// The export path's own error, when that is what this is. A caller
        /// that wants to know *which* step failed asks for this rather than
        /// parsing a message.
        var exportError: FullResolutionExportError? {
            error as? FullResolutionExportError
        }

        var message: String {
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        var failureReason: String? {
            (error as? LocalizedError)?.failureReason
        }
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
        /// Prepared and rendered. This is the only success, and the only case
        /// that carries the normalised mosaic.
        ///
        /// The mosaic is retained **only** here, and that is the whole of the
        /// "retain after a successful open" rule: it is roughly 49 MB on the
        /// reference camera, and holding it for a file that never produced an
        /// image would be paying the largest retained cost in the application
        /// for a document with no controls to spend it on.
        case rendered(NormalizedRAWSource, WorkspacePreviewPipeline.Source, WorkspacePreview)
        /// Prepared, then refused by the orientation or display stage. The
        /// reduced source is kept for diagnosis; nothing can be re-rendered
        /// from it, so the normalised mosaic is released.
        case unrenderable(WorkspacePreviewPipeline.Source, RAWPathFailure)
        /// Never reached a scene-linear state at all.
        case unprepared(RAWPathFailure)
        /// The file decoded, and the capture profile its saved state names does
        /// not describe the camera that took it. Nothing was processed under
        /// it, and nothing was substituted for it.
        case profileRefused(IRCaptureProfileError)
    }

    /// Why an open ended without a document. Two unrelated problems, kept
    /// apart all the way to `Status`.
    private enum OpenFailure: Error {
        /// Neither RAW path produced an image.
        case raw(DocumentOpenError)
        /// The saved adjustments could not be read, so nothing was decoded.
        case adjustments(DocumentAdjustmentError)
        /// The capture profile the saved state names could not be resolved, or
        /// could not be applied to this camera. The photograph is fine and
        /// nothing was rewritten.
        case captureProfile(DocumentCaptureProfileError)
    }

    /// Orients a prepared source and encodes it for display.
    ///
    /// Injected so a test can count the renders an open performs and can make
    /// one refuse; production passes `pipelineRender` and nothing else ever
    /// does.
    /// It takes the resolved capture profile beside the adjustments, because a
    /// rendering is provenance as well as pixels: the preview has to be able to
    /// say which profile produced it. The pipeline refuses a profile whose
    /// processing basis is not the one the source was prepared under, so a
    /// profile change that *does* affect pixels cannot be smuggled through the
    /// cheap path.
    typealias PreviewRender = @Sendable (
        WorkspacePreviewPipeline.Source, IRCaptureProfile, ImageAdjustments,
        ProcessingCancellation
    ) throws -> WorkspacePreview

    /// The real thing: the last phase of `WorkspacePreviewPipeline`.
    nonisolated static let pipelineRender: PreviewRender = {
        source, captureProfile, adjustments, cancellation in
        try WorkspacePreviewPipeline().render(
            source,
            captureProfile: captureProfile,
            adjustments: adjustments,
            cancellation: cancellation
        )
    }

    /// Re-prepares the reduced pre-mix preview for one white-balance decision,
    /// from the retained normalised mosaic.
    ///
    /// Injected for the same reasons `render` is: a test needs to count how
    /// many preparations a burst of patches actually starts, to hold one open
    /// while it asks for another, and to make one refuse. Production passes
    /// `pipelineSourcePreparation` and nothing else ever does.
    ///
    /// It takes a `NormalizedRAWSource` and a white balance — never a `URL`
    /// and never a decoder. There is no parameter through which this could
    /// read the file again, which is the performance claim of this milestone
    /// expressed as a signature rather than as a promise.
    /// It also takes the resolved capture profile, because the
    /// camera-to-working transform this phase runs is the profile's one
    /// contribution to a pixel — and because that makes the two inputs a
    /// preparation depends on visible in its signature. Still no `URL` and
    /// still no decoder.
    typealias SourcePreparation = @Sendable (
        NormalizedRAWSource, UserWhiteBalanceAdjustment, IRCaptureProfile,
        PreviewResolutionPolicy, ProcessingCancellation
    ) throws -> WorkspacePreviewPipeline.Source

    /// The real thing: the white-balance-dependent phase of
    /// `WorkspacePreviewPipeline`.
    nonisolated static let pipelineSourcePreparation: SourcePreparation = {
        base, whiteBalance, captureProfile, policy, cancellation in
        try WorkspacePreviewPipeline().prepareSource(
            base,
            whiteBalance: whiteBalance,
            captureProfile: captureProfile,
            policy: policy,
            cancellation: cancellation
        )
    }

    /// Renders one export snapshot at full resolution and writes it.
    ///
    /// Injected so a test can hold an export open, make one fail, and observe
    /// exactly which request reached it; production passes
    /// `fullResolutionTIFFExport` and nothing else ever does.
    ///
    /// It takes a `URL` and an `ImageAdjustments` — never a preview, a
    /// `Source` or a `CGImage`. There is no parameter through which the pixels
    /// on screen could reach a file.
    typealias ExportRun = @Sendable (
        ExportRequest, URL, any RAWDecoder
    ) throws -> TIFFExportResult

    /// The real thing: decode the RAW file again, at full resolution.
    nonisolated static let fullResolutionTIFFExport: ExportRun = { request, destination, decoder in
        try FullResolutionExportPipeline().export(
            request, to: destination, using: decoder
        )
    }

    private(set) var status: Status = .empty

    /// Decisions this workspace could not make durable, oldest first.
    ///
    /// Appended to only when a document leaves the screen with something at
    /// stake. Empty in normal operation: a successful save adds nothing.
    private(set) var unsavedAdjustments: [UnsavedAdjustment] = []

    /// Where the most recent export has got to.
    private(set) var exportStatus: ExportStatus = .idle

    private let decoder: RAWDecoder
    private let store: any PhotographProcessingStore

    /// Where capture profile **definitions** come from.
    ///
    /// Injected, so a test can install profiles this build does not ship —
    /// a camera-specific one, or one with a different processing basis — and
    /// exercise resolution, mismatch and invalidation without production
    /// growing fake profiles to make the tests possible. Production passes
    /// `IRCaptureProfileRegistry.builtin`, which holds exactly one.
    ///
    /// It is consulted in three places and nowhere else: when a file is
    /// opened, when a user picks a profile, and when the profile library
    /// replaces it. No processing stage sees it, and an export never does — an
    /// export carries an already-resolved profile. See
    /// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 10.
    ///
    /// It is a `var` because the set of profiles is no longer fixed: a person
    /// can create, edit and delete them while a photograph is open. It is still
    /// **replaced, never mutated** — `IRCaptureProfileRegistry` is an immutable
    /// value — and it is replaced through exactly one path,
    /// `updateCaptureProfiles(_:)`, so this document is never reading a
    /// definition that changed underneath it. This document does not own the
    /// library and never reads the profile folder; `IRCaptureProfileLibrary`
    /// does both. See
    /// `docs/decisions/0021-user-capture-profile-library.md`.
    private var registry: IRCaptureProfileRegistry
    private let render: PreviewRender
    private let prepareSource: SourcePreparation

    /// How large the interactive preview each opened file gets may be.
    ///
    /// Injected for the same reason `render` is: a test needs to exercise the
    /// reduction on an image far smaller than any production default, and the
    /// alternative — making test fixtures thousands of pixels wide — would put
    /// minutes of full-resolution work into suites that are about scheduling.
    /// Production passes the workspace policy and nothing else ever does.
    private let previewPolicy: PreviewResolutionPolicy
    private let exportRun: ExportRun
    private var decodeTask: Task<Void, Never>?

    /// The export in flight, if any.
    ///
    /// Deliberately **not** cancelled by `open(_:)`. An export is bound to the
    /// snapshot it started with, and a user who starts a twelve-megapixel
    /// render and then looks at the next photograph has not changed their mind
    /// about the file they asked for. See
    /// `docs/decisions/0018-full-resolution-tiff-export.md`, Decision 11.
    private var exportTask: Task<Void, Never>?

    /// Which open this is. Incremented by every `open(_:)`.
    ///
    /// A render's delivery is routed by the generation it was made for, not by
    /// its URL: the same file can be opened twice, and the second open's
    /// preview must never be replaced by the first open's late result.
    private var generation = 0

    /// The fast slot: one complete adjustment state applied to a reduced
    /// pre-mix preview. `nil` when nothing adjustable is open.
    ///
    /// Built once per opened file and never rebuilt. It does **not** close
    /// over that file's source any more — the source travels in the request,
    /// because a new white balance replaces it and rebuilding a slot that may
    /// still be unwinding a cancelled pass would break the one-at-a-time
    /// guarantee the slot exists to make.
    private var renderer: PreviewRenderSlot?

    /// The heavy slot: one white-balance decision re-prepared from the
    /// retained normalised mosaic into a new reduced pre-mix preview. `nil`
    /// when nothing adjustable is open.
    ///
    /// Its closure holds that file's `NormalizedRAWSource` — the same value
    /// `Loaded.base` holds, which is one buffer with two references rather
    /// than two buffers. Releasing the slot and the document releases the
    /// mosaic. Roughly 49 MB on the reference camera, retained from a
    /// successful open until the document is left and has settled.
    private var preparer: SourcePreparationSlot?

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
        let requested: PhotographProcessingState
        /// The reduced pre-mix preview this document's render starts from.
        ///
        /// A `var` for exactly one reason, and it is the reason settling had
        /// to be generalised: the outstanding work may be a **white-balance
        /// preparation**, whose result is a new source that its own render
        /// then has to run against. A document left mid-preparation therefore
        /// still has two steps to take, and both happen here, with no screen.
        var source: WorkspacePreviewPipeline.Source
        /// The resolved profile the requested state names, so the render that
        /// settles this document carries the same provenance it would have had
        /// on screen. It is not resolved again here: a registry lookup after
        /// the document has left the workspace would be a second chance for the
        /// answer to differ.
        let captureProfile: IRCaptureProfile
        /// Kept so the heavy pass is not deallocated mid-flight — and released
        /// as soon as the document settles, because it holds that file's
        /// normalised mosaic.
        let preparer: SourcePreparationSlot
        /// Kept so the render is not deallocated mid-flight.
        let renderer: PreviewRenderSlot
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
        /// The profile a recovery asked for, when this open is one. It waits
        /// with the open it belongs to: a recovery of a file that is still
        /// settling is still that file's recovery when its turn comes.
        let captureProfileOverride: IRCaptureProfileID?
    }

    private var deferredOpen: DeferredOpen?

    init(
        decoder: RAWDecoder = LibRawDecoder(),
        store: any PhotographProcessingStore = JSONSidecarPhotographProcessingStore(),
        registry: IRCaptureProfileRegistry = .builtin,
        render: @escaping PreviewRender = DocumentState.pipelineRender,
        prepareSource: @escaping SourcePreparation = DocumentState.pipelineSourcePreparation,
        previewPolicy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy,
        exportRun: @escaping ExportRun = DocumentState.fullResolutionTIFFExport
    ) {
        self.decoder = decoder
        self.store = store
        self.registry = registry
        self.render = render
        self.prepareSource = prepareSource
        self.previewPolicy = previewPolicy
        self.exportRun = exportRun
    }

    var selectedFileURL: URL? {
        switch status {
        case .empty: return nil
        case .decoding(let url): return url
        case .decoded(let loaded): return loaded.url
        case .failed(let url, _): return url
        case .adjustmentsUnreadable(let url, _): return url
        case .captureProfileUnusable(let url, _): return url
        }
    }

    /// The capture profile the open photograph is processed under, resolved, or
    /// the built-in uncalibrated profile when nothing is open.
    ///
    /// The **requested** selection, like every other control's accessor: while
    /// a profile change is being prepared this is already the new one, and the
    /// preview's own `captureProfile` still describes the pixels on screen.
    var captureProfile: IRCaptureProfile {
        guard case .decoded(let loaded) = status else { return .builtinUncalibrated }
        return loaded.captureProfile
    }

    /// Every profile a photograph may be switched to, in a deterministic order.
    ///
    /// The registry's list and nothing else. There is deliberately no free-text
    /// entry: a profile identifier a user typed would name nothing, and a
    /// photograph pointing at nothing is exactly the unresolvable state this
    /// milestone refuses to create on purpose.
    ///
    /// Sorted by **identity**, which is what makes it reproducible. A picker
    /// wants `captureProfileChoices` instead: that one is sorted for reading,
    /// by a field a person can rename.
    var availableCaptureProfiles: [IRCaptureProfile] { registry.allProfiles }

    /// One profile as a picker sees it: the definition, and whether it may be
    /// applied to the photograph that is open.
    ///
    /// Applicability travels with the profile rather than being recomputed by
    /// a view, so nothing on screen can invent its own idea of whether a
    /// profile fits — and so a refusal can be **shown** rather than discovered
    /// by pressing something that does nothing.
    struct CaptureProfileChoice: Identifiable {
        let profile: IRCaptureProfile
        /// Whether this profile describes the open photograph's camera. Always
        /// `.matches` when nothing is open: there is nothing to check against.
        let applicability: IRCaptureProfileApplicability

        var id: IRCaptureProfileID { profile.id }

        /// Whether selecting it would be accepted.
        var isApplicable: Bool { applicability.isApplicable }

        /// Whether this is a profile the application ships rather than one a
        /// person defined.
        var isBuiltin: Bool { profile.id.isReserved }

        /// Why it may not be applied, in words, or `nil` when it may.
        var refusalDescription: String? {
            applicability.error.flatMap { $0.failureReason ?? $0.errorDescription }
        }
    }

    /// Every profile, ordered for a menu, each paired with whether it fits the
    /// open photograph.
    ///
    /// Built-in profiles first, then user profiles by display name. A
    /// mismatched profile is **listed and disabled**, not hidden: a person who
    /// created a profile for another body should see that it exists and why it
    /// cannot be used here, rather than watch it vanish and wonder whether it
    /// was saved at all.
    var captureProfileChoices: [CaptureProfileChoice] {
        let metadata: RAWMetadata? = {
            guard case .decoded(let loaded) = status else { return nil }
            return loaded.metadata
        }()
        return registry.profilesForDisplay.map { profile in
            CaptureProfileChoice(
                profile: profile,
                applicability: metadata.map { profile.applicability(to: $0) } ?? .matches
            )
        }
    }

    /// The camera the open photograph records, where it records one.
    ///
    /// Offered so that creating a profile while a photograph is open can
    /// **prefill** the make and model a person would otherwise retype from the
    /// inspector. It is convenience and nothing more: nothing in this project
    /// reads a camera name and creates or selects a profile from it. A camera
    /// says nothing about which filter was on the lens or what was done to the
    /// sensor. See
    /// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 4.
    ///
    /// The decoder's normalised spellings are preferred where it has them, for
    /// the same reason `IRCameraMatch` prefers them: they are the spellings a
    /// later match is most likely to agree with.
    var currentCameraIdentity: (make: String, model: String)? {
        guard case .decoded(let loaded) = status else { return nil }
        let identity = loaded.metadata.identity
        guard let make = Self.nonEmpty(identity.normalizedMake ?? identity.make),
              let model = Self.nonEmpty(identity.normalizedModel ?? identity.model)
        else { return nil }
        return (make: make, model: model)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Installs a new set of profile definitions, and re-resolves the open
    /// photograph against it.
    ///
    /// The one path by which the registry is replaced. `IRCaptureProfileLibrary`
    /// owns the definitions and calls this when a profile is created, edited or
    /// deleted, so a document never reads the profile folder and never holds a
    /// registry built at a different moment from every other document's.
    ///
    /// ## What it does not do
    ///
    /// It does not change a single adjustment. A white balance, an orientation,
    /// a channel mix and an exposure belong to one photograph, and no profile
    /// operation may reach them — not even the one that replaces the definition
    /// this photograph is rendered under.
    ///
    /// It does not select a profile either. The photograph keeps the identity
    /// it had; only the definition that identity resolves to may have changed.
    /// And it writes nothing: the canonical state is unchanged, so there is
    /// nothing new to make durable. Renaming a profile must not rewrite a
    /// single sidecar.
    func updateCaptureProfiles(_ registry: IRCaptureProfileRegistry) {
        self.registry = registry
        reresolveCaptureProfile()
    }

    /// Re-renders the open photograph under the current definition of the
    /// profile it already names, when that definition has changed.
    ///
    /// ```text
    /// definition unchanged      nothing happens
    /// definition changed        re-render, so the inspector stops showing stale
    ///                           metadata; a changed processing basis re-prepares
    /// profile no longer stored  the resolved definition is kept in memory
    /// ```
    ///
    /// The last row is the one worth stating. A profile deleted while a
    /// photograph is open leaves that photograph rendering exactly as it was —
    /// the resolved definition is a value this document holds — and the
    /// consequence appears the next time the file is opened, which is where a
    /// refusal with a remedy belongs. Silently switching it to another profile
    /// would change the picture on screen and say nothing.
    ///
    /// A definition edited so that it no longer describes this camera is
    /// treated the same way, and for the same reason: the photograph on screen
    /// was rendered under a profile that did apply, and withdrawing it
    /// retroactively would take a picture away in response to somebody typing
    /// in a different window.
    private func reresolveCaptureProfile() {
        guard case .decoded(var loaded) = status, loaded.isAdjustable,
              let renderer, let preparer, let source = loaded.source,
              let resolved = try? registry.profile(for: loaded.state.captureProfile),
              resolved != loaded.captureProfile
        else { return }

        if let refusal = resolved.applicability(to: loaded.metadata).error {
            Self.log(refusal, path: "Capture profile", url: loaded.url)
            return
        }

        loaded.captureProfile = resolved
        status = .decoded(loaded)
        requestWork(
            for: loaded.state,
            captureProfile: resolved,
            source: source,
            renderer: renderer,
            preparer: preparer
        )
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

    /// The user's exposure compensation for the open file — the **requested**
    /// value, ahead of the rendered preview while a render is pending — or
    /// `.neutral` when nothing is open.
    var exposureAdjustment: UserExposureAdjustment {
        guard case .decoded(let loaded) = status else { return .neutral }
        return loaded.adjustments.exposure
    }

    /// The user's infrared white balance for the open file — the
    /// **requested** decision, ahead of the rendered preview while a
    /// preparation is running — or `.defaultNeutralPatch` when nothing is
    /// open.
    var whiteBalanceAdjustment: UserWhiteBalanceAdjustment {
        guard case .decoded(let loaded) = status else { return .defaultNeutralPatch }
        return loaded.adjustments.whiteBalance
    }

    /// The active image area of the open file, in samples, or `nil` when there
    /// is nothing a patch could be picked from.
    ///
    /// The coordinates a picked patch is a fraction of. A view needs them to
    /// size a patch in sensor samples rather than in preview pixels, and to
    /// draw the overlay for the patch currently in force.
    var activeAreaSize: (width: Int, height: Int)? {
        guard case .decoded(let loaded) = status, let base = loaded.base else { return nil }
        return (width: base.activeAreaWidth, height: base.activeAreaHeight)
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
    var adjustmentSaveFailure: PhotographProcessingPersistenceError? {
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
        open(url, captureProfileOverride: nil)
    }

    /// The open above, plus the one thing a recovery needs: a capture profile
    /// that replaces the one the sidecar names.
    ///
    /// Private, because the only caller is
    /// `useUncalibratedCaptureProfile()`. An override is an **explicit user
    /// edit** — "open this photograph under that profile instead" — and it is
    /// not something an ordinary open may do, because an ordinary open that
    /// substituted a profile would be the silent fallback this project refuses.
    private func open(_ url: URL, captureProfileOverride: IRCaptureProfileID?) {
        decodeTask?.cancel()
        handOverCurrentDocument()
        generation += 1
        status = .decoding(url)
        // At most one open is ever waiting, and it is always the newest one: a
        // superseded deferred open is simply replaced here, which is how
        // "newest user open wins" survives the wait.
        deferredOpen = nil

        guard !isSettling(url) else {
            deferredOpen = DeferredOpen(
                url: url,
                generation: generation,
                captureProfileOverride: captureProfileOverride
            )
            return
        }
        startDecoding(
            url, generation: generation, captureProfileOverride: captureProfileOverride
        )
    }

    /// The profile a photograph refused by its saved capture profile can be
    /// reopened with, or `nil` when nothing is in that state.
    ///
    /// Always the built-in uncalibrated profile, because it is the one profile
    /// that is guaranteed to exist and to apply to any camera. It is offered
    /// rather than applied: a substitution nobody asked for is exactly what
    /// `Status.captureProfileUnusable` exists to prevent.
    var captureProfileRecovery: IRCaptureProfile? {
        guard case .captureProfileUnusable = status else { return nil }
        return registry.uncalibratedProfile
    }

    /// Reopens a photograph whose saved capture profile could not be used,
    /// under the built-in uncalibrated profile.
    ///
    /// **An explicit user edit, not a fallback.** The distinction is the whole
    /// of `Status.captureProfileUnusable`: nothing substitutes a profile on its
    /// own, and this runs because a person pressed something that said what it
    /// would do.
    ///
    /// What follows is the ordinary lifecycle and nothing special. The
    /// photograph is opened with the new profile and the **saved adjustments
    /// unchanged** — the white balance, orientation, channel mix and exposure
    /// are the user's and a profile problem is no reason to touch them — the
    /// owned pipeline renders it, and the sidecar is written once that render
    /// has succeeded. A render that refuses writes nothing, as ever.
    func useUncalibratedCaptureProfile() {
        guard case .captureProfileUnusable(let url, _) = status else { return }
        open(url, captureProfileOverride: .builtinUncalibrated)
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
    private func startDecoding(
        _ url: URL, generation: Int, captureProfileOverride: IRCaptureProfileID? = nil
    ) {
        let decoder = self.decoder
        let store = self.store
        let registry = self.registry
        let render = self.render
        let prepareSource = self.prepareSource
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
                registry: registry,
                captureProfileOverride: captureProfileOverride,
                render: render,
                prepareSource: prepareSource,
                previewPolicy: previewPolicy
            ) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.apply(
                    outcome,
                    generation: generation,
                    captureProfileOverride: captureProfileOverride
                )
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
        startDecoding(
            deferred.url,
            generation: deferred.generation,
            captureProfileOverride: deferred.captureProfileOverride
        )
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
        defer {
            renderer = nil
            preparer = nil
        }
        guard case .decoded(let loaded) = status else {
            cancelAllWork()
            return
        }

        switch loaded.persistence {
        case .pending:
            guard let renderer, let preparer, let source = loaded.source else { return }
            // Deliberately not cancelled — either slot. This is the whole
            // hand-over, and it now covers both costs: a user who picks a
            // neutral patch and immediately opens the next photograph has
            // made a decision whose only route to disk runs through a heavy
            // preparation *and* the render after it.
            settling[generation] = SettlingDocument(
                url: loaded.url,
                requested: loaded.state,
                source: source,
                captureProfile: loaded.captureProfile,
                preparer: preparer,
                renderer: renderer
            )

        case .renderRefused:
            cancelAllWork()
            record(
                UnsavedAdjustment(
                    url: loaded.url, state: loaded.state, reason: .renderRefused
                )
            )

        case .saveFailed(let error):
            cancelAllWork()
            record(
                UnsavedAdjustment(
                    url: loaded.url,
                    state: loaded.state,
                    reason: .saveRefused(error)
                )
            )

        case .unchanged, .saved:
            // Nothing is at stake. Any work still unwinding here is for a
            // state that was already superseded or already written.
            cancelAllWork()
        }
    }

    /// Abandons both slots' work for the document being left.
    private func cancelAllWork() {
        renderer?.cancelAll()
        preparer?.cancelAll()
    }

    /// Records a decision that did not reach disk, and says so in the log.
    private func record(_ unsaved: UnsavedAdjustment) {
        unsavedAdjustments.append(unsaved)
        Log.ui.error(
            """
            Left \(unsaved.url.lastPathComponent, privacy: .public) with unsaved \
            settings \(unsaved.adjustmentDescription, privacy: .public): \
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
        store: any PhotographProcessingStore,
        registry: IRCaptureProfileRegistry,
        captureProfileOverride: IRCaptureProfileID?,
        render: PreviewRender,
        prepareSource: SourcePreparation,
        previewPolicy: PreviewResolutionPolicy
    ) -> Result<Loaded, OpenFailure>? {
        var state: PhotographProcessingState
        do {
            // `nil` is the ordinary case: no sidecar, so no saved decisions
            // and no saved profile selection, so the default record — the
            // built-in uncalibrated profile and no adjustments. It is the only
            // thing that becomes `.none`; a record that exists and cannot be
            // read never does.
            state = try store.load(for: url) ?? .none
        } catch {
            log(error, path: "Saved settings", url: url)
            return .failure(.adjustments(DocumentAdjustmentError(url: url, failure: error)))
        }

        // A recovery: the user has asked for this photograph under a different
        // profile from the one its sidecar names. It replaces **only** the
        // profile half — every adjustment the record carries is theirs and is
        // untouched — and the resulting state then travels the ordinary road,
        // resolved, rendered, and written once it has rendered.
        if let captureProfileOverride {
            state.captureProfile = captureProfileOverride
        }

        // Resolved **before** the file is decoded, and for the same reason the
        // sidecar is read before it: the profile chooses the camera-to-working
        // transform, so it is part of the document's opening state rather than
        // something applied afterwards. There is no first render under the
        // built-in profile followed by a switch to the saved one.
        //
        // Resolving before the decode also means a photograph whose profile is
        // missing costs no decode at all to find that out.
        let captureProfile: IRCaptureProfile
        do {
            captureProfile = try registry.profile(for: state.captureProfile)
        } catch let error as IRCaptureProfileError {
            log(error, path: "Capture profile", url: url)
            return .failure(
                .captureProfile(DocumentCaptureProfileError(url: url, failure: error))
            )
        } catch {
            // `profile(for:)` throws exactly one error type, so this is
            // unreachable. It is written rather than forced, because a `try!`
            // here would turn a future widening of that contract into a crash.
            log(error, path: "Capture profile", url: url)
            return .failure(
                .captureProfile(
                    DocumentCaptureProfileError(
                        url: url, failure: .unknownProfile(id: state.captureProfile)
                    )
                )
            )
        }

        guard let owned = ownedOutcome(
            for: url,
            using: decoder,
            adjustments: state.adjustments,
            captureProfile: captureProfile,
            render: render,
            prepareSource: prepareSource,
            previewPolicy: previewPolicy,
            cancellation: .enclosingTask
        ) else { return nil }

        // A profile that does not describe this camera refuses the whole
        // document, whatever the diagnostic decode managed. The alternative —
        // opening it and quietly processing under a profile made for another
        // body — is the silent substitution this milestone exists to prevent.
        if case .profileRefused(let error) = owned {
            return .failure(
                .captureProfile(DocumentCaptureProfileError(url: url, failure: error))
            )
        }

        let legacy = legacyReference(for: url, using: decoder)

        // The six cases, written out as the six cases. Metadata comes from
        // whichever path read it — both paths read the same file with the same
        // decoder — and the owned one is preferred because it belongs to the
        // image the workspace shows.
        switch (owned, legacy) {
        case (.rendered(let base, let source, let preview), _):
            return .success(
                Loaded(
                    url: url,
                    metadata: source.metadata,
                    legacy: legacy,
                    base: base,
                    source: source,
                    isAdjustable: true,
                    state: state,
                    captureProfile: captureProfile,
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
                    base: nil,
                    source: source,
                    isAdjustable: false,
                    state: state,
                    captureProfile: captureProfile,
                    owned: .unavailable(failure)
                )
            )

        case (.unprepared(let failure), .decoded(let decoded, _)):
            return .success(
                Loaded(
                    url: url,
                    metadata: decoded.metadata,
                    legacy: legacy,
                    base: nil,
                    source: nil,
                    isAdjustable: false,
                    state: state,
                    captureProfile: captureProfile,
                    owned: .unavailable(failure)
                )
            )

        case (.unrenderable(_, let ownedFailure), .unavailable(let legacyFailure)),
             (.unprepared(let ownedFailure), .unavailable(let legacyFailure)):
            return .failure(
                .raw(DocumentOpenError(url: url, owned: ownedFailure, legacy: legacyFailure))
            )

        case (.profileRefused(let refusal), _):
            // Handled above, before the diagnostic decode ran, so this is
            // unreachable today. It is written out rather than defaulted — and
            // as the same refusal rather than as a trap — so that a future
            // outcome can neither fall through it silently nor crash here.
            return .failure(
                .captureProfile(DocumentCaptureProfileError(url: url, failure: refusal))
            )
        }
    }

    /// Prepares and renders the application-owned pipeline, keeping the
    /// phases distinguishable in the result.
    ///
    /// ```text
    /// prepareBase     decode → normalise                    (the file)
    /// prepareSource   the SAVED white balance → … → reduce  (the user's patch)
    /// render          the SAVED mix, orientation, exposure  (the rest)
    /// ```
    ///
    /// A failure is reported, never replaced by the LibRaw image. Every error
    /// the chain can raise is `LocalizedError`, so the message a user sees
    /// names the stage that actually refused — an unsupported sensor layout, a
    /// patch that measured no samples of a colour plane, an orientation code we
    /// do not model — instead of a generic "preview failed". The error value
    /// itself is kept too, which is what lets the caller tell a preparation
    /// refusal from a render one.
    ///
    /// Exactly one preparation and one render happen here, with the
    /// adjustments the caller loaded. **The saved white balance is used for
    /// the first preparation there is**: there is no pass with the default
    /// patch, so a photograph saved with a picked patch never appears on
    /// screen balanced from the middle of the frame, not even for a frame.
    ///
    /// - Returns: the outcome, or `nil` when the work was cancelled.
    ///   Cancellation is not a failure and must never be shown as one.
    private nonisolated static func ownedOutcome(
        for url: URL,
        using decoder: RAWDecoder,
        adjustments: ImageAdjustments,
        captureProfile: IRCaptureProfile,
        render: PreviewRender,
        prepareSource: SourcePreparation,
        previewPolicy: PreviewResolutionPolicy,
        cancellation: ProcessingCancellation
    ) -> OwnedOutcome? {
        let pipeline = WorkspacePreviewPipeline()

        let base: NormalizedRAWSource
        do {
            base = try pipeline.prepareBase(decoding: url, using: decoder)
        } catch is CancellationError {
            // `prepareBase` polls nothing, so this is unreachable today. It is
            // written because the contract, not the current implementation, is
            // what callers rely on — and a cancelled open is not a failed one.
            return nil
        } catch {
            log(error, path: "Owned preparation", url: url)
            return .unprepared(RAWPathFailure(stage: .ownedPreparation, error))
        }

        // Between the decode and the first processing stage, because that is
        // the earliest point at which the question can be asked and the latest
        // at which the answer still matters. The make and model only exist
        // after the file has been read; nothing has yet been processed under a
        // profile that may not describe this camera.
        //
        // The built-in uncalibrated profile matches everything, so this is a
        // no-op for every photograph in the application as it ships.
        if let refusal = captureProfile.applicability(to: base.metadata).error {
            log(refusal, path: "Capture profile", url: url)
            return .profileRefused(refusal)
        }

        let source: WorkspacePreviewPipeline.Source
        do {
            source = try prepareSource(
                base, adjustments.whiteBalance, captureProfile, previewPolicy, cancellation
            )
        } catch is CancellationError {
            return nil
        } catch {
            log(error, path: "Owned preparation", url: url)
            return .unprepared(RAWPathFailure(stage: .ownedPreparation, error))
        }

        do {
            let preview = try render(source, captureProfile, adjustments, cancellation)
            return .rendered(base, source, preview)
        } catch is CancellationError {
            return nil
        } catch {
            log(error, path: "Owned render", url: url)
            // The normalised mosaic is deliberately not carried out of here.
            // Nothing can be re-rendered from this file, so there is nothing
            // for 49 MB of retained samples to do.
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

    // MARK: - Exposure adjustment

    /// Chooses the exposure compensation and re-renders.
    ///
    /// The first continuous adjustment, and it goes through exactly the path
    /// the discrete ones do: the complete record is updated, persistence
    /// becomes `.pending`, and one request goes to the coalescing renderer. A
    /// slider drag is a burst of such calls; the renderer collapses it to the
    /// newest state, and only that state can be installed or written. There is
    /// no timer, no debounce and no exposure-specific queue here, deliberately.
    ///
    /// No arithmetic happens here either. The value is already validated by
    /// its type, and what it does to a pixel is the display renderer's
    /// business.
    ///
    /// Asking for the exposure already in force does nothing at all.
    func setExposure(_ exposure: UserExposureAdjustment) {
        adjust { $0.exposure = exposure }
    }

    /// Returns the exposure to `0 EV`, and changes nothing else.
    ///
    /// Like the orientation's reset, it is itself a decision and is saved once
    /// it has rendered; and like it, it leaves the other adjustments exactly
    /// as they were.
    func resetExposure() { setExposure(.neutral) }

    // MARK: - White-balance adjustment

    /// Chooses which samples the infrared white balance is measured from, and
    /// re-prepares.
    ///
    /// The first adjustment that is upstream of demosaicing, and it goes
    /// through exactly the path the other three do: the complete record is
    /// updated, persistence becomes `.pending`, and one request goes to a
    /// coalescing slot. It is simply a different slot, because the work is a
    /// different cost. A burst of picks collapses to the newest patch, and the
    /// ones in between are never estimated at all.
    ///
    /// It is a **state, not an operation**: this replaces whatever was asked
    /// for before, and no patch is ever measured relative to a previous one.
    /// The gains are re-derived from the normalised mosaic every time, so
    /// white balances no more compose than mixes do.
    ///
    /// Asking for the white balance already in force does nothing at all.
    func setWhiteBalance(_ whiteBalance: UserWhiteBalanceAdjustment) {
        adjust { $0.whiteBalance = whiteBalance }
    }

    /// Returns the white balance to the application's default centred patch,
    /// and changes nothing else.
    ///
    /// Exactly the historical behaviour, because `.defaultNeutralPatch`
    /// resolves through the rule this project has always used — not "no white
    /// balance", which the pipeline has never done and which this button does
    /// not offer. Like every other reset it is itself a decision, saved once
    /// it has rendered, and it leaves the orientation, the channel mix and the
    /// exposure exactly as they were.
    func resetWhiteBalance() { setWhiteBalance(.defaultNeutralPatch) }

    /// Picks a neutral patch around a point the user clicked, in **active-area
    /// unit coordinates**.
    ///
    /// The view has already done the two things a view is the only thing that
    /// can do: work out where inside its bounds the aspect-fitted image
    /// actually is, and undo the displayed orientation. What arrives here is a
    /// fraction of the sensor's own active area, in sensor axes, and what is
    /// stored is the region `UserWhiteBalanceAdjustment.pickedRegion` builds
    /// from it — never a view coordinate, a preview pixel or a `CGPoint`.
    ///
    /// Does nothing when there is no adjustable document, or when the point
    /// cannot make a region: a photograph too small to hold a patch, or a
    /// coordinate that is not finite. A refusal here is silent because the
    /// only way to reach it is a click the geometry already rejected.
    func pickNeutralPatch(atX x: Double, y: Double) {
        guard case .decoded(let loaded) = status, loaded.isAdjustable,
              let base = loaded.base
        else { return }

        guard let region = try? UserWhiteBalanceAdjustment.pickedRegion(
            atX: x,
            y: y,
            activeAreaWidth: base.activeAreaWidth,
            activeAreaHeight: base.activeAreaHeight
        ) else { return }

        setWhiteBalance(.neutralPatch(region))
    }

    // MARK: - Capture-profile selection

    /// Selects the capture profile this photograph is processed under.
    ///
    /// A **decision about the photograph**, and it travels the same road every
    /// adjustment does: the complete canonical record is updated, persistence
    /// becomes `.pending`, and the profile reaches the sidecar only once the
    /// state it belongs to has actually rendered. It is not an adjustment, and
    /// it is deliberately not a field of `ImageAdjustments`; it is the other
    /// half of `PhotographProcessingState`.
    ///
    /// ## What it costs, and why that is asked of the data
    ///
    /// ```text
    /// basis unchanged   the pixels cannot differ — re-render for provenance
    /// basis changed     the camera-to-working transform differs — re-prepare
    /// ```
    ///
    /// The question is asked of `IRCaptureProcessingBasis`, which is the only
    /// part of a profile that reaches a pixel, and it is asked of the **source**
    /// rather than of the previous selection — the two disagree exactly when it
    /// matters, which is while an earlier preparation is still running.
    ///
    /// A metadata-only change therefore costs one reduced-resolution render,
    /// not a re-preparation, and the inspector still updates: a preview carries
    /// the profile it was rendered under. A change of basis costs the heavy
    /// path, the same one a new neutral patch takes, because the transform runs
    /// upstream of the reduction. No third cache and no third slot. See
    /// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 8.
    ///
    /// ## Nothing is copied into the adjustments
    ///
    /// Selecting a profile changes no adjustment. There is no live coupling by
    /// which a later profile change would overwrite an exposure the user set,
    /// and no recommendation is applied on selection — this build's profiles
    /// carry none at all. See Decision 11.
    ///
    /// - Parameter profile: a profile from `availableCaptureProfiles`. Asking
    ///   for the one already selected does nothing at all.
    func setCaptureProfile(_ profile: IRCaptureProfile) {
        guard case .decoded(let loaded) = status,
              loaded.isAdjustable,
              loaded.captureProfile != profile
        else { return }
        // A profile that does not describe this camera is refused here rather
        // than applied and refused later: the document keeps the profile it
        // has, and nothing is rendered, requested or written.
        if let refusal = profile.applicability(to: loaded.metadata).error {
            Self.log(refusal, path: "Capture profile", url: loaded.url)
            return
        }
        adjustState(profile: profile) { $0.captureProfile = profile.id }
    }

    // MARK: - Exporting

    /// The snapshot an export started now would use, or `nil` when there is
    /// nothing this application can export.
    ///
    /// Two things make it `nil`, and both are refusals rather than omissions:
    /// no document, and a document whose **application-owned** pipeline did
    /// not produce an image. The LibRaw diagnostic reference is deliberately
    /// not a fallback — it is a different decode with different processing,
    /// and exporting it would quietly hand the user a file this pipeline did
    /// not make. See `docs/decisions/0012-independent-raw-paths.md`.
    ///
    /// The adjustments are the **current canonical** ones, which is the whole
    /// point of reading them here: they are what the user has asked for, not
    /// what the last preview managed to display and not what the sidecar last
    /// accepted. An export requested while a preview render is still in
    /// flight, or while a save has failed, uses the state on the controls.
    var exportRequest: ExportRequest? {
        guard case .decoded(let loaded) = status, loaded.isAdjustable else { return nil }
        return ExportRequest(
            rawURL: loaded.url,
            // Resolved, and resolved to the profile the document currently has
            // — not looked up again inside the export, and not the one the
            // preview on screen happens to have been rendered under. An export
            // requested after a profile change but before its render lands
            // therefore uses the new profile, for exactly the reason it uses a
            // newly picked neutral patch: the canonical state is what is
            // exported.
            captureProfile: loaded.captureProfile,
            adjustments: loaded.adjustments
        )
    }

    /// Whether an export is running.
    var isExporting: Bool { exportStatus.isRunning }

    /// Whether the export control should be available.
    ///
    /// One export at a time, and the control is simply unavailable while one
    /// runs. No queue, and no cancelling the first with the second: both would
    /// be more mechanism than a single-file export needs, and a user who
    /// wants a different rendering can wait for this file and ask again. See
    /// `docs/decisions/0018-full-resolution-tiff-export.md`, Decision 10.
    var canExport: Bool { exportRequest != nil && !isExporting }

    /// The filename to suggest in a save panel, by the one rule that owns it.
    var suggestedExportFilename: String? {
        exportRequest.map { ExportDestinationPolicy.suggestedFilename(for: $0.rawURL) }
    }

    /// Renders the current canonical state at full resolution and writes it to
    /// `destination`.
    ///
    /// The snapshot — the RAW URL and the adjustments — is taken **here**, at
    /// the start, and is never consulted again. Everything the user does
    /// afterwards, including opening another photograph, leaves this export
    /// alone; and this export leaves the document alone, including its
    /// sidecar, which it never writes.
    ///
    /// Does nothing when there is nothing to export or an export is already
    /// running. That is the same refusal `canExport` reports, restated where
    /// it is enforced rather than only where it is displayed.
    func exportTIFF(to destination: URL) {
        guard let request = exportRequest, exportTask == nil else { return }

        exportStatus = .exporting(request, destination: destination)

        let decoder = self.decoder
        let run = self.exportRun
        exportTask = Task.detached(priority: .userInitiated) {
            let outcome = Result { try run(request, destination, decoder) }
            await MainActor.run { [weak self] in
                self?.finishExport(outcome, request: request, destination: destination)
            }
        }
    }

    /// Clears a finished export's status.
    ///
    /// Only a finished one: a running export is not something a caller can
    /// dismiss, because the file is still being written.
    func acknowledgeExport() {
        guard !isExporting else { return }
        exportStatus = .idle
    }

    private func finishExport(
        _ outcome: Result<TIFFExportResult, any Error>,
        request: ExportRequest,
        destination: URL
    ) {
        exportTask = nil
        switch outcome {
        case .success(let result):
            Log.export.info(
                """
                Exported \(request.rawURL.lastPathComponent, privacy: .public) to \
                \(result.destination.lastPathComponent, privacy: .public): \
                \(result.diagnosticDescription, privacy: .public)
                """
            )
            exportStatus = .succeeded(result)
        case .failure(let error) where error is CancellationError:
            // Nobody wanted it. No file, no error, nothing to tell the user.
            exportStatus = .idle
        case .failure(let error):
            Self.log(error, path: "Export", url: request.rawURL)
            exportStatus = .failed(
                ExportFailure(request: request, destination: destination, error: error)
            )
        }
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
        adjustState { change(&$0.adjustments) }
    }

    /// The same road, for a change that may touch either half of the canonical
    /// record.
    ///
    /// `adjust` is this with the profile left alone. They are one method
    /// because a photograph has one canonical state and one render request, and
    /// the scheduling question — fast or heavy — is asked of that state rather
    /// than of which control produced it.
    ///
    /// - Parameter profile: the resolved profile the updated state names, when
    ///   the change selects one. `nil` keeps the document's current profile,
    ///   which is what every adjustment does.
    private func adjustState(
        profile: IRCaptureProfile? = nil,
        _ change: (inout PhotographProcessingState) -> Void
    ) {
        guard case .decoded(var loaded) = status, loaded.isAdjustable,
              let renderer, let preparer, let source = loaded.source
        else { return }

        var updated = loaded.state
        change(&updated)
        guard updated != loaded.state else { return }

        let captureProfile = profile ?? loaded.captureProfile
        // The invariant `Loaded` exists to keep: the resolved profile and the
        // identity in the canonical state are assigned together and are never
        // allowed to drift apart.
        guard captureProfile.id == updated.captureProfile else { return }

        // Record the intent immediately, so the controls reflect what the
        // user asked for even while the work is still running — and say, in
        // the same breath, that this state is not on disk. The state that was
        // saved a moment ago is no longer the state on screen, and reporting
        // it as saved would be a claim about the wrong adjustment.
        loaded.state = updated
        loaded.captureProfile = captureProfile
        loaded.persistence = .pending
        status = .decoded(loaded)

        requestWork(
            for: updated,
            captureProfile: captureProfile,
            source: source,
            renderer: renderer,
            preparer: preparer
        )
    }

    /// Asks for whichever of the two costs a complete state needs.
    ///
    /// Split out of `adjustState` so that the **same** scheduling rule serves
    /// a change of state and a change of a profile's *definition*. The two
    /// differ in exactly one respect and it is not this one: an adjustment is a
    /// decision and becomes `.pending`, while a redefinition is not the
    /// photograph's decision at all and leaves persistence alone.
    private func requestWork(
        for state: PhotographProcessingState,
        captureProfile: IRCaptureProfile,
        source: WorkspacePreviewPipeline.Source,
        renderer: PreviewRenderSlot,
        preparer: SourcePreparationSlot
    ) {
        // Which of the two costs this state needs is one question with one
        // answer: does the retained preview already describe the white balance
        // **and** the camera-to-working processing being asked for?
        //
        // Both are upstream of the reduction, and nothing downstream can
        // reproduce either, so they are the same question asked about two
        // stages. It is asked of the **source**, not of the previous state,
        // because those two disagree exactly when it matters. Picking patch B
        // while patch A is still being prepared leaves the source at the
        // original balance, and both patches need the heavy path.
        //
        // Only the processing basis is compared, never the profile's identity:
        // two profiles that share a basis produce identical pixels by
        // construction, so re-preparing between them would be work whose result
        // is already on screen. What such a change does need is a re-render,
        // because the preview carries the profile it was rendered under and the
        // inspector reads it from there.
        let request = SourcePreparationRequest(
            whiteBalance: state.adjustments.whiteBalance, captureProfile: captureProfile
        )
        if source.whiteBalance != request.whiteBalance
            || source.captureProfile.processingBasis != captureProfile.processingBasis {
            // Heavy. The render is deliberately *not* requested here: the
            // source it would use is the wrong one, and rendering it would put
            // the old white balance — or the old camera transform — on screen
            // under the new state's name. The render happens when the
            // preparation lands, for whatever the latest complete state is by
            // then.
            //
            // And only when it is not already on its way. Every change reaches
            // this method, so a change of exposure made while a patch is being
            // prepared arrives here wanting that same patch — and `request`
            // supersedes unconditionally, so asking again would cancel a pass
            // that was about to produce the right answer and start it over. A
            // user dragging the exposure slider during a preparation would
            // restart it on every frame and never see a result.
            //
            // The comparison is on the whole request, so a profile change
            // during a patch preparation does restart it: those two passes
            // would produce different pixels.
            if preparer.target != request {
                preparer.request(request)
            }
        } else {
            // Fast. Any preparation still outstanding is for a state the user
            // has now moved away from — most often by returning to the one
            // already prepared — so it is abandoned rather than left to finish
            // and be discarded on delivery.
            preparer.cancelAll()
            renderer.request(
                PreviewRenderRequest(
                    source: source,
                    captureProfile: captureProfile,
                    adjustments: state.adjustments
                )
            )
        }
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
    private func makeRenderer(url: URL, generation: Int) -> PreviewRenderSlot {
        let render = self.render
        return PreviewRenderSlot(
            work: { request, cancellation in
                try render(
                    request.source, request.captureProfile, request.adjustments, cancellation
                )
            },
            deliver: { [weak self] outcome, request in
                self?.deliver(
                    outcome,
                    state: PhotographProcessingState(
                        captureProfile: request.captureProfile.id,
                        adjustments: request.adjustments
                    ),
                    url: url,
                    generation: generation
                )
            }
        )
    }

    /// Builds the heavy slot for a freshly opened file.
    ///
    /// The closure captures that file's retained **normalised mosaic**, which
    /// is the whole of this milestone: a change of neutral patch re-estimates
    /// and re-demosaics from those samples, and reads nothing. There is no
    /// `URL` and no decoder in the capture, so re-decoding is not something
    /// this path could do by mistake.
    ///
    /// It also captures the file's URL and the generation of the open it
    /// belongs to, for the same reason the render slot does: a delivery has to
    /// find its way back to the right document, or — when that document has
    /// been left — to the settling record that is still finishing its work.
    private func makePreparer(
        base: NormalizedRAWSource, url: URL, generation: Int
    ) -> SourcePreparationSlot {
        let prepareSource = self.prepareSource
        let policy = self.previewPolicy
        return SourcePreparationSlot(
            work: { request, cancellation in
                try prepareSource(
                    base, request.whiteBalance, request.captureProfile, policy, cancellation
                )
            },
            deliver: { [weak self] outcome, request in
                self?.deliverPreparedSource(
                    outcome, request: request, url: url, generation: generation
                )
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
        state: PhotographProcessingState,
        url: URL,
        generation: Int
    ) {
        if generation == self.generation {
            applyReprocessed(outcome, state: state, for: url)
        } else if let document = settling[generation] {
            settle(document, generation: generation, outcome: outcome, state: state)
        }
    }

    /// Routes a settled white-balance preparation to the document it was made
    /// for, and starts the render that must follow it.
    ///
    /// ```text
    /// the document is still on screen   install the source, render the LATEST state
    /// the document has been left        install it, render its frozen state, then save
    /// neither                           nothing; there is nowhere for it to go
    /// ```
    ///
    /// Routing is by **generation**, exactly as a render's is: the same file
    /// can be opened twice, and the first open's late preparation must not
    /// replace the second open's source merely because the paths match.
    private func deliverPreparedSource(
        _ outcome: Result<WorkspacePreviewPipeline.Source, Error>,
        request: SourcePreparationRequest,
        url: URL,
        generation: Int
    ) {
        if generation == self.generation {
            applyPreparedSource(outcome, request: request, for: url)
        } else if let document = settling[generation] {
            settlePreparedSource(
                document, generation: generation, outcome: outcome, request: request
            )
        }
    }

    /// Installs a re-prepared reduced preview and asks for the render that
    /// turns it into a picture — unless a newer white balance has already
    /// superseded it.
    ///
    /// The guard is the same one every delivery uses, asked about the one
    /// field this work depended on: the white balance the preparation was made
    /// for must still be the one the user wants. A superseded preparation
    /// installs nothing, renders nothing and saves nothing — patch A finishing
    /// after patch B was asked for leaves no trace at all.
    ///
    /// The render that follows is requested with **`loaded.adjustments`**, the
    /// latest complete state, and not with a state captured when the patch was
    /// picked. That is the whole answer to "what happens to an exposure change
    /// made while a patch was being prepared": it is in the result, because
    /// the result is a render of what the user currently wants, from the
    /// source that now describes their patch.
    ///
    /// Nothing is saved here. `.pending` survives the preparation and ends
    /// where it always has — where a render succeeds and is installed —
    /// because a white balance that estimated cleanly and then failed to
    /// demosaic, orient or encode is not a state worth restoring on the next
    /// launch. See `docs/decisions/0013-adjustment-sidecar.md`.
    private func applyPreparedSource(
        _ outcome: Result<WorkspacePreviewPipeline.Source, Error>,
        request: SourcePreparationRequest,
        for url: URL
    ) {
        // Both halves of the request are checked, because both decide what the
        // prepared pixels are. A source prepared under profile P1 must not
        // install into a document that has since moved to a P2 with a different
        // basis — those are different pixels, and labelling them with P2 would
        // be precisely the silent substitution this milestone refuses.
        guard case .decoded(var loaded) = status,
              loaded.url == url,
              loaded.adjustments.whiteBalance == request.whiteBalance,
              loaded.captureProfile == request.captureProfile,
              let renderer
        else { return }

        switch outcome {
        case .success(let source):
            // The previous reduced preview is released here, and this one
            // takes its place. A document holds one, never a chain of them.
            loaded.source = source
            status = .decoded(loaded)
            renderer.request(
                PreviewRenderRequest(
                    source: source,
                    captureProfile: loaded.captureProfile,
                    adjustments: loaded.adjustments
                )
            )

        case .failure(let error):
            Self.log(error, path: "Owned white-balance preparation", url: url)
            loaded.owned = .unavailable(RAWPathFailure(stage: .ownedPreparation, error))
            // The retained source is left exactly as it was: the previous
            // white balance is still the one those pixels describe, and a
            // failed estimate must not be allowed to make it look otherwise.
            // Not eligible to be written either, and the sidecar is untouched.
            if case .pending = loaded.persistence {
                loaded.persistence = .renderRefused
            }
            status = .decoded(loaded)
        }
    }

    /// Finishes the heavy half for a document the workspace has left.
    ///
    /// The generalisation ADR 0014's settling needed once an adjustment could
    /// cost two passes. A document left mid-preparation still has both to
    /// make, and it makes them here: the new source is installed into the
    /// settling record, and its **frozen** requested state is rendered from
    /// it. That render's delivery reaches `settle`, which writes the sidecar
    /// and releases the document.
    ///
    /// The frozen state, not the latest one, because there is no latest one:
    /// a settling document has no UI and nothing can change what it was asked
    /// for.
    private func settlePreparedSource(
        _ document: SettlingDocument,
        generation: Int,
        outcome: Result<WorkspacePreviewPipeline.Source, Error>,
        request: SourcePreparationRequest
    ) {
        guard document.requested.adjustments.whiteBalance == request.whiteBalance,
              document.captureProfile == request.captureProfile
        else { return }

        switch outcome {
        case .success(let source):
            var updated = document
            updated.source = source
            settling[generation] = updated
            updated.renderer.request(
                PreviewRenderRequest(
                    source: source,
                    captureProfile: updated.captureProfile,
                    adjustments: updated.requested.adjustments
                )
            )

        case .failure(let error):
            Self.log(error, path: "Owned white-balance preparation", url: document.url)
            record(
                UnsavedAdjustment(
                    url: document.url,
                    state: document.requested,
                    reason: .renderRefused
                )
            )
            // Done: this document's newest state has been refused, so there is
            // nothing left for it to write. Releasing it frees its normalised
            // mosaic and its file, which may be what an open is waiting for.
            release(document)
            settling[generation] = nil
            startDeferredOpenIfReady()
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
        state: PhotographProcessingState,
        for url: URL
    ) {
        // The whole record is compared, profile selection included: a render
        // made under the profile the user has since moved away from is
        // superseded exactly as a render of a superseded exposure is.
        guard case .decoded(var loaded) = status,
              loaded.url == url,
              loaded.state == state
        else { return }

        switch outcome {
        case .success(let preview):
            loaded.owned = .rendered(preview)
            // One record, written once. The capture profile and the four
            // adjustments reach the sidecar together or not at all — a profile
            // selection that landed on disk without the state it was rendered
            // with would reopen showing something nobody ever saw.
            //
            // And only for a render that settles a **decision**. `.pending` is
            // what a decision looks like on its way to disk; a render made for
            // any other reason — a profile whose *definition* was edited in the
            // library, say — has nothing new to make durable, because the
            // canonical state did not change. Renaming a profile must not
            // rewrite a single sidecar.
            if case .pending = loaded.persistence {
                loaded.persistence = write(state, for: url).map {
                    AdjustmentPersistence.saveFailed($0)
                } ?? .saved
            }
        case .failure(let error):
            Self.log(error, path: "Owned re-render", url: url)
            loaded.owned = .unavailable(RAWPathFailure(stage: .ownedRender, error))
            // Not eligible to be written, and the sidecar is untouched: it
            // still holds the last state that actually rendered.
            //
            // Only a **pending** decision is refused, for the reason only a
            // pending decision is written. A render the library asked for
            // because a profile's definition changed does not make a state
            // that was already saved unsaved: the sidecar still holds exactly
            // the state the user decided on, and reporting otherwise would
            // announce a lost edit that does not exist.
            if case .pending = loaded.persistence {
                loaded.persistence = .renderRefused
            }
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
        state: PhotographProcessingState
    ) {
        guard document.requested == state else { return }

        switch outcome {
        case .success:
            if let failure = write(state, for: document.url) {
                record(
                    UnsavedAdjustment(
                        url: document.url, state: state, reason: .saveRefused(failure)
                    )
                )
            }
        case .failure(let error):
            Self.log(error, path: "Owned re-render", url: document.url)
            record(
                UnsavedAdjustment(
                    url: document.url, state: state, reason: .renderRefused
                )
            )
        }

        // This document is done: its newest state has now either been written
        // or refused. Releasing the record releases its reduced preview and,
        // through its heavy slot, its normalised mosaic — and frees its file,
        // which may be what an open is waiting for.
        //
        // The order matters and is the whole fix: the write above has already
        // returned, so an open released here reads a sidecar that no older
        // generation can still change.
        release(document)
        settling[generation] = nil
        startDeferredOpenIfReady()
    }

    /// Releases the slots a settling document no longer needs.
    ///
    /// Both, because either may still be holding something large: the heavy
    /// slot holds that file's normalised mosaic, and the fast slot's pending
    /// request holds its reduced preview.
    private func release(_ document: SettlingDocument) {
        document.preparer.cancelAll()
        document.renderer.cancelAll()
    }

    /// Writes one rendered photograph state to its sidecar.
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
        _ state: PhotographProcessingState, for url: URL
    ) -> PhotographProcessingPersistenceError? {
        do {
            try store.save(state, for: url)
            return nil
        } catch {
            Self.log(error, path: "Saving settings", url: url)
            return error
        }
    }

    private func apply(
        _ outcome: Result<Loaded, OpenFailure>,
        generation: Int,
        captureProfileOverride: IRCaptureProfileID? = nil
    ) {
        // Ignore a result that a newer selection has already superseded.
        guard generation == self.generation else { return }

        switch outcome {
        case .success(var loaded):
            // Only an adjustable file gets slots. A prepared source nothing
            // can be rendered from gets none, so there is no path by which a
            // control could request work that is known to fail — and no file
            // without an image retains a normalised mosaic.
            //
            // The two are built together and released together: `base` is
            // non-nil exactly when the file rendered, which is exactly when
            // `adjustableSource` is.
            if loaded.adjustableSource != nil, let base = loaded.base {
                renderer = makeRenderer(url: loaded.url, generation: generation)
                preparer = makePreparer(
                    base: base, url: loaded.url, generation: generation
                )
            } else {
                renderer = nil
                preparer = nil
            }

            // A recovery is a decision, and it reaches the sidecar the way
            // every decision does: **after** it has rendered. The initial
            // render is that render — it ran with the new profile and the saved
            // adjustments — so there is nothing further to wait for and nothing
            // extra to render. A file that could not be rendered writes
            // nothing, exactly as a refused adjustment writes nothing.
            if captureProfileOverride != nil {
                if loaded.isAdjustable {
                    loaded.persistence = write(loaded.state, for: loaded.url).map {
                        AdjustmentPersistence.saveFailed($0)
                    } ?? .saved
                } else {
                    loaded.persistence = .renderRefused
                }
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

        case .failure(.captureProfile(let error)):
            Log.ui.error(
                """
                Did not open \(error.url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            status = .captureProfileUnusable(error.url, error)
        }
    }
}
