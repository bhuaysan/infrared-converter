import Foundation

/// What the export encoder did, and what it deliberately did not do.
///
/// Carries the exposure stage's record, which carries the orientation stage's,
/// and so on back to the mosaic — so an exported file's provenance is the
/// whole history of its pixels, not just its last step.
public struct ExportImageProcessing: Equatable, Sendable {
    /// The range policy and encoding this image was produced with.
    public let settings: ExportRenderSettings
    /// The scene-linear state it was produced from.
    public let exposureProcessing: SceneLinearExposureProcessing
    /// How many components the range policy clipped to `0`.
    public let clippedLowSampleCount: Int
    /// How many components the range policy clipped to `1`.
    public let clippedHighSampleCount: Int

    /// What this stage did.
    public let exportRangeClippingApplied: Bool = true
    public let transferFunctionApplied: Bool = true
    public let quantized: Bool = true

    /// What it did not do. The values are no longer proportional to light —
    /// which is exactly what makes this the boundary it is.
    public let sceneLinear: Bool = false
    public let toneMappingApplied: Bool = false
    public let highlightReconstructionApplied: Bool = false
    public let automaticExposureApplied: Bool = false
    public let contrastApplied: Bool = false
    public let saturationApplied: Bool = false
    public let sharpeningApplied: Bool = false
    public let resampled: Bool = false
    public let cropped: Bool = false

    public init(
        settings: ExportRenderSettings,
        exposureProcessing: SceneLinearExposureProcessing,
        clippedLowSampleCount: Int,
        clippedHighSampleCount: Int
    ) {
        self.settings = settings
        self.exposureProcessing = exposureProcessing
        self.clippedLowSampleCount = clippedLowSampleCount
        self.clippedHighSampleCount = clippedHighSampleCount
    }

    public var rangePolicy: ExportRangePolicy { settings.rangePolicy }
    public var encoding: ExportEncoding { settings.encoding }
    public var clippedSampleCount: Int { clippedLowSampleCount + clippedHighSampleCount }

    /// Whether these samples came from a reduced preview rendition.
    ///
    /// Always `false` for anything the encoder produced — it refuses a reduced
    /// source outright — and kept as a readable fact so an export's own record
    /// says so rather than leaving it to be inferred.
    public var reducedForPreview: Bool { exposureProcessing.reducedForPreview }

    public var exposureEV: Double { exposureProcessing.exposureEV }
    public var exposureScale: Double { exposureProcessing.exposureScale }
    public var exposureApplied: Bool { exposureProcessing.exposureApplied }
    public var orientation: RAWImageOrientation { exposureProcessing.orientation }
    public var orientationApplied: Bool { exposureProcessing.orientationApplied }
    public var orientationSwappedDimensions: Bool {
        exposureProcessing.orientationSwappedDimensions
    }
    public var mix: IRChannelMix { exposureProcessing.mix }
    public var mixSource: IRChannelMixSource { exposureProcessing.mixSource }
    public var channelMixApplied: Bool { exposureProcessing.channelMixApplied }
    public var workingColorSpace: RAWWorkingColorSpace {
        exposureProcessing.workingColorSpace
    }
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        exposureProcessing.cameraToWorkingTransform
    }
    public var cameraToWorkingTransformSource: RAWCameraToWorkingColorTransformSource {
        exposureProcessing.cameraToWorkingTransformSource
    }
    public var isValidatedInfraredCalibration: Bool {
        exposureProcessing.isValidatedInfraredCalibration
    }
    public var demosaiced: Bool { exposureProcessing.demosaiced }
    public var demosaicAlgorithm: RAWDemosaicAlgorithm {
        exposureProcessing.demosaicAlgorithm
    }
    public var whiteBalanceApplied: Bool { exposureProcessing.whiteBalanceApplied }
    public var whiteBalanceGains: RAWWhiteBalanceGains {
        exposureProcessing.whiteBalanceGains
    }
    public var blackLevelSubtracted: Bool { exposureProcessing.blackLevelSubtracted }
    public var normalized: Bool { exposureProcessing.normalized }

    public var diagnosticDescription: String {
        """
        \(settings.diagnosticDescription), 16 bits per component, \
        \(clippedLowSampleCount) low and \(clippedHighSampleCount) high samples clipped
        """
    }
}

/// One export pixel, as three 16-bit samples.
public struct ExportEncodedRGBPixel: Equatable, Sendable {
    public let red: UInt16
    public let green: UInt16
    public let blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public func sample(_ channel: RAWLinearRGBChannel) -> UInt16 {
        switch channel {
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }
}

/// Display-referred sRGB at 16 bits per component: what a file writer writes,
/// and the last representation before bytes on disk.
///
/// ```text
/// 3 channels, interleaved R G B, row-major, no alpha
/// 16 bits per component, unsigned, normalised: 0 → 0.0, 65535 → 1.0
/// sRGB primaries, D65 white point, piecewise sRGB transfer function applied
/// display-referred: these values are NOT proportional to light
/// ```
///
/// ## Samples, not bytes
///
/// The buffer is `[UInt16]`, not `Data`. That is deliberate: a byte buffer
/// would have a byte order, and a byte order is exactly the kind of detail
/// that silently produces a file whose reds and greens are swapped by 256.
/// Byte order belongs to the file writer, at the one point where these values
/// have to become bytes, and nowhere else.
public struct ExportEncodedImage: Equatable, Sendable {
    public static let channelCount = 3
    public static let bitsPerComponent = 16
    public static let bytesPerComponent = 2
    public static let bytesPerPixel = channelCount * bytesPerComponent
    public static let bitsPerPixel = channelCount * bitsPerComponent
    /// The largest encodable sample, and what an encoded `1.0` becomes.
    public static let maximumSample = UInt16.max

    /// Width in pixels, as viewed — orientation has already been applied to
    /// the pixels themselves.
    public let width: Int
    /// Height in pixels, as viewed.
    public let height: Int
    /// Interleaved RGB samples, `width × height × 3` of them.
    public let samples: [UInt16]
    /// What produced them, including the whole upstream chain by reference.
    public let processing: ExportImageProcessing

    public init(
        width: Int,
        height: Int,
        samples: [UInt16],
        processing: ExportImageProcessing
    ) {
        self.width = width
        self.height = height
        self.samples = samples
        self.processing = processing
    }

    public var samplesPerRow: Int? {
        let (result, overflow) = width.multipliedReportingOverflow(by: Self.channelCount)
        return overflow ? nil : result
    }

    public var bytesPerRow: Int? {
        guard let samples = samplesPerRow else { return nil }
        let (result, overflow) = samples.multipliedReportingOverflow(by: Self.bytesPerComponent)
        return overflow ? nil : result
    }

    public static func expectedSampleCount(width: Int, height: Int) -> Int? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (total, totalOverflow) = pixels.multipliedReportingOverflow(by: channelCount)
        return totalOverflow ? nil : total
    }

    public var expectedSampleCount: Int? {
        Self.expectedSampleCount(width: width, height: height)
    }

    public var pixelCount: Int? {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : pixels
    }

    public var isGeometryConsistent: Bool {
        guard width > 0, height > 0, let expected = expectedSampleCount else { return false }
        return samples.count == expected
    }

    public func sampleIndex(row: Int, column: Int) -> Int? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: width)
        guard !rowOverflow else { return nil }
        let (pixelIndex, pixelOverflow) = rowOffset.addingReportingOverflow(column)
        guard !pixelOverflow else { return nil }
        let (base, baseOverflow) = pixelIndex.multipliedReportingOverflow(by: Self.channelCount)
        guard !baseOverflow, base >= 0 else { return nil }
        let (last, lastOverflow) = base.addingReportingOverflow(Self.channelCount - 1)
        guard !lastOverflow, last < samples.count else { return nil }
        return base
    }

    public func sample(
        row: Int, column: Int, channel: RAWLinearRGBChannel
    ) -> UInt16? {
        guard let base = sampleIndex(row: row, column: column) else { return nil }
        return samples[base + channel.storageOffset]
    }

    public func pixel(row: Int, column: Int) -> ExportEncodedRGBPixel? {
        guard let base = sampleIndex(row: row, column: column) else { return nil }
        return ExportEncodedRGBPixel(
            red: samples[base],
            green: samples[base + 1],
            blue: samples[base + 2]
        )
    }
}
