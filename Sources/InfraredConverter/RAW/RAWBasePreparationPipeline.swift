import Foundation

/// The part of the RAW front half that depends on **nothing the user can
/// decide**: read the file, unpack the mosaic, subtract black and normalise.
///
/// ```text
/// URL
///     ↓  RAWDecoder.decodeMosaic
/// DecodedRAWMosaic                   ← raw UInt16 samples; released here
///     ↓  RAWMosaicNormalizer
/// LinearRAWMosaic                    ← scene-linear Float32 CFA samples
/// ```
///
/// ## Why this is its own pipeline
///
/// Because the white balance became a user decision, and the stages above are
/// the ones it cannot reach. Everything from the white-balance estimate
/// onwards depends on which samples the user pointed at; everything here
/// depends only on the file. Splitting them at exactly that line is what lets
/// the workspace re-balance a photograph without decoding it again:
///
/// ```text
/// open a file        decode → normalise → RETAIN                (once)
/// pick a patch       retained mosaic → estimate → balance → …   (per pick)
/// ```
///
/// The split is not an optimisation bolted onto a pipeline: it is the
/// boundary the adjustment model already implies. See
/// `docs/decisions/0019-interactive-white-balance.md`.
///
/// ## Cost, and what it is not cancellable
///
/// The single most expensive thing in the RAW path — a long blocking C++
/// decode followed by one pass over every sample — and it is **not**
/// cooperatively cancellable: neither `decodeMosaic` nor `RAWMosaicNormalizer`
/// polls a cancellation signal, so it is abandoned only at the task boundary.
///
/// That is deliberate scope rather than an oversight. This runs once, when a
/// file is opened, in response to a user action that cannot be repeated by
/// holding a control down. The half a user *can* re-trigger repeatedly — the
/// white balance, the demosaic, the working conversion and the reduction — is
/// the half that polls, and it begins after this returns.
struct RAWBasePreparationPipeline: Sendable {
    init() {}

    /// Decodes a RAW file and normalises its mosaic, and stops.
    ///
    /// LibRaw's processed-RGB path is not involved: this calls `decodeMosaic`,
    /// and the normalisation after it is ours.
    ///
    /// - Throws: whatever the stage that failed reports —
    ///   `RAWDecodingError` or `RAWProcessingError`.
    func prepare(
        decoding url: URL,
        using decoder: RAWDecoder
    ) throws -> NormalizedRAWSource {
        let decoded = try decoder.decodeMosaic(at: url)

        // `.mosaic`, deliberately, rather than the `ProcessedRAWMosaic`
        // wrapper the normaliser returns. The wrapper keeps its `source`
        // reachable, which on the reference camera is a 24 MB UInt16 buffer
        // this value would then hold for as long as the file is open — beside
        // the 49 MB of Float32 that replaced it. The decoded mosaic becomes
        // unreachable when this function returns.
        let normalized = try RAWMosaicNormalizer().process(decoded).mosaic

        return NormalizedRAWSource(
            mosaic: normalized, metadata: decoded.metadata, url: url
        )
    }
}

/// One RAW file, decoded and normalised: the state every white balance is
/// estimated from and applied to.
///
/// ```text
/// full sensor resolution      the active image area, unreduced
/// scene-linear Float32        black subtracted, divided by the white level
/// still a CFA mosaic          one colour per sample; not demosaiced
/// no white balance            LinearRAWMosaic's own contract says so
/// ```
///
/// ## It is the workspace's one retained full-resolution buffer
///
/// A document holds exactly this and one reduced preview. That is a deliberate
/// exception to a rule this project otherwise keeps — nothing full-resolution
/// survives preparation — and the reason is that the alternative is worse: a
/// user moving the neutral patch would re-read and re-normalise a
/// twelve-megapixel file on every pick, when neither stage depends on the
/// patch at all.
///
/// It is **one** buffer, not a chain. `RAWBasePreparationPipeline` stores the
/// bare mosaic rather than the normaliser's wrapper precisely so the decoded
/// UInt16 samples are unreachable from here, and everything the white balance
/// produces — the balanced mosaic, the demosaiced image, the working-colour
/// image — is transient and goes out of scope when a preparation returns.
///
/// On the reference camera it is 4056 × 3040 × 4 bytes ≈ 49 MB. See
/// `docs/decisions/0019-interactive-white-balance.md`.
///
/// ## Not the truth, and not an export source
///
/// The canonical editing state of a photograph is unchanged:
///
/// ```text
/// the RAW file  +  ImageAdjustments
/// ```
///
/// This is a cache derived from the first of those two, and the export path
/// deliberately does not consume it — it reads the file again, so that an
/// exported rendering is reproducible from the file alone rather than from
/// whatever a workspace happened to be holding.
struct NormalizedRAWSource: Sendable {
    /// The normalised, **unbalanced** scene-linear mosaic. Its type says it
    /// is unbalanced: `LinearRAWMosaic.processing.whiteBalanceApplied` is a
    /// `let` constant of `false`, and the balancer's result is a different
    /// type that this value cannot hold.
    let mosaic: LinearRAWMosaic
    /// The RAW-state metadata the mosaic was read with.
    let metadata: RAWMetadata
    /// The file these samples came from.
    let url: URL

    /// Width of the active image area, in samples.
    var activeAreaWidth: Int { mosaic.width }
    /// Height of the active image area, in samples.
    var activeAreaHeight: Int { mosaic.height }
}
