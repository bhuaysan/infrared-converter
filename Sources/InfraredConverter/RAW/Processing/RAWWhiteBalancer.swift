import Foundation

/// The infrared white-balance stage: explicit per-CFA-plane linear gains,
/// `LinearRAWMosaic` → `WhiteBalancedRAWMosaic`.
///
/// ```text
/// LibRawDecoder
///       ↓
/// RAWMosaic                 ← LibRaw's responsibility ends here
///       ↓
/// RAWMosaicNormalizer
///       ↓
/// LinearRAWMosaic
///       ↓
/// RAWWhiteBalancer          ← this stage
///       ↓
/// WhiteBalancedRAWMosaic
/// ```
///
/// Like `RAWMosaicNormalizer`, this type is application-owned and lives
/// outside the decoder: it does not import `CLibRaw`, reads no LibRaw
/// structure, and has no idea which decoder produced its input. That is not
/// only tidiness — it is what makes silently applying a camera white balance
/// *impossible* here rather than merely discouraged (see below).
///
/// ## Applies, never estimates
///
/// This is the apply half of a deliberate split:
///
/// ```text
/// ESTIMATE gains        (future: neutral point, neutral patch, automatic,
///                        filter profiles, saved recipes)
///         ↓
/// RAWWhiteBalanceGains
///         ↓
/// APPLY gains           (this type)
/// ```
///
/// No estimation happens here — no grey-world, no percentile, no neutral
/// patch, no camera-WB conversion, no temperature/tint model. Every future
/// way of *deciding* what the gains should be is expected to end by producing
/// a `RAWWhiteBalanceGains` and handing it to this same primitive.
///
/// ## Gains are literal
///
/// For every sample:
///
/// ```text
/// output = input * gainForThatSamplesColorPlane
/// ```
///
/// Nothing else. In particular this stage does **not**:
///
/// - normalise the gains so green becomes `1`,
/// - divide through by the largest or the smallest gain,
/// - preserve average luminance or overall exposure,
/// - rescale the gains against `cam_mul` or `pre_mul`.
///
/// So `0.25` with a gain of `4` is `1.0`, and doubling every gain doubles
/// every output value. That is intentional at this layer. Choosing a
/// canonical scale is a policy question, and it belongs to whichever future
/// estimator produces the gains — which will then have to state its policy
/// explicitly, rather than inheriting a hidden one from here.
///
/// ## Camera and daylight multipliers are unused
///
/// `RAWMetadata.Color.cameraMultipliers` (LibRaw's `cam_mul`) and
/// `daylightMultipliers` (`pre_mul`) are visible-light-calibrated diagnostics.
/// For infrared capture they are not a reasonable default, so they are never
/// applied here. This method's signature is the enforcement: it receives a
/// mosaic and a set of gains and no metadata at all, so there is nothing for
/// a camera white balance to leak in through.
///
/// ## Before demosaicing
///
/// Gains are applied to the CFA mosaic, one value per sensor location, not to
/// demosaiced RGB. The order is black subtraction → normalisation → infrared
/// white balance → demosaic; see
/// `docs/decisions/0003-infrared-white-balance.md`.
public struct RAWWhiteBalancer: Sendable {
    public init() {}

    /// Applies explicit per-CFA-plane gains to a normalised mosaic.
    ///
    /// The gains are validated in full before any pixel is touched, so an
    /// invalid gain fails immediately rather than partway through a
    /// 12-megapixel buffer.
    ///
    /// - Parameters:
    ///   - mosaic: the normalised, pre-white-balance mosaic.
    ///   - gains: the literal multipliers, indexed by CFA colour plane.
    ///   - gainSource: how those gains were arrived at, recorded in
    ///     provenance. Only `.explicit` exists today.
    /// - Throws: `RAWProcessingError`.
    public func apply(
        to mosaic: LinearRAWMosaic,
        gains: RAWWhiteBalanceGains,
        gainSource: RAWWhiteBalanceSource = .explicit
    ) throws -> WhiteBalancedRAWMosaic {
        try gains.validate()

        guard mosaic.isGeometryConsistent else {
            throw RAWProcessingError.invalidGeometry(
                reason: """
                    Linear mosaic geometry \(mosaic.width)x\(mosaic.height) needs \
                    \(mosaic.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(mosaic.values.count).
                    """
            )
        }
        // `isGeometryConsistent` already establishes this product, but it is
        // recomputed rather than inferred so the allocation size below stands
        // on its own arithmetic.
        let (valueCount, countOverflow) = mosaic.width.multipliedReportingOverflow(by: mosaic.height)
        guard !countOverflow else {
            throw RAWProcessingError.invalidGeometry(
                reason: "Element count \(mosaic.width) x \(mosaic.height) overflows."
            )
        }

        let width = mosaic.width
        let height = mosaic.height
        let layout = mosaic.sensorColorLayout

        // Four locals rather than a per-sample call through the gains value:
        // the lookup below is then a switch over registers, with no
        // allocation and no dictionary, on every one of ~12 million samples.
        let gain0 = gains.plane0
        let gain1 = gains.plane1
        let gain2 = gains.plane2
        let gain3 = gains.plane3

        // One owned Float32 allocation, written once. The input is read
        // through a borrowed buffer pointer: no intermediate copy of the
        // source, no second output buffer, no Double staging, no per-plane
        // full-resolution pass, and no separate validation scan — input
        // finiteness is established by the same multiplication that produces
        // the output.
        let values = try [Float](unsafeUninitializedCapacity: valueCount) { buffer, initializedCount in
            initializedCount = 0
            try mosaic.values.withUnsafeBufferPointer { input in
                guard input.count >= valueCount else {
                    throw RAWProcessingError.invalidGeometry(
                        reason: "Value buffer is smaller than the declared geometry requires."
                    )
                }

                var index = 0
                for row in 0..<height {
                    for column in 0..<width {
                        guard let plane = layout.colorPlaneIndex(row: row, column: column) else {
                            initializedCount = index
                            throw RAWProcessingError.missingColorPlane(row: row, column: column)
                        }
                        let gain: Float
                        switch plane {
                        case 0: gain = gain0
                        case 1: gain = gain1
                        case 2: gain = gain2
                        case 3: gain = gain3
                        default:
                            initializedCount = index
                            throw RAWProcessingError.missingWhiteBalanceGain(
                                row: row, column: column, colorPlane: plane
                            )
                        }

                        let value = input[index]
                        let result = value * gain

                        // The single hot-path check. A finite input times a
                        // finite positive gain is non-finite only on
                        // overflow, and a non-finite input propagates, so
                        // one test covers both failures; which of the two it
                        // was is worked out on the cold path, where building
                        // an error costs nothing.
                        guard result.isFinite else {
                            initializedCount = index
                            if !value.isFinite {
                                throw RAWProcessingError.nonFiniteInputValue(
                                    row: row, column: column, value: value
                                )
                            }
                            throw RAWProcessingError.nonFiniteWhiteBalanceResult(
                                row: row, column: column, colorPlane: plane,
                                input: value, gain: gain
                            )
                        }

                        buffer[index] = result
                        index += 1
                    }
                }
                initializedCount = index
            }
        }

        return WhiteBalancedRAWMosaic(
            width: width,
            height: height,
            values: values,
            sensorColorLayout: layout,
            processing: RAWWhiteBalanceProcessing(
                gains: gains,
                gainSource: gainSource,
                linearProcessing: mosaic.processing
            )
        )
    }

    /// Applies gains to a normalised result, keeping that whole pre-white-
    /// balance state reachable on the returned value's `source`.
    ///
    /// Use this rather than the bare-mosaic overload whenever the caller may
    /// want to change the gains later: the result carries everything needed
    /// to re-balance from the normalised source.
    public func apply(
        to processed: ProcessedRAWMosaic,
        gains: RAWWhiteBalanceGains,
        gainSource: RAWWhiteBalanceSource = .explicit
    ) throws -> WhiteBalancedProcessedRAWMosaic {
        let balanced = try apply(to: processed.mosaic, gains: gains, gainSource: gainSource)
        return WhiteBalancedProcessedRAWMosaic(source: processed, mosaic: balanced)
    }

    /// Re-balances an already-balanced result with different gains, starting
    /// from its normalised source rather than from its balanced values.
    ///
    /// This exists so that the correct behaviour is also the convenient one.
    /// Gains never compound: replacing gains of `2` with gains of `3` yields
    /// `3 × normalised`, not `6 × normalised`. Nothing is decoded again and
    /// black subtraction and normalisation are not re-run.
    public func apply(
        gains: RAWWhiteBalanceGains,
        replacing previous: WhiteBalancedProcessedRAWMosaic,
        gainSource: RAWWhiteBalanceSource = .explicit
    ) throws -> WhiteBalancedProcessedRAWMosaic {
        try apply(to: previous.source, gains: gains, gainSource: gainSource)
    }
}
