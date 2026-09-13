import CoreGraphics
import Foundation

/// The application-owned preview the workspace shows, and the one place the
/// choices behind it are made.
///
/// ```text
/// decodeMosaic
///     ↓  RAWMosaicNormalizer
/// LinearRAWMosaic
///     ↓  RAWWhiteBalanceEstimator over a centred neutral patch
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
///     ↓  DisplayPreviewRenderer (adjustments.exposure, hard clipping, sRGB)
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
/// - **A centred neutral patch.** A deterministic placeholder, not a scene
///   analysis. Nothing verifies that what is in the middle of the frame is
///   neutral; the user will choose the patch when there is a UI for it.
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
/// prepare   decode → normalise → balance → demosaic → convert → reduce
///           → RETAIN the pre-mix reduced preview
///
/// render    retained pre-mix preview → channel mix → orientation
///           → display (exposure, range policy, encoding)
/// ```
///
/// `prepare(decoding:using:)` stops at the reduction and hands back a `Source`
/// that keeps its result. `render(_:adjustments:)` takes that `Source` and one
/// complete `ImageAdjustments`, and applies every adjustable stage to it.
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

    /// The camera-to-working transform a freshly opened file gets.
    ///
    /// Owned by `RAWWorkingImagePipeline`, which is the shared RAW front half
    /// the export path uses too. Restated here rather than duplicated: a
    /// second literal would be a second decision that could drift from this
    /// one without anything failing.
    static let initialTransform = RAWWorkingImagePipeline.cameraToWorkingTransform

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
    /// adjustment: exposure changes which values those are, never this.
    static let displayRangePolicy = DisplayRangePolicy.hardClipToDisplayRange

    /// The encoding the display stage produces. Not an adjustment either.
    static let displayEncoding = DisplayEncoding.sRGB

    /// The display settings one complete adjustment state is rendered with.
    ///
    /// The user's exposure is passed through **unchanged** — no rounding, no
    /// clamp, no scale computed here. `DisplayPreviewRenderer` is the one
    /// authority on what `exposureEV` does to a pixel, and it did so before
    /// exposure was a user decision. The range policy and the encoding are
    /// the application's fixed choices and do not depend on the adjustments.
    static func displaySettings(for adjustments: ImageAdjustments) -> DisplayRenderSettings {
        DisplayRenderSettings(
            exposureEV: adjustments.exposure.ev,
            rangePolicy: displayRangePolicy,
            encoding: displayEncoding
        )
    }

    /// The fraction of the shorter active-area dimension the neutral patch
    /// spans. A sixteenth is large enough to average thousands of samples of
    /// every CFA plane and small enough to stay well inside the frame.
    static let neutralPatchDivisor = RAWWorkingImagePipeline.neutralPatchDivisor

    /// A centred, even-sided square in active-image coordinates.
    ///
    /// Even sides matter: a region of even width and height contains whole
    /// 2×2 CFA cells whatever its origin's parity, so every colour plane is
    /// measured. A minimum of two keeps that true for absurdly small images.
    ///
    /// This is a deterministic placeholder for a picker, not an estimate of
    /// where the neutral part of a photograph is.
    static func centredNeutralPatch(width: Int, height: Int) -> RAWActiveAreaRegion {
        RAWWorkingImagePipeline.centredNeutralPatch(width: width, height: height)
    }

    /// Decodes a RAW file and runs every stage up to and including the preview
    /// reduction, keeping the reduced, **pre-mix** result.
    ///
    /// ```text
    /// prepare   decode
    ///           → normalise
    ///           → white balance (neutral-patch estimate, then gains)
    ///           → demosaic
    ///           → camera → working
    ///           → preview reduction
    ///           → RETAIN the pre-mix source
    ///
    /// render    mix → orientation → display rendering
    /// ```
    ///
    /// This is the expensive half, and it depends on none of the user's
    /// adjustments: no creative stage, no geometry and no display encoding
    /// runs here, so it runs once per file rather than once per adjustment.
    /// Every adjustable stage is in `render(_:adjustments:cancellation:)`.
    ///
    /// LibRaw's processed-RGB path is not involved: this calls `decodeMosaic`,
    /// and every stage after it is ours.
    ///
    /// It is **not** cooperatively cancellable. None of the stages it calls
    /// polls a cancellation signal yet, so it is abandoned only at the task
    /// boundary, after the pass. That is deliberate scope: the half a user can
    /// re-trigger by holding a button down is the orientation/display half,
    /// and that is the half `render(_:adjustments:cancellation:)` can stop.
    ///
    /// - Throws: whatever the stage that failed reports —
    ///   `RAWDecodingError`, `RAWProcessingError` or `IRProcessingError`.
    ///   Nothing is caught and turned into a plausible-looking picture here.
    func prepare(
        decoding url: URL,
        using decoder: RAWDecoder,
        policy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy
    ) throws -> Source {
        // The shared RAW front half: decode, normalise, white balance,
        // demosaic, camera → working, at sensor resolution. Identical code to
        // the one the full-resolution export runs, which is what makes an
        // export the same rendering as the preview rather than a second
        // pipeline that resembles it.
        let prepared = try RAWWorkingImagePipeline().prepare(
            decoding: url, using: decoder
        )

        // The reduction point, and the end of this phase. Everything above
        // this line is full resolution and every buffer it produced — the
        // decoded mosaic, the normalised mosaic, the white-balanced mosaic,
        // the camera-native image and the working-colour image — becomes
        // unreachable when this function returns. Nothing below this line is
        // ever full resolution again.
        //
        // The bare-image overload is used deliberately: the wrapper overloads
        // exist to keep a stage's whole upstream chain reachable through
        // `source`, which is exactly what must not survive into the retained
        // value.
        //
        // No creative stage runs here. The mix is an adjustment, and applying
        // one now — even the identity — would retain a mixed buffer that a
        // later mix could only be composed onto.
        let reduced = try SceneLinearPreviewReducer()
            .reduce(prepared.image, policy: policy)

        return Source(
            preview: reduced,
            metadata: prepared.metadata,
            url: url,
            neutralPatch: prepared.neutralPatch
        )
    }

    /// Applies one complete adjustment state to a prepared source and encodes
    /// the result for display.
    ///
    /// ```text
    /// retained pre-mix preview
    ///   → IRChannelMixer      adjustments.channelMix
    ///   → ImageOrienter       the file's orientation + adjustments.orientation
    ///   → DisplayPreviewRenderer
    ///                         exposureEV = adjustments.exposure
    ///                         range policy and encoding unchanged
    /// ```
    ///
    /// The interactive half, and the only half any adjustment reruns.
    ///
    /// Exposure is scene-linear arithmetic, `× 2^EV`, and it happens inside the
    /// display stage **before** that stage's range policy: nothing here clamps
    /// the mixed, oriented values first, so a value that exposure lifts above
    /// `1` is clipped — and counted — by the policy that owns clipping, not by
    /// anything upstream of it. It
    /// always starts from `source.preview`, which is unmixed and unoriented,
    /// so repeated changes never compose: the mix is applied exactly once, by
    /// the requested matrix, and the image is permuted exactly once, by the
    /// effective orientation, from the same buffer every time.
    ///
    /// The order is fixed and is not a matter of taste. The mix is a colour
    /// operation on a scene-linear representation and the orientation is
    /// discrete geometry, so they commute in principle — but the orientation
    /// stage is where the provenance chain is assembled and the display stage
    /// is the first thing that stops being proportional to light, so a colour
    /// stage after either would be a different kind of claim. Colour, then
    /// geometry, then encoding.
    ///
    /// All three stages poll `cancellation`, so a superseded re-render stops
    /// inside the pass rather than at the end of it. A cancelled call throws
    /// `CancellationError` and produces no preview; it is the caller's job to
    /// tell that apart from a stage refusing the image.
    ///
    /// - Throws: `PreviewReductionError`, `IRProcessingError`,
    ///   `OrientationError`, `DisplayRenderingError`, or `CancellationError`.
    func render(
        _ source: Source,
        adjustments: ImageAdjustments,
        cancellation: ProcessingCancellation = .none
    ) throws -> WorkspacePreview {
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

        let encoded = try DisplayPreviewRenderer().render(
            oriented,
            settings: Self.displaySettings(for: adjustments),
            cancellation: cancellation
        )

        return WorkspacePreview(
            image: try DisplayPreviewCGImageAdapter.makeCGImage(from: encoded),
            processing: encoded.processing,
            neutralPatch: source.neutralPatch,
            orientationProvenance: OrientationProvenance(
                orientation: orientation, stage: oriented.processing
            ),
            channelMixAdjustment: adjustments.channelMix,
            exposureAdjustment: adjustments.exposure,
            resolution: source.resolution,
            sourcePixelWidth: source.preview.width,
            sourcePixelHeight: source.preview.height,
            pixelWidth: encoded.width,
            pixelHeight: encoded.height
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
        policy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy,
        cancellation: ProcessingCancellation = .none
    ) throws -> WorkspacePreview {
        try render(
            prepare(decoding: url, using: decoder, policy: policy),
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
        /// The region the white balance was estimated from, in **full
        /// resolution** sensor (pre-orientation) active-area coordinates.
        ///
        /// Deliberately not rescaled to preview coordinates. It describes
        /// where the estimate was taken from, which happened before the
        /// reduction and in the sensor's own coordinates; restating it in the
        /// preview's would make it look like something that could be sampled
        /// again from the reduced buffer, which it cannot.
        let neutralPatch: RAWActiveAreaRegion

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
    /// The region the white balance was estimated from, in **sensor**
    /// (pre-orientation) active-area coordinates.
    let neutralPatch: RAWActiveAreaRegion
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
    /// The exposure the display stage actually applied, from its own
    /// provenance. What the inspector shows.
    var renderedExposureEV: Double { processing.exposureEV }
    /// Width of the full-resolution, unoriented active image area, in pixels.
    var fullResolutionSourcePixelWidth: Int { resolution.sourceWidth }
    /// Height of that same area.
    var fullResolutionSourcePixelHeight: Int { resolution.sourceHeight }
}
