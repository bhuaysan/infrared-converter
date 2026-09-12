import Foundation

/// What the orientation stage did — and explicitly did not do — to produce an
/// `OrientedSceneLinearRGBImage`.
///
/// As with `RAWLinearProcessing`, `RAWWhiteBalanceProcessing`,
/// `RAWDemosaicProcessing`, `RAWWorkingColorProcessing` and
/// `IRChannelMixProcessing`, the facts that are structural properties of this
/// stage rather than choices are `let` constants, so the type itself states
/// them.
///
/// Nothing upstream is copied. The creative mix, the camera-to-working
/// transform, the demosaic algorithm, the gains and their provenance, the
/// white level and the black subtraction all already live on
/// `channelMixProcessing` and are read through it. Two copies of the same
/// history can disagree; one cannot.
public struct ImageOrientationProcessing: Equatable, Sendable {
    /// The exact orientation that was applied.
    public let orientation: RAWImageOrientation
    /// Provenance of the `IRChannelMixedRGBImage` this stage consumed, carried
    /// forward so the whole chain from unpacked samples to here is readable
    /// from one record.
    public let channelMixProcessing: IRChannelMixProcessing
    /// How the scene-linear image this stage consumed was reduced for
    /// interactive preview, or `nil` when it was not reduced at all —
    /// when the values came straight from a sensor-resolution chain.
    ///
    /// This is the one fact the upstream stage records cannot carry.
    /// `IRChannelMixProcessing` and everything below it describe stages
    /// that are exactly as true of a reduced image as of a full one; the
    /// reduction happened *between* two of them, and a reader of a
    /// finished preview has to be able to learn that the pixels are a
    /// smaller rendition rather than the sensor's own.
    public let previewResolution: PreviewResolution?

    /// The orientation stage ran. Which arrangement it applied is
    /// `orientation` — this flag says only that the stage was traversed, and
    /// it is `true` for `.upright` too, because reaching the stage and being
    /// asked for no rearrangement is a different fact from never reaching it.
    ///
    /// Every representation upstream of here reports `orientationApplied` as
    /// `false`, and that remains correct: they were produced before this
    /// stage.
    public let orientationApplied: Bool = true
    /// Pixels were relocated whole. Not one channel value was read as a
    /// number, so nothing was averaged, blended, weighted or invented.
    public let pixelValuesPreserved: Bool = true
    /// The values are still scene-linear. Orientation is geometry; it cannot
    /// change what a coordinate means.
    public let sceneLinear: Bool = true
    /// No interpolation and no resampling. The eight orientations are exact
    /// permutations of the sample grid, so none is needed and none is
    /// performed.
    public let interpolated: Bool = false
    /// No arbitrary-angle rotation. Only the eight discrete orientations
    /// exist here; straightening is an editing feature this stage is not.
    public let arbitraryRotationApplied: Bool = false
    /// No crop. Every source pixel appears in the output exactly once.
    public let cropped: Bool = false
    /// No scaling. The pixel count is identical to the input's.
    public let scaled: Bool = false
    /// Nothing was clamped. Values below `0` and above `1` are legitimate in
    /// an extended linear space and are moved, not limited.
    public let clamped: Bool = false
    /// No gamma or other transfer function. The transfer function is still
    /// linear.
    public let gammaApplied: Bool = false
    /// No tone mapping, no auto exposure, no gamut compression.
    public let toneMappingApplied: Bool = false
    /// Not encoded for a display. That is the next, separate stage.
    public let displayEncodingApplied: Bool = false

    /// Whether the applied orientation exchanged width and height.
    /// Whether the values this stage oriented had already been reduced for
    /// interactive preview.
    public var sourceReducedForPreview: Bool { previewResolution != nil }

    public var dimensionsSwapped: Bool { orientation.swapsDimensions }
    /// Whether the applied orientation was a reflection rather than a
    /// rotation. Read through `orientation`, never stored twice.
    public var orientationIsMirrored: Bool { orientation.isMirrored }

    /// The coordinate system the values are in — **unchanged** by this stage.
    /// Read through the upstream record.
    public var workingColorSpace: RAWWorkingColorSpace {
        channelMixProcessing.workingColorSpace
    }
    /// The creative mix applied upstream — a **different operation** from
    /// anything this stage did, kept separately readable so a rendering can be
    /// audited for both.
    public var mix: IRChannelMix { channelMixProcessing.mix }
    /// Where that mix came from: a built-in, or an explicit caller choice.
    public var mixSource: IRChannelMixSource { channelMixProcessing.mixSource }
    /// A creative channel mix ran upstream. It is not applied again here.
    public var channelMixApplied: Bool { channelMixProcessing.channelMixApplied }
    /// The camera-to-working transform applied further upstream.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        channelMixProcessing.cameraToWorkingTransform
    }
    /// Where that upstream transform came from.
    public var cameraToWorkingTransformSource: RAWCameraToWorkingColorTransformSource {
        channelMixProcessing.cameraToWorkingTransformSource
    }
    /// Whether the upstream camera-to-working transform is a validated
    /// infrared colour calibration. `false` for every source the project can
    /// produce — and rearranging pixels never makes it anything else.
    public var isValidatedInfraredCalibration: Bool {
        channelMixProcessing.isValidatedInfraredCalibration
    }
    /// The working colour representation was established upstream.
    public var workingColorRepresentationEstablished: Bool {
        channelMixProcessing.workingColorRepresentationEstablished
    }
    /// Missing channels were reconstructed upstream, in the mosaic domain.
    public var demosaiced: Bool { channelMixProcessing.demosaiced }
    /// Which algorithm reconstructed them.
    public var demosaicAlgorithm: RAWDemosaicAlgorithm {
        channelMixProcessing.demosaicAlgorithm
    }
    /// White balance was applied upstream, per CFA plane in the mosaic domain.
    public var whiteBalanceApplied: Bool { channelMixProcessing.whiteBalanceApplied }
    /// The exact gains applied upstream.
    public var whiteBalanceGains: RAWWhiteBalanceGains {
        channelMixProcessing.whiteBalanceGains
    }
    /// The effective black level was subtracted, five stages upstream.
    public var blackLevelSubtracted: Bool { channelMixProcessing.blackLevelSubtracted }
    /// Samples were normalised against a white level, five stages upstream.
    public var normalized: Bool { channelMixProcessing.normalized }

    /// Public, like every other stage-processing record: this is a description
    /// of a stage, and the bare `OrientedSceneLinearRGBImage` it belongs to is
    /// a data representation a test or an alternate producer may legitimately
    /// build.
    ///
    /// The pairing that must not be forgeable lives one level up, on
    /// `OrientedProcessedRAWImage`, whose initialiser is module-internal.
    public init(
        orientation: RAWImageOrientation,
        channelMixProcessing: IRChannelMixProcessing,
        previewResolution: PreviewResolution? = nil
    ) {
        self.orientation = orientation
        self.channelMixProcessing = channelMixProcessing
        self.previewResolution = previewResolution
    }
}

/// Three `Float32` values per pixel, in the **same working colour space** and
/// with the **same values** as the channel-mixed image they came from, but
/// arranged for viewing.
///
/// ## The distinction this type exists to make
///
/// ```text
/// IRChannelMixedRGBImage        extended-linear-sRGB coordinates
///                               in SENSOR reading order
///
/// OrientedSceneLinearRGBImage   the same coordinates, the same numbers,
///                               in VIEWING order
/// ```
///
/// Nothing about the colour changed. No primaries, no white point, no transfer
/// function, no channel, no value. What changed is *where each pixel is*, and
/// that is the whole of it. The difference between the two types is
/// **geometry state**, which is exactly why they are two types: a function
/// signature can then refuse an image that has not been oriented, or one that
/// has been oriented twice.
///
/// ## A permutation, exactly
///
/// Every source pixel appears in the output exactly once, and every output
/// pixel comes from exactly one source pixel. The three `Float` components
/// are copied, never computed, so their **bit patterns survive** — signed
/// zeros, subnormals, the largest and smallest finite magnitudes, and
/// non-finite values alike. The stage reads no value as a number and therefore
/// refuses none; that is `DisplayPreviewRenderer`'s boundary, not this one.
///
/// ## What has not happened
///
/// The values are still linear, still unclamped, not gamma-encoded, not tone
/// mapped, not gamut mapped, not display encoded, not quantised and not a
/// preview. Values below `0` and above `1` are normal and are preserved. No
/// interpolation, no resampling, no arbitrary-angle rotation, no crop, no
/// scaling.
///
/// ## Coordinate convention
///
/// `(0, 0)` is the top-left **as viewed**, which is the point of the type. The
/// source image's `(0, 0)` is the top-left of the active sensor area; where it
/// ends up here is decided by `processing.orientation`, and
/// `RAWImageOrientation.sourceCoordinate(row:column:sourceWidth:sourceHeight:)`
/// is the exact mapping.
///
/// `width` and `height` are exchanged relative to the source for the four
/// orientations whose `swapsDimensions` is `true`, and equal to it for the
/// other four. The pixel count is invariant either way.
///
/// ## Storage
///
/// The same contract as every other RGB representation in the pipeline:
/// tightly packed, row-major, interleaved.
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
/// Exactly three `Float32` per pixel — 12 bytes, not 16. The layout matching
/// the earlier RGB images is **not** a reason to merge them into one generic
/// image type: a shared layout is a coincidence of storage, not a shared
/// meaning.
public struct OrientedSceneLinearRGBImage: Equatable, Sendable {
    /// How many `Float32` values one pixel occupies. Always `3`.
    public static let channelCount = 3

    /// Width in pixels, **as viewed**. Equal to the source image's height for
    /// a dimension-swapping orientation, and to its width otherwise.
    public let width: Int
    /// Height in pixels, **as viewed**.
    public let height: Int
    /// `width * height * 3` values, row-major, tightly packed, interleaved
    /// `R G B`, in the working colour space `processing.workingColorSpace`
    /// names — the same space, and the same numbers, as the input.
    public let values: [Float]
    /// What produced these values: the orientation applied, and the whole
    /// upstream chain.
    public let processing: ImageOrientationProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: ImageOrientationProcessing
    ) {
        self.width = width
        self.height = height
        self.values = values
        self.processing = processing
    }

    /// The orientation that was applied, read through `processing`.
    public var orientation: RAWImageOrientation { processing.orientation }

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
        Self.expectedValueCount(width: width, height: height)
    }

    /// The element count a geometry implies, or `nil` on overflow.
    ///
    /// Static so the orienter can size a buffer before it has an image to ask,
    /// and so both callers use the same arithmetic rather than two copies of
    /// it.
    public static func expectedValueCount(width: Int, height: Int) -> Int? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (total, totalOverflow) = pixels.multipliedReportingOverflow(by: channelCount)
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

    /// One channel's coordinate at a viewing coordinate, or `nil` when out of
    /// bounds. Never traps.
    ///
    /// `RAWLinearRGBChannel` names a storage position — first, second, third —
    /// and is reused here for exactly that.
    public func value(row: Int, column: Int, channel: RAWLinearRGBChannel) -> Float? {
        guard let base = storageIndex(row: row, column: column) else { return nil }
        return values[base + channel.storageOffset]
    }

    /// All three coordinates at a viewing coordinate, or `nil` when out of
    /// bounds. Never traps.
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

/// An `OrientedSceneLinearRGBImage` paired with the channel-mixed state it was
/// produced from.
///
/// ## Why the source is kept
///
/// Changing an orientation must restart from the **unoriented** channel-mixed
/// image, never from an already-oriented one:
///
/// ```text
/// new result = orient(the channel-mixed image, O2)
///        NOT   orient(orient(the channel-mixed image, O1), O2)
/// ```
///
/// Chaining would silently compose the two orientations. That is worse than it
/// first sounds: the eight orientations form a group, so a composition is
/// always *some* valid orientation, and a wrongly composed result is a
/// perfectly well-formed picture that is simply not the one asked for. Setting
/// `.upright` after `.rotated90Clockwise` would leave the image rotated while
/// every record claimed it was upright.
///
/// So the channel-mixed image stays reachable here, with the pre-mix working
/// image below it, the camera-native image below that, and the mosaics, the
/// decoded `UInt16` mosaic and the metadata at the bottom. Nothing is mutated
/// in place and nothing is discarded.
///
/// `ImageOrienter.apply(orientation:replacing:)` is the structural expression
/// of that: it takes a previous result and reaches through it to `source`, so
/// a caller cannot accidentally compose.
///
/// ## A stage-produced pairing, not a caller-assembled one
///
/// As with every other wrapper in this chain, the initialiser is
/// module-internal: outside the module the pairing can be read in full but not
/// minted, so a channel-mixed source from one run cannot be attached to an
/// oriented result from another.
public struct OrientedProcessedRAWImage: Sendable {
    /// The unoriented, channel-mixed state this was produced from, unchanged —
    /// with the pre-mix working image on its own `.source`, and the
    /// camera-native image and the mosaics below that.
    public let source: IRChannelMixedProcessedRAWImage
    /// The oriented image, with the same values as `source.image`.
    public let image: OrientedSceneLinearRGBImage

    /// Module-internal, deliberately: only `ImageOrienter` pairs a
    /// channel-mixed state with the oriented image it produced from it.
    init(source: IRChannelMixedProcessedRAWImage, image: OrientedSceneLinearRGBImage) {
        self.source = source
        self.image = image
    }

    /// The unoriented channel-mixed image the orientation was applied to.
    /// Changing the orientation must always start here.
    public var channelMixedImage: IRChannelMixedRGBImage { source.image }
    /// The pre-mix working-colour image. Changing the creative mix starts
    /// here.
    public var workingColorImage: WorkingColorRGBImage { source.workingColorImage }
    /// The linear camera-native RGB image. Changing the camera-to-working
    /// transform starts here.
    public var demosaicedImage: DemosaicedRAWRGBImage { source.demosaicedImage }
    /// The white-balanced mosaic. Changing demosaic algorithm starts here.
    public var whiteBalancedMosaic: WhiteBalancedRAWMosaic { source.whiteBalancedMosaic }
    /// The normalised, pre-white-balance mosaic. Changing or re-estimating the
    /// gains starts here.
    public var linearMosaic: LinearRAWMosaic { source.linearMosaic }
    /// Provenance for `image`. Forwarded rather than stored a second time, so
    /// the buffer and the record of how it was made can never disagree.
    public var processing: ImageOrientationProcessing { image.processing }
    /// The orientation that produced `image`.
    public var orientation: RAWImageOrientation { image.processing.orientation }
    /// The creative mix applied upstream — a different operation from anything
    /// this stage did, and still separately readable.
    public var mix: IRChannelMix { source.mix }
    /// The camera-to-working transform applied further upstream.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        source.cameraToWorkingTransform
    }
    /// The RAW-state metadata the chain was processed against.
    ///
    /// This stage reads none of it. The orientation it applied was chosen by a
    /// caller and passed in — `metadata.geometry.orientation` is where that
    /// caller will normally have got it, but the stage neither knows nor
    /// requires that.
    public var metadata: RAWMetadata { source.metadata }
    public var url: URL { source.url }
}
