import Foundation

/// Failures the application-owned RAW processing stages can report.
///
/// Deliberately separate from `RAWDecodingError`: that type describes the
/// decoder boundary (what LibRaw could or could not do with a file), while
/// these describe our own processing refusing to proceed on decoded input.
/// Sharing one type would blur the boundary the pipeline is built around, and
/// would make a processing bug read like a file problem in the UI.
///
/// Decoded metadata is treated as untrusted input here: a black or white
/// level that cannot produce a meaningful normalisation is reported, never
/// silently substituted with a plausible one.
public enum RAWProcessingError: Error, Equatable {
    /// The input mosaic's declared geometry does not add up (non-positive
    /// dimensions, a stride narrower than the width, a buffer too small, or
    /// arithmetic that would overflow).
    case invalidGeometry(reason: String)
    /// The sensor colour layout could not name a colour plane for a
    /// coordinate inside the mosaic, so the effective black level for that
    /// sample is unknown. Layouts with no per-pixel mosaic (Foveon, already
    /// full-colour files) and LibRaw's non-standard 16×16 CFA reach this.
    case missingColorPlane(row: Int, column: Int)
    /// The white level is not above the effective black level at this
    /// sample, so `white - black` is zero or negative and no normalisation
    /// denominator exists. Reported rather than worked around: substituting
    /// a different white level would silently change what every value in the
    /// image means.
    case invalidNormalizationRange(
        whiteLevel: UInt32,
        blackLevel: UInt32,
        row: Int,
        column: Int,
        colorPlane: Int
    )
    /// A white-balance gain is not a usable multiplier: it is zero, negative,
    /// NaN, or infinite. There is deliberately no upper bound — infrared
    /// white balance legitimately needs extreme multipliers — so only these
    /// four kinds of value are refused.
    ///
    /// Note that `==` on this case is `false` when `value` is NaN, since
    /// `Float` comparison says so; match the case rather than comparing
    /// whole errors when the offending value may be NaN.
    case invalidWhiteBalanceGain(colorPlane: Int, value: Float)
    /// The sensor colour layout named a colour plane the supplied gains have
    /// no slot for, so this sample has no defined multiplier. Reported rather
    /// than folded onto an existing plane: reducing the index modulo the slot
    /// count would silently apply the wrong colour's gain.
    case missingWhiteBalanceGain(row: Int, column: Int, colorPlane: Int)
    /// An input value was NaN or infinite. The normalisation stage cannot
    /// produce either, so this means a hand-constructed or otherwise
    /// unvalidated mosaic reached a processing stage; it is reported rather
    /// than multiplied and propagated silently.
    case nonFiniteInputValue(row: Int, column: Int, value: Float)
    /// A finite input multiplied by a finite gain overflowed `Float32`. The
    /// result is reported rather than clamped to
    /// `Float.greatestFiniteMagnitude` or otherwise substituted: an image
    /// containing a silently invented value is worse than a failed stage.
    case nonFiniteWhiteBalanceResult(
        row: Int,
        column: Int,
        colorPlane: Int,
        input: Float,
        gain: Float
    )
    /// A requested active-area region is not a usable selection: a negative
    /// origin, a non-positive width or height, a far edge that overflows
    /// `Int`, or an extent past the mosaic's edge. Reported rather than
    /// cropped — silently shrinking a selection would change which samples a
    /// measurement covers without saying so.
    case invalidActiveAreaRegion(reason: String)
    /// Per-CFA-plane estimation is not meaningful for this sensor colour
    /// layout, so no set of colour planes could be discovered. Foveon,
    /// already-full-colour files, layouts the decoder did not describe,
    /// LibRaw's non-standard 16×16 Bayer code, and malformed X-Trans tables
    /// all reach this.
    case unsupportedSensorLayoutForEstimation(
        pattern: RAWMetadata.SensorColorLayout.Pattern,
        reason: String
    )
    /// The sensor colour layout names a colour-plane index outside
    /// `0..<RAWWhiteBalanceGains.planeCount`, which the four-slot gain model
    /// cannot represent. Reported rather than reduced modulo the slot count
    /// or modulo `colorCount`: either would silently estimate one colour's
    /// gain from another colour's samples.
    case unsupportedColorPlaneIndex(colorPlane: Int)
    /// A colour plane that genuinely exists in the sensor layout received no
    /// samples at all from the requested patch, so there is nothing to
    /// estimate its gain from.
    ///
    /// Deliberately distinct from a plane the layout never produces: an
    /// unused plane gets an identity gain, while this one is a patch too
    /// small or too badly placed to cover the CFA. Inventing a gain here
    /// would be fabricating a measurement.
    case insufficientPatchSamples(colorPlane: Int, region: RAWActiveAreaRegion)
    /// A measured colour plane's arithmetic mean cannot scale to a target:
    /// it is zero, negative, NaN or infinite. Dividing by it would produce an
    /// infinite, negative or undefined gain, none of which is white balance.
    ///
    /// Note that `==` on this case is `false` when `mean` is NaN, since
    /// `Double` comparison says so; match the case rather than comparing
    /// whole errors when the offending value may be NaN.
    case invalidPlaneMean(colorPlane: Int, mean: Double)
    /// `target / planeMean` is not representable as a finite, strictly
    /// positive `Float`, so the plane has no usable gain. Reported rather
    /// than clamped to `Float.greatestFiniteMagnitude`, and there is
    /// deliberately no arbitrary maximum gain: a very small but positive mean
    /// may legitimately produce a very large gain, as long as it stays
    /// finite.
    case nonFiniteEstimatedGain(colorPlane: Int, targetMean: Double, planeMean: Double)
}

extension RAWProcessingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The RAW mosaic's dimensions are inconsistent and cannot be processed."
        case .missingColorPlane:
            return "This sensor colour layout does not describe a colour plane for every sample."
        case .invalidNormalizationRange:
            return "The file's black and white levels do not describe a usable range."
        case .invalidWhiteBalanceGain:
            return "A white-balance gain is not a usable multiplier."
        case .missingWhiteBalanceGain:
            return "The white-balance gains do not cover every colour plane in this sensor layout."
        case .nonFiniteInputValue:
            return "The image data contains a value that is not a finite number."
        case .nonFiniteWhiteBalanceResult:
            return "These white-balance gains produce values too large to represent."
        case .invalidActiveAreaRegion:
            return "The selected image region is not a usable selection."
        case .unsupportedSensorLayoutForEstimation:
            return "White balance cannot be estimated from this sensor's colour layout."
        case .unsupportedColorPlaneIndex:
            return "This sensor layout names a colour plane the white-balance model cannot hold."
        case .insufficientPatchSamples:
            return "The selected region does not cover every colour of the sensor's filter array."
        case .invalidPlaneMean:
            return "The selected region is not bright enough in every colour to balance from."
        case .nonFiniteEstimatedGain:
            return "The selected region needs a white-balance gain too large to represent."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .missingColorPlane(let row, let column):
            return "No colour plane at row \(row), column \(column)."
        case .invalidNormalizationRange(let white, let black, let row, let column, let plane):
            return """
                White level \(white) is not above the effective black level \(black) \
                at row \(row), column \(column), colour plane \(plane).
                """
        case .invalidWhiteBalanceGain(let plane, let value):
            return """
                Gain \(value) for colour plane \(plane) is not finite and greater than zero.
                """
        case .missingWhiteBalanceGain(let row, let column, let plane):
            return """
                No gain for colour plane \(plane), sampled at row \(row), column \(column).
                """
        case .nonFiniteInputValue(let row, let column, let value):
            return "Value \(value) at row \(row), column \(column) is not finite."
        case .nonFiniteWhiteBalanceResult(let row, let column, let plane, let input, let gain):
            return """
                \(input) x \(gain) overflows Float32 at row \(row), column \(column), \
                colour plane \(plane).
                """
        case .invalidActiveAreaRegion(let reason):
            return reason
        case .unsupportedSensorLayoutForEstimation(let pattern, let reason):
            return "Sensor layout \(pattern): \(reason)"
        case .unsupportedColorPlaneIndex(let plane):
            return """
                Colour plane \(plane) is outside 0..<\(RAWWhiteBalanceGains.planeCount), \
                which the gain model cannot address.
                """
        case .insufficientPatchSamples(let plane, let region):
            return """
                Colour plane \(plane) exists in this sensor layout but received no samples \
                from the region at row \(region.originRow), column \(region.originColumn), \
                size \(region.width)x\(region.height).
                """
        case .invalidPlaneMean(let plane, let mean):
            return """
                Colour plane \(plane) has arithmetic mean \(mean), which is not finite and \
                greater than zero.
                """
        case .nonFiniteEstimatedGain(let plane, let target, let mean):
            return """
                Target mean \(target) divided by colour plane \(plane)'s mean \(mean) is not \
                a finite positive Float32.
                """
        }
    }
}
