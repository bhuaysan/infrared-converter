import Foundation

/// How an estimator decides the overall scale of the gains it produces.
///
/// The scale is a real choice, not an implementation detail: `[1, 2, 5, 2.5]`
/// and `[0.2, 0.4, 1, 0.5]` describe the same colour balance and differ only
/// in exposure. `RAWWhiteBalancer` deliberately has no opinion — it multiplies
/// literally — so the opinion has to live here, named and recorded.
///
/// Exactly one policy exists. It is an enum rather than an unstated
/// convention so that adding a second (preserve luminance, normalise green to
/// `1`, preserve the weakest plane) is a visible change with a visible effect
/// on every image already estimated, rather than a silent change of meaning.
public enum RAWWhiteBalanceEstimationScalePolicy: Equatable, Sendable {
    /// Scale so the strongest measured plane keeps a gain of exactly `1`, and
    /// every other measured plane is lifted to match it:
    ///
    /// ```text
    /// target       = max(mean of every colour plane present in the layout)
    /// gain[plane]  = target / mean[plane]
    /// ```
    ///
    /// So no measured plane is ever attenuated, at least one gain is exactly
    /// `1`, and no measured gain is below `1`. The alternative — dividing
    /// through by the weakest plane, or by green — would multiply the
    /// strongest plane by less than one and quietly darken it, which for
    /// infrared capture is usually the plane carrying most of the signal.
    ///
    /// Colour-plane slots the sensor layout never produces are not measured
    /// and are left at identity.
    case preserveStrongestMeasuredPlane
}

/// What one CFA colour plane measured inside a selected patch.
///
/// `mean` is `nil` exactly when `sampleCount` is `0`: a mean of no samples is
/// not a number, and recording `0` for it would be indistinguishable from a
/// plane that genuinely measured zero.
///
/// ## An observation, not a parameter
///
/// This is a record of a measurement that already happened. Its properties are
/// `let` and its initialiser is module-internal: outside the module it can be
/// read in full but neither edited nor forged. Editing a historical
/// measurement is not a use case — it is how provenance comes to describe
/// numbers it did not produce.
public struct RAWColorPlaneStatistics: Equatable, Sendable {
    /// How many samples of this colour plane the patch contained.
    public let sampleCount: Int
    /// The arithmetic mean of those samples, accumulated in `Double`, or
    /// `nil` when there were none.
    ///
    /// Every finite sample of the plane inside the patch contributes: nothing
    /// is clamped, rejected, offset or made absolute first. Negative values
    /// are legitimate black-subtracted sensor noise and lower this mean, as
    /// they should.
    public let mean: Double?

    /// Module-internal: only `RAWWhiteBalanceEstimator` produces these
    /// records. See the type's own note on why they are not forgeable from
    /// outside.
    init(sampleCount: Int, mean: Double?) {
        self.sampleCount = sampleCount
        self.mean = mean
    }
}

/// Per-CFA-plane statistics measured over one selected patch.
///
/// ## Four optional slots, addressed literally
///
/// The four slots are indexed by the CFA colour-plane index that
/// `SensorColorLayout.colorPlaneIndex(row:column:)` returns, exactly like
/// `RAWWhiteBalanceGains` — never by `colorCount`, and never modulo anything.
///
/// A slot is `nil` when the sensor layout **never produces that plane index**
/// anywhere in its repeating CFA cell. That is a different fact from a plane
/// that exists but happened to fall outside the patch, which is recorded as a
/// present slot with `sampleCount == 0`, and which estimation refuses to
/// invent a gain for.
///
/// ```text
/// slot == nil                      → plane not in this sensor layout  → gain 1
/// slot!.sampleCount == 0           → plane exists, patch missed it    → error
/// slot!.sampleCount  > 0           → measured                         → gain from mean
/// ```
///
/// As with `RAWColorPlaneStatistics`, this is an observation: `let`
/// properties, module-internal initialiser, fully readable from anywhere.
public struct RAWNeutralPatchStatistics: Equatable, Sendable {
    /// Statistics for CFA colour plane `0`, or `nil` when the layout has no
    /// such plane.
    public let plane0: RAWColorPlaneStatistics?
    /// Statistics for CFA colour plane `1` — the first green on an RGBG
    /// layout. Independent of `plane3`.
    public let plane1: RAWColorPlaneStatistics?
    /// Statistics for CFA colour plane `2`.
    public let plane2: RAWColorPlaneStatistics?
    /// Statistics for CFA colour plane `3` — the second green on an RGBG
    /// layout, a real plane even when `colorCount == 3`, and measured
    /// independently of `plane1`.
    public let plane3: RAWColorPlaneStatistics?

    /// Module-internal: only `RAWWhiteBalanceEstimator` produces these.
    init(
        plane0: RAWColorPlaneStatistics?,
        plane1: RAWColorPlaneStatistics?,
        plane2: RAWColorPlaneStatistics?,
        plane3: RAWColorPlaneStatistics?
    ) {
        self.plane0 = plane0
        self.plane1 = plane1
        self.plane2 = plane2
        self.plane3 = plane3
    }

    /// Statistics for a CFA colour-plane index, or `nil` both when the index
    /// is outside `0..<RAWWhiteBalanceGains.planeCount` and when the layout
    /// has no such plane.
    public func statistics(forColorPlane index: Int) -> RAWColorPlaneStatistics? {
        switch index {
        case 0: return plane0
        case 1: return plane1
        case 2: return plane2
        case 3: return plane3
        default: return nil
        }
    }

    /// The colour-plane indices the sensor layout actually produces, ascending.
    public var measuredColorPlanes: [Int] {
        (0..<RAWWhiteBalanceGains.planeCount).filter { statistics(forColorPlane: $0) != nil }
    }

    /// Sample counts in colour-plane order, `0` for planes the layout does
    /// not produce. For provenance and diagnostics, not the per-sample path.
    public var sampleCountsByColorPlane: [Int] {
        (0..<RAWWhiteBalanceGains.planeCount).map {
            statistics(forColorPlane: $0)?.sampleCount ?? 0
        }
    }

    /// Arithmetic means in colour-plane order, `nil` for planes the layout
    /// does not produce and for planes with no samples.
    public var meansByColorPlane: [Double?] {
        (0..<RAWWhiteBalanceGains.planeCount).map { statistics(forColorPlane: $0)?.mean }
    }
}

/// How a set of gains was obtained by measuring a rectangular neutral patch.
///
/// This is the provenance half of `RAWWhiteBalanceEstimate`, and it is what
/// `RAWWhiteBalanceProcessing.gainSource` carries. It deliberately does **not**
/// repeat the gains: they are already stored, literally, in
/// `RAWWhiteBalanceProcessing.gains`, and two copies of the same numbers can
/// disagree. This record explains how those numbers were arrived at — from
/// which samples, under which policy, against which target.
///
/// ## Not forgeable from outside the module
///
/// Every property is `let` and the initialiser is module-internal, so
/// `RAWWhiteBalanceEstimator` is the only thing that can mint one. External
/// consumers need to *inspect* provenance — read the region, the policy, the
/// statistics, the target — not to author an estimator result. That
/// restriction is also what stops a caller from attaching a plausible-looking
/// `.neutralPatch` provenance to gains no measurement produced.
public struct RAWNeutralPatchWhiteBalanceSource: Equatable, Sendable {
    /// The active-image rectangle the statistics were measured over.
    public let region: RAWActiveAreaRegion
    /// The policy that turned the statistics into gains.
    public let scalePolicy: RAWWhiteBalanceEstimationScalePolicy
    /// What each CFA colour plane measured inside `region`.
    public let statistics: RAWNeutralPatchStatistics
    /// The plane mean every measured plane was scaled to.
    public let targetMean: Double

    /// Module-internal: only `RAWWhiteBalanceEstimator` produces these.
    init(
        region: RAWActiveAreaRegion,
        scalePolicy: RAWWhiteBalanceEstimationScalePolicy,
        statistics: RAWNeutralPatchStatistics,
        targetMean: Double
    ) {
        self.region = region
        self.scalePolicy = scalePolicy
        self.statistics = statistics
        self.targetMean = targetMean
    }
}

/// The result of estimating white balance from a neutral patch: the gains,
/// plus everything needed to see exactly how they were obtained.
///
/// Deliberately not four bare `Float`s. A gain of `5.2` is not reviewable on
/// its own; `5.2, because plane 2's 1024 samples in a 64×64 patch at
/// (1488, 1996) averaged 0.0962 against a target of 0.5` is.
///
/// Nothing here has been applied to an image. Handing this to
/// `RAWWhiteBalancer.apply(to:estimate:)` is what applies it, and that
/// overload takes the gains and the provenance from the *same* estimate so
/// the two cannot be mismatched.
///
/// ## The two halves cannot be separated or swapped
///
/// This is enforced by the type, not by call-site discipline:
///
/// - both properties are `let`, so neither half can be replaced after the
///   estimator paired them;
/// - the initialiser is module-internal, so an estimate cannot be minted
///   outside the module with gains and provenance that never met;
/// - `RAWWhiteBalancer` exposes no public way to supply a
///   `RAWWhiteBalanceSource` alongside gains — an apply either takes bare
///   gains and records `.explicit`, or takes a whole estimate and records
///   *that estimate's* provenance.
///
/// Together those make "gains of `[2, 3, 4, 5]`, obtained by measuring a
/// patch that produced `[1, 1.44, 6.8, 1.43]`" unrepresentable rather than
/// merely discouraged.
public struct RAWWhiteBalanceEstimate: Equatable, Sendable {
    /// The estimated multipliers, indexed by CFA colour plane. Slots for
    /// planes the sensor layout does not produce are exactly `1`.
    public let gains: RAWWhiteBalanceGains
    /// How `gains` was obtained.
    public let provenance: RAWNeutralPatchWhiteBalanceSource

    /// Module-internal, deliberately: see the type's note above. Only
    /// `RAWWhiteBalanceEstimator` pairs gains with the measurement that
    /// produced them.
    init(gains: RAWWhiteBalanceGains, provenance: RAWNeutralPatchWhiteBalanceSource) {
        self.gains = gains
        self.provenance = provenance
    }

    /// `provenance` as the enum `RAWWhiteBalanceProcessing` records.
    public var source: RAWWhiteBalanceSource { .neutralPatch(provenance) }

    /// The active-image rectangle that was measured.
    public var region: RAWActiveAreaRegion { provenance.region }
    /// The scale policy that produced `gains`.
    public var scalePolicy: RAWWhiteBalanceEstimationScalePolicy { provenance.scalePolicy }
    /// What each CFA colour plane measured.
    public var statistics: RAWNeutralPatchStatistics { provenance.statistics }
    /// The plane mean every measured plane was scaled to.
    public var targetMean: Double { provenance.targetMean }
}
