import Foundation

/// What the demosaicing stage did — and explicitly did not do — to produce a
/// `DemosaicedRAWRGBImage`.
///
/// As with `RAWLinearProcessing` and `RAWWhiteBalanceProcessing`, the facts
/// that are structural properties of this stage rather than choices are `let`
/// constants, so the type itself states them.
///
/// The upstream chain is **not** copied: black subtraction, normalisation,
/// the white level, the gains and their source all already live on
/// `whiteBalanceProcessing` and are read through it. Two copies of the same
/// history could disagree.
public struct RAWDemosaicProcessing: Equatable, Sendable {
    /// Which algorithm reconstructed the missing channels.
    public let algorithm: RAWDemosaicAlgorithm
    /// The 2×2 Bayer phase that was **discovered** from the source mosaic's
    /// sensor colour layout, not assumed. Recorded so the decision is
    /// auditable after the fact: `"RGGB"`, `"BGGR"`, `"GRBG"` or `"GBRG"`.
    public let sourcePattern: RAWBayerCellPattern
    /// Provenance of the `WhiteBalancedRAWMosaic` this stage consumed,
    /// carried forward so the whole chain from unpacked samples to here is
    /// readable from one record.
    public let whiteBalanceProcessing: RAWWhiteBalanceProcessing

    /// Missing channels were reconstructed by interpolation.
    public let demosaiced: Bool = true
    /// Nothing was clamped. Interpolated values are arithmetic means of the
    /// source samples, so values below `0` and above `1` occur and are
    /// preserved exactly as the arithmetic produced them.
    public let clamped: Bool = false
    /// No camera or vendor colour matrix has been applied. These values are
    /// linear camera-native responses, not colour-space coordinates.
    public let cameraColorMatrixApplied: Bool = false
    /// No gamma or other transfer function has been applied.
    public let gammaApplied: Bool = false
    /// No orientation (rotation/flip) transform has been applied.
    public let orientationApplied: Bool = false

    /// White balance was applied — upstream, before interpolation. Read
    /// through the upstream record rather than restated, so it cannot
    /// disagree with it.
    public var whiteBalanceApplied: Bool { whiteBalanceProcessing.whiteBalanceApplied }
    /// The effective black level was subtracted, two stages upstream.
    public var blackLevelSubtracted: Bool {
        whiteBalanceProcessing.linearProcessing.blackLevelSubtracted
    }
    /// Samples were normalised against a white level, two stages upstream.
    public var normalized: Bool { whiteBalanceProcessing.linearProcessing.normalized }
    /// The exact gains applied upstream.
    public var whiteBalanceGains: RAWWhiteBalanceGains { whiteBalanceProcessing.gains }

    public init(
        algorithm: RAWDemosaicAlgorithm,
        sourcePattern: RAWBayerCellPattern,
        whiteBalanceProcessing: RAWWhiteBalanceProcessing
    ) {
        self.algorithm = algorithm
        self.sourcePattern = sourcePattern
        self.whiteBalanceProcessing = whiteBalanceProcessing
    }
}

/// Three `Float32` values per pixel — linear, camera-native red, green and
/// blue — after black subtraction, normalisation, per-CFA-plane white balance
/// and demosaicing, and after nothing else.
///
/// ## What a value IS
///
/// The **linear camera-native response** of one of the sensor's three filter
/// colours at one pixel. At a pixel whose CFA location carries that colour,
/// it is that location's own white-balanced sample, copied bit for bit. At a
/// pixel whose CFA location carries a different colour, it is an arithmetic
/// mean of neighbouring samples of the wanted colour; see `RAWDemosaicer` for
/// the exact rule.
///
/// ## What a value is NOT
///
/// This is the distinction most easily lost at this boundary, so it is stated
/// flatly: **these are not colour-space coordinates.** No camera colour matrix
/// has been applied, and none is applied anywhere on this path. The values are
/// specifically *not* in, and must not be treated as being in:
///
/// - sRGB, or linear sRGB
/// - Display P3
/// - Adobe RGB
/// - ProPhoto RGB
/// - CIE XYZ
/// - ACES, or any other device-independent RGB
///
/// The labels `R`, `G` and `B` identify **which colour filter on this sensor**
/// produced the response, resolved through the layout's `colorDescription`.
/// Two cameras' `red` values are not comparable, and writing this buffer to a
/// file tagged sRGB would be wrong.
///
/// Converting camera-native RGB into a defined working representation is a
/// later, explicit stage: `RAWWorkingColorConverter`, which needs a
/// `RAWCameraToWorkingColorTransform` chosen by the caller and produces a
/// `WorkingColorRGBImage` in extended linear sRGB (ADR 0006). Until that stage
/// has run, these values are in no colour space at all.
///
/// It is also **not clamped**, not gamma-encoded, not oriented, and not a
/// preview.
///
/// ## Coordinate convention
///
/// Identical to the `WhiteBalancedRAWMosaic` it was produced from: `(0, 0)` is
/// the top-left of the **active image area**, and the dimensions are
/// unchanged — every CFA location produces exactly one output pixel,
/// including at the borders. No crop, no rotation, no resampling.
///
/// There is deliberately no `sensorColorLayout` here. Asking a demosaiced
/// image which colour plane a pixel came from invites reasoning that only
/// makes sense before this stage; the source mosaic, layout included, stays
/// reachable through `DemosaicedProcessedRAWImage.source`.
///
/// ## Storage
///
/// Tightly packed, row-major, interleaved:
///
/// ```text
/// R G B  R G B  R G B ...
///
/// base = (row * width + column) * 3
/// R = values[base + 0]
/// G = values[base + 1]
/// B = values[base + 2]
/// ```
///
/// Exactly three `Float32` per pixel — 12 bytes, not 16. `[SIMD3<Float>]` is
/// deliberately **not** the storage type: `SIMD3<Float>` has a 16-byte stride,
/// so the E-PL3's 4056 × 3040 image would silently allocate 197 MB instead of
/// 148 MB, a third of it padding. `RAWLinearRGBPixel` exists for handing one
/// pixel back to a caller and is never stored.
public struct DemosaicedRAWRGBImage: Equatable, Sendable {
    /// How many `Float32` values one pixel occupies. Always `3`.
    public static let channelCount = 3

    /// Width in pixels. Equal to the source `WhiteBalancedRAWMosaic.width`.
    public let width: Int
    /// Height in pixels. Equal to the source `WhiteBalancedRAWMosaic.height`.
    public let height: Int
    /// `width * height * 3` values, row-major, tightly packed, interleaved
    /// `R G B`.
    public let values: [Float]
    /// What produced these values.
    public let processing: RAWDemosaicProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: RAWDemosaicProcessing
    ) {
        self.width = width
        self.height = height
        self.values = values
        self.processing = processing
    }

    /// Elements between the starts of consecutive rows. Always `width * 3`,
    /// or `nil` when that multiplication would overflow `Int`.
    public var valuesPerRow: Int? {
        let (result, overflow) = width.multipliedReportingOverflow(by: Self.channelCount)
        return overflow ? nil : result
    }

    /// The element count implied by `width * height * 3`, or `nil` when
    /// either multiplication would overflow `Int`.
    ///
    /// Both products are checked. A three-channel image reaches
    /// `Int.max / 3` at a third of the geometry a single-channel one does, so
    /// assuming the second multiplication is safe because the first was is
    /// not sound.
    public var expectedValueCount: Int? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (total, totalOverflow) = pixels.multipliedReportingOverflow(by: Self.channelCount)
        return totalOverflow ? nil : total
    }

    /// The pixel count implied by `width * height`, or `nil` on overflow.
    public var pixelCount: Int? {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : pixels
    }

    /// True when `values` holds exactly the declared geometry's worth of
    /// elements. Non-positive dimensions, or geometry whose implied count
    /// would overflow, make this `false` rather than trap.
    public var isGeometryConsistent: Bool {
        guard width > 0, height > 0, let expected = expectedValueCount else { return false }
        return values.count == expected
    }

    /// The index of a pixel's first (`red`) element, or `nil` when the
    /// coordinate is out of bounds or the offset arithmetic would overflow.
    ///
    /// Never traps, for any value the public initialiser accepts: passing the
    /// bounds check is not sufficient on its own, since a pathological
    /// `width` can overflow the offset arithmetic while the coordinate still
    /// looks in range.
    public func storageIndex(row: Int, column: Int) -> Int? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: width)
        guard !rowOverflow else { return nil }
        let (pixelIndex, pixelOverflow) = rowOffset.addingReportingOverflow(column)
        guard !pixelOverflow else { return nil }
        let (base, baseOverflow) = pixelIndex.multipliedReportingOverflow(by: Self.channelCount)
        guard !baseOverflow, base >= 0 else { return nil }
        // The last element of the pixel must exist too.
        let (last, lastOverflow) = base.addingReportingOverflow(Self.channelCount - 1)
        guard !lastOverflow, last < values.count else { return nil }
        return base
    }

    /// One channel's value at a pixel coordinate, or `nil` when out of
    /// bounds. Never traps.
    public func value(row: Int, column: Int, channel: RAWLinearRGBChannel) -> Float? {
        guard let base = storageIndex(row: row, column: column) else { return nil }
        return values[base + channel.storageOffset]
    }

    /// All three channels at a pixel coordinate, or `nil` when out of bounds.
    /// Never traps.
    ///
    /// A convenience for callers reading a handful of pixels. It is not the
    /// storage representation and not the path a full-frame pass should take;
    /// use `values.withUnsafeBufferPointer` for that.
    public func pixel(row: Int, column: Int) -> RAWLinearRGBPixel? {
        guard let base = storageIndex(row: row, column: column) else { return nil }
        return RAWLinearRGBPixel(
            red: values[base],
            green: values[base + 1],
            blue: values[base + 2]
        )
    }
}

/// A `DemosaicedRAWRGBImage` paired with the white-balanced mosaic it was
/// produced from.
///
/// ## Why the source is kept
///
/// Every edit a user will make to an already-opened file restarts from an
/// earlier representation, never from this one:
///
/// ```text
/// change the gains          → restart at ProcessedRAWMosaic (normalised)
/// re-estimate white balance → restart at ProcessedRAWMosaic (normalised)
/// change demosaic algorithm → restart at WhiteBalancedRAWMosaic
/// compare two algorithms    → run both from WhiteBalancedRAWMosaic
/// ```
///
/// Demosaicing an already-demosaiced RGB buffer is meaningless, and
/// re-deriving the mosaic from it is impossible. So the chain stays reachable:
/// this wrapper holds the white-balanced mosaic, which holds the normalised
/// one, which holds the decoded `UInt16` mosaic and its metadata. Nothing is
/// mutated in place and nothing is discarded.
///
/// That retention is a **deliberate memory tradeoff**, not an oversight. For
/// the E-PL3 the RGB image alone is about 148 MB and the two upstream Float32
/// mosaics about 49 MB each; keeping them costs roughly 100 MB and buys
/// re-editing without a second decode. When interactive editing exists and has
/// been measured, that tradeoff can be revisited — by measurement, not by
/// dropping buffers to make a number look smaller.
///
/// ## A stage-produced pairing, not a caller-assembled one
///
/// The two halves are a **historical claim**: this mosaic was produced from
/// that source, by this stage, in one run. `let` properties and a
/// module-internal initialiser make that claim true by construction — outside
/// the module the pairing can be read in full but not minted, so a source
/// from one processing run cannot be attached to a result from another.
/// The same reasoning as `RAWWhiteBalanceEstimate`, and the same reason the
/// bare value types below it stay publicly constructible: `LinearRAWMosaic`,
/// `WhiteBalancedRAWMosaic` and `DemosaicedRAWRGBImage` are data
/// representations that a test, an alternate producer or a future integration
/// may legitimately build, while these wrappers assert provenance.
public struct DemosaicedProcessedRAWImage: Sendable {
    /// The white-balanced, pre-demosaic state this was produced from,
    /// unchanged — with the normalised mosaic on its own `.source`, and the
    /// decoded `UInt16` mosaic below that.
    public let source: WhiteBalancedProcessedRAWMosaic
    /// The demosaiced linear camera-native RGB image.
    public let image: DemosaicedRAWRGBImage

    /// Module-internal, deliberately: only `RAWDemosaicer` pairs a
    /// white-balanced state with the image it interpolated from it. See the
    /// type's note above on why that pairing is not forgeable from outside.
    init(source: WhiteBalancedProcessedRAWMosaic, image: DemosaicedRAWRGBImage) {
        self.source = source
        self.image = image
    }

    /// The white-balanced mosaic this was demosaiced from. Changing demosaic
    /// algorithm must always start here.
    public var whiteBalancedMosaic: WhiteBalancedRAWMosaic { source.mosaic }
    /// The normalised, pre-white-balance mosaic. Changing or re-estimating
    /// the gains must always start here.
    public var linearMosaic: LinearRAWMosaic { source.linearMosaic }
    /// Provenance for `image`. Forwarded rather than stored a second time, so
    /// the buffer and the record of how it was made can never disagree.
    public var processing: RAWDemosaicProcessing { image.processing }
    /// The RAW-state metadata the chain was processed against. Its colour
    /// matrices and multipliers are diagnostics; no stage on this path reads
    /// them, demosaicing included.
    public var metadata: RAWMetadata { source.metadata }
    public var url: URL { source.url }
}
