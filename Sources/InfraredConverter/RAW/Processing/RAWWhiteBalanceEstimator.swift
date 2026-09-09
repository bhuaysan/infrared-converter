import Foundation

/// The infrared white-balance *estimation* stage: it decides what the gains
/// should be by measuring a rectangular patch of the pre-white-balance mosaic.
///
/// ```text
/// LinearRAWMosaic
///       │
///       ├── measure the selected neutral patch
///       ↓
/// RAWWhiteBalanceEstimator          ← this type
///       ↓
/// RAWWhiteBalanceGains
///       ↓
/// RAWWhiteBalancer                  ← applies them, literally
///       ↓
/// WhiteBalancedRAWMosaic
/// ```
///
/// The two halves meet at the gains, not at the image. This type never
/// multiplies a sample, allocates an image-sized buffer, or produces a mosaic;
/// `RAWWhiteBalancer` never measures anything or rescales what it is given.
/// Keeping the split means the policy question — *what should the gains be* —
/// has exactly one home, stated out loud, instead of leaking into the apply
/// loop as a hidden normalisation.
///
/// ## Input is the normalised mosaic, before white balance
///
/// Estimating from an already-balanced mosaic would fold the previous gains
/// into the new ones. The signature enforces the right input: it takes a
/// `LinearRAWMosaic`, which by construction has `whiteBalanceApplied == false`.
///
/// ## No decoder, no camera metadata
///
/// Like every other application-owned stage, this one does not import
/// `CLibRaw`, receives no LibRaw structure, and receives no `RAWMetadata`. So
/// `cam_mul` and `pre_mul` — visible-light-calibrated diagnostics that are not
/// a reasonable infrared default — cannot leak in. That is structural, not a
/// convention: there is no parameter for them to arrive through.
///
/// ## A patch, not a pixel
///
/// A single CFA sample carries exactly one colour plane, so it cannot
/// determine the other three gains. A future UI "neutral point picker" will
/// therefore turn a click into a small rectangle and call this estimator with
/// it; the picker is presentation, this is the measurement.
///
/// ## Cost
///
/// `O(samples in the region)` time and constant auxiliary memory: four
/// `Double` sums, four counters, no per-plane arrays, no copy of the patch,
/// and no full-frame intermediate. The full mosaic is read through a borrowed
/// buffer pointer.
public struct RAWWhiteBalanceEstimator: Sendable {
    public init() {}

    // MARK: - Which colour planes the layout actually produces

    /// The CFA colour-plane indices a sensor layout can actually produce,
    /// discovered by walking one complete repeating cell through the layout's
    /// own `colorPlaneIndex(row:column:)` accessor.
    ///
    /// The cell is the layout's own repeat, not an assumed 2×2:
    ///
    /// | Pattern | Cell walked |
    /// | --- | --- |
    /// | `.bayer` | 8 rows × 2 columns — the extent of the packed `filters` code |
    /// | `.xTrans` | 6 × 6 — the `xTransPattern` table |
    ///
    /// Nothing here re-derives LibRaw's CFA decoding: the accessor is the
    /// single implementation, and this walks it. So a layout whose accessor
    /// refuses a coordinate (Foveon, full-colour files, unknown layouts,
    /// LibRaw's non-standard 16×16 code with `filters == 1`, a malformed
    /// X-Trans table) is refused here too, rather than being guessed at.
    ///
    /// `colorCount` is deliberately not consulted. On the reference camera it
    /// is `3` while the CFA genuinely produces plane `3`, so inferring the
    /// plane set from it would drop the second green.
    ///
    /// - Returns: the discovered indices, ascending. Never empty on success.
    /// - Throws: `RAWProcessingError.unsupportedSensorLayoutForEstimation`
    ///   when the layout has no per-plane mosaic to discover, and
    ///   `.unsupportedColorPlaneIndex` when it names a plane outside
    ///   `0..<RAWWhiteBalanceGains.planeCount`.
    public static func colorPlanes(
        in layout: RAWMetadata.SensorColorLayout
    ) throws -> [Int] {
        let cell: (rows: Int, columns: Int)
        switch layout.pattern {
        case .bayer:
            // The packed dcraw/LibRaw code addresses an 8-row × 2-column
            // cell; most sensors repeat every 2 rows, but walking the full
            // 8 costs 16 lookups and is correct for the ones that do not.
            cell = (rows: 8, columns: 2)
        case .xTrans:
            cell = (rows: 6, columns: 6)
        case .foveon, .none, .unknown:
            throw RAWProcessingError.unsupportedSensorLayoutForEstimation(
                pattern: layout.pattern,
                reason: """
                    This layout has no per-sample colour mosaic, so there are no CFA \
                    colour planes to measure independently.
                    """
            )
        }

        var found = Set<Int>()
        for row in 0..<cell.rows {
            for column in 0..<cell.columns {
                guard let plane = layout.colorPlaneIndex(row: row, column: column) else {
                    throw RAWProcessingError.unsupportedSensorLayoutForEstimation(
                        pattern: layout.pattern,
                        reason: """
                            The layout named no colour plane at row \(row), column \(column) \
                            of its repeating \(cell.rows)x\(cell.columns) cell.
                            """
                    )
                }
                guard plane >= 0, plane < RAWWhiteBalanceGains.planeCount else {
                    throw RAWProcessingError.unsupportedColorPlaneIndex(colorPlane: plane)
                }
                found.insert(plane)
            }
        }

        // Unreachable for the two patterns above — both cells are non-empty —
        // but an empty plane set would make every downstream guarantee
        // vacuous, so it is refused rather than assumed away.
        guard !found.isEmpty else {
            throw RAWProcessingError.unsupportedSensorLayoutForEstimation(
                pattern: layout.pattern,
                reason: "No colour planes were discovered in the repeating CFA cell."
            )
        }
        return found.sorted()
    }

    // MARK: - Measurement

    /// Measures per-CFA-plane sample counts and arithmetic means over a
    /// rectangular active-image patch.
    ///
    /// Every finite sample inside `region` participates in its plane's mean.
    /// Nothing is clamped to zero or to one, no shadows or highlights are
    /// discarded, no absolute value is taken, no epsilon is added, and no
    /// percentile or outlier rejection happens. Negative values are real —
    /// sensor noise straddles the black point — and lowering a mean is
    /// exactly what they should do.
    ///
    /// A NaN or infinite sample is reported with its coordinate rather than
    /// skipped: silently dropping it would change the denominator of a mean
    /// without saying so.
    ///
    /// Sums are accumulated in `Double` even though the mosaic stores
    /// `Float`. This is not the white-balance hot multiply loop — it runs
    /// once over a small patch — and summing thousands of `Float32` values in
    /// `Float32` would add rounding error to the one number every gain is
    /// derived from, for no measurable gain.
    ///
    /// - Throws: `RAWProcessingError`.
    public func measureNeutralPatch(
        in mosaic: LinearRAWMosaic,
        region: RAWActiveAreaRegion
    ) throws -> RAWNeutralPatchStatistics {
        guard mosaic.isGeometryConsistent else {
            throw RAWProcessingError.invalidGeometry(
                reason: """
                    Linear mosaic geometry \(mosaic.width)x\(mosaic.height) needs \
                    \(mosaic.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(mosaic.values.count).
                    """
            )
        }
        try region.validate(in: mosaic)
        let layoutPlanes = try Self.colorPlanes(in: mosaic.sensorColorLayout)

        let width = mosaic.width
        let layout = mosaic.sensorColorLayout
        // `validate(in:)` established both limits are representable and in
        // bounds, so these force-unwraps cannot fail here.
        let rowLimit = region.originRow + region.height
        let columnLimit = region.originColumn + region.width

        // Constant auxiliary memory: four sums, four counters. No per-plane
        // arrays, no copy of the patch, no dictionary on the per-sample path.
        var sum0 = 0.0, sum1 = 0.0, sum2 = 0.0, sum3 = 0.0
        var count0 = 0, count1 = 0, count2 = 0, count3 = 0

        try mosaic.values.withUnsafeBufferPointer { input in
            for row in region.originRow..<rowLimit {
                let rowOffset = row * width
                for column in region.originColumn..<columnLimit {
                    let index = rowOffset + column
                    guard index >= 0, index < input.count else {
                        throw RAWProcessingError.invalidGeometry(
                            reason: """
                                Sample at row \(row), column \(column) lies outside the \
                                mosaic's value buffer.
                                """
                        )
                    }
                    let value = input[index]
                    guard value.isFinite else {
                        throw RAWProcessingError.nonFiniteInputValue(
                            row: row, column: column, value: value
                        )
                    }
                    guard let plane = layout.colorPlaneIndex(row: row, column: column) else {
                        throw RAWProcessingError.missingColorPlane(row: row, column: column)
                    }

                    let sample = Double(value)
                    switch plane {
                    case 0: sum0 += sample; count0 += 1
                    case 1: sum1 += sample; count1 += 1
                    case 2: sum2 += sample; count2 += 1
                    case 3: sum3 += sample; count3 += 1
                    default:
                        throw RAWProcessingError.unsupportedColorPlaneIndex(colorPlane: plane)
                    }
                }
            }
        }

        let sums = [sum0, sum1, sum2, sum3]
        let counts = [count0, count1, count2, count3]

        /// A slot is present when the layout produces that plane at all. The
        /// `counts` half is defensive: a plane the cell walk did not find but
        /// the patch nevertheless contained must not silently vanish from the
        /// statistics.
        func slot(_ index: Int) -> RAWColorPlaneStatistics? {
            let count = counts[index]
            guard layoutPlanes.contains(index) || count > 0 else { return nil }
            return RAWColorPlaneStatistics(
                sampleCount: count,
                mean: count > 0 ? sums[index] / Double(count) : nil
            )
        }

        return RAWNeutralPatchStatistics(
            plane0: slot(0), plane1: slot(1), plane2: slot(2), plane3: slot(3)
        )
    }

    // MARK: - Estimation

    /// Estimates per-CFA-plane white-balance gains from a rectangular patch
    /// the caller selected as neutral.
    ///
    /// "Neutral" is the caller's claim about the scene, not something this
    /// method verifies. What it does is make that claim true of the output:
    /// under `.preserveStrongestMeasuredPlane` the returned gains equalise the
    /// patch's per-plane arithmetic means, so applying them makes the selected
    /// samples average the same in every colour plane.
    ///
    /// ```text
    /// target      = max(mean of every colour plane the layout produces)
    /// gain[plane] = target / mean[plane]        for planes the layout produces
    /// gain[plane] = 1                           for slots it does not
    /// ```
    ///
    /// Consequences, all of them tested:
    ///
    /// 1. every measured plane gets a finite, strictly positive gain;
    /// 2. at least one measured plane's gain is exactly `1`;
    /// 3. no measured plane's gain is below `1`, so nothing is attenuated;
    /// 4. applying the gains equalises the patch means, to Float32 precision;
    /// 5. unused gain slots are exactly `1`;
    /// 6. this is estimator policy — `RAWWhiteBalancer` still multiplies
    ///    literally and normalises nothing afterwards.
    ///
    /// The gains are not renormalised again after step 3.
    ///
    /// - Parameters:
    ///   - mosaic: the normalised, **pre**-white-balance mosaic.
    ///   - region: the active-image rectangle to measure. Never cropped to
    ///     fit; an out-of-bounds region is an error.
    ///   - scalePolicy: how the measured means become gains.
    /// - Throws: `RAWProcessingError`. In particular
    ///   `.insufficientPatchSamples` when a plane the sensor layout genuinely
    ///   produces received no samples from `region` — a gain is never
    ///   invented for it — and `.invalidPlaneMean` when a measured mean is
    ///   zero, negative or non-finite.
    public func estimateNeutralPatch(
        in mosaic: LinearRAWMosaic,
        region: RAWActiveAreaRegion,
        scalePolicy: RAWWhiteBalanceEstimationScalePolicy = .preserveStrongestMeasuredPlane
    ) throws -> RAWWhiteBalanceEstimate {
        let statistics = try measureNeutralPatch(in: mosaic, region: region)

        // Every plane the layout produces must have been measured, and must
        // have a mean that can scale to a target. A plane the layout does not
        // produce is simply absent here, and keeps its identity gain below.
        var means = [Int: Double]()
        for plane in 0..<RAWWhiteBalanceGains.planeCount {
            guard let planeStatistics = statistics.statistics(forColorPlane: plane) else { continue }
            guard planeStatistics.sampleCount > 0, let mean = planeStatistics.mean else {
                throw RAWProcessingError.insufficientPatchSamples(
                    colorPlane: plane, region: region
                )
            }
            guard mean.isFinite, mean > 0 else {
                throw RAWProcessingError.invalidPlaneMean(colorPlane: plane, mean: mean)
            }
            means[plane] = mean
        }
        guard let target = means.values.max() else {
            throw RAWProcessingError.unsupportedSensorLayoutForEstimation(
                pattern: mosaic.sensorColorLayout.pattern,
                reason: "No colour plane was measured, so there is no target mean."
            )
        }

        var gainValues = [Float](repeating: 1, count: RAWWhiteBalanceGains.planeCount)
        switch scalePolicy {
        case .preserveStrongestMeasuredPlane:
            for (plane, mean) in means {
                // Divided in Double and narrowed once. `target / target` is
                // exactly 1, so the strongest plane's gain is exactly 1, and
                // every other ratio is >= 1 because target is the maximum.
                let gain = Float(target / mean)
                guard gain.isFinite, gain > 0 else {
                    throw RAWProcessingError.nonFiniteEstimatedGain(
                        colorPlane: plane, targetMean: target, planeMean: mean
                    )
                }
                gainValues[plane] = gain
            }
        }

        let gains = RAWWhiteBalanceGains(
            plane0: gainValues[0],
            plane1: gainValues[1],
            plane2: gainValues[2],
            plane3: gainValues[3]
        )
        // The apply stage validates too; doing it here as well means an
        // estimate is never handed back in a state the apply stage would
        // reject.
        try gains.validate()

        return RAWWhiteBalanceEstimate(
            gains: gains,
            provenance: RAWNeutralPatchWhiteBalanceSource(
                region: region,
                scalePolicy: scalePolicy,
                statistics: statistics,
                targetMean: target
            )
        )
    }
}
