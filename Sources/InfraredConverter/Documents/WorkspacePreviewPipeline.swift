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
/// IRChannelMixedRGBImage
///     ↓  ImageOrienter (the orientation the file's metadata names)
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
/// - **The orientation the file itself names.** Read from
///   `RAWMetadata.Geometry.orientation`, which is the decoder's `flip` mapped
///   once into an application-owned case. There is no camera-model table, no
///   per-file override and no correction of any kind: if the file records
///   upright, the photograph is shown as it was stored, because that is what
///   the file says. A value the application does not model is a **typed
///   failure**, not a silent `.upright`.
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
    /// The one place the workspace's orientation policy lives. It is a
    /// *reading* of metadata, never a correction of it: no camera model, no
    /// filename and no heuristic takes part, and nothing here can make an
    /// upright-recorded photograph rotate.
    static func orientation(for metadata: RAWMetadata) -> RAWImageOrientation? {
        metadata.geometry.orientation
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

    /// Decodes a RAW file and renders the workspace's preview from it, through
    /// the application-owned pipeline only.
    ///
    /// LibRaw's processed-RGB path is not involved: this calls `decodeMosaic`,
    /// and every stage after it is ours.
    ///
    /// - Throws: whatever the stage that failed reports —
    ///   `RAWDecodingError`, `RAWProcessingError`, `IRProcessingError`,
    ///   `OrientationError` or `DisplayRenderingError`. Nothing is caught and
    ///   turned into a plausible-looking picture here.
    func render(decoding url: URL, using decoder: RAWDecoder) throws -> WorkspacePreview {
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

        // The file's own orientation, or a refusal. Reading an unmodelled
        // code as upright would turn a field we could not parse into a claim
        // about the photograph, so the preview fails and says which code it
        // could not read.
        guard let orientation = Self.orientation(for: mixed.metadata) else {
            throw OrientationError.unsupportedDecoderOrientation(
                flip: mixed.metadata.geometry.flip
            )
        }
        let oriented = try ImageOrienter().apply(to: mixed, orientation: orientation)

        let preview = try DisplayPreviewRenderer()
            .render(oriented, settings: Self.initialSettings)

        return WorkspacePreview(
            image: try DisplayPreviewCGImageAdapter.makeCGImage(from: preview.image),
            processing: preview.processing,
            neutralPatch: region,
            orientation: orientation,
            sourcePixelWidth: oriented.source.image.width,
            sourcePixelHeight: oriented.source.image.height,
            pixelWidth: preview.image.width,
            pixelHeight: preview.image.height
        )
    }
}

/// What the workspace shows, plus enough of its provenance to describe it.
///
/// The scene-linear chain is deliberately **not** retained here. Reprocessing
/// from it is a property of `DisplayPreviewProcessedRAWImage`, and the
/// workspace has no controls to reprocess with yet; holding several hundred
/// megabytes of intermediate buffers for a capability nothing currently uses
/// would be a memory cost with no user. When exposure becomes adjustable, this
/// is where the retained chain arrives.
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
    /// The orientation the file's metadata named, applied by `ImageOrienter`.
    let orientation: RAWImageOrientation
    /// Active-area dimensions before orientation, in pixels.
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    /// Preview dimensions in pixels, **as viewed**. Equal to the source
    /// dimensions exchanged for a quarter-turn-family orientation, and to them
    /// unchanged otherwise; orientation is the only stage in this chain that
    /// touches geometry at all.
    let pixelWidth: Int
    let pixelHeight: Int
}
