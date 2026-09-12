import Foundation

/// What the creative channel-mix stage did to a **reduced** scene-linear
/// preview.
///
/// It follows the same rule as every other stage record in this project: facts
/// that are structural properties of the stage are `let` constants, so the
/// type itself states them, and nothing upstream is copied. The mix, the
/// working colour space, the camera transform, the demosaic algorithm, the
/// gains, the white level and the black subtraction are all read through
/// `channelMixProcessing`.
///
/// ## What it adds over `IRChannelMixProcessing`
///
/// One fact, and it is the fact the upstream stage records cannot carry: the
/// resolution. `IRChannelMixProcessing` describes a stage that is exactly as
/// true of a reduced image as of a sensor-resolution one, and the reduction
/// happened before it. A reader of a finished preview has to be able to learn
/// that these pixels are a smaller rendition rather than the sensor's own.
public struct IRChannelMixedPreviewProcessing: Equatable, Sendable {

    /// What was reduced, to what, by which rule and by which method — carried
    /// through the mix untouched, because a mix is not a reduction.
    public let resolution: PreviewResolution
    /// Provenance of the creative mix and, through it, of the whole chain from
    /// unpacked samples to here.
    public let channelMixProcessing: IRChannelMixProcessing

    /// The creative stage ran. Which mix, and what it is entitled to claim, is
    /// `mix.source` — this flag says only that the stage was traversed, and it
    /// is `true` for `.identity` too, because asking for no remapping is a
    /// different fact from never reaching the stage.
    public let channelMixApplied: Bool = true
    /// These pixels are a reduced rendition made for interactive display. They
    /// are **not** the processing truth, and nothing may export from them.
    public let reducedForPreview: Bool = true
    /// The values are still proportional to light, in the same working colour
    /// space, with the same units, as the image the mix was applied to.
    public let sceneLinear: Bool = true
    /// Nothing was clamped. A creative mix with negative or amplifying
    /// coefficients legitimately produces coordinates below `0` and above `1`,
    /// and they are preserved exactly as the arithmetic produced them.
    public let clamped: Bool = false
    /// No transfer function, no tone mapping, no display encoding, no
    /// quantisation.
    public let gammaApplied: Bool = false
    public let toneMappingApplied: Bool = false
    public let displayEncodingApplied: Bool = false
    /// Geometry: unchanged by this stage. Still in sensor order, still
    /// uncropped, still unrotated, and still the size the reduction made it.
    public let orientationApplied: Bool = false
    public let cropped: Bool = false
    public let arbitraryRotationApplied: Bool = false
    public let scaled: Bool = false

    /// Whether the reduction that preceded the mix actually resampled.
    /// `false` for a photograph that was already within the preview limit.
    public var resampled: Bool { resolution.isReduced }

    /// The exact mix that was applied. Read through the stage record, never
    /// duplicated.
    public var mix: IRChannelMix { channelMixProcessing.mix }
    /// Where that mix came from: a built-in, or an explicit caller choice.
    public var mixSource: IRChannelMixSource { channelMixProcessing.mixSource }
    /// The 3×3 matrix that was applied.
    public var matrix: RAWColorMatrix3x3 { channelMixProcessing.matrix }

    /// Provenance of the working-colour image the reduction consumed.
    public var workingColorProcessing: RAWWorkingColorProcessing {
        channelMixProcessing.workingColorProcessing
    }

    // Forwarded, never duplicated.
    public var workingColorSpace: RAWWorkingColorSpace {
        channelMixProcessing.workingColorSpace
    }
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        channelMixProcessing.cameraToWorkingTransform
    }
    public var cameraToWorkingTransformSource: RAWCameraToWorkingColorTransformSource {
        channelMixProcessing.cameraToWorkingTransformSource
    }
    public var isValidatedInfraredCalibration: Bool {
        channelMixProcessing.isValidatedInfraredCalibration
    }
    public var workingColorRepresentationEstablished: Bool {
        channelMixProcessing.workingColorRepresentationEstablished
    }
    public var demosaiced: Bool { workingColorProcessing.demosaiced }
    public var demosaicAlgorithm: RAWDemosaicAlgorithm {
        workingColorProcessing.demosaicAlgorithm
    }
    public var whiteBalanceApplied: Bool { workingColorProcessing.whiteBalanceApplied }
    public var whiteBalanceGains: RAWWhiteBalanceGains {
        workingColorProcessing.whiteBalanceGains
    }
    public var blackLevelSubtracted: Bool { workingColorProcessing.blackLevelSubtracted }
    public var normalized: Bool { workingColorProcessing.normalized }

    public init(
        resolution: PreviewResolution,
        channelMixProcessing: IRChannelMixProcessing
    ) {
        self.resolution = resolution
        self.channelMixProcessing = channelMixProcessing
    }
}

/// Three `Float32` per pixel, scene-linear, in the working colour space, at
/// **preview resolution**, with the user's creative channel mix applied.
///
/// ```text
/// SceneLinearPreviewImage        reduced, PRE-mix   ← what a document retains
///       ↓  IRChannelMixer, with the user's mix
/// IRChannelMixedPreviewImage     reduced, POST-mix  ← this type; transient
///       ↓  ImageOrienter
/// OrientedSceneLinearRGBImage
///       ↓  DisplayPreviewRenderer
/// DisplayEncodedPreviewImage
/// ```
///
/// ## Why the two reduced types are separate
///
/// Because **mixes never compose** (ADR 0007, Decision 27), and because the
/// mix is now something a user changes. Both states are live in one call graph
/// on every interaction: the workspace holds the pre-mix buffer open and
/// produces a post-mix one from it several times a second.
///
/// ADR 0015 modelled the same two states as one type with an optional
/// `mix: IRChannelMix?`, checked at both boundaries — `IRChannelMixer` refused
/// an already-mixed preview, `ImageOrienter` refused an unmixed one. That was
/// adequate while the mix ran once, inside `prepare`, and was never replaced.
/// It stopped being adequate when the mix became an adjustment: a runtime
/// refusal on the hot path of every interaction is a test away from being a
/// composed matrix on screen, and a composed matrix is not recognisably wrong.
/// It is simply a different rendering than the one asked for.
///
/// Two types make the whole question disappear. There is no
/// `IRChannelMixer.apply` that accepts this type, so `M2 × (M1 × preview)`
/// cannot be written; there is no `ImageOrienter.apply` that accepts a pre-mix
/// preview, so an incomplete provenance chain cannot reach the display stage.
/// Neither refusal has to be remembered, documented or tested, because neither
/// compiles. See `docs/decisions/0016-interactive-channel-mixer.md`.
///
/// ## What it is not
///
/// Not the source of truth, not an export source, and not what a document
/// keeps. The canonical editing state remains:
///
/// ```text
/// the RAW file  +  ImageAdjustments
/// ```
///
/// This value exists for the length of one render. What survives it is the
/// display-encoded result and the **pre-mix** buffer it was made from — never
/// this, because retaining it would be retaining one mix.
///
/// ## Storage
///
/// Identical in layout to every other three-channel image here: row-major,
/// tightly packed, interleaved `R G B`, `width * height * 3` elements.
public struct IRChannelMixedPreviewImage: Equatable, Sendable {
    /// How many `Float32` values one pixel occupies. Always `3`.
    public static let channelCount = 3

    /// Width in pixels. Equal to `processing.resolution.width`.
    public let width: Int
    /// Height in pixels. Equal to `processing.resolution.height`.
    public let height: Int
    /// `width * height * 3` values, row-major, interleaved `R G B`, in the
    /// working colour space `processing.workingColorSpace` names.
    public let values: [Float]
    /// What produced these values: the mix, the reduction that preceded it,
    /// and the whole upstream chain.
    public let processing: IRChannelMixedPreviewProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: IRChannelMixedPreviewProcessing
    ) {
        self.width = width
        self.height = height
        self.values = values
        self.processing = processing
    }

    /// How the image this was mixed from was reduced, and from what.
    public var resolution: PreviewResolution { processing.resolution }

    /// Elements between the starts of consecutive rows, or `nil` on overflow.
    public var valuesPerRow: Int? {
        let (result, overflow) = width.multipliedReportingOverflow(by: Self.channelCount)
        return overflow ? nil : result
    }

    /// The element count implied by `width * height * 3`, or `nil` when either
    /// multiplication would overflow.
    public var expectedValueCount: Int? {
        Self.expectedValueCount(width: width, height: height)
    }

    static func expectedValueCount(width: Int, height: Int) -> Int? {
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
    /// elements, and when that geometry is the one the resolution record
    /// names. Non-positive dimensions make this `false` rather than trap.
    public var isGeometryConsistent: Bool {
        guard width > 0, height > 0, let expected = expectedValueCount else { return false }
        guard width == processing.resolution.width,
              height == processing.resolution.height
        else { return false }
        return values.count == expected
    }

    /// The index of a pixel's first (`red`) element, or `nil` when the
    /// coordinate is out of bounds or the offset arithmetic would overflow.
    public func storageIndex(row: Int, column: Int) -> Int? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: width)
        guard !rowOverflow else { return nil }
        let (pixelIndex, pixelOverflow) = rowOffset.addingReportingOverflow(column)
        guard !pixelOverflow else { return nil }
        let (base, baseOverflow) = pixelIndex.multipliedReportingOverflow(by: Self.channelCount)
        guard !baseOverflow, base >= 0 else { return nil }
        let (last, lastOverflow) = base.addingReportingOverflow(Self.channelCount - 1)
        guard !lastOverflow, last < values.count else { return nil }
        return base
    }

    /// One channel of one pixel, or `nil` when the coordinate is out of range.
    public func value(row: Int, column: Int, channel: RAWLinearRGBChannel) -> Float? {
        guard let base = storageIndex(row: row, column: column) else { return nil }
        return values[base + channel.storageOffset]
    }

    /// All three channels of one pixel, or `nil` when the coordinate is out of
    /// range.
    public func pixel(row: Int, column: Int) -> RAWLinearRGBPixel? {
        guard let base = storageIndex(row: row, column: column) else { return nil }
        return RAWLinearRGBPixel(
            red: values[base], green: values[base + 1], blue: values[base + 2]
        )
    }
}
