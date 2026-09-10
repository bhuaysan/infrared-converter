import Foundation

/// What the display rendering stage did — and explicitly did not do — to
/// produce a `DisplayEncodedPreviewImage`.
///
/// As with `RAWLinearProcessing`, `RAWWhiteBalanceProcessing`,
/// `RAWDemosaicProcessing`, `RAWWorkingColorProcessing` and
/// `IRChannelMixProcessing`, the facts that are structural properties of this
/// stage rather than choices are `let` constants, so the type itself states
/// them.
///
/// Nothing upstream is copied. The exposure, the range policy and the encoding
/// live on `settings`; the creative mix, the camera-to-working transform, the
/// demosaic algorithm, the gains and their provenance, the white level and the
/// black subtraction all already live on `channelMixProcessing` and are read
/// through it. Two copies of the same history can disagree; one cannot.
///
/// ## One thing here is measured, not declared
///
/// `clippedLowSampleCount` and `clippedHighSampleCount` are counts the
/// renderer took while it worked. Provenance elsewhere in this project records
/// *what a stage did*; this stage **discards information**, so naming the
/// policy does not fully describe what it did. How much of the image the
/// policy consumed is part of the honest record.
public struct DisplayPreviewProcessing: Equatable, Sendable {
    /// The exact settings that were applied: exposure, range policy, encoding.
    public let settings: DisplayRenderSettings
    /// Provenance of the `IRChannelMixedRGBImage` this stage consumed, carried
    /// forward so the whole chain from unpacked samples to here is readable
    /// from one record.
    public let channelMixProcessing: IRChannelMixProcessing
    /// How many **components** (not pixels) were below `0` after exposure and
    /// were replaced by `0`.
    ///
    /// A destroyed shadow, counted. Zero means nothing was clipped low, which
    /// is a stronger statement than the policy alone can make.
    public let clippedLowSampleCount: Int
    /// How many **components** (not pixels) were above `1` after exposure and
    /// were replaced by `1`.
    ///
    /// A destroyed highlight, counted. This is the number that says whether a
    /// preview's whites are white because the scene was bright or because the
    /// display range ran out.
    public let clippedHighSampleCount: Int

    /// Exposure was applied, in the linear domain, before clipping and before
    /// encoding. `true` even at `0 EV`: traversing the stage and asking for
    /// `×1` is a different fact from never applying exposure at all.
    public let exposureApplied: Bool = true
    /// Coordinates outside `0...1` were clipped, per `settings.rangePolicy`.
    /// This stage's whole answer to out-of-range data.
    public let displayRangeClippingApplied: Bool = true
    /// The values were encoded for a display: they are no longer linear.
    public let displayEncodingApplied: Bool = true
    /// The values were quantised to integers. Precision below one 8-bit level
    /// is gone.
    public let quantized: Bool = true
    /// These are **not** scene-linear values. The scene-linear image they came
    /// from is still reachable through the processed wrapper, unchanged.
    public let sceneLinear: Bool = false
    /// No tone mapping of any kind: no Reinhard, no filmic curve, no shoulder
    /// or toe, no local operator. Clipping is not tone mapping.
    public let toneMappingApplied: Bool = false
    /// No automatic exposure. No histogram was read, no mean or percentile was
    /// computed, and nothing was normalised to a maximum. The exposure is the
    /// one on `settings`, chosen by a caller.
    public let automaticExposureApplied: Bool = false
    /// No contrast adjustment.
    public let contrastApplied: Bool = false
    /// No saturation or vibrance adjustment.
    public let saturationApplied: Bool = false
    /// No highlight reconstruction. Clipped highlights were destroyed, not
    /// recovered.
    public let highlightReconstructionApplied: Bool = false
    /// No sharpening and no noise reduction.
    public let sharpeningApplied: Bool = false
    /// No orientation (rotation/flip) transform. This stage is
    /// geometry-preserving and does not read the file's orientation metadata;
    /// the application-owned pipeline still has no orientation stage.
    public let orientationApplied: Bool = false

    /// Exposure in stops, read through `settings`.
    public var exposureEV: Double { settings.exposureEV }
    /// The linear multiplier that exposure applied, `2^EV`.
    public var exposureScale: Double { settings.exposureScale }
    /// What was done with out-of-range coordinates.
    public var rangePolicy: DisplayRangePolicy { settings.rangePolicy }
    /// The transfer function and colour space the bytes are in.
    public var encoding: DisplayEncoding { settings.encoding }
    /// Components clipped in either direction.
    public var clippedSampleCount: Int { clippedLowSampleCount + clippedHighSampleCount }

    /// The creative mix applied upstream — a **different operation** from
    /// anything this stage did, kept separately readable so a rendering can be
    /// audited for both.
    public var mix: IRChannelMix { channelMixProcessing.mix }
    /// Where that mix came from: a built-in, or an explicit caller choice.
    public var mixSource: IRChannelMixSource { channelMixProcessing.mixSource }
    /// The working colour space the scene-linear input was in. Display
    /// encoding does not change primaries; it changes the transfer function
    /// and the range.
    public var workingColorSpace: RAWWorkingColorSpace {
        channelMixProcessing.workingColorSpace
    }
    /// A creative channel mix ran upstream. It is not applied again here.
    public var channelMixApplied: Bool { channelMixProcessing.channelMixApplied }
    /// The camera-to-working transform applied upstream.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        channelMixProcessing.cameraToWorkingTransform
    }
    /// Where that upstream transform came from.
    public var cameraToWorkingTransformSource: RAWCameraToWorkingColorTransformSource {
        channelMixProcessing.cameraToWorkingTransformSource
    }
    /// Whether the upstream camera-to-working transform is a validated
    /// infrared colour calibration. `false` for every source the project can
    /// produce — and making an image displayable never makes it one.
    public var isValidatedInfraredCalibration: Bool {
        channelMixProcessing.isValidatedInfraredCalibration
    }
    /// Missing channels were reconstructed upstream, in the mosaic domain.
    public var demosaiced: Bool { channelMixProcessing.demosaiced }
    /// Which algorithm reconstructed them.
    public var demosaicAlgorithm: RAWDemosaicAlgorithm {
        channelMixProcessing.demosaicAlgorithm
    }
    /// White balance was applied upstream, per CFA plane in the mosaic domain
    /// — and is not applied again here.
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
    /// of a stage, and the bare `DisplayEncodedPreviewImage` it belongs to is
    /// a data representation a test or an alternate producer may legitimately
    /// build.
    ///
    /// The pairing that must not be forgeable lives one level up, on
    /// `DisplayPreviewProcessedRAWImage`, whose initialiser is
    /// module-internal.
    public init(
        settings: DisplayRenderSettings,
        channelMixProcessing: IRChannelMixProcessing,
        clippedLowSampleCount: Int,
        clippedHighSampleCount: Int
    ) {
        self.settings = settings
        self.channelMixProcessing = channelMixProcessing
        self.clippedLowSampleCount = clippedLowSampleCount
        self.clippedHighSampleCount = clippedHighSampleCount
    }
}

/// Three `UInt8` per pixel, at one pixel coordinate: a convenience returned by
/// `DisplayEncodedPreviewImage.pixel(row:column:)`.
///
/// Not the image's storage representation — the image owns a flat byte buffer.
/// This exists only to hand one pixel back to a caller, as `RAWLinearRGBPixel`
/// does for the Float32 images. It is a separate type from that one because
/// these are display-encoded integer samples and those are scene-linear
/// coordinates, and a shared shape is not a shared meaning.
public struct DisplayEncodedRGBPixel: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// One component's sample.
    public func sample(_ channel: RAWLinearRGBChannel) -> UInt8 {
        switch channel {
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }
}

/// Display-referred, sRGB-encoded, clipped and quantised pixels: the first
/// representation in this project that a monitor can be handed correctly.
///
/// ## What these values are
///
/// ```text
/// display referred     NOT scene-linear
/// sRGB encoded         the piecewise sRGB transfer function has been applied
/// clipped              per the named DisplayRangePolicy, in both directions
/// quantised            8 bits per component, rounded to nearest
/// ```
///
/// ## What they are not
///
/// They are **not** light-proportional and must never be treated as though
/// they were. Averaging them, mixing channels in them, applying a matrix to
/// them or running exposure on them are all meaningless: the transfer function
/// has already been applied, and everything below `0` and above `1` is
/// already gone. Every operation of that kind belongs upstream, on the
/// scene-linear image this was rendered from — which is still reachable,
/// unchanged, through `DisplayPreviewProcessedRAWImage`.
///
/// They are also not a claim that the picture is **correct**. Displayable is a
/// strictly weaker property than colourimetrically right: no transform in this
/// pipeline is a validated infrared calibration, and a defined display
/// encoding does not create one.
///
/// ## Why this is not one of the scene-linear image types
///
/// `WorkingColorRGBImage` and `IRChannelMixedRGBImage` hold unclamped Float32
/// coordinates in extended linear sRGB. `RAWImage` holds LibRaw's processed
/// output. This holds neither. That the storage shape could be made to fit one
/// of them is a coincidence of layout, not a reason to reuse it: a function
/// signature has to be able to refuse a buffer that is already encoded, and
/// only a distinct type can do that.
///
/// ## Coordinate convention
///
/// Identical to the image it was rendered from: `(0, 0)` is the top-left of
/// the **active image area**, and the dimensions are unchanged. Rendering is
/// strictly per-pixel and touches no geometry — no crop, no resize, no
/// rotation, no flip, no resampling. In particular the file's orientation is
/// **not** applied here, and the pipeline still has no stage that applies it.
///
/// ## Storage
///
/// Tightly packed, row-major, interleaved, three bytes per pixel:
///
/// ```text
/// R G B  R G B  R G B ...
///
/// index = (row * width + column) * 3
/// R = bytes[index + 0]
/// G = bytes[index + 1]
/// B = bytes[index + 2]
/// ```
///
/// | | |
/// | --- | --- |
/// | Bits per component | 8 |
/// | Components | 3, interleaved `R G B` |
/// | Alpha | none — there is no alpha channel |
/// | Bytes per pixel | 3 |
/// | Bytes per row | `width × 3`, no padding |
/// | Byte order | not applicable: one byte per component |
///
/// There is no alpha channel rather than an ignored or invented one: the image
/// is opaque by construction, a fourth byte would carry no meaning, and a
/// quarter of the buffer would be padding. `CGImage` accepts 24-bit-per-pixel
/// RGB with `kCGImageAlphaNone` directly, so the adapter pays nothing for the
/// choice.
///
/// Byte order is genuinely not a question here, unlike for the 16-bit decoder
/// output: a one-byte component has no internal ordering.
public struct DisplayEncodedPreviewImage: Equatable, Sendable {
    /// How many components one pixel occupies. Always `3`.
    public static let channelCount = 3
    /// Bits per component. Always `8`.
    public static let bitsPerComponent = 8
    /// Bytes one pixel occupies. Always `3`.
    public static let bytesPerPixel = 3

    /// Width in pixels. Equal to the source image's width.
    public let width: Int
    /// Height in pixels. Equal to the source image's height.
    public let height: Int
    /// `width * height * 3` bytes, row-major, tightly packed, interleaved
    /// `R G B`, display-encoded per `processing.encoding`.
    public let bytes: Data
    /// What produced these bytes, including the exact settings, how much was
    /// clipped away, and the whole upstream chain.
    public let processing: DisplayPreviewProcessing

    public init(
        width: Int,
        height: Int,
        bytes: Data,
        processing: DisplayPreviewProcessing
    ) {
        self.width = width
        self.height = height
        self.bytes = bytes
        self.processing = processing
    }

    /// Bytes between the starts of consecutive rows. Always `width * 3`, or
    /// `nil` when that multiplication would overflow `Int`.
    public var bytesPerRow: Int? {
        let (result, overflow) = width.multipliedReportingOverflow(by: Self.bytesPerPixel)
        return overflow ? nil : result
    }

    /// The byte count `width * height * 3` implies, or `nil` when either
    /// multiplication would overflow `Int`.
    ///
    /// Both products are checked, for the reason the Float32 images give: a
    /// three-component image reaches `Int.max / 3` at a third of the geometry
    /// a single-component one does.
    ///
    /// Static so a producer can size a buffer before it has an image to ask,
    /// and so both callers use the same arithmetic rather than two copies of
    /// it.
    public static func expectedByteCount(width: Int, height: Int) -> Int? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (total, totalOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        return totalOverflow ? nil : total
    }

    /// The byte count this image's declared geometry implies, or `nil` on
    /// overflow.
    public var expectedByteCount: Int? {
        Self.expectedByteCount(width: width, height: height)
    }

    /// The pixel count implied by `width * height`, or `nil` on overflow.
    public var pixelCount: Int? {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : pixels
    }

    /// True when `bytes` holds exactly the declared geometry's worth of bytes.
    /// Non-positive dimensions, or geometry whose implied count would
    /// overflow, make this `false` rather than trap.
    public var isGeometryConsistent: Bool {
        guard width > 0, height > 0, let expected = expectedByteCount else { return false }
        return bytes.count == expected
    }

    /// The index of a pixel's first (`red`) byte, or `nil` when the coordinate
    /// is out of bounds or the offset arithmetic would overflow.
    ///
    /// Never traps, for any value the public initialiser accepts: passing the
    /// bounds check is not sufficient on its own, since a pathological `width`
    /// can overflow the offset arithmetic while the coordinate still looks in
    /// range.
    public func byteIndex(row: Int, column: Int) -> Int? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: width)
        guard !rowOverflow else { return nil }
        let (pixelIndex, pixelOverflow) = rowOffset.addingReportingOverflow(column)
        guard !pixelOverflow else { return nil }
        let (base, baseOverflow) = pixelIndex.multipliedReportingOverflow(by: Self.bytesPerPixel)
        guard !baseOverflow, base >= 0 else { return nil }
        // The last byte of the pixel must exist too.
        let (last, lastOverflow) = base.addingReportingOverflow(Self.bytesPerPixel - 1)
        guard !lastOverflow, last < bytes.count else { return nil }
        return base
    }

    /// One component's sample at a pixel coordinate, or `nil` when out of
    /// bounds. Never traps.
    ///
    /// `RAWLinearRGBChannel` names a storage position — first, second, third —
    /// and is reused here for exactly that. In this type its `red` means the
    /// display-encoded red sample, neither a sensor filter nor a scene-linear
    /// coordinate.
    public func sample(row: Int, column: Int, channel: RAWLinearRGBChannel) -> UInt8? {
        guard let base = byteIndex(row: row, column: column) else { return nil }
        return bytes[bytes.startIndex + base + channel.storageOffset]
    }

    /// All three samples at a pixel, or `nil` when out of bounds. Never traps.
    ///
    /// A convenience for callers reading a handful of pixels. It is not the
    /// storage representation and not the path a full-frame pass should take.
    public func pixel(row: Int, column: Int) -> DisplayEncodedRGBPixel? {
        guard let base = byteIndex(row: row, column: column) else { return nil }
        let start = bytes.startIndex + base
        return DisplayEncodedRGBPixel(
            red: bytes[start],
            green: bytes[start + 1],
            blue: bytes[start + 2]
        )
    }
}

/// A `DisplayEncodedPreviewImage` paired with the scene-linear state it was
/// rendered from.
///
/// ## Why the source is kept
///
/// Changing display settings must re-render from the **scene-linear** image,
/// never from an already-encoded preview:
///
/// ```text
/// new preview = render(the IRChannelMixedRGBImage, newSettings)
///        NOT   render(the previous 8-bit preview, newSettings)
/// ```
///
/// Re-rendering an encoded buffer would compound quantisation, apply the
/// transfer function twice, and could not recover a single clipped highlight —
/// and the result would look entirely plausible. So the mixed image stays
/// reachable here, with the pre-mix working image below it, the camera-native
/// image below that, and the mosaics, the decoded `UInt16` mosaic and the
/// metadata at the bottom. Nothing is mutated in place and nothing is
/// discarded.
///
/// `DisplayPreviewRenderer.render(settings:replacing:)` is the structural
/// expression of that: it takes a previous result and reaches through it to
/// `source`, so a caller cannot accidentally re-render a preview.
///
/// ## A stage-produced pairing, not a caller-assembled one
///
/// As with every other wrapper in this chain, the initialiser is
/// module-internal: outside the module the pairing can be read in full but not
/// minted, so a scene-linear source from one run cannot be attached to a
/// preview from another.
public struct DisplayPreviewProcessedRAWImage: Sendable {
    /// The scene-linear, channel-mixed state this was rendered from,
    /// unchanged — with the pre-mix working image on its own `.source`, and
    /// the camera-native image and the mosaics below that.
    public let source: IRChannelMixedProcessedRAWImage
    /// The display-encoded preview.
    public let image: DisplayEncodedPreviewImage

    /// Module-internal, deliberately: only `DisplayPreviewRenderer` pairs a
    /// scene-linear state with the preview it rendered from it.
    init(source: IRChannelMixedProcessedRAWImage, image: DisplayEncodedPreviewImage) {
        self.source = source
        self.image = image
    }

    /// The scene-linear image the settings were applied to, untouched by
    /// rendering. Changing exposure or the encoding must always start here.
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
    public var processing: DisplayPreviewProcessing { image.processing }
    /// The settings that produced `image`.
    public var settings: DisplayRenderSettings { image.processing.settings }
    /// The creative mix applied upstream — a different operation from anything
    /// this stage did, and still separately readable.
    public var mix: IRChannelMix { source.mix }
    /// The camera-to-working transform applied further upstream.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        source.cameraToWorkingTransform
    }
    /// The RAW-state metadata the chain was processed against. This stage
    /// reads none of it — not even the orientation, which it deliberately does
    /// not apply.
    public var metadata: RAWMetadata { source.metadata }
    public var url: URL { source.url }
}
