import Foundation

/// What the preview-reduction stage did — and explicitly did not do — to
/// produce a `SceneLinearPreviewImage`.
///
/// It follows the same rule as every other stage record in this project: facts
/// that are structural properties of the stage are `let` constants, so the
/// type itself states them, and nothing upstream is copied. The working colour
/// space, the camera transform, the demosaic algorithm, the gains, the white
/// level and the black subtraction all live on `workingColorProcessing` and
/// are read through it.
///
/// ## The one field that is not a stage fact
///
/// `mix` is `nil` until the creative channel mix has run on this reduced
/// image, and holds the mix that ran afterwards. That is deliberate, and it is
/// the one place this milestone departs from "a new type per stage".
///
/// The reduced preview domain is a **working representation for the
/// interactive workspace**, not a second copy of the pipeline. Giving the
/// reduction and the mix a type each would fork every downstream stage into a
/// full-resolution and a preview-resolution variant, which is the general
/// image engine this milestone is explicitly not building. One type with an
/// honest two-state record says the same thing and costs one optional.
///
/// The invariant the optional protects is the same one
/// `IRChannelMixedProcessedRAWImage` protects structurally: **mixes never
/// compose.** `IRChannelMixer` refuses a preview image that has already been
/// mixed, so `M2 x (M1 x preview)` cannot be built by accident.
public struct SceneLinearPreviewProcessing: Equatable, Sendable {

    /// What was reduced, to what, by which rule and by which method.
    public let resolution: PreviewResolution
    /// Provenance of the `WorkingColorRGBImage` this stage consumed, carried
    /// forward so the whole chain from unpacked samples to here is readable
    /// from one record.
    public let workingColorProcessing: RAWWorkingColorProcessing
    /// The creative channel mix applied to this reduced image, or `nil` when
    /// the creative stage has not run on it yet.
    public let mix: IRChannelMix?

    /// These pixels are a reduced rendition made for interactive display. They
    /// are **not** the processing truth, and nothing may export from them.
    public let reducedForPreview: Bool = true
    /// The values are still proportional to light, in the same working colour
    /// space, with the same units, as the image they were reduced from.
    public let sceneLinear: Bool = true
    /// Nothing was clamped. An area-weighted mean of extended-linear values is
    /// itself an extended-linear value, and values below `0` and above `1`
    /// survive.
    public let clamped: Bool = false
    /// No transfer function, no tone mapping, no display encoding, no
    /// quantisation.
    public let gammaApplied: Bool = false
    public let toneMappingApplied: Bool = false
    public let displayEncodingApplied: Bool = false
    /// Geometry: the image is smaller, and that is all. It is still in sensor
    /// order, still uncropped, and still unrotated.
    public let orientationApplied: Bool = false
    public let cropped: Bool = false
    public let arbitraryRotationApplied: Bool = false

    /// Whether the pixels were actually resampled. `false` for a photograph
    /// that was already within the preview limit, whose samples survive
    /// bit-for-bit.
    public var resampled: Bool { resolution.isReduced }
    /// Whether the creative stage has run on this image.
    public var channelMixApplied: Bool { mix != nil }

    /// The mix stage's own record, synthesised from what this image knows, or
    /// `nil` before the mix has run.
    ///
    /// This is what lets a reduced preview hand a complete, ordinary
    /// `ImageOrientationProcessing` to the geometry stage: the downstream
    /// chain reads exactly the same provenance it would have read at full
    /// resolution, plus `PreviewResolution` beside it.
    public var channelMixProcessing: IRChannelMixProcessing? {
        mix.map {
            IRChannelMixProcessing(mix: $0, workingColorProcessing: workingColorProcessing)
        }
    }

    // Forwarded, never duplicated.
    public var workingColorSpace: RAWWorkingColorSpace {
        workingColorProcessing.workingColorSpace
    }
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        workingColorProcessing.transform
    }
    public var cameraToWorkingTransformSource: RAWCameraToWorkingColorTransformSource {
        workingColorProcessing.transformSource
    }
    public var isValidatedInfraredCalibration: Bool {
        workingColorProcessing.isValidatedInfraredCalibration
    }
    public var workingColorRepresentationEstablished: Bool {
        workingColorProcessing.workingColorRepresentationEstablished
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
        workingColorProcessing: RAWWorkingColorProcessing,
        mix: IRChannelMix? = nil
    ) {
        self.resolution = resolution
        self.workingColorProcessing = workingColorProcessing
        self.mix = mix
    }

    /// The same record with a creative mix recorded on it.
    ///
    /// Module-internal: only `IRChannelMixer` may say that a mix has run.
    func mixed(_ mix: IRChannelMix) -> SceneLinearPreviewProcessing {
        SceneLinearPreviewProcessing(
            resolution: resolution,
            workingColorProcessing: workingColorProcessing,
            mix: mix
        )
    }
}

/// Three `Float32` per pixel, scene-linear, in the working colour space, at
/// **preview resolution**.
///
/// ## What this type is for
///
/// It is the buffer the interactive workspace holds open and re-renders from.
/// Everything the user can change today — the orientation — and everything
/// they will be able to change next — the channel mix, exposure, tone — is
/// applied to this, at this size, and never to a sensor-resolution buffer.
///
/// ```text
/// WorkingColorRGBImage       4056 x 3040   the processing truth, transient
///       ↓  SceneLinearPreviewReducer
/// SceneLinearPreviewImage    2048 x 1535   retained, disposable, interactive
/// ```
///
/// ## Why it is a separate type from `WorkingColorRGBImage`
///
/// Because that type's contract says the dimensions are those of the image it
/// was demosaiced from and that no resampling has happened, and both stop
/// being true here. A reduced buffer wearing the full-resolution type would be
/// distinguishable from the real thing only by comparing its width against the
/// sensor's, which is exactly the guess this type exists to remove.
///
/// ## What it is not
///
/// It is not the source of truth and it is not an export source. The canonical
/// editing state of a photograph remains:
///
/// ```text
/// the RAW file  +  ImageAdjustments
/// ```
///
/// This is a cache derived from those two, cheap to throw away and cheap to
/// rebuild, and a full-resolution render — when one exists — will start from
/// the RAW file again rather than from these pixels. Encoding these values for
/// export would ship a downsampled photograph as if it were the original.
///
/// ## Storage
///
/// Identical in layout to every other three-channel image here: row-major,
/// tightly packed, interleaved `R G B`, `width * height * 3` elements. Twelve
/// bytes per pixel, not sixteen.
public struct SceneLinearPreviewImage: Equatable, Sendable {
    /// How many `Float32` values one pixel occupies. Always `3`.
    public static let channelCount = 3

    /// Width in pixels. Equal to `processing.resolution.width`.
    public let width: Int
    /// Height in pixels. Equal to `processing.resolution.height`.
    public let height: Int
    /// `width * height * 3` values, row-major, interleaved `R G B`, in the
    /// working colour space `processing.workingColorSpace` names.
    public let values: [Float]
    /// What produced these values: the reduction, the mix if one has run, and
    /// the whole upstream chain.
    public let processing: SceneLinearPreviewProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: SceneLinearPreviewProcessing
    ) {
        self.width = width
        self.height = height
        self.values = values
        self.processing = processing
    }

    /// How this image was reduced, and from what.
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
