import Foundation

/// What the exposure stage did, and what it deliberately did not do.
///
/// Follows the chain: it carries the orientation stage's record, which carries
/// the channel mix's, which carries the working-colour conversion's, and so on
/// back to the mosaic. Reading an exposed image tells you the whole history of
/// the pixels.
public struct SceneLinearExposureProcessing: Equatable, Sendable {
    /// The exposure that was applied, as the shared primitive.
    public let exposure: SceneLinearExposure
    /// The stage this image was produced from.
    public let orientationProcessing: ImageOrientationProcessing

    /// Exposure was applied, in the linear domain.
    public let exposureApplied: Bool = true
    /// The values are still proportional to light.
    public let sceneLinear: Bool = true

    /// Nothing was clipped, clamped or compressed. A value exposure lifted
    /// above `1` is still above `1` here, which is exactly what lets a range
    /// policy downstream own clipping — and what lets a negative exposure
    /// bring a value back into range instead of finding it already destroyed.
    public let clamped: Bool = false
    public let gammaApplied: Bool = false
    public let displayEncodingApplied: Bool = false
    public let quantized: Bool = false
    public let toneMappingApplied: Bool = false
    public let automaticExposureApplied: Bool = false
    public let highlightReconstructionApplied: Bool = false
    public let contrastApplied: Bool = false
    public let saturationApplied: Bool = false
    public let sharpeningApplied: Bool = false

    /// Geometry is untouched by this stage: it multiplies, it does not move,
    /// resample or resize anything.
    public let interpolated: Bool = false
    public let scaled: Bool = false
    public let cropped: Bool = false

    public init(
        exposure: SceneLinearExposure,
        orientationProcessing: ImageOrientationProcessing
    ) {
        self.exposure = exposure
        self.orientationProcessing = orientationProcessing
    }

    public var exposureEV: Double { exposure.ev }
    public var exposureScale: Double { exposure.scale }

    /// Whether the image this was produced from is a **reduced preview**
    /// rendition rather than the sensor's own resolution.
    ///
    /// The load-bearing fact for export: an encoder that would turn these
    /// values into a final file refuses when this is `true`. Preview pixels
    /// are a disposable cache, never export truth. See
    /// `docs/decisions/0015-reduced-resolution-preview.md`.
    public var reducedForPreview: Bool { orientationProcessing.sourceReducedForPreview }
    /// What the reduction was, when there was one.
    public var previewResolution: PreviewResolution? {
        orientationProcessing.previewResolution
    }

    public var orientation: RAWImageOrientation { orientationProcessing.orientation }
    public var orientationApplied: Bool { orientationProcessing.orientationApplied }
    public var orientationSwappedDimensions: Bool {
        orientationProcessing.dimensionsSwapped
    }
    public var pixelValuesPreservedByOrientation: Bool {
        orientationProcessing.pixelValuesPreserved
    }
    public var channelMixProcessing: IRChannelMixProcessing {
        orientationProcessing.channelMixProcessing
    }
    public var mix: IRChannelMix { orientationProcessing.mix }
    public var mixSource: IRChannelMixSource { orientationProcessing.mixSource }
    public var channelMixApplied: Bool { orientationProcessing.channelMixApplied }
    public var workingColorSpace: RAWWorkingColorSpace {
        orientationProcessing.workingColorSpace
    }
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        orientationProcessing.cameraToWorkingTransform
    }
    public var cameraToWorkingTransformSource: RAWCameraToWorkingColorTransformSource {
        orientationProcessing.cameraToWorkingTransformSource
    }
    public var isValidatedInfraredCalibration: Bool {
        orientationProcessing.isValidatedInfraredCalibration
    }
    public var demosaiced: Bool { orientationProcessing.demosaiced }
    public var demosaicAlgorithm: RAWDemosaicAlgorithm {
        orientationProcessing.demosaicAlgorithm
    }
    public var whiteBalanceApplied: Bool { orientationProcessing.whiteBalanceApplied }
    public var whiteBalanceGains: RAWWhiteBalanceGains {
        orientationProcessing.whiteBalanceGains
    }
    public var blackLevelSubtracted: Bool { orientationProcessing.blackLevelSubtracted }
    public var normalized: Bool { orientationProcessing.normalized }
}

/// Scene-linear working-space RGB with every canonical user adjustment
/// applied, and nothing else.
///
/// ```text
/// extended linear sRGB    sRGB primaries, D65, linear transfer, unclamped
/// Float32, interleaved    R, G, B per pixel, row-major
/// channel mix             applied
/// orientation             applied, as whole-pixel permutation
/// exposure                applied, as × 2^EV
/// display encoding        NOT applied
/// range policy            NOT applied — values outside 0…1 are ordinary here
/// ```
///
/// This is the end of the adjustment chain and the input to whichever encoder
/// turns light into pixels for a destination. For a full-resolution export it
/// is the sensor's own resolution; the same type can also hold a preview-sized
/// rendition, and `processing.reducedForPreview` says which — the export
/// encoder refuses the latter.
public struct ExposedSceneLinearRGBImage: Equatable, Sendable {
    public static let channelCount = 3

    /// Width in pixels, **as viewed** — the orientation stage has already run.
    public let width: Int
    /// Height in pixels, as viewed.
    public let height: Int
    /// Interleaved RGB, row-major, `width × height × 3` values.
    public let values: [Float]
    /// What produced them, including the whole upstream chain by reference.
    public let processing: SceneLinearExposureProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: SceneLinearExposureProcessing
    ) {
        self.width = width
        self.height = height
        self.values = values
        self.processing = processing
    }

    public var exposureEV: Double { processing.exposureEV }
    public var orientation: RAWImageOrientation { processing.orientation }

    public var valuesPerRow: Int? {
        let (result, overflow) = width.multipliedReportingOverflow(by: Self.channelCount)
        return overflow ? nil : result
    }

    public static func expectedValueCount(width: Int, height: Int) -> Int? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (total, totalOverflow) = pixels.multipliedReportingOverflow(by: channelCount)
        return totalOverflow ? nil : total
    }

    public var expectedValueCount: Int? {
        Self.expectedValueCount(width: width, height: height)
    }

    public var pixelCount: Int? {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : pixels
    }

    public var isGeometryConsistent: Bool {
        guard width > 0, height > 0, let expected = expectedValueCount else { return false }
        return values.count == expected
    }

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

    public func value(row: Int, column: Int, channel: RAWLinearRGBChannel) -> Float? {
        guard let base = storageIndex(row: row, column: column) else { return nil }
        return values[base + channel.storageOffset]
    }

    public func pixel(row: Int, column: Int) -> RAWLinearRGBPixel? {
        guard let base = storageIndex(row: row, column: column) else { return nil }
        return RAWLinearRGBPixel(
            red: values[base],
            green: values[base + 1],
            blue: values[base + 2]
        )
    }
}
