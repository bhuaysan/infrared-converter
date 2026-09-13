import Foundation

/// The RAW front half, from a file on disk to the full-resolution working
/// representation — and the one place the application's choices about that
/// half are made.
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
/// WorkingColorRGBImage           ← full resolution, scene-linear, PRE-creative
/// ```
///
/// ## Why this exists as its own type
///
/// Two end paths need exactly this, and needed it to be exactly the same:
///
/// ```text
/// interactive preview   … → WorkingColorRGBImage → preview reduction → mix …
/// full-resolution export … → WorkingColorRGBImage →                     mix …
/// ```
///
/// It lived inside `WorkspacePreviewPipeline.prepare` while the preview was
/// the only consumer. Leaving it there and writing the same seven calls again
/// in the export path would have produced two RAW pipelines that start
/// identical and drift silently: a different neutral patch, a different
/// camera-to-working transform or a different demosaic would make an export
/// disagree with the preview it was supposed to be the full-resolution version
/// of, and nothing would say so. See
/// `docs/decisions/0018-full-resolution-tiff-export.md`.
///
/// The split is deliberately at the **working representation**, because that
/// is exactly where the two paths genuinely diverge: the preview reduces and
/// the export does not. Everything before it is common; everything after it
/// is each path's own.
///
/// ## What is decided here, and what is not
///
/// Every stage below requires its decision to be named — there is no default
/// transform and no default white balance anywhere in the processing API. The
/// choices for a file the user has only just opened are made here, in the
/// application layer, where they are visible in one place:
///
/// - **`.sensorRGBIdentityFalseColor`**, the IR-safe placement into the
///   working space. The file's own `rgbFromCamera` is visible-light data whose
///   validity for an infrared capture is the open question of this project,
///   so it is not used.
/// - **A centred neutral patch** for the white-balance estimate. A
///   deterministic placeholder, not a scene analysis. Nothing verifies that
///   what is in the middle of the frame is neutral; the user will choose the
///   patch when there is a UI for it.
///
/// What is **not** decided here is every adjustable stage: no creative mix, no
/// orientation, no exposure, no reduction and no encoding. Those belong to the
/// path that renders, and they are what makes a preview a preview and an
/// export an export.
///
/// ## Cost
///
/// The expensive half, on the CPU, with no cache. It runs once per file for a
/// preview and once per export; it does not depend on any adjustment, so no
/// slider movement reruns it.
///
/// It is **not** cooperatively cancellable: none of the stages it calls polls
/// a cancellation signal, so it is abandoned only at the task boundary, after
/// the pass. That is unchanged from when it lived in
/// `WorkspacePreviewPipeline`, and is the reason the cancellable half of both
/// end paths starts after it.
struct RAWWorkingImagePipeline {

    /// The camera-to-working transform every path uses.
    ///
    /// Not a colour claim. `.sensorRGBIdentityFalseColor` places camera-native
    /// sensor RGB into the working space's coordinates without asserting that
    /// the result is colorimetrically anything; a validated infrared
    /// calibration would be a different transform with different provenance.
    static let cameraToWorkingTransform = RAWCameraToWorkingColorTransform
        .sensorRGBIdentityFalseColor

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

    /// The orientation a file's own metadata names, or `nil` when it names one
    /// this application does not model.
    ///
    /// The one place the application's *reading* of orientation metadata
    /// lives. It is never a correction of it: no camera model, no filename and
    /// no heuristic takes part, and nothing here can make an upright-recorded
    /// photograph rotate. Only a user can do that, and that is the separate
    /// term in `effectiveOrientation(for:adjustments:)`.
    static func orientation(for metadata: RAWMetadata) -> RAWImageOrientation? {
        metadata.geometry.orientation
    }

    /// The file's recorded orientation and the user's correction, kept
    /// distinct and combined into the single orientation the pixels get.
    ///
    /// Shared by the preview and the export deliberately: an exported file
    /// that disagreed with the preview about which way up the photograph is
    /// would be the most visible possible failure of the "same adjustments"
    /// claim.
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

    /// Decodes a RAW file and runs every stage up to and including the
    /// camera-to-working conversion, at **sensor resolution**.
    ///
    /// LibRaw's processed-RGB path is not involved: this calls `decodeMosaic`,
    /// and every stage after it is ours.
    ///
    /// - Throws: whatever the stage that failed reports —
    ///   `RAWDecodingError` or `RAWProcessingError`. Nothing is caught and
    ///   turned into a plausible-looking picture here.
    func prepare(
        decoding url: URL,
        using decoder: RAWDecoder
    ) throws -> PreparedWorkingImage {
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

        // The bare-image overload, deliberately: the wrapper overloads exist
        // to keep a stage's whole upstream chain reachable through `source`,
        // and at full resolution that chain is four more buffers the size of
        // the image. The decoded mosaic, the normalised mosaic, the
        // white-balanced mosaic and the camera-native image all become
        // unreachable when this function returns.
        let working = try RAWWorkingColorConverter()
            .convert(demosaiced.image, using: Self.cameraToWorkingTransform)

        return PreparedWorkingImage(
            image: working,
            metadata: decoded.metadata,
            url: url,
            neutralPatch: region
        )
    }
}

/// The full-resolution working representation of one RAW file, with the facts
/// about the file that the stages after it need.
///
/// ```text
/// full sensor resolution      the active image area, unreduced
/// extended linear sRGB        scene-linear, unclamped Float32
/// pre-creative                no mix, no orientation, no exposure, no encoding
/// ```
///
/// This is the hand-over point between the shared RAW front half and each end
/// path. It is **not** retained by anything interactive: the workspace reduces
/// it and keeps the reduction, and the export encodes it and keeps nothing.
struct PreparedWorkingImage: Sendable {
    /// The full-resolution scene-linear image, before any adjustment.
    let image: WorkingColorRGBImage
    /// The RAW-state metadata the chain was processed against.
    let metadata: RAWMetadata
    /// The file these pixels came from.
    let url: URL
    /// The region the white balance was estimated from, in full-resolution
    /// sensor (pre-orientation) active-area coordinates.
    let neutralPatch: RAWActiveAreaRegion
}
