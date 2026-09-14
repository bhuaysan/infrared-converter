import Foundation

/// The white-balance-dependent half of the RAW front half: from a normalised
/// mosaic and one white-balance decision to the full-resolution working
/// representation.
///
/// ```text
/// NormalizedRAWSource                ← RAWBasePreparationPipeline produced it
///     ↓  UserWhiteBalanceAdjustment.resolvedRegion    the user's patch, in samples
///     ↓  RAWWhiteBalanceEstimator                     measured, never guessed
///     ↓  RAWWhiteBalancer
/// WhiteBalancedRAWMosaic
///     ↓  RAWDemosaicer (bilinear Bayer)
/// DemosaicedRAWRGBImage
///     ↓  RAWWorkingColorConverter (the capture profile's basis)
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
/// the only consumer. Leaving it there and writing the same calls again in the
/// export path would have produced two RAW pipelines that start identical and
/// drift silently: a different neutral patch, a different camera-to-working
/// transform or a different demosaic would make an export disagree with the
/// preview it was supposed to be the full-resolution version of, and nothing
/// would say so. See `docs/decisions/0018-full-resolution-tiff-export.md`.
///
/// That mattered more once the patch became the user's. The export resolves a
/// saved patch through `UserWhiteBalanceAdjustment.resolvedRegion` and
/// estimates with `RAWWhiteBalanceEstimator` because **this** code does; there
/// is no second resolver and no second estimator to disagree with. See
/// `docs/decisions/0019-interactive-white-balance.md`.
///
/// It mattered again once the camera-to-working transform became a profile's
/// choice rather than a constant. Both end paths resolve the **same** profile
/// and hand its basis's transform to this one function, so a preview and its
/// export cannot be processed under different capture profiles. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 9.
///
/// ## Where it splits, and why there
///
/// ```text
/// RAWBasePreparationPipeline   decode, normalise      ← independent of the user
/// RAWWorkingImagePipeline      balance … convert      ← this type
/// each end path                reduce / mix / …       ← what makes it a preview
///                                                       or an export
/// ```
///
/// The first line is split off because nothing in it depends on the white
/// balance: a workspace can retain its result and re-balance from it without
/// re-reading the file. The second is split off because that is exactly where
/// the two end paths diverge — the preview reduces and the export does not.
///
/// ## Nothing is decided here
///
/// Every stage below requires its decision to be named — there is no default
/// transform and no default white balance anywhere in the processing API — and
/// this type now names none of them itself. Both are **parameters**:
///
/// - **the camera-to-working transform**, which comes from the resolved
///   `IRCaptureProfile`'s processing basis. It used to be a static constant
///   here, `.sensorRGBIdentityFalseColor`, which every caller silently got;
///   that made the application's one capture-processing assumption invisible
///   and unselectable. `builtin.uncalibrated` supplies exactly that transform,
///   so migrated photographs render identically. See
///   `docs/decisions/0020-ir-capture-profile-foundation.md`.
/// - **the white balance**, which is the user's own decision, and for which the
///   default centred patch is one value that parameter can take
///   (`UserWhiteBalanceAdjustment.defaultNeutralPatch`) rather than a hidden
///   fallback inside a shared pipeline.
///
/// What is **not** handled here at all is every adjustable stage after the
/// working representation: no creative mix, no orientation, no exposure, no
/// reduction and no encoding. Those belong to the path that renders, and they
/// are what makes a preview a preview and an export an export.
///
/// ## Cost and cancellation
///
/// The expensive half after decoding, on the CPU, with no cache. It runs once
/// per file for a preview, again each time the user moves the neutral patch,
/// and once per export.
///
/// Every stage it calls **does** poll the cancellation signal it is handed —
/// the estimator per patch row, the balancer, the demosaicer and the working
/// converter per image row — so a superseded pass stops inside itself rather
/// than at the task boundary. That is a requirement rather than a nicety now
/// that a user can re-trigger this by clicking: a run abandoned only at the
/// end would keep a core and a buffer busy producing a picture nobody will
/// see.
struct RAWWorkingImagePipeline {

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

    /// Estimates and applies one white-balance decision, then demosaics and
    /// converts to the working representation, at **sensor resolution**.
    ///
    /// The patch is resolved against this file's own active area, measured,
    /// and turned into gains, in that order — so the persisted decision means
    /// the same rectangle of the same photograph however the file is opened.
    ///
    /// - Throws: whatever the stage that failed reports —
    ///   `RAWProcessingError` for a patch that cannot be resolved or measured,
    ///   or `CancellationError`. Nothing is caught and turned into a
    ///   plausible-looking picture here.
    func prepare(
        _ source: NormalizedRAWSource,
        whiteBalance: UserWhiteBalanceAdjustment,
        cameraToWorkingTransform: RAWCameraToWorkingColorTransform,
        cancellation: ProcessingCancellation = .none
    ) throws -> PreparedWorkingImage {
        let region = try whiteBalance.resolvedRegion(
            activeAreaWidth: source.activeAreaWidth,
            activeAreaHeight: source.activeAreaHeight
        )
        let estimate = try RAWWhiteBalanceEstimator().estimateNeutralPatch(
            in: source.mosaic, region: region, cancellation: cancellation
        )

        let balanced = try RAWWhiteBalancer().apply(
            to: source.mosaic, estimate: estimate, cancellation: cancellation
        )
        let demosaiced = try RAWDemosaicer().demosaic(balanced, cancellation: cancellation)

        // The bare-image overload, deliberately: the wrapper overloads exist
        // to keep a stage's whole upstream chain reachable through `source`,
        // and at full resolution that chain is three more buffers the size of
        // the image. The white-balanced mosaic and the camera-native image
        // both become unreachable when this function returns; the normalised
        // mosaic belongs to the caller, not to this result.
        let working = try RAWWorkingColorConverter().convert(
            demosaiced,
            using: cameraToWorkingTransform,
            cancellation: cancellation
        )

        return PreparedWorkingImage(
            image: working,
            metadata: source.metadata,
            url: source.url,
            whiteBalance: whiteBalance,
            estimate: estimate
        )
    }

    /// Decodes a RAW file and runs every stage up to and including the
    /// camera-to-working conversion, at **sensor resolution**.
    ///
    /// Both halves, for a caller that has no reason to keep the normalised
    /// mosaic — the full-resolution export, which reads the file once and
    /// retains nothing.
    ///
    /// LibRaw's processed-RGB path is not involved: this calls `decodeMosaic`,
    /// and every stage after it is ours.
    ///
    /// - Throws: whatever the stage that failed reports —
    ///   `RAWDecodingError`, `RAWProcessingError` or `CancellationError`.
    func prepare(
        decoding url: URL,
        using decoder: RAWDecoder,
        whiteBalance: UserWhiteBalanceAdjustment,
        cameraToWorkingTransform: RAWCameraToWorkingColorTransform,
        cancellation: ProcessingCancellation = .none
    ) throws -> PreparedWorkingImage {
        let base = try RAWBasePreparationPipeline().prepare(decoding: url, using: decoder)
        return try prepare(
            base,
            whiteBalance: whiteBalance,
            cameraToWorkingTransform: cameraToWorkingTransform,
            cancellation: cancellation
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
    /// The white balance the **user** asked for, as intent.
    ///
    /// Kept beside the estimate rather than derived from it, for the reason
    /// `WorkspacePreview` keeps the channel-mix adjustment beside the applied
    /// matrix: one is what a person chose and the other is what the pipeline
    /// measured. A control reads this; an audit of the rendering reads
    /// `estimate`.
    let whiteBalance: UserWhiteBalanceAdjustment
    /// What the estimator measured and produced: the resolved region, the
    /// per-plane statistics, the target mean and the gains.
    let estimate: RAWWhiteBalanceEstimate

    /// The region the white balance was estimated from, in full-resolution
    /// sensor (pre-orientation) active-area coordinates.
    var neutralPatch: RAWActiveAreaRegion { estimate.region }
    /// The multipliers the estimate produced, indexed by CFA colour plane.
    var whiteBalanceGains: RAWWhiteBalanceGains { estimate.gains }
}
