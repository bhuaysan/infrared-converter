import Foundation

/// Why a rendered image has the geometry it has.
///
/// The orientation stage's own record, `ImageOrientationProcessing`, says
/// which arrangement was applied. It deliberately does not say **why**: the
/// stage is handed one orientation and has no idea whether a file asked for
/// it, a user did, or both. That question is the application layer's, so the
/// answer lives here.
///
/// ```text
/// decoder / source orientation    ─┐
///                                  ├─ EffectiveImageOrientation ─→ applied
/// user orientation adjustment     ─┘
///                                          │
///                                          ↓
///                      ImageOrientationProcessing   the stage's own record
///                                          │  channelMixProcessing
///                                          ↓
///                          IRChannelMixProcessing   and the whole chain below
/// ```
///
/// ## Nothing upstream is copied
///
/// The same rule every provenance type in this project follows: the mix, the
/// camera-to-working transform, the demosaic algorithm, the gains, the white
/// level and the black subtraction all already live on `stage` and are read
/// **through** it. Two copies of the same history can disagree; one cannot.
public struct OrientationProvenance: Equatable, Sendable {

    /// The three orientation facts, kept distinct: what the file said, what
    /// the user asked for, and what was applied.
    public let orientation: EffectiveImageOrientation

    /// The orientation stage's own record, and through it the entire upstream
    /// chain back to the unpacked mosaic.
    public let stage: ImageOrientationProcessing

    /// Module-internal: only the application layer pairs a derivation with
    /// the stage record it actually drove. Outside the module the pairing can
    /// be read in full but not minted, so a derivation from one render cannot
    /// be attached to a stage record from another.
    init(orientation: EffectiveImageOrientation, stage: ImageOrientationProcessing) {
        self.orientation = orientation
        self.stage = stage
    }

    /// What the decoder reported for this file. Unchanged by anything the
    /// user does.
    public var sourceOrientation: RAWImageOrientation { orientation.source }

    /// What the user asked for, as a canonical single state.
    public var userAdjustment: UserOrientationAdjustment { orientation.userAdjustment }

    /// The orientation the pixels were actually permuted by.
    public var effectiveOrientation: RAWImageOrientation { orientation.applied }

    /// Whether the user asked for any correction at all.
    public var isUserAdjusted: Bool { orientation.isUserAdjusted }

    /// The orientation the stage reports it applied.
    ///
    /// Equal to `effectiveOrientation` for every provenance the application
    /// produces, and worth being able to compare rather than assume: the
    /// derivation and the permutation agreeing is the invariant that makes
    /// this record trustworthy.
    public var stageOrientation: RAWImageOrientation { stage.orientation }

    /// Whether the derivation and the stage agree about what was applied.
    public var isConsistent: Bool { stageOrientation == effectiveOrientation }

    /// The creative channel mix applied upstream, and through it the rest of
    /// the chain. Read, never copied.
    public var channelMixProcessing: IRChannelMixProcessing { stage.channelMixProcessing }

    /// A one-line account of the geometry, naming all three facts.
    public var diagnosticDescription: String { orientation.diagnosticDescription }
}
