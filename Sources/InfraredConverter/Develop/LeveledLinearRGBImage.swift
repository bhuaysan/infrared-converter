import Foundation

/// What the levels stage did, and what it deliberately did not do.
///
/// Follows the chain: it carries the exposure stage's record, which carries
/// the orientation stage's, which carries the channel mix's, and so on back to
/// the mosaic. Reading a levelled image tells you the whole history of the
/// pixels.
public struct LinearLevelsProcessing: Equatable, Sendable {
    /// The levels that were applied, as the shared primitive.
    public let levels: LinearLevels
    /// The stage this image was produced from.
    public let exposureProcessing: SceneLinearExposureProcessing

    /// Levels were applied, in the linear domain, after exposure.
    ///
    /// `true` even at black `0` / white `1`: traversing the stage and asking
    /// for the identity is a different fact from never applying levels at all,
    /// and this project does not describe a stage it ran as one it skipped.
    public let levelsApplied: Bool = true

    /// The values are still **linear-light encoded**: no transfer function has
    /// been applied, nothing has been compressed, and no curve has been
    /// evaluated.
    public let linearLightEncoded: Bool = true

    /// They are **not** scene-linear.
    ///
    /// This is the flag that stops being `true` here, and it is the whole
    /// reason this type exists rather than another `ExposedSceneLinearRGBImage`.
    /// Exposure is a pure gain, so a scene-linear image multiplied by `2^EV`
    /// is still proportional to the light that reached the sensor. Levels
    /// subtract an offset, and an offset destroys that proportionality at
    /// every level.
    ///
    /// `preservesProportionalityToSceneRadiance` reports the one case in which
    /// the claim would still have held — a black point of exactly `0` — but
    /// this flag stays `false` either way: a reader asking "is this
    /// scene-linear data?" of a stage that is licensed to subtract an offset
    /// should get one answer, not an answer that depends on the value.
    public let sceneLinear: Bool = false

    /// Nothing was clipped, clamped or compressed. A value these levels pushed
    /// below `0` or above `1` still has its magnitude — which is exactly what
    /// lets the destination's range policy own clipping, and what lets a later
    /// levels change bring the value back.
    public let clamped: Bool = false
    public let gammaApplied: Bool = false
    public let displayEncodingApplied: Bool = false
    public let quantized: Bool = false
    public let toneMappingApplied: Bool = false
    public let toneCurveApplied: Bool = false
    public let contrastApplied: Bool = false
    public let automaticLevelsApplied: Bool = false
    public let histogramRead: Bool = false
    public let highlightReconstructionApplied: Bool = false
    public let shadowRecoveryApplied: Bool = false
    public let saturationApplied: Bool = false
    public let sharpeningApplied: Bool = false

    /// The same two numbers were applied to all three components. There are no
    /// per-channel levels in this project.
    public let perChannelLevelsApplied: Bool = false

    /// Geometry is untouched by this stage: it subtracts and multiplies, it
    /// does not move, resample or resize anything.
    public let interpolated: Bool = false
    public let scaled: Bool = false
    public let cropped: Bool = false

    public init(
        levels: LinearLevels,
        exposureProcessing: SceneLinearExposureProcessing
    ) {
        self.levels = levels
        self.exposureProcessing = exposureProcessing
    }

    public var blackPoint: Double { levels.blackPoint }
    public var whitePoint: Double { levels.whitePoint }
    public var levelsScale: Double { levels.scale }

    /// Whether the levels that were applied happen to preserve proportionality
    /// to scene radiance — true exactly when the black point is `0`, which
    /// makes the map a pure gain.
    ///
    /// Derived from the levels rather than stored, so it cannot disagree with
    /// what was applied. It does **not** make `sceneLinear` true; see that
    /// property.
    public var preservesProportionalityToSceneRadiance: Bool {
        levels.preservesProportionalityToSceneRadiance
    }

    /// Whether the image this was produced from is a **reduced preview**
    /// rendition rather than the sensor's own resolution.
    public var reducedForPreview: Bool { exposureProcessing.reducedForPreview }
    /// What the reduction was, when there was one.
    public var previewResolution: PreviewResolution? {
        exposureProcessing.previewResolution
    }

    public var exposure: SceneLinearExposure { exposureProcessing.exposure }
    public var exposureEV: Double { exposureProcessing.exposureEV }
    public var exposureScale: Double { exposureProcessing.exposureScale }
    public var exposureApplied: Bool { exposureProcessing.exposureApplied }

    public var orientationProcessing: ImageOrientationProcessing {
        exposureProcessing.orientationProcessing
    }
    public var orientation: RAWImageOrientation { exposureProcessing.orientation }
    public var orientationApplied: Bool { exposureProcessing.orientationApplied }
    public var orientationSwappedDimensions: Bool {
        exposureProcessing.orientationSwappedDimensions
    }
    public var pixelValuesPreservedByOrientation: Bool {
        exposureProcessing.pixelValuesPreservedByOrientation
    }
    public var channelMixProcessing: IRChannelMixProcessing {
        exposureProcessing.channelMixProcessing
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

    /// A one-line summary for diagnostics.
    public var diagnosticDescription: String {
        "\(levels.diagnosticDescription); linear-light, not scene-linear"
    }
}

/// Linear-light working-space RGB with every canonical user adjustment
/// applied, and nothing else.
///
/// ```text
/// sRGB primaries, D65     unchanged since the working-space conversion
/// linear transfer         no transfer function has been applied
/// Float32, interleaved    R, G, B per pixel, row-major
/// channel mix             applied
/// orientation             applied, as whole-pixel permutation
/// exposure                applied, as × 2^EV
/// levels                  applied, as (x − black) × 1/(white − black)
/// display encoding        NOT applied
/// range policy            NOT applied — values outside 0…1 are ordinary here
/// ```
///
/// ## Why it is not called scene-linear
///
/// `ExposedSceneLinearRGBImage` is scene-linear because every stage above it
/// is either a permutation, a matrix on colour coordinates, or a gain — none
/// of which moves the origin. Levels move the origin. After subtracting a
/// black point, a value is still *linear* in the sense that matters for
/// encoding — nothing has been curved, compressed or gamma-ed, and the
/// destination's transfer function is still the next thing that will happen to
/// it — but it is no longer proportional to the light that reached the sensor.
///
/// Carrying that distinction in the type rather than in a comment is the point.
/// A function that requires scene-radiance proportionality — a future
/// measurement, a calibration fit, an exposure-invariant statistic — can now
/// refuse this image in its signature instead of trusting a caller to know.
///
/// ## The one type both destinations take
///
/// This is the end of the adjustment chain and the input to **both** encoders:
///
/// ```text
/// LeveledLinearRGBImage ─┬─ DisplayPreviewRenderer  → 8-bit sRGB, on screen
///                        └─ ExportImageEncoder      → 16-bit sRGB, in a file
/// ```
///
/// They differ in range policy, bit depth and destination, and in nothing
/// else. Every adjustment has already happened, identically, above this line.
/// For a full-resolution export it holds the sensor's own resolution; the same
/// type also holds a preview-sized rendition, and
/// `processing.reducedForPreview` says which — the export encoder refuses the
/// latter.
public struct LeveledLinearRGBImage: Equatable, Sendable {
    public static let channelCount = 3

    /// Width in pixels, **as viewed** — the orientation stage has already run.
    public let width: Int
    /// Height in pixels, as viewed.
    public let height: Int
    /// Interleaved RGB, row-major, `width × height × 3` values.
    public let values: [Float]
    /// What produced them, including the whole upstream chain by reference.
    public let processing: LinearLevelsProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: LinearLevelsProcessing
    ) {
        self.width = width
        self.height = height
        self.values = values
        self.processing = processing
    }

    public var blackPoint: Double { processing.blackPoint }
    public var whitePoint: Double { processing.whitePoint }
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

/// A levelled image paired with the whole exposed state it was produced from.
///
/// The last link in the `…ProcessedRAWImage` chain: the mosaics, the
/// camera-native image, the working-colour image, the mix, the orientation and
/// the exposure are all still reachable through `source`, so a caller can
/// change any adjustment and restart from exactly the right stage without
/// decoding again.
///
/// Use the bare-image overloads instead whenever the result is going to be
/// **retained**. Holding one of these alive at full resolution holds every
/// upstream buffer alive with it.
public struct LeveledProcessedRAWImage: Sendable {
    /// The exposed, un-levelled state this was produced from, unchanged.
    public let source: ExposedProcessedRAWImage
    /// The levelled image.
    public let image: LeveledLinearRGBImage

    /// Module-internal, deliberately: only `LinearLevelsApplier` pairs an
    /// exposed state with the levelled image it produced from it.
    init(source: ExposedProcessedRAWImage, image: LeveledLinearRGBImage) {
        self.source = source
        self.image = image
    }

    /// The exposed image these levels were applied to. Changing the levels
    /// must always start here.
    public var exposedImage: ExposedSceneLinearRGBImage { source.image }
    /// The oriented, un-exposed image. Changing the exposure starts here.
    public var orientedImage: OrientedSceneLinearRGBImage { source.orientedImage }
    /// The unoriented channel-mixed image. Changing the orientation starts
    /// here.
    public var channelMixedImage: IRChannelMixedRGBImage { source.channelMixedImage }
    /// The pre-mix working-colour image. Changing the creative mix starts
    /// here.
    public var workingColorImage: WorkingColorRGBImage { source.workingColorImage }
    /// The linear camera-native RGB image.
    public var demosaicedImage: DemosaicedRAWRGBImage { source.demosaicedImage }
    /// The white-balanced mosaic.
    public var whiteBalancedMosaic: WhiteBalancedRAWMosaic { source.whiteBalancedMosaic }
    /// The normalised, pre-white-balance mosaic.
    public var linearMosaic: LinearRAWMosaic { source.linearMosaic }
    /// Provenance for `image`. Forwarded rather than stored a second time.
    public var processing: LinearLevelsProcessing { image.processing }
    /// The levels that produced `image`.
    public var levels: LinearLevels { image.processing.levels }
    /// The exposure applied upstream.
    public var exposure: SceneLinearExposure { source.exposure }
    /// The orientation applied further upstream.
    public var orientation: RAWImageOrientation { source.orientation }
    /// The creative mix applied further upstream still.
    public var mix: IRChannelMix { source.mix }
    /// The camera-to-working transform the working image was produced by.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        source.cameraToWorkingTransform
    }
    /// The RAW-state metadata the chain was processed against. This stage
    /// reads none of it.
    public var metadata: RAWMetadata { source.metadata }
    public var url: URL { source.url }
}
