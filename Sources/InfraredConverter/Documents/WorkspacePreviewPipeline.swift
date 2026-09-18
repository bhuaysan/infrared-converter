import CoreGraphics
import Foundation

/// The application-owned preview the workspace shows, and the one place the
/// choices behind it are made.
///
/// ```text
/// decodeMosaic
///     ↓  RAWMosaicNormalizer
/// LinearRAWMosaic                            ← full resolution, RETAINED
///     ↓  UserWhiteBalanceAdjustment.resolvedRegion  (adjustments.whiteBalance)
///     ↓  RAWWhiteBalanceEstimator
///     ↓  RAWWhiteBalancer
/// WhiteBalancedRAWMosaic
///     ↓  RAWDemosaicer (bilinear Bayer)
/// DemosaicedRAWRGBImage
///     ↓  RAWWorkingColorConverter (.sensorRGBIdentityFalseColor)
/// WorkingColorRGBImage                       ← full resolution; released here
///     ↓  SceneLinearPreviewReducer (area average, PreviewResolutionPolicy)
/// SceneLinearPreviewImage                    ← reduced, PRE-MIX, retained
///     ↓  IRChannelMixer (adjustments.channelMix)
/// IRChannelMixedPreviewImage                 ← reduced, post-mix, transient
///     ↓  EffectiveImageOrientation (metadata orientation + user adjustment)
///     ↓  ImageOrienter (one permutation, by the effective orientation)
/// OrientedSceneLinearRGBImage
///     ↓  SceneLinearExposer (adjustments.exposure)
/// ExposedSceneLinearRGBImage
///     ↓  LinearLevelsApplier (adjustments.levels)
/// LeveledLinearRGBImage                      ← linear-light, not scene-linear
///     ↓  GlobalContrastApplier (adjustments.contrast)
/// ToneCurvedRGBImage                         ← no longer linear-light
///     ↓  DisplayPreviewRenderer (hard clipping, sRGB, 8-bit)
/// DisplayEncodedPreviewImage
///     ↓  DisplayPreviewCGImageAdapter
/// CGImage
/// ```
///
/// ## Why the choices live here
///
/// Every stage below requires its decision to be named: there is no default
/// transform, no default mix and no default exposure anywhere in the
/// processing API, deliberately. Something still has to choose for a file the
/// user has only just opened, and that something is the **application layer**,
/// here, where the choices are visible in one place and can be argued with.
///
/// They are not renderer defaults in disguise. Moving any of them into a core
/// API would hide a product decision inside a piece of mathematics.
///
/// ## What each choice is, and is not
///
/// See `docs/decisions/0008-display-preview-rendering.md`, Decision 19.
///
/// - **The channel mix the user asked for**, which for a file with no saved
///   decision is `.identity`. The canonical infrared operation is the
///   red/blue swap, and it is deliberately *not* what a freshly opened file
///   gets: the application cannot know that a given file is an infrared
///   capture, and swapping a visible-light frame's channels would be simply
///   wrong. Identity traverses the creative stage and asks for nothing, which
///   the provenance chain records as exactly that. Only a person can ask for
///   the swap — there is no automatic infrared detection, and this is the
///   layer that would be the place for one if there were.
/// - **`.sensorRGBIdentityFalseColor`.** The IR-safe placement into the
///   working space. The file's own `rgbFromCamera` is visible-light data whose
///   validity for an infrared capture is the open question of this project, so
///   it is not used.
/// - **The white balance the user asked for**, which for a file with no saved
///   decision is `.defaultNeutralPatch` — the deterministic centred square
///   this project has always measured. It is a placeholder, not a scene
///   analysis: nothing verifies that what is in the middle of the frame is
///   neutral, and nothing here is an automatic white balance. A person can
///   replace it by picking a patch, and that decision is persisted as the
///   patch rather than as the multipliers it produced.
/// - **The exposure the user asked for**, which for a file with no saved
///   decision is `0 EV` — the mathematically neutral value, chosen rather
///   than assumed. It is passed to `DisplayPreviewRenderer` unchanged, which
///   applies `× 2^EV` in the linear domain before the range policy. Nothing
///   derives it from the image.
/// - **The orientation the file itself names, plus whatever the user has
///   asked for.** The file's own orientation is read from
///   `RAWMetadata.Geometry.orientation` — the decoder's `flip` mapped once
///   into an application-owned case — and the user's correction is composed
///   onto it by `EffectiveImageOrientation`. There is still no camera-model
///   table, no filename heuristic and no automatic straightening: the only
///   thing that can depart from the metadata is a person. A `flip` value the
///   application does not model is a **typed failure**, not a silent
///   `.upright`.
///
/// ## Two phases, because the mix, the orientation and the exposure are adjustable
///
/// ```text
/// prepareBase    decode → normalise
///                → RETAIN the full-resolution normalised mosaic
///
/// prepareSource  retained mosaic → estimate the user's patch → balance
///                → demosaic → convert → reduce
///                → RETAIN the pre-mix reduced preview
///
/// render         retained pre-mix preview → channel mix → orientation
///                → exposure → levels → contrast
///                → display (range policy, encoding)
/// ```
///
/// Three phases rather than two, and the new line is the white balance. It sits
/// upstream of demosaicing, so it is the one adjustment that cannot be applied
/// to the reduced preview — changing it re-runs `prepareSource` from the
/// retained mosaic, and never the decode. `prepareBase` runs once per open;
/// `prepareSource` runs once per open and once per patch; `render` runs for
/// every adjustment there is. See
/// `docs/decisions/0019-interactive-white-balance.md`.
///
/// The retained source is **pre-creative**, and that is the load-bearing part.
/// Changing any adjustment reruns the last three stages only, from the
/// unmixed, unoriented image — never from the previous result. Nothing
/// decodes, normalises, white-balances, demosaics, converts or reduces again;
/// no mix is ever composed onto another, and no orientation is ever applied on
/// top of another. Both facts have the same shape, and both are structural
/// rather than remembered: the retained buffer's type is the pre-mix one, so
/// there is no overload through which a second mix could reach it.
///
/// One render request is one complete state. `render` is never asked for "the
/// new mix" or "the new orientation" — it is asked for the whole record — so a
/// burst of changes to either control collapses to one newest state and
/// nothing in between reaches the screen or the sidecar. See
/// `docs/decisions/0016-interactive-channel-mixer.md`.
///
/// None of this is a colour claim. The result is displayable, which is a
/// strictly weaker property than correct.
///
/// ## Two resolutions, and which one is the truth
///
/// ```text
/// full resolution     the processing truth; transient, rebuilt from the file
/// preview resolution  the interactive working representation; retained
/// ```
///
/// `prepare` runs the RAW path at sensor resolution — decoding, normalising,
/// white-balancing and demosaicing a mosaic is not something a smaller buffer
/// can stand in for — and reduces exactly once, at the point where the working
/// representation has just been established. What it keeps is the reduced
/// image; the full-resolution chain goes out of scope with the call.
///
/// The canonical editing state is unchanged and is **not** these pixels:
///
/// ```text
/// the RAW file  +  ImageAdjustments
/// ```
///
/// The reduced preview is a cache derived from those two. A full-resolution
/// render — for export, when there is one — will start from the file again. It
/// will not, and must not, start here. See
/// `docs/decisions/0015-reduced-resolution-preview.md`.
///
/// ## Cost
///
/// On the CPU, with no cache. `prepare` is the expensive half and runs once
/// per file; `render` is the interactive half and works on the reduced buffer
/// only — on the E-PL3 fixture, 3.1 megapixels rather than 12.3. Both belong
/// off the main thread, and `DocumentState` runs them there.
struct WorkspacePreviewPipeline {

    /// The creative mix a file with no saved decision gets. See the note
    /// above: the red/blue swap is a claim about the photograph, and nothing
    /// in this application is entitled to make it on a user's behalf.
    ///
    /// It is expressed as the **adjustment** rather than as an `IRChannelMix`,
    /// because that is what it now is: the initial value of a field in the
    /// canonical editing state, which the first render then applies like any
    /// other. It is not a fallback inside a processing stage, and no
    /// processing entry point has a default mix.
    static let initialChannelMix = UserChannelMixAdjustment.identity

    /// The white balance a file with no saved decision gets.
    ///
    /// Expressed as the **adjustment**, like the mix and the exposure, because
    /// that is what it now is: the initial value of a field in the canonical
    /// editing state, which the first preparation then resolves like any other.
    /// It is not a fallback inside a processing stage — no processing entry
    /// point has a default patch any more.
    static let initialWhiteBalance = UserWhiteBalanceAdjustment.initial

    /// The capture profile a file with no saved selection gets.
    ///
    /// `builtin.uncalibrated` — the profile whose processing basis is exactly
    /// the identity false-colour axis assignment every build of this
    /// application has used. It is what a historical sidecar migrates to, and
    /// what a photograph with no sidecar starts on, for the same reason in both
    /// cases: it is the only camera-to-working processing this project has ever
    /// done, and naming it is more honest than leaving it unstated. See
    /// `docs/decisions/0020-ir-capture-profile-foundation.md`.
    ///
    /// It is not a recommendation. Nothing here inspects the camera, the
    /// filename or the metadata to choose a profile — that would be exactly the
    /// automatic selection this milestone refuses.
    static let initialCaptureProfile = IRCaptureProfile.builtinUncalibrated

    /// The camera-to-working transform a freshly opened file gets.
    ///
    /// Derived from the initial profile's processing basis rather than named
    /// again. A second literal would be a second decision that could drift from
    /// the profile's without anything failing.
    static let initialTransform = IRCaptureProfile.builtinUncalibrated
        .cameraToWorkingTransform

    /// How large the interactive preview a freshly opened file gets may be.
    ///
    /// A product decision like every other choice on this type, spelled out
    /// here rather than defaulted inside a processing stage — and injectable,
    /// so a test can ask for a limit small enough to exercise the reduction on
    /// a modest image.
    static let previewPolicy = PreviewResolutionPolicy.workspace

    /// The orientation a file gets when its metadata names one this
    /// application models, or `nil` when it does not.
    ///
    /// The one place the workspace's *reading* of orientation metadata lives.
    /// It is never a correction of it: no camera model, no filename and no
    /// heuristic takes part, and nothing here can make an upright-recorded
    /// photograph rotate. Only a user can do that, and that is the separate
    /// term in `effectiveOrientation(for:adjustments:)`.
    static func orientation(for metadata: RAWMetadata) -> RAWImageOrientation? {
        RAWWorkingImagePipeline.orientation(for: metadata)
    }

    /// The file's recorded orientation and the user's correction, kept
    /// distinct and combined into the single orientation the pixels get.
    ///
    /// - Throws: `OrientationError.unsupportedDecoderOrientation` when the
    ///   decoder reported a `flip` this application does not model. Reading
    ///   an unmodelled code as upright would turn a field we could not parse
    ///   into a claim about the photograph — and would then silently let the
    ///   user's adjustment compose onto that invented value.
    static func effectiveOrientation(
        for metadata: RAWMetadata,
        adjustments: ImageAdjustments
    ) throws -> EffectiveImageOrientation {
        try RAWWorkingImagePipeline.effectiveOrientation(
            for: metadata, adjustments: adjustments
        )
    }

    /// What the display stage does with values outside `0...1`. Not an
    /// adjustment: exposure and levels change which values those are, never
    /// this.
    static let displayRangePolicy = DisplayRangePolicy.hardClipToDisplayRange

    /// The encoding the display stage produces. Not an adjustment either.
    static let displayEncoding = DisplayEncoding.sRGB

    /// The display settings every interactive render uses.
    ///
    /// A constant rather than a function of the adjustments, and that is the
    /// visible trace of this milestone's boundary change. It used to carry
    /// `exposureEV`, because the display renderer applied exposure in the same
    /// pass that it clipped and encoded. Exposure and levels are now stages of
    /// their own, upstream, so nothing a user chooses reaches these settings —
    /// they are the application's two fixed destination choices and nothing
    /// more. See `docs/decisions/0026-linear-levels.md`.
    static let displaySettings = DisplayRenderSettings(
        rangePolicy: displayRangePolicy, encoding: displayEncoding
    )

    /// Decodes a RAW file and normalises its mosaic, and stops.
    ///
    /// The first of the three phases, and the only one that reads the file.
    /// What it produces is retained for as long as the document is open, so
    /// that a change of white balance — which is upstream of demosaicing —
    /// does not have to decode a twelve-megapixel file again.
    ///
    /// LibRaw's processed-RGB path is not involved: this calls `decodeMosaic`,
    /// and the normalisation after it is ours.
    ///
    /// It is **not** cooperatively cancellable; see
    /// `RAWBasePreparationPipeline`, which owns that decision and the reason
    /// for it.
    ///
    /// - Throws: `RAWDecodingError` or `RAWProcessingError`.
    func prepareBase(
        decoding url: URL,
        using decoder: RAWDecoder
    ) throws -> NormalizedRAWSource {
        try RAWBasePreparationPipeline().prepare(decoding: url, using: decoder)
    }

    /// Estimates and applies one white-balance decision, demosaics, converts
    /// to the working representation and reduces, keeping the reduced,
    /// **pre-mix** result.
    ///
    /// ```text
    /// prepareSource   retained normalised mosaic
    ///                 → resolve the user's patch against this active area
    ///                 → estimate gains  → apply them
    ///                 → demosaic
    ///                 → camera → working
    ///                 → preview reduction
    ///                 → RETAIN the pre-mix source
    ///
    /// render          mix → orientation → display rendering
    /// ```
    ///
    /// The heavy interactive phase. It depends on exactly one of the user's
    /// adjustments — the white balance — and on none of the others: no
    /// creative stage, no geometry and no display encoding runs here, so a
    /// rotation, a mix or a slider drag never reaches it.
    ///
    /// Every stage it calls polls `cancellation`, so a superseded patch stops
    /// inside the pass rather than at the end of it. That matters here in a way
    /// it did not when this work only happened on open: a user can re-trigger
    /// it by clicking, and an abandoned pass that kept running would compete
    /// with the one whose result they are waiting for. A cancelled call throws
    /// `CancellationError` and produces no source; it is the caller's job to
    /// tell that apart from a stage refusing the image.
    ///
    /// - Throws: whatever the stage that failed reports —
    ///   `RAWProcessingError`, `PreviewReductionError`, or
    ///   `CancellationError`. Nothing is caught and turned into a
    ///   plausible-looking picture here.
    func prepareSource(
        _ base: NormalizedRAWSource,
        whiteBalance: UserWhiteBalanceAdjustment,
        captureProfile: IRCaptureProfile,
        policy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy,
        cancellation: ProcessingCancellation = .none
    ) throws -> Source {
        // The shared RAW front half: white balance, demosaic, camera → working,
        // at sensor resolution. Identical code to the one the full-resolution
        // export runs, which is what makes an export the same rendering as the
        // preview rather than a second pipeline that resembles it — and what
        // makes a saved patch resolve to the same samples in both.
        //
        // The transform comes from the resolved capture profile rather than
        // from a constant, and it is the only thing a profile contributes to a
        // pixel. Which is why the profile is recorded on the `Source` below: a
        // reduced preview is only valid for the basis it was prepared under.
        let prepared = try RAWWorkingImagePipeline().prepare(
            base,
            whiteBalance: whiteBalance,
            cameraToWorkingTransform: captureProfile.cameraToWorkingTransform,
            cancellation: cancellation
        )

        // The reduction point, and the end of this phase. Everything above
        // this line is full resolution, and every buffer it produced — the
        // white-balanced mosaic, the camera-native image and the
        // working-colour image — becomes unreachable when this function
        // returns. The normalised mosaic survives, because it belongs to the
        // caller and is what the next patch will be measured from. Nothing
        // below this line is ever full resolution again.
        //
        // The bare-image overload is used deliberately: the wrapper overloads
        // exist to keep a stage's whole upstream chain reachable through
        // `source`, which is exactly what must not survive into the retained
        // value.
        //
        // No creative stage runs here. The mix is an adjustment, and applying
        // one now — even the identity — would retain a mixed buffer that a
        // later mix could only be composed onto.
        let reduced = try SceneLinearPreviewReducer().reduce(
            prepared.image, policy: policy, cancellation: cancellation
        )

        return Source(
            preview: reduced,
            metadata: prepared.metadata,
            url: base.url,
            captureProfile: captureProfile,
            whiteBalance: whiteBalance,
            estimate: prepared.estimate
        )
    }

    /// Both preparation phases, for a caller opening a file for the first time
    /// or one that has no reason to keep the normalised mosaic.
    ///
    /// - Throws: whatever the stage that failed reports.
    func prepare(
        decoding url: URL,
        using decoder: RAWDecoder,
        whiteBalance: UserWhiteBalanceAdjustment = WorkspacePreviewPipeline.initialWhiteBalance,
        captureProfile: IRCaptureProfile = WorkspacePreviewPipeline.initialCaptureProfile,
        policy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy,
        cancellation: ProcessingCancellation = .none
    ) throws -> Source {
        try prepareSource(
            prepareBase(decoding: url, using: decoder),
            whiteBalance: whiteBalance,
            captureProfile: captureProfile,
            policy: policy,
            cancellation: cancellation
        )
    }

    /// Applies one complete adjustment state to a prepared source and encodes
    /// the result for display.
    ///
    /// ```text
    /// retained pre-mix preview
    ///   → IRChannelMixer      adjustments.channelMix
    ///   → ImageOrienter       the file's orientation + adjustments.orientation
    ///   → SceneLinearExposer    adjustments.exposure
    ///   → LinearLevelsApplier   adjustments.levels
    ///   → GlobalContrastApplier adjustments.contrast
    ///   → DisplayPreviewRenderer
    ///                           range policy and encoding only
    /// ```
    ///
    /// The interactive half, and the only half any adjustment reruns.
    ///
    /// Exposure is `× 2^EV` on scene-linear light; levels are
    /// `(x − black) × 1/(white − black)` on the result. Both happen **before**
    /// the display stage's range policy, and neither clamps — so a value
    /// either of them pushes outside `0…1` is clipped, and counted, by the
    /// policy that owns clipping, not by anything upstream of it.
    ///
    /// It always starts from `source.preview`, which is unmixed, unoriented,
    /// unexposed and unlevelled, so repeated changes never compose: the mix is
    /// applied exactly once by the requested matrix, the image is permuted
    /// exactly once by the effective orientation, and the levels are applied
    /// exactly once to the exposed values, from the same buffer every time.
    ///
    /// The order is fixed and is not a matter of taste. The mix is a colour
    /// operation on a scene-linear representation and the orientation is
    /// discrete geometry, so those two commute in principle — but the
    /// orientation stage is where the provenance chain is assembled, so a
    /// colour stage after it would be a different kind of claim. Exposure
    /// precedes levels because they are different decisions: a gain and an
    /// affine remap, and folding them together would make each control change
    /// what the other one did. Colour, then geometry, then exposure, then
    /// levels, then encoding. Levels precede the contrast curve because the
    /// curve's fixed points — `0`, `0.5` and `1` — mean nothing until
    /// something has said where black and white are, so the curve comes last
    /// of the adjustments and first before the destination.
    ///
    /// All six stages poll `cancellation`, so a superseded re-render stops
    /// inside the pass rather than at the end of it. A cancelled call throws
    /// `CancellationError` and produces no preview; it is the caller's job to
    /// tell that apart from a stage refusing the image.
    ///
    /// ## What it costs
    ///
    /// Two more reduced-resolution `Float32` buffers than before this
    /// milestone, transiently — the exposed image and the levelled one, each
    /// the size of the mixed and oriented ones already allocated here, and all
    /// of them unreachable the moment this function returns. At the default
    /// preview policy that is tens of megabytes, not hundreds, and it buys the
    /// boundary that makes preview and export provably the same rendering.
    /// `0 EV` and neutral levels each hand their input's buffer back rather
    /// than copying it, so the common case allocates neither.
    ///
    /// - Throws: `PreviewReductionError`, `IRProcessingError`,
    ///   `OrientationError`, `SceneLinearExposureError`, `LinearLevelsError`,
    ///   `GlobalContrastError`, `DisplayRenderingError`, or
    ///   `CancellationError`.
    func render(
        _ source: Source,
        captureProfile: IRCaptureProfile,
        adjustments: ImageAdjustments,
        cancellation: ProcessingCancellation = .none
    ) throws -> WorkspacePreview {
        // The one guard that keeps a profile's name honest. Nothing in this
        // function can re-run the camera-to-working transform — the source was
        // prepared with one, upstream — so rendering a source under a profile
        // whose basis differs would label these pixels with a processing
        // decision they were not produced by. Two profiles that share a basis
        // are interchangeable here by construction, which is exactly what
        // makes a metadata-only profile change a cheap re-render rather than a
        // re-preparation. See ADR 0020, Decision 8.
        guard captureProfile.processingBasis == source.captureProfile.processingBasis else {
            throw IRCaptureProfileError.processingBasisMismatch(
                prepared: source.captureProfile.id, requested: captureProfile.id
            )
        }

        let mixed = try IRChannelMixer().apply(
            to: source.preview,
            mix: adjustments.channelMix.mix,
            cancellation: cancellation
        )

        let orientation = try Self.effectiveOrientation(
            for: source.metadata, adjustments: adjustments
        )
        let oriented = try ImageOrienter().apply(
            to: mixed,
            orientation: orientation.applied,
            cancellation: cancellation
        )

        // Exposure and levels, as their own stages, in that order. The export
        // path calls the identical two with the identical values; that is what
        // makes a preview and an export the same rendering at two resolutions
        // rather than two pipelines.
        let exposed = try SceneLinearExposer().apply(
            to: oriented,
            exposure: SceneLinearExposure(adjustments.exposure),
            cancellation: cancellation
        )

        let leveled = try LinearLevelsApplier().apply(
            to: exposed,
            levels: LinearLevels(adjustments.levels),
            cancellation: cancellation
        )

        // The first nonlinear operation in the pipeline, and the last stage
        // before the destination. The export path calls the identical one with
        // the identical value.
        let curved = try GlobalContrastApplier().apply(
            to: leveled,
            curve: GlobalContrastCurve(adjustments.contrast),
            cancellation: cancellation
        )

        let encoded = try DisplayPreviewRenderer().render(
            curved,
            settings: Self.displaySettings,
            cancellation: cancellation
        )

        return WorkspacePreview(
            image: try DisplayPreviewCGImageAdapter.makeCGImage(from: encoded),
            processing: encoded.processing,
            captureProfile: captureProfile,
            whiteBalanceAdjustment: source.whiteBalance,
            estimate: source.estimate,
            sensorColorLayout: source.metadata.sensor,
            orientationProvenance: OrientationProvenance(
                orientation: orientation, stage: oriented.processing
            ),
            channelMixAdjustment: adjustments.channelMix,
            exposureAdjustment: adjustments.exposure,
            levelsAdjustment: adjustments.levels,
            contrastAdjustment: adjustments.contrast,
            resolution: source.resolution,
            sourcePixelWidth: source.preview.width,
            sourcePixelHeight: source.preview.height,
            pixelWidth: encoded.width,
            pixelHeight: encoded.height
        )
    }

    /// The same render, under the profile the source was prepared with.
    ///
    /// The identity case, and it is a real one rather than a convenience
    /// default: a rendering's capture profile and its source's are the same
    /// value except in exactly one situation — a metadata-only profile change,
    /// where the basis is unchanged and the label is not. Callers that are not
    /// in that situation should not have to restate the profile, and restating
    /// it is exactly where the two could be made to disagree by accident.
    ///
    /// The document uses the explicit overload, because it is the one caller
    /// that can be in that situation.
    func render(
        _ source: Source,
        adjustments: ImageAdjustments,
        cancellation: ProcessingCancellation = .none
    ) throws -> WorkspacePreview {
        try render(
            source,
            captureProfile: source.captureProfile,
            adjustments: adjustments,
            cancellation: cancellation
        )
    }

    /// Both phases, for a caller that has no reason to keep the scene-linear
    /// state — a test, or a one-shot render.
    ///
    /// - Throws: whatever the stage that failed reports.
    func render(
        decoding url: URL,
        using decoder: RAWDecoder,
        adjustments: ImageAdjustments = .none,
        captureProfile: IRCaptureProfile = WorkspacePreviewPipeline.initialCaptureProfile,
        policy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy,
        cancellation: ProcessingCancellation = .none
    ) throws -> WorkspacePreview {
        try render(
            prepare(
                decoding: url,
                using: decoder,
                whiteBalance: adjustments.whiteBalance,
                captureProfile: captureProfile,
                policy: policy,
                cancellation: cancellation
            ),
            captureProfile: captureProfile,
            adjustments: adjustments,
            cancellation: cancellation
        )
    }
}

extension WorkspacePreviewPipeline {
    /// The reduced scene-linear state a workspace holds on to so that a change
    /// of adjustment does not decode the file again.
    ///
    /// ## What is retained, and what is not
    ///
    /// Non-destructive reprocessing needs the **unmixed, unoriented**
    /// scene-linear image: an adjustment must be applied to it, never to
    /// whatever is currently on screen. What it does not need is that image at
    /// sensor resolution, and it does not need the chain that produced it.
    ///
    /// This type therefore holds exactly one buffer, at preview resolution,
    /// pre-creative, and reaches nothing upstream. The mosaics, the
    /// camera-native image and the full-resolution working-colour image are
    /// unreachable from here by construction: `prepare` uses the bare-image
    /// overload after the reduction precisely so that no `source` chain
    /// survives into this value.
    ///
    /// On the E-PL3 fixture the scene-linear buffer it holds is roughly 36 MB,
    /// where the chain it replaced was roughly 420 MB. Those numbers are the
    /// **application-owned scene-linear buffers** and nothing else: a document
    /// also holds the LibRaw diagnostic reference, the display `CGImage`s, the
    /// metadata and a little small state, and no claim is made here about
    /// their size.
    ///
    /// ## Why pre-mix, and not identity-mixed
    ///
    /// An identity mix is arithmetically free — its path hands the same
    /// immutable array back — so retaining a mixed buffer would have cost no
    /// memory. It would have cost the adjustment. `IRChannelMixer` has no
    /// overload that accepts an already-mixed preview, deliberately, because
    /// `M2 × (M1 × preview)` is a different rendering from the one a user
    /// asked for and is not recognisably wrong when it happens. Retaining the
    /// pre-mix state is what makes a change of mix an ordinary re-render
    /// rather than a re-decode. See
    /// `docs/decisions/0016-interactive-channel-mixer.md`.
    ///
    /// ## Why that is safe
    ///
    /// Because these pixels are not the document. The canonical editing state
    /// is the RAW file plus `ImageAdjustments`, and this is a cache derived
    /// from the pair — cheap to throw away, and rebuildable by opening the
    /// file again. An adjustment that needs a stage upstream of the reduction
    /// — a different white balance, a different demosaic, a different camera
    /// transform — re-prepares from the file rather than from here, and an
    /// eventual full-resolution export does the same. See
    /// `docs/decisions/0015-reduced-resolution-preview.md`.
    struct Source: Sendable {
        /// The reduced, **unmixed**, unoriented scene-linear image. The one
        /// buffer every interactive re-render reads.
        ///
        /// Its type is what says it is unmixed: `SceneLinearPreviewImage` is
        /// the pre-creative state, and the mixer's result is a different type
        /// that no `Source` can hold.
        let preview: SceneLinearPreviewImage
        /// The RAW-state metadata the chain was processed against.
        ///
        /// Stored, rather than read through the image as it used to be: the
        /// image no longer reaches the decoded mosaic that carried it, which
        /// is the point.
        let metadata: RAWMetadata
        /// The file these pixels came from.
        let url: URL
        /// The capture profile these pixels were prepared under.
        ///
        /// Recorded because the profile's processing basis chose the
        /// camera-to-working transform that produced them, and that stage is
        /// upstream of the reduction: this buffer is valid only for that basis.
        /// `render` refuses a profile whose basis disagrees, and
        /// `DocumentState` compares against it to decide whether selecting a
        /// profile costs a re-preparation or only a re-render. See
        /// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 8.
        let captureProfile: IRCaptureProfile
        /// The white balance the **user** asked for, which these pixels were
        /// prepared with.
        ///
        /// The one thing a reader cannot recover from the preview's own
        /// provenance: the chain records the region that was measured and the
        /// gains it produced, and this records the decision that chose them.
        /// It is also what the workspace compares against a newly requested
        /// white balance to decide whether this source is still usable or has
        /// to be prepared again.
        let whiteBalance: UserWhiteBalanceAdjustment

        /// What the estimator measured and produced: the resolved region, the
        /// per-plane statistics, the target mean and the gains.
        let estimate: RAWWhiteBalanceEstimate

        /// The region the white balance was estimated from, in **full
        /// resolution** sensor (pre-orientation) active-area coordinates.
        ///
        /// Deliberately not rescaled to preview coordinates. It describes
        /// where the estimate was taken from, which happened before the
        /// reduction and in the sensor's own coordinates; restating it in the
        /// preview's would make it look like something that could be sampled
        /// again from the reduced buffer, which it cannot.
        var neutralPatch: RAWActiveAreaRegion { estimate.region }

        /// What resolution this preview is, what it was reduced from, and by
        /// what rule.
        var resolution: PreviewResolution { preview.resolution }
    }
}

/// What the workspace shows, plus enough of its provenance to describe it.
///
/// The scene-linear image is **not** retained here. It is retained one level
/// up, on `WorkspacePreviewPipeline.Source`, which is where reprocessing
/// starts from: a preview is a finished result, and holding the state that
/// could produce a different one on the result itself would invite someone to
/// reprocess from a rendered image. `DocumentState` keeps the two side by
/// side.
struct WorkspacePreview {
    /// The display-encoded pixels, tagged sRGB.
    let image: CGImage
    /// What produced them, including the whole upstream chain by reference:
    /// settings, clip counts, mix, camera transform, demosaic, gains,
    /// normalisation.
    let processing: DisplayPreviewProcessing
    /// The capture profile this rendering was processed under, resolved.
    ///
    /// Carried whole rather than as an identifier, so the inspector can state
    /// the camera, the conversion, the filter and — above all — whether the
    /// processing is a validated infrared calibration, without looking anything
    /// up. For every profile this build ships that last answer is `false`, and
    /// it is derived from the transform's own provenance rather than asserted.
    ///
    /// It is **provenance**, not an edit: the photograph-local decisions are
    /// the adjustments below it.
    let captureProfile: IRCaptureProfile
    /// The white balance the user asked for, as the canonical adjustment
    /// rather than as the region or the gains it became.
    ///
    /// Kept beside `estimate` for the reason `channelMixAdjustment` is kept
    /// beside `processing.mix`: one is what the person chose, the other is
    /// what the pipeline measured. A control reads this; an audit of the
    /// rendering reads that.
    let whiteBalanceAdjustment: UserWhiteBalanceAdjustment
    /// What the estimator measured and produced for this rendering.
    let estimate: RAWWhiteBalanceEstimate
    /// The CFA colour layout the gains below are indexed by.
    ///
    /// Carried because the gains are four numbers addressed by colour-plane
    /// index, and nothing else in a finished preview says what any of those
    /// planes is. Read from the preparation's own metadata — the same layout
    /// the estimator walked — rather than looked up from a document or from a
    /// second decode, so a reader of this preview cannot be shown plane labels
    /// that belong to a different file or a different read of it.
    ///
    /// It says nothing about the *rendering*: the pixels here are demosaiced,
    /// mixed and oriented, and no CFA plane survives into them. It describes
    /// where the gains came from.
    let sensorColorLayout: RAWMetadata.SensorColorLayout

    /// The region the white balance was estimated from, in **sensor**
    /// (pre-orientation) active-area coordinates.
    var neutralPatch: RAWActiveAreaRegion { estimate.region }
    /// The multipliers the estimate produced, indexed by CFA colour plane.
    var whiteBalanceGains: RAWWhiteBalanceGains { estimate.gains }
    /// The same multipliers, each paired with what the sensor layout says its
    /// colour plane is. What the inspector shows.
    ///
    /// Throws only for a layout with no CFA colour planes, which could not
    /// have produced these gains through the neutral-patch estimator. See
    /// `RAWWhiteBalanceGainListing`.
    func whiteBalanceGainListing() throws -> RAWWhiteBalanceGainListing {
        try RAWWhiteBalanceGainListing(
            gains: whiteBalanceGains, sensorColorLayout: sensorColorLayout
        )
    }
    /// Why the image has the geometry it has: what the file recorded, what
    /// the user asked for, and what `ImageOrienter` actually applied.
    let orientationProvenance: OrientationProvenance
    /// The creative channel mix the user asked for, as the canonical
    /// adjustment rather than as the matrix it became.
    ///
    /// `processing.mix` already carries the `IRChannelMix` the stage applied,
    /// and this is not a duplicate of it: one is what the pipeline did, the
    /// other is what the person chose. They are the same two facts
    /// `orientationProvenance` keeps apart for the orientation — a control
    /// reads this, an audit of the rendering reads that.
    let channelMixAdjustment: UserChannelMixAdjustment
    /// The exposure the user asked for, as the canonical adjustment.
    ///
    /// The exposure that was **rendered** is `processing.exposureEV` — see
    /// `renderedExposureEV` — and the pipeline passes one to the other
    /// unchanged, so the two always hold the same number. They are kept as
    /// two facts for the reason `channelMixAdjustment` is: a control reads
    /// what the person chose, an audit of the rendering reads what the stage
    /// applied, and a test asserts that they agree.
    let exposureAdjustment: UserExposureAdjustment
    /// The black and white points the user asked for, as the canonical
    /// adjustment.
    ///
    /// The levels that were **rendered** are `processing.levels` — see
    /// `renderedLevels` — and the pipeline passes one to the other unchanged,
    /// so the two always hold the same pair. Two facts, for the same reason
    /// `exposureAdjustment` is two.
    let levelsAdjustment: UserLevelsAdjustment
    /// The global contrast the user asked for, as the canonical adjustment.
    ///
    /// The curve that was **rendered** is `processing.contrastCurve` — see
    /// `renderedContrastCurve` — and the pipeline passes one to the other
    /// unchanged, so the two always hold the same amount. Two facts, for the
    /// same reason `levelsAdjustment` is two.
    let contrastAdjustment: UserContrastAdjustment
    /// What resolution these pixels are, what full resolution they were
    /// reduced from, by which policy and by which method.
    ///
    /// The one thing the stage-by-stage provenance chain cannot say on its
    /// own. Without it a reader of a finished preview would have to compare
    /// its width against the sensor's to learn that it is a smaller rendition.
    let resolution: PreviewResolution
    /// Preview-source dimensions before orientation, in pixels — the
    /// **reduced** ones. The full-resolution active area is
    /// `resolution.sourceWidth` by `resolution.sourceHeight`.
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    /// Preview dimensions in pixels, **as viewed**. Equal to the source
    /// dimensions exchanged for a quarter-turn-family orientation, and to them
    /// unchanged otherwise; orientation is the only stage after the reduction
    /// that touches geometry at all, and it exchanges the two dimensions
    /// rather than changing either.
    let pixelWidth: Int
    let pixelHeight: Int

    /// The orientation the file's own metadata named.
    var sourceOrientation: RAWImageOrientation {
        orientationProvenance.sourceOrientation
    }
    /// The correction the user asked for, as a canonical single state.
    var userOrientationAdjustment: UserOrientationAdjustment {
        orientationProvenance.userAdjustment
    }
    /// The orientation the pixels were actually permuted by.
    var effectiveOrientation: RAWImageOrientation {
        orientationProvenance.effectiveOrientation
    }
    /// The mix the creative stage actually applied, with its provenance.
    var channelMix: IRChannelMix { processing.mix }
    /// The exposure the exposure stage actually applied, from the rendering's
    /// own provenance. What the inspector shows.
    var renderedExposureEV: Double { processing.exposureEV }
    /// The levels the levels stage actually applied, from the rendering's own
    /// provenance.
    var renderedLevels: LinearLevels { processing.levels }
    /// The curve the contrast stage actually applied, from the rendering's own
    /// provenance. What the inspector shows.
    var renderedContrastCurve: GlobalContrastCurve { processing.contrastCurve }
    /// Whether the rendered curve left the values linear-light encoded — true
    /// exactly when the contrast amount is `0`.
    var preservesLinearLightEncoding: Bool {
        processing.preservesLinearLightEncoding
    }
    /// Whether the rendered levels left the values proportional to scene
    /// radiance — true exactly when the black point is `0`.
    var preservesProportionalityToSceneRadiance: Bool {
        processing.preservesProportionalityToSceneRadiance
    }
    /// Width of the full-resolution, unoriented active image area, in pixels.
    var fullResolutionSourcePixelWidth: Int { resolution.sourceWidth }
    /// Height of that same area.
    var fullResolutionSourcePixelHeight: Int { resolution.sourceHeight }

    /// The identity of the capture profile this rendering was processed under.
    var captureProfileID: IRCaptureProfileID { captureProfile.id }
    /// Whether this rendering's camera-to-working processing is a validated
    /// infrared colour calibration. `false` for every profile this build ships.
    var isValidatedInfraredCalibration: Bool {
        captureProfile.isValidatedInfraredCalibration
    }
}
