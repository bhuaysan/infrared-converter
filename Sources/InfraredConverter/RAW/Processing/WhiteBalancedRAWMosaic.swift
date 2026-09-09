import Foundation

/// Where a set of `RAWWhiteBalanceGains` came from.
///
/// A case is added when the feature that produces it exists, never before:
/// declaring cases for absent features would put metadata in the archive that
/// no code can honestly produce. Automatic estimation, filter profiles and
/// saved recipes are therefore still absent.
///
/// A case carries **how** the gains were obtained, not the gains themselves.
/// Those are already recorded, literally, in
/// `RAWWhiteBalanceProcessing.gains`, and a second copy could disagree with
/// the first.
public enum RAWWhiteBalanceSource: Equatable, Sendable {
    /// The gains were supplied literally by the caller.
    case explicit
    /// The gains were estimated by measuring a rectangular patch of the
    /// pre-white-balance `LinearRAWMosaic`. See `RAWWhiteBalanceEstimator`.
    case neutralPatch(RAWNeutralPatchWhiteBalanceSource)
}

/// What the white-balance stage did — and explicitly did not do — to produce
/// a `WhiteBalancedRAWMosaic`.
///
/// As with `RAWLinearProcessing`, the false facts are `let` constants rather
/// than caller-settable parameters: they are structural properties of this
/// stage, not choices.
public struct RAWWhiteBalanceProcessing: Equatable, Sendable {
    /// The exact multipliers applied, per CFA colour plane.
    ///
    /// The gains themselves, not a label for them: given `[2, 3, 4, 5]` this
    /// records `[2, 3, 4, 5]`. So, given the same `LinearRAWMosaic`, this
    /// record contains the exact gains required to reproduce the
    /// white-balance transformation. "Custom white balance" would not.
    ///
    /// Note the precise claim. This record does **not** carry the source
    /// pixels, so it reproduces the *transformation*, not the image; the
    /// normalised mosaic it was applied to has to come from
    /// `WhiteBalancedProcessedRAWMosaic.linearMosaic` or from decoding and
    /// normalising the file again.
    public var gains: RAWWhiteBalanceGains
    /// How those gains were arrived at.
    public var gainSource: RAWWhiteBalanceSource
    /// Provenance of the `LinearRAWMosaic` this stage consumed, carried
    /// forward so the whole chain from unpacked samples to here is readable
    /// from one record.
    public var linearProcessing: RAWLinearProcessing

    /// White balance has been applied.
    public let whiteBalanceApplied: Bool = true
    /// Nothing was clamped, before or after multiplication. Values below `0`
    /// and above `1` are preserved exactly as the arithmetic produced them.
    public let clamped: Bool = false
    /// No demosaicing: still one value per CFA location.
    public let demosaiced: Bool = false
    /// No camera or vendor colour matrix has been applied.
    public let cameraColorMatrixApplied: Bool = false
    /// No gamma or other transfer function has been applied.
    public let gammaApplied: Bool = false
    /// No orientation (rotation/flip) transform has been applied.
    public let orientationApplied: Bool = false

    public init(
        gains: RAWWhiteBalanceGains,
        gainSource: RAWWhiteBalanceSource,
        linearProcessing: RAWLinearProcessing
    ) {
        self.gains = gains
        self.gainSource = gainSource
        self.linearProcessing = linearProcessing
    }
}

/// One `Float32` sample per sensor mosaic location, active area only, after
/// black subtraction, normalisation and per-CFA-plane white-balance gains —
/// and after nothing else.
///
/// ## What a value IS
///
/// For each mosaic position, with `linear` the corresponding
/// `LinearRAWMosaic` value and `gain` the multiplier for that position's CFA
/// colour plane:
///
/// ```text
/// value = linear * gain
/// ```
///
/// That is the whole operation. No offset, no renormalisation, no exposure
/// compensation.
///
/// ## What a value is NOT
///
/// - **Not clamped.** Negative values (samples under their black level,
///   scaled by a positive gain) stay negative, and values above `1` stay
///   above `1`. Highlight handling is a later, explicit stage.
/// - **Not camera-white-balanced.** The gains came from the caller. Neither
///   `cameraMultipliers` (`cam_mul`) nor `daylightMultipliers` (`pre_mul`)
///   is read anywhere on this path; see `RAWWhiteBalancer`.
/// - **Not demosaiced, not RGB.** There is still exactly one value per CFA
///   location, and its colour plane comes from `sensorColorLayout`.
/// - **Not colour-converted, not gamma-encoded, not oriented.**
///
/// ## Coordinate convention
///
/// Identical to the `LinearRAWMosaic` this was produced from, and therefore
/// to the `RAWMosaic` before that: `(0, 0)` is the top-left of the **active
/// image area**, dimensions are unchanged, and `sensorColorLayout` is carried
/// over untouched, so `colorPlaneIndex(row:column:)` returns the same plane
/// for the same coordinate as it did before white balance. No crop, no
/// rotation, no CFA phase change.
///
/// ## Storage
///
/// `values` is a plain `[Float]`, tightly packed and row-major:
/// `values[row * width + column]`, matching `LinearRAWMosaic` exactly.
public struct WhiteBalancedRAWMosaic: Equatable, Sendable {
    /// Width of the active mosaic area, in samples. Equal to the source
    /// `LinearRAWMosaic.width`.
    public let width: Int
    /// Height of the active mosaic area, in samples. Equal to the source
    /// `LinearRAWMosaic.height`.
    public let height: Int
    /// `width * height` white-balanced values, row-major and tightly packed.
    public let values: [Float]
    /// The sensor's colour-filter layout, carried over unchanged.
    public let sensorColorLayout: RAWMetadata.SensorColorLayout
    /// What produced these values, including the exact gains.
    public let processing: RAWWhiteBalanceProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        sensorColorLayout: RAWMetadata.SensorColorLayout,
        processing: RAWWhiteBalanceProcessing
    ) {
        self.width = width
        self.height = height
        self.values = values
        self.sensorColorLayout = sensorColorLayout
        self.processing = processing
    }

    /// Elements between the starts of consecutive rows. Always `width`.
    public var valuesPerRow: Int { width }

    /// The element count implied by `width * height`, or `nil` when that
    /// multiplication would overflow `Int`.
    public var expectedValueCount: Int? {
        let (result, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : result
    }

    /// True when `values` holds exactly the declared geometry's worth of
    /// elements. Non-positive dimensions, or geometry whose implied count
    /// would overflow, make this `false` rather than trap.
    public var isGeometryConsistent: Bool {
        guard width > 0, height > 0, let expected = expectedValueCount else { return false }
        return values.count == expected
    }

    /// The white-balanced value at an active-image coordinate, or `nil` when
    /// out of bounds. Never traps, for any value the public initialiser
    /// accepts.
    public func value(row: Int, column: Int) -> Float? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: width)
        guard !rowOverflow else { return nil }
        let (index, indexOverflow) = rowOffset.addingReportingOverflow(column)
        guard !indexOverflow, index >= 0, index < values.count else { return nil }
        return values[index]
    }

    /// The colour-plane index at an active-image coordinate, bounds-checked
    /// against this mosaic's own extent first. Matches the source
    /// `LinearRAWMosaic.colorPlaneIndex(row:column:)` exactly.
    public func colorPlaneIndex(row: Int, column: Int) -> Int? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        return sensorColorLayout.colorPlaneIndex(row: row, column: column)
    }
}

/// A `WhiteBalancedRAWMosaic` paired with the normalised state it was
/// produced from.
///
/// ## Why the source is kept
///
/// White balance is the first stage a user will want to change repeatedly,
/// and re-applying gains to an already-balanced buffer would compound them:
/// gains of `2` followed by gains of `3` would silently mean `6`. Keeping the
/// pre-white-balance `ProcessedRAWMosaic` reachable makes the correct
/// behaviour the easy one.
///
/// The invariant this type exists to protect:
///
/// ```text
/// new result = apply(new gains, the normalised mosaic)
///        NOT   apply(new gains, the previous white-balanced result)
/// ```
///
/// `RAWWhiteBalancer.apply(gains:replacing:)` is the structural expression of
/// that: it takes a previous result and reaches through it to `source`, so a
/// caller cannot accidentally chain.
///
/// Nothing is mutated in place, so re-balancing needs neither a LibRaw decode
/// nor a second run of black subtraction and normalisation.
public struct WhiteBalancedProcessedRAWMosaic: Sendable {
    /// The normalised, pre-white-balance state this was produced from,
    /// unchanged — and with the original `UInt16` mosaic still reachable on
    /// its own `.source`.
    public let source: ProcessedRAWMosaic
    /// The white-balanced Float32 mosaic.
    public let mosaic: WhiteBalancedRAWMosaic

    public init(source: ProcessedRAWMosaic, mosaic: WhiteBalancedRAWMosaic) {
        self.source = source
        self.mosaic = mosaic
    }

    /// The normalised mosaic white balance was applied to. Re-applying
    /// different gains must always start here.
    public var linearMosaic: LinearRAWMosaic { source.mosaic }
    /// Provenance for `mosaic`. Forwarded rather than stored a second time,
    /// so the buffer and the record of how it was made can never disagree.
    public var processing: RAWWhiteBalanceProcessing { mosaic.processing }
    /// The RAW-state metadata the normalisation ran against. Its
    /// `color.cameraMultipliers` / `color.daylightMultipliers` are
    /// diagnostics; no stage on this path reads them.
    public var metadata: RAWMetadata { source.metadata }
    public var url: URL { source.url }
}
