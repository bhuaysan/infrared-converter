import Foundation

/// What the infrared channel-mix stage did — and explicitly did not do — to
/// produce an `IRChannelMixedRGBImage`.
///
/// As with `RAWLinearProcessing`, `RAWWhiteBalanceProcessing`,
/// `RAWDemosaicProcessing` and `RAWWorkingColorProcessing`, the facts that are
/// structural properties of this stage rather than choices are `let`
/// constants, so the type itself states them.
///
/// Nothing upstream is copied. The working colour space and the matrix live on
/// `mix` and are read through it; the camera-to-working transform, the
/// demosaic algorithm, the gains and their provenance, the white level and the
/// black subtraction all already live on `workingColorProcessing` and are read
/// through that. Two copies of the same history can disagree; one cannot.
public struct IRChannelMixProcessing: Equatable, Sendable {
    /// The exact mix that was applied: the working space it was authored for,
    /// the 3×3 matrix, and where that matrix came from.
    public let mix: IRChannelMix
    /// Provenance of the `WorkingColorRGBImage` this stage consumed, carried
    /// forward so the whole chain from unpacked samples to here is readable
    /// from one record.
    public let workingColorProcessing: RAWWorkingColorProcessing

    /// A creative channel mix was applied. Which one, and what it is entitled
    /// to claim, is `mix.source` — this flag says only that the stage ran, and
    /// it is `true` for `.identity` too, because traversing the stage and
    /// asking for no remapping is a different fact from never reaching it.
    public let channelMixApplied: Bool = true
    /// Nothing was clamped. Negative coordinates and coordinates above `1` are
    /// legitimate in an extended linear space — and creative mixes with
    /// negative or above-one coefficients are a normal way to produce them —
    /// so they are preserved exactly as the arithmetic produced them.
    public let clamped: Bool = false
    /// No gamma or other transfer function has been applied. The transfer
    /// function is still linear.
    public let gammaApplied: Bool = false
    /// No tone mapping, no auto exposure, no gamut compression.
    public let toneMappingApplied: Bool = false
    /// Not encoded for a display. That is a later, separate stage.
    public let displayEncodingApplied: Bool = false
    /// No orientation (rotation/flip) transform has been applied.
    public let orientationApplied: Bool = false

    /// The coordinate system the values are in — **unchanged** by this stage.
    /// Read through `mix`, which the mixer has already checked against the
    /// input image's own space.
    public var workingColorSpace: RAWWorkingColorSpace { mix.workingColorSpace }
    /// The exact matrix that was applied, in the column-vector convention
    /// `RAWColorMatrix3x3` documents. Read through `mix`, never duplicated.
    public var matrix: RAWColorMatrix3x3 { mix.matrix }
    /// Where that matrix came from: a built-in, or an explicit caller choice.
    public var mixSource: IRChannelMixSource { mix.source }

    /// The camera-to-working transform applied upstream — a **different
    /// operation** from the mix above, kept separately readable so a rendering
    /// can be audited for both.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        workingColorProcessing.transform
    }
    /// Where that upstream transform came from.
    public var cameraToWorkingTransformSource: RAWCameraToWorkingColorTransformSource {
        workingColorProcessing.transformSource
    }
    /// Whether the upstream camera-to-working transform is a validated
    /// infrared colour calibration. `false` for every source the project can
    /// produce — and a creative channel mix never makes it anything else.
    public var isValidatedInfraredCalibration: Bool {
        workingColorProcessing.isValidatedInfraredCalibration
    }
    /// The working colour representation was established upstream, before this
    /// stage; this stage did not establish it and did not change it.
    public var workingColorRepresentationEstablished: Bool {
        workingColorProcessing.workingColorRepresentationEstablished
    }
    /// A camera-to-working transform ran upstream. It is not applied again
    /// here.
    public var cameraToWorkingTransformApplied: Bool {
        workingColorProcessing.cameraToWorkingTransformApplied
    }
    /// Missing channels were reconstructed upstream, in the mosaic domain.
    public var demosaiced: Bool { workingColorProcessing.demosaiced }
    /// White balance was applied upstream, per CFA plane in the mosaic domain
    /// — and is not applied again here.
    public var whiteBalanceApplied: Bool { workingColorProcessing.whiteBalanceApplied }
    /// The effective black level was subtracted, four stages upstream.
    public var blackLevelSubtracted: Bool { workingColorProcessing.blackLevelSubtracted }
    /// Samples were normalised against a white level, four stages upstream.
    public var normalized: Bool { workingColorProcessing.normalized }
    /// The exact gains applied upstream.
    public var whiteBalanceGains: RAWWhiteBalanceGains {
        workingColorProcessing.whiteBalanceGains
    }
    /// Which algorithm reconstructed the missing channels upstream.
    public var demosaicAlgorithm: RAWDemosaicAlgorithm {
        workingColorProcessing.demosaicAlgorithm
    }

    /// Public, like every other stage-processing record: this is a description
    /// of a stage, and the bare `IRChannelMixedRGBImage` it belongs to is a
    /// data representation a test or an alternate producer may legitimately
    /// build.
    ///
    /// The provenance that must not be forgeable lives one level down, on
    /// `mix`, whose matrix and source can only be paired by the factories that
    /// genuinely produced them — and one level up, on
    /// `IRChannelMixedProcessedRAWImage`, whose initialiser is
    /// module-internal.
    public init(mix: IRChannelMix, workingColorProcessing: RAWWorkingColorProcessing) {
        self.mix = mix
        self.workingColorProcessing = workingColorProcessing
    }
}

/// Three `Float32` values per pixel in the **same working colour space** as
/// the image they were mixed from, after a creative infrared channel mix, and
/// after nothing else.
///
/// ## The distinction this type exists to make
///
/// ```text
/// WorkingColorRGBImage     = extended-linear-sRGB coordinates
///                            BEFORE creative IR channel mixing
///
/// IRChannelMixedRGBImage   = extended-linear-sRGB coordinates
///                            AFTER creative IR channel mixing
/// ```
///
/// The colour space has **not** changed. No new primaries are created, no
/// chromatic adaptation happens, no camera transform happens, no white balance
/// happens. Coordinates inside one linear RGB space were remixed, and that is
/// the whole of it. The difference between the two types is **processing
/// state**, not colour-space identity — which is exactly why they are two
/// types: a function signature can then refuse an image that has not been
/// through the creative stage, or one that has been through it twice.
///
/// ## What the coordinates do NOT mean
///
/// That the rendering is *correct*. It is creative intent, recorded as such:
/// `processing.mixSource` says which choice was made, and no choice available
/// here is a camera calibration, a filter calibration or a measurement. A
/// red/blue-swapped infrared frame is the exact red/blue swap of its input —
/// nothing more is claimed for it.
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
/// Identical to the `WorkingColorRGBImage` it was produced from: `(0, 0)` is
/// the top-left of the **active image area**, and the dimensions are
/// unchanged. Channel mixing is strictly per-pixel and touches no geometry —
/// no crop, no resize, no rotation, no resampling.
///
/// ## Storage
///
/// The same contract as every RGB representation in the pipeline: tightly
/// packed, row-major, interleaved.
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
/// deliberately not the storage type: its 16-byte stride would make the
/// E-PL3's image 197 MB instead of 148 MB, a third of it padding.
///
/// The layout matching the earlier RGB images is **not** a reason to merge
/// them into one generic image type. A shared layout is a coincidence of
/// storage, not a shared meaning.
public struct IRChannelMixedRGBImage: Equatable, Sendable {
    /// How many `Float32` values one pixel occupies. Always `3`.
    public static let channelCount = 3

    /// Width in pixels. Equal to the source `WorkingColorRGBImage.width`.
    public let width: Int
    /// Height in pixels. Equal to the source `WorkingColorRGBImage.height`.
    public let height: Int
    /// `width * height * 3` values, row-major, tightly packed, interleaved
    /// `R G B`, in the working colour space `processing.workingColorSpace`
    /// names — the same space as the input.
    public let values: [Float]
    /// What produced these values, including the exact mix and the whole
    /// upstream chain.
    public let processing: IRChannelMixProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: IRChannelMixProcessing
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
    /// working space's red axis after mixing, not a sensor filter.
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

/// An `IRChannelMixedRGBImage` paired with the pre-mix working-colour state it
/// was produced from.
///
/// ## Why the source is kept
///
/// Changing a creative channel mix must restart from the **pre-mix** working
/// image, never from an already-mixed one:
///
/// ```text
/// new result = M2 × the working-colour image
///        NOT   M2 × (M1 × the working-colour image)
/// ```
///
/// Chaining would silently compose matrices, and a composed creative mix is
/// not recognisably wrong — it is just a different rendering than the one
/// asked for. Two red/blue swaps in a row would cancel; a swap followed by a
/// monochrome collapse would be neither. So the working-colour image stays
/// reachable here, with the camera-native image below it, the white-balanced
/// mosaic below that, and the normalised mosaic, the decoded `UInt16` mosaic
/// and the metadata at the bottom. Nothing is mutated in place and nothing is
/// discarded.
///
/// `IRChannelMixer.apply(mix:replacing:)` is the structural expression of
/// that: it takes a previous result and reaches through it to `source`, so a
/// caller cannot accidentally chain.
///
/// ## A stage-produced pairing, not a caller-assembled one
///
/// As with every other wrapper in this chain, the initialiser is
/// module-internal from the start: outside the module the pairing can be read
/// in full but not minted, so a working-colour source from one run cannot be
/// attached to a channel-mixed result from another.
public struct IRChannelMixedProcessedRAWImage: Sendable {
    /// The pre-mix working-colour state this was produced from, unchanged —
    /// with the camera-native image on its own `.source`, and the mosaics
    /// below that.
    public let source: WorkingColorProcessedRAWImage
    /// The channel-mixed image, in the same working colour space as `source`.
    public let image: IRChannelMixedRGBImage

    /// Module-internal, deliberately: only `IRChannelMixer` pairs a
    /// working-colour state with the mixed image it produced from it.
    init(source: WorkingColorProcessedRAWImage, image: IRChannelMixedRGBImage) {
        self.source = source
        self.image = image
    }

    /// The pre-mix working-colour image the mix was applied to. Changing the
    /// mix must always start here.
    public var workingColorImage: WorkingColorRGBImage { source.image }
    /// The linear camera-native RGB image, one stage further upstream.
    /// Changing the camera-to-working transform starts here.
    public var demosaicedImage: DemosaicedRAWRGBImage { source.demosaicedImage }
    /// The white-balanced mosaic. Changing demosaic algorithm starts here.
    public var whiteBalancedMosaic: WhiteBalancedRAWMosaic { source.whiteBalancedMosaic }
    /// The normalised, pre-white-balance mosaic. Changing or re-estimating the
    /// gains starts here.
    public var linearMosaic: LinearRAWMosaic { source.linearMosaic }
    /// Provenance for `image`. Forwarded rather than stored a second time, so
    /// the buffer and the record of how it was made can never disagree.
    public var processing: IRChannelMixProcessing { image.processing }
    /// The creative mix that produced `image`.
    public var mix: IRChannelMix { image.processing.mix }
    /// The camera-to-working transform applied upstream — a different
    /// operation from `mix`, and still separately readable.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        source.transform
    }
    /// The RAW-state metadata the chain was processed against. This stage
    /// reads none of it: a channel mix is decided by its matrix alone.
    public var metadata: RAWMetadata { source.metadata }
    public var url: URL { source.url }
}
