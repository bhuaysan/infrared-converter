import Foundation

/// What the working-colour stage did — and explicitly did not do — to produce
/// a `WorkingColorRGBImage`.
///
/// As with `RAWLinearProcessing`, `RAWWhiteBalanceProcessing` and
/// `RAWDemosaicProcessing`, the facts that are structural properties of this
/// stage rather than choices are `let` constants, so the type itself states
/// them.
///
/// Nothing upstream is copied. The demosaic algorithm, the Bayer phase, the
/// gains, their provenance, the white level and the black subtraction all
/// already live on `demosaicProcessing` and are read through it — and the
/// matrix and the working space live on `transform` and are read through that.
/// Two copies of the same history can disagree; one cannot.
public struct RAWWorkingColorProcessing: Equatable, Sendable {
    /// The exact transform that was applied: the working space, the 3×3
    /// matrix, and where that matrix came from.
    public let transform: RAWCameraToWorkingColorTransform
    /// Provenance of the `DemosaicedRAWRGBImage` this stage consumed, carried
    /// forward so the whole chain from unpacked samples to here is readable
    /// from one record.
    public let demosaicProcessing: RAWDemosaicProcessing

    /// A defined working colour representation now exists: the values are
    /// coordinates in a named space rather than bare sensor responses.
    public let workingColorRepresentationEstablished: Bool = true
    /// A camera-to-working transform was applied. Which one, and what it is
    /// entitled to claim, is `transform.source` — this flag says only that the
    /// stage ran.
    public let cameraToWorkingTransformApplied: Bool = true
    /// Nothing was clamped. Negative coordinates and coordinates above `1` are
    /// legitimate in an extended linear space and are preserved exactly as the
    /// arithmetic produced them.
    public let clamped: Bool = false
    /// No gamma or other transfer function has been applied. The transfer
    /// function is linear, which is what `.extendedLinearSRGB` means.
    public let gammaApplied: Bool = false
    /// No tone mapping, no auto exposure, no gamut compression.
    public let toneMappingApplied: Bool = false
    /// Not encoded for a display. That is a later, separate stage.
    public let displayEncodingApplied: Bool = false
    /// No orientation (rotation/flip) transform has been applied.
    public let orientationApplied: Bool = false

    /// The coordinate system the values are in. Read through `transform`
    /// rather than stored a second time, so the buffer's space and the applied
    /// transform's space cannot disagree.
    public var workingColorSpace: RAWWorkingColorSpace { transform.workingColorSpace }
    /// The exact matrix that was applied, in the column-vector convention
    /// `RAWColorMatrix3x3` documents. Read through `transform`, never
    /// duplicated.
    public var matrix: RAWColorMatrix3x3 { transform.matrix }
    /// Where that matrix came from.
    public var transformSource: RAWCameraToWorkingColorTransformSource { transform.source }
    /// Whether the applied transform is a validated infrared colour
    /// calibration. `false` for every source this milestone can produce; see
    /// `RAWCameraToWorkingColorTransformSource`.
    public var isValidatedInfraredCalibration: Bool {
        transform.source.isValidatedInfraredCalibration
    }

    /// Missing channels were reconstructed upstream, before this stage.
    public var demosaiced: Bool { demosaicProcessing.demosaiced }
    /// White balance was applied upstream, in the mosaic domain — and is not
    /// applied again here.
    public var whiteBalanceApplied: Bool { demosaicProcessing.whiteBalanceApplied }
    /// The effective black level was subtracted, three stages upstream.
    public var blackLevelSubtracted: Bool { demosaicProcessing.blackLevelSubtracted }
    /// Samples were normalised against a white level, three stages upstream.
    public var normalized: Bool { demosaicProcessing.normalized }
    /// The exact gains applied upstream.
    public var whiteBalanceGains: RAWWhiteBalanceGains { demosaicProcessing.whiteBalanceGains }
    /// Which algorithm reconstructed the missing channels upstream.
    public var demosaicAlgorithm: RAWDemosaicAlgorithm { demosaicProcessing.algorithm }

    /// Public, like `RAWDemosaicProcessing` and `RAWWhiteBalanceProcessing`
    /// before it: this is a description of a stage, and the bare
    /// `WorkingColorRGBImage` it belongs to is a data representation a test or
    /// an alternate producer may legitimately build.
    ///
    /// The provenance that must not be forgeable lives one level down, on
    /// `transform`, whose matrix and source can only be paired by the
    /// factories that genuinely produced them — and one level up, on
    /// `WorkingColorProcessedRAWImage`, whose initialiser is module-internal.
    public init(
        transform: RAWCameraToWorkingColorTransform,
        demosaicProcessing: RAWDemosaicProcessing
    ) {
        self.transform = transform
        self.demosaicProcessing = demosaicProcessing
    }
}

/// Three `Float32` values per pixel in a **defined RGB coordinate system** —
/// extended linear sRGB — after an explicit camera-to-working transform, and
/// after nothing else.
///
/// ## The distinction this type exists to make
///
/// ```text
/// DemosaicedRAWRGBImage   = linear CAMERA-NATIVE RGB sensor responses
/// WorkingColorRGBImage    = EXTENDED LINEAR sRGB coordinates
/// ```
///
/// Camera-native values are responses of *this sensor's* colour filters; two
/// cameras' `red` values are not comparable and neither is in any colour
/// space. The values here are coordinates in a named space: sRGB primaries,
/// D65 white point, linear transfer function. Later stages can therefore
/// reason about them — mix channels, apply exposure, eventually encode for a
/// display — knowing what the numbers mean.
///
/// ## What the coordinates do NOT mean
///
/// That the mapping into them is physically meaningful. Provenance decides
/// that, and it stays attached: `processing.transformSource` says how the
/// values got here. In particular `.sensorRGBIdentityFalseColor` means the
/// coordinates were **assigned deliberately for false-colour work**, not
/// obtained from a colour calibration of an infrared-converted camera — no
/// such calibration exists in this project. A `WorkingColorRGBImage` is
/// well-defined; whether it is *photometrically meaningful* is a question its
/// provenance answers, and for infrared the honest answer today is "these are
/// defined coordinates for a false-colour rendering".
///
/// ## What has not happened
///
/// The values are still linear, still unclamped, not gamma-encoded, not tone
/// mapped, not gamut mapped, not display encoded, not quantised, not oriented
/// and not a preview. Values below `0` and above `1` are normal and are
/// preserved.
///
/// ## Coordinate convention
///
/// Identical to the `DemosaicedRAWRGBImage` it was produced from: `(0, 0)` is
/// the top-left of the **active image area**, and the dimensions are
/// unchanged. This stage is per-pixel and touches no geometry — no crop, no
/// rotation, no resampling.
///
/// ## Storage
///
/// The same contract as the demosaiced image: tightly packed, row-major,
/// interleaved.
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
/// deliberately not the storage type, for the reason `DemosaicedRAWRGBImage`
/// gives: its 16-byte stride would make the E-PL3's image 197 MB instead of
/// 148 MB, a third of it padding.
///
/// The layout matching the demosaiced image is **not** a reason to merge the
/// two into one generic image type. Their semantic states differ — one is a
/// sensor response, the other a coordinate — and that difference is what makes
/// a function signature able to refuse the wrong input. A shared layout is a
/// coincidence of storage, not a shared meaning.
public struct WorkingColorRGBImage: Equatable, Sendable {
    /// How many `Float32` values one pixel occupies. Always `3`.
    public static let channelCount = 3

    /// Width in pixels. Equal to the source `DemosaicedRAWRGBImage.width`.
    public let width: Int
    /// Height in pixels. Equal to the source `DemosaicedRAWRGBImage.height`.
    public let height: Int
    /// `width * height * 3` values, row-major, tightly packed, interleaved
    /// `R G B`, in the working colour space `processing.workingColorSpace`
    /// names.
    public let values: [Float]
    /// What produced these values, including the exact transform and the
    /// whole upstream chain.
    public let processing: RAWWorkingColorProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: RAWWorkingColorProcessing
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

    /// The element count implied by `width * height * 3`, or `nil` when either
    /// multiplication would overflow `Int`.
    ///
    /// Both products are checked. A three-channel image reaches `Int.max / 3`
    /// at a third of the geometry a single-channel one does, so assuming the
    /// second multiplication is safe because the first was is not sound.
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
    /// bounds check is not sufficient on its own, since a pathological `width`
    /// can overflow the offset arithmetic while the coordinate still looks in
    /// range.
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

    /// One channel's coordinate at a pixel coordinate, or `nil` when out of
    /// bounds. Never traps.
    ///
    /// `RAWLinearRGBChannel` names a storage position — first, second, third —
    /// and is reused here for exactly that. In this type its `red` means the
    /// working space's red axis, not a sensor filter.
    public func value(row: Int, column: Int, channel: RAWLinearRGBChannel) -> Float? {
        guard let base = storageIndex(row: row, column: column) else { return nil }
        return values[base + channel.storageOffset]
    }

    /// All three coordinates at a pixel, or `nil` when out of bounds. Never
    /// traps.
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

/// A `WorkingColorRGBImage` paired with the camera-native state it was
/// produced from.
///
/// ## Why the source is kept
///
/// Changing the camera-to-working transform must restart from camera-native
/// RGB, never from an already-transformed working buffer:
///
/// ```text
/// new result = M2 × the demosaiced camera-native RGB
///        NOT   M2 × (M1 × the demosaiced camera-native RGB)
/// ```
///
/// Chaining would silently compose matrices, and for a transform with negative
/// coefficients the composed result is not recognisably wrong — it is just
/// wrong. So the demosaiced image stays reachable here, with the
/// white-balanced mosaic below it, the normalised mosaic below that, and the
/// decoded `UInt16` mosaic and metadata at the bottom. Nothing is mutated in
/// place and nothing is discarded.
///
/// `RAWWorkingColorConverter.convert(using:replacing:)` is the structural
/// expression of that: it takes a previous result and reaches through it to
/// `source`, so a caller cannot accidentally chain.
///
/// ## A stage-produced pairing, not a caller-assembled one
///
/// As with every other wrapper in this chain, the initialiser is
/// module-internal from the start: outside the module the pairing can be read
/// in full but not minted, so a camera-native source from one run cannot be
/// attached to a working-colour result from another.
public struct WorkingColorProcessedRAWImage: Sendable {
    /// The camera-native, pre-transform state this was produced from,
    /// unchanged — with the white-balanced mosaic on its own `.source`, and
    /// the normalised and decoded mosaics below that.
    public let source: DemosaicedProcessedRAWImage
    /// The working-colour image, in extended linear sRGB coordinates.
    public let image: WorkingColorRGBImage

    /// Module-internal, deliberately: only `RAWWorkingColorConverter` pairs a
    /// camera-native state with the working-colour image it produced from it.
    init(source: DemosaicedProcessedRAWImage, image: WorkingColorRGBImage) {
        self.source = source
        self.image = image
    }

    /// The linear camera-native RGB image the transform was applied to.
    /// Changing the transform must always start here.
    public var demosaicedImage: DemosaicedRAWRGBImage { source.image }
    /// The white-balanced mosaic, two stages upstream. Changing demosaic
    /// algorithm starts here.
    public var whiteBalancedMosaic: WhiteBalancedRAWMosaic { source.whiteBalancedMosaic }
    /// The normalised, pre-white-balance mosaic. Changing or re-estimating the
    /// gains starts here.
    public var linearMosaic: LinearRAWMosaic { source.linearMosaic }
    /// Provenance for `image`. Forwarded rather than stored a second time, so
    /// the buffer and the record of how it was made can never disagree.
    public var processing: RAWWorkingColorProcessing { image.processing }
    /// The transform that produced `image`.
    public var transform: RAWCameraToWorkingColorTransform { image.processing.transform }
    /// The RAW-state metadata the chain was processed against. Its colour
    /// matrices and multipliers are diagnostics; this stage reads none of them
    /// unless a caller explicitly built a transform from `rgbFromCamera`.
    public var metadata: RAWMetadata { source.metadata }
    public var url: URL { source.url }
}
