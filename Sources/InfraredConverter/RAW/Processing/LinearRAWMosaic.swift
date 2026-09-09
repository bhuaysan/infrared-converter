import Foundation

/// The white level a normalisation stage divided by, as a typed policy rather
/// than a free-form string.
///
/// Only one policy exists today. It is an enum, and not an implicit
/// assumption, so that adding an alternative later (a per-plane
/// `linearMaximum` model, a camera-profile white level, a measured
/// saturation point) is a visible, deliberate change rather than a silent
/// change of meaning for every image already processed.
public enum RAWWhiteLevelPolicy: Equatable, Sendable {
    /// `RAWMetadata.Levels.maximum` — the decoder's own saturation level for
    /// the RAW state the samples came from.
    ///
    /// Deliberately **not** `2 ^ sourceRawBitDepth - 1` (source/file-format
    /// information, not a numeric range for unpacked samples) and
    /// deliberately **not** `Levels.linearMaximum` (per-plane linearity /
    /// specular limits, which are not universally the saturation white
    /// point). See `docs/decisions/0002-raw-normalization.md`.
    case metadataMaximum
}

/// What the application-owned linear RAW stage did — and, just as
/// importantly, explicitly did not do — to produce a `LinearRAWMosaic`.
///
/// The false facts below are `let` constants rather than caller-settable
/// parameters: they are structural properties of this stage, not choices, and
/// modelling them as constants makes that self-evident from the type rather
/// than from documentation someone has to trust. The same reasoning as
/// `RAWMosaicProcessing`.
public struct RAWLinearProcessing: Equatable, Sendable {
    /// The effective black level was subtracted from every sample.
    ///
    /// "Effective" means the value
    /// `RAWMetadata.Levels.blackLevel(row:column:colorPlane:)` returns for
    /// that sample's coordinate and colour plane — the sum of the global
    /// black, the per-plane offset and the repeating pattern contribution.
    /// The stage never recombines those terms itself.
    public let blackLevelSubtracted: Bool = true
    /// Samples were divided by `whiteLevel - effectiveBlack`, so a sample at
    /// the white level maps to `1.0` and a sample at its black level maps to
    /// `0.0`.
    public let normalized: Bool = true
    /// Which white-level model supplied `whiteLevel`.
    public var whiteLevelPolicy: RAWWhiteLevelPolicy
    /// The white level actually used, in raw sample units, recorded so the
    /// normalisation can be understood or reproduced without re-reading the
    /// metadata.
    public var whiteLevel: UInt32

    /// Nothing was clamped. Values below `0` (samples under their black
    /// level) and above `1` (samples over the white level) are preserved
    /// exactly as the arithmetic produced them.
    public let clamped: Bool = false
    /// No white balance of any kind has been applied.
    public let whiteBalanceApplied: Bool = false
    /// No demosaicing: still one sample per CFA location.
    public let demosaiced: Bool = false
    /// No camera or vendor colour matrix has been applied.
    public let cameraColorMatrixApplied: Bool = false
    /// No gamma or other transfer function has been applied.
    public let gammaApplied: Bool = false
    /// No orientation (rotation/flip) transform has been applied.
    public let orientationApplied: Bool = false

    public init(whiteLevelPolicy: RAWWhiteLevelPolicy, whiteLevel: UInt32) {
        self.whiteLevelPolicy = whiteLevelPolicy
        self.whiteLevel = whiteLevel
    }
}

/// One `Float32` sample per sensor mosaic location, active area only, after
/// black subtraction and white-level normalisation — and after nothing else.
///
/// ## What a value IS
///
/// For each mosaic position, with `black` the effective black level at that
/// position and `white` the normalisation white level:
///
/// ```text
/// value = (Float(sample) - Float(black)) / Float(white - black)
/// ```
///
/// So a sample at its black level is `0`, and a sample at the white level is
/// `1`. This is the first application-owned processing representation in the
/// project: `RAWMosaic` is LibRaw's unpacked output, this is ours.
///
/// ## What a value is NOT
///
/// - **Not clamped.** Values below `0` and above `1` are normal and are
///   preserved. Sensor noise straddles the black point, so genuinely
///   negative values exist in real files; highlights above the white level
///   are left for an explicit later stage to handle. See
///   `docs/decisions/0002-raw-normalization.md`.
/// - **Not white balanced**, not demosaiced, not colour-converted, not
///   gamma-encoded, not oriented. Every one of those is recorded as `false`
///   on `processing`.
/// - **Not RGB.** There is still exactly one value per CFA location, and its
///   colour plane comes from `sensorColorLayout`.
///
/// ## Coordinate convention
///
/// Identical to the `RAWMosaic` this was produced from: `(0, 0)` is the
/// top-left of the **active image area**, and `sensorColorLayout` is carried
/// over unchanged, so `colorPlaneIndex(row:column:)` returns the same plane
/// for the same coordinate as it did before processing. No geometry or
/// orientation transform happens at this stage.
///
/// ## Storage
///
/// `values` is a plain `[Float]`, tightly packed and row-major:
/// `values[row * width + column]`. `[Float]` rather than `Data` because the
/// element type is then part of the type, indexing is bounds-checked by the
/// standard library instead of by hand-written byte arithmetic, and there is
/// no byte-order reinterpretation to get wrong — `RAWMosaic` needs `Data`
/// because it wraps bytes copied out of a C buffer, this type does not. It
/// is a single copy-on-write allocation and hands a contiguous
/// `UnsafeBufferPointer` to any future Metal upload via
/// `withUnsafeBufferPointer`.
public struct LinearRAWMosaic: Equatable, Sendable {
    /// Width of the active mosaic area, in samples. Equal to the source
    /// `RAWMosaic.width`.
    public let width: Int
    /// Height of the active mosaic area, in samples. Equal to the source
    /// `RAWMosaic.height`.
    public let height: Int
    /// `width * height` normalised values, row-major and tightly packed.
    ///
    /// The source mosaic's `bytesPerRow` is deliberately not carried over:
    /// that stride existed to honour LibRaw's `raw_pitch`, and `RAWMosaic`
    /// already resolved that boundary. The row stride here is always
    /// `width` elements.
    public let values: [Float]
    /// The sensor's colour-filter layout, carried over unchanged from the
    /// source mosaic.
    public let sensorColorLayout: RAWMetadata.SensorColorLayout
    /// What produced these values.
    public let processing: RAWLinearProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        sensorColorLayout: RAWMetadata.SensorColorLayout,
        processing: RAWLinearProcessing
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

    /// The normalised value at an active-image coordinate, or `nil` when out
    /// of bounds. Never traps, for any value the public initialiser accepts:
    /// the offset arithmetic is checked, and an offset past the end of
    /// `values` returns `nil` rather than trapping.
    public func value(row: Int, column: Int) -> Float? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: width)
        guard !rowOverflow else { return nil }
        let (index, indexOverflow) = rowOffset.addingReportingOverflow(column)
        guard !indexOverflow, index >= 0, index < values.count else { return nil }
        return values[index]
    }

    /// The colour-plane index at an active-image coordinate, bounds-checked
    /// against this mosaic's own extent first so an out-of-range coordinate
    /// returns `nil` rather than wrapping onto the repeating CFA pattern.
    /// Matches `RAWMosaic.colorPlaneIndex(row:column:)` exactly for the
    /// mosaic this was produced from.
    public func colorPlaneIndex(row: Int, column: Int) -> Int? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        return sensorColorLayout.colorPlaneIndex(row: row, column: column)
    }
}

/// A `LinearRAWMosaic` paired with the decoded RAW state it came from.
///
/// The original LibRaw-unpacked `UInt16` mosaic and its metadata stay
/// available through `source` — nothing is mutated in place — so diagnostics
/// and reprocessing under a different policy remain possible without decoding
/// the file again.
public struct ProcessedRAWMosaic: Sendable {
    /// The decoder output this was processed from, unchanged.
    public let source: DecodedRAWMosaic
    /// The black-subtracted, normalised Float32 mosaic.
    public let mosaic: LinearRAWMosaic

    public init(source: DecodedRAWMosaic, mosaic: LinearRAWMosaic) {
        self.source = source
        self.mosaic = mosaic
    }

    /// Provenance for `mosaic`. Forwarded rather than stored a second time,
    /// so the buffer and the record of how it was made can never disagree.
    public var processing: RAWLinearProcessing { mosaic.processing }
    /// The RAW-state metadata `mosaic` was normalised against.
    public var metadata: RAWMetadata { source.metadata }
    public var url: URL { source.url }
}
