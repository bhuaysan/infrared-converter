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
/// WorkingColorRGBImage
///     ↓  IRChannelMixer (.identity)
/// IRChannelMixedRGBImage                     ← retained, for reprocessing
///     ↓  EffectiveImageOrientation (metadata orientation + user adjustment)
///     ↓  ImageOrienter (one permutation, by the effective orientation)
/// OrientedSceneLinearRGBImage
///     ↓  DisplayPreviewRenderer (0 EV, hard clipping, sRGB)
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
/// - **`.identity` channel mix.** The canonical infrared operation is the
///   red/blue swap, and it is deliberately *not* what a freshly opened file
///   gets: the application cannot know that a given file is an infrared
///   capture, and swapping a visible-light frame's channels would be simply
///   wrong. Identity traverses the creative stage and asks for nothing, which
///   the provenance chain records as exactly that.
/// - **`.sensorRGBIdentityFalseColor`.** The IR-safe placement into the
///   working space. The file's own `rgbFromCamera` is visible-light data whose
///   validity for an infrared capture is the open question of this project, so
///   it is not used.
/// - **A centred neutral patch.** A deterministic placeholder, not a scene
///   analysis. Nothing verifies that what is in the middle of the frame is
///   neutral; the user will choose the patch when there is a UI for it.
/// - **`0 EV`.** The mathematically neutral exposure, chosen rather than
///   assumed.
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
/// ## Two phases, because orientation is adjustable
///
/// `prepare(decoding:using:)` runs everything up to and including the
/// creative mix and hands back a `Source` that keeps it. `render(_:adjustments:)`
/// takes that `Source` and applies the orientation and the display encode.
///
/// Changing the orientation therefore reruns the last two stages only, from
/// the **unoriented** channel-mixed image — never from the previous displayed
/// buffer. Nothing decodes, normalises, white-balances, demosaics, converts
/// or remixes again, and no orientation is ever applied on top of another.
///
/// None of this is a colour claim. The result is displayable, which is a
/// strictly weaker property than correct.
///
/// ## Cost
///
/// Full resolution, on the CPU, with no cache and no reduced-resolution path:
/// preview strategy is a later decision. Every call decodes and runs the whole
/// chain, so this belongs off the main thread — `DocumentState` runs it there.
struct WorkspacePreviewPipeline {

    /// The creative mix a freshly opened file gets. See the note above: the
    /// red/blue swap is a claim about the photograph, and this is not the
    /// layer that can make it.
    static let initialMix = IRChannelMix.identity

    /// The camera-to-working transform a freshly opened file gets.
    static let initialTransform = RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor

    /// The orientation a file gets when its metadata names one this
    /// application models, or `nil` when it does not.
    ///
    /// The one place the workspace's *reading* of orientation metadata lives.
    /// It is never a correction of it: no camera model, no filename and no
    /// heuristic takes part, and nothing here can make an upright-recorded
    /// photograph rotate. Only a user can do that, and that is the separate
    /// term in `effectiveOrientation(for:adjustments:)`.
    static func orientation(for metadata: RAWMetadata) -> RAWImageOrientation? {
        metadata.geometry.orientation
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
        guard let source = orientation(for: metadata) else {
            throw OrientationError.unsupportedDecoderOrientation(
                flip: metadata.geometry.flip
            )
        }
        return EffectiveImageOrientation(
            source: source, userAdjustment: adjustments.orientation
        )
    }

    /// The display settings a freshly opened file gets. Spelled out rather
    /// than defaulted, because no entry point offers a default.
    static let initialSettings = DisplayRenderSettings(
        exposureEV: 0,
        rangePolicy: .hardClipToDisplayRange,
        encoding: .sRGB
    )

    /// The fraction of the shorter active-area dimension the neutral patch
    /// spans. A sixteenth is large enough to average thousands of samples of
    /// every CFA plane and small enough to stay well inside the frame.
    static let neutralPatchDivisor = 16

    /// A centred, even-sided square in active-image coordinates.
    ///
    /// Even sides matter: a region of even width and height contains whole
    /// 2×2 CFA cells whatever its origin's parity, so every colour plane is
    /// measured. A minimum of two keeps that true for absurdly small images.
    ///
    /// This is a deterministic placeholder for a picker, not an estimate of
    /// where the neutral part of a photograph is.
    static func centredNeutralPatch(width: Int, height: Int) -> RAWActiveAreaRegion {
        let shorter = min(width, height)
        let side = max(2, (shorter / neutralPatchDivisor) & ~1)
        return RAWActiveAreaRegion(
            originRow: max(0, (height - side) / 2),
            originColumn: max(0, (width - side) / 2),
            width: min(side, width),
            height: min(side, height)
        )
    }

    /// Decodes a RAW file and runs every stage up to and including the
    /// creative channel mix, keeping the result.
    ///
    /// This is the expensive half — decode, normalise, estimate, balance,
    /// demosaic, convert, mix — and it does not depend on the orientation, so
    /// it runs once per file rather than once per rotation.
    ///
    /// LibRaw's processed-RGB path is not involved: this calls `decodeMosaic`,
    /// and every stage after it is ours.
    ///
    /// - Throws: whatever the stage that failed reports —
    ///   `RAWDecodingError`, `RAWProcessingError` or `IRProcessingError`.
    ///   Nothing is caught and turned into a plausible-looking picture here.
    func prepare(decoding url: URL, using decoder: RAWDecoder) throws -> Source {
        let decoded = try decoder.decodeMosaic(at: url)
        let normalized = try RAWMosaicNormalizer().process(decoded)

        let region = Self.centredNeutralPatch(
            width: normalized.mosaic.width,
            height: normalized.mosaic.height
        )
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: normalized.mosaic, region: region)

        let balanced = try RAWWhiteBalancer().apply(to: normalized, estimate: estimate)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)
        let working = try RAWWorkingColorConverter()
            .convert(demosaiced, using: Self.initialTransform)
        let mixed = try IRChannelMixer().apply(to: working, mix: Self.initialMix)

        return Source(channelMixed: mixed, neutralPatch: region)
    }

    /// Orients a prepared source and encodes it for display.
    ///
    /// The cheap half, and the only half a change of orientation reruns. It
    /// always starts from `source.channelMixed`, which is unoriented, so
    /// repeated user rotations never compose pixel permutations: the image is
    /// permuted exactly once, by the effective orientation, from the same
    /// buffer every time.
    ///
    /// - Throws: `OrientationError` or `DisplayRenderingError`.
    func render(
        _ source: Source,
        adjustments: ImageAdjustments
    ) throws -> WorkspacePreview {
        let orientation = try Self.effectiveOrientation(
            for: source.metadata, adjustments: adjustments
        )
        let oriented = try ImageOrienter()
            .apply(to: source.channelMixed, orientation: orientation.applied)

        let preview = try DisplayPreviewRenderer()
            .render(oriented, settings: Self.initialSettings)

        return WorkspacePreview(
            image: try DisplayPreviewCGImageAdapter.makeCGImage(from: preview.image),
            processing: preview.processing,
            neutralPatch: source.neutralPatch,
            orientationProvenance: OrientationProvenance(
                orientation: orientation, stage: oriented.image.processing
            ),
            sourcePixelWidth: oriented.source.image.width,
            sourcePixelHeight: oriented.source.image.height,
            pixelWidth: preview.image.width,
            pixelHeight: preview.image.height
        )
    }

    /// Both phases, for a caller that has no reason to keep the scene-linear
    /// state — a test, or a one-shot render.
    ///
    /// - Throws: whatever the stage that failed reports.
    func render(
        decoding url: URL,
        using decoder: RAWDecoder,
        adjustments: ImageAdjustments = .none
    ) throws -> WorkspacePreview {
        try render(prepare(decoding: url, using: decoder), adjustments: adjustments)
    }
}

extension WorkspacePreviewPipeline {
    /// The scene-linear state a workspace holds on to so that a change of
    /// orientation does not decode the file again.
    ///
    /// ## Why this is retained, and what it costs
    ///
    /// Non-destructive reprocessing needs the **unoriented** channel-mixed
    /// image: an adjustment must be applied to it, never to whatever is
    /// currently on screen. Keeping it is the alternative to a full RAW
    /// decode on every button press, which the project's own architecture
    /// notes name as a red flag.
    ///
    /// It is not free, and the cost should be stated rather than discovered.
    /// `IRChannelMixedProcessedRAWImage` reaches the working-colour image,
    /// the camera-native image and both mosaics through its `source` chain,
    /// so a 4056 × 3040 frame retains roughly half a gigabyte of Float32
    /// buffers for as long as the file is open. Reduced-resolution previews,
    /// caching and eviction are all undecided; this is the simple thing, and
    /// it is measured by nothing yet.
    struct Source: Sendable {
        /// Everything up to and including the creative mix, unoriented, with
        /// the whole upstream chain reachable through it.
        let channelMixed: IRChannelMixedProcessedRAWImage
        /// The region the white balance was estimated from, in sensor
        /// (pre-orientation) active-area coordinates.
        let neutralPatch: RAWActiveAreaRegion

        /// The RAW-state metadata the chain was processed against, read
        /// through the retained image rather than stored twice.
        var metadata: RAWMetadata { channelMixed.metadata }
        var url: URL { channelMixed.url }
    }
}

/// What the workspace shows, plus enough of its provenance to describe it.
///
/// The scene-linear chain is **not** retained here. It is retained one level
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
    /// Active-area dimensions before orientation, in pixels.
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    /// Preview dimensions in pixels, **as viewed**. Equal to the source
    /// dimensions exchanged for a quarter-turn-family orientation, and to them
    /// unchanged otherwise; orientation is the only stage in this chain that
    /// touches geometry at all.
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
}
