import Foundation

/// What the global contrast stage did, and what it deliberately did not do.
///
/// Follows the chain: it carries the levels stage's record, which carries the
/// exposure stage's, which carries the orientation stage's, and so on back to
/// the mosaic. Reading a tone-curved image tells you the whole history of the
/// pixels.
public struct GlobalContrastProcessing: Equatable, Sendable {
    /// The curve that was applied, as the shared primitive.
    public let curve: GlobalContrastCurve
    /// The stage this image was produced from.
    public let levelsProcessing: LinearLevelsProcessing

    /// A global contrast curve was applied, per RGB component, after levels.
    ///
    /// `true` even at amount `0`: traversing the stage and asking for the
    /// identity is a different fact from never applying a curve at all, and
    /// this project does not describe a stage it ran as one it skipped. The
    /// pixels may be bit-identical to the input in that case, and provenance
    /// still records that the stage was traversed.
    public let contrastApplied: Bool = true

    /// The same fact under the more general name. A contrast amount is applied
    /// *as* a tone curve here; there is no second, separate curve stage, and
    /// no arbitrary-control-point curve exists in this project at all.
    public let toneCurveApplied: Bool = true

    /// The values are **no longer linear-light encoded**.
    ///
    /// This is the flag that stops being `true` here, and it is the whole
    /// reason this type exists rather than another `LeveledLinearRGBImage`.
    /// Every stage above this one is a permutation, a matrix on colour
    /// coordinates, a gain or an affine remap — none of which bends the
    /// relationship between neighbouring values. A tone curve does. After it,
    /// "no transfer function has been applied, nothing has been compressed"
    /// is simply false.
    ///
    /// `preservesLinearLightEncoding` reports the one case in which the claim
    /// would still have held — an amount of exactly `0` — but this flag stays
    /// `false` either way, for the reason `LeveledLinearRGBImage.sceneLinear`
    /// stays `false` at neutral levels: a reader asking "has a curve been
    /// evaluated on this data?" of a stage that is licensed to evaluate one
    /// should get one answer, not an answer that depends on the value.
    public let linearLightEncoded: Bool = false

    /// They are not scene-linear either, and have not been since the levels
    /// stage subtracted an offset.
    public let sceneLinear: Bool = false

    /// Nothing was clipped, clamped or compressed. A value outside `0…1`
    /// reached this stage with its magnitude intact and left with it intact —
    /// which is what lets the destination's range policy own clipping, and
    /// count what it destroyed.
    public let clamped: Bool = false

    /// Nothing about this curve was derived from the image.
    ///
    /// No histogram was built or read, no statistic was computed, and no
    /// amount was chosen by the application. If a value here changed the
    /// rendering, a person chose it.
    public let histogramRead: Bool = false
    public let automaticContrastApplied: Bool = false
    public let automaticLevelsApplied: Bool = false

    /// Every component was evaluated from its own value and from nothing
    /// else. No neighbourhood, kernel or region was read, so this is not
    /// clarity, texture, dehaze or any other local-contrast operation.
    public let localContrastApplied: Bool = false

    /// The same curve was applied to all three components. There are no
    /// per-channel curves in this project, and the stage has no way to be told
    /// otherwise.
    public let perChannelCurveApplied: Bool = false

    /// A tone *curve* is not tone *mapping*: nothing here maps a high-dynamic
    /// range onto a display range, rolls off a highlight or models a film.
    public let toneMappingApplied: Bool = false

    public let gammaApplied: Bool = false
    public let displayEncodingApplied: Bool = false
    public let quantized: Bool = false
    public let highlightReconstructionApplied: Bool = false
    public let shadowRecoveryApplied: Bool = false
    public let saturationApplied: Bool = false
    public let sharpeningApplied: Bool = false

    /// Geometry is untouched by this stage: it evaluates a function of one
    /// value, it does not move, resample or resize anything.
    public let interpolated: Bool = false
    public let scaled: Bool = false
    public let cropped: Bool = false

    public init(
        curve: GlobalContrastCurve,
        levelsProcessing: LinearLevelsProcessing
    ) {
        self.curve = curve
        self.levelsProcessing = levelsProcessing
    }

    /// The normalised amount that was applied.
    public var contrastAmount: Double { curve.amount }
    /// The exponent it produced, `2^amount` — the part that means something
    /// arithmetically.
    public var contrastExponent: Double { curve.exponent }

    /// Whether the curve that was applied happens to leave the values
    /// linear-light encoded — true exactly when the amount is `0`, which makes
    /// the curve the identity.
    ///
    /// Derived from the curve rather than stored, so it cannot disagree with
    /// what was applied. It does **not** make `linearLightEncoded` true; see
    /// that property.
    public var preservesLinearLightEncoding: Bool { curve.isIdentity }

    /// Whether the image this was produced from is a **reduced preview**
    /// rendition rather than the sensor's own resolution.
    public var reducedForPreview: Bool { levelsProcessing.reducedForPreview }
    /// What the reduction was, when there was one.
    public var previewResolution: PreviewResolution? {
        levelsProcessing.previewResolution
    }

    public var levels: LinearLevels { levelsProcessing.levels }
    public var levelsApplied: Bool { levelsProcessing.levelsApplied }
    public var blackPoint: Double { levelsProcessing.blackPoint }
    public var whitePoint: Double { levelsProcessing.whitePoint }
    public var preservesProportionalityToSceneRadiance: Bool {
        levelsProcessing.preservesProportionalityToSceneRadiance
    }
    public var perChannelLevelsApplied: Bool {
        levelsProcessing.perChannelLevelsApplied
    }

    public var exposureProcessing: SceneLinearExposureProcessing {
        levelsProcessing.exposureProcessing
    }
    public var exposure: SceneLinearExposure { levelsProcessing.exposure }
    public var exposureEV: Double { levelsProcessing.exposureEV }
    public var exposureScale: Double { levelsProcessing.exposureScale }
    public var exposureApplied: Bool { levelsProcessing.exposureApplied }

    public var orientationProcessing: ImageOrientationProcessing {
        levelsProcessing.orientationProcessing
    }
    public var orientation: RAWImageOrientation { levelsProcessing.orientation }
    public var orientationApplied: Bool { levelsProcessing.orientationApplied }
    public var orientationSwappedDimensions: Bool {
        levelsProcessing.orientationSwappedDimensions
    }
    public var pixelValuesPreservedByOrientation: Bool {
        levelsProcessing.pixelValuesPreservedByOrientation
    }
    public var channelMixProcessing: IRChannelMixProcessing {
        levelsProcessing.channelMixProcessing
    }
    public var mix: IRChannelMix { levelsProcessing.mix }
    public var mixSource: IRChannelMixSource { levelsProcessing.mixSource }
    public var channelMixApplied: Bool { levelsProcessing.channelMixApplied }
    public var workingColorSpace: RAWWorkingColorSpace {
        levelsProcessing.workingColorSpace
    }
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        levelsProcessing.cameraToWorkingTransform
    }
    public var cameraToWorkingTransformSource: RAWCameraToWorkingColorTransformSource {
        levelsProcessing.cameraToWorkingTransformSource
    }
    public var isValidatedInfraredCalibration: Bool {
        levelsProcessing.isValidatedInfraredCalibration
    }
    public var demosaiced: Bool { levelsProcessing.demosaiced }
    public var demosaicAlgorithm: RAWDemosaicAlgorithm {
        levelsProcessing.demosaicAlgorithm
    }
    public var whiteBalanceApplied: Bool { levelsProcessing.whiteBalanceApplied }
    public var whiteBalanceGains: RAWWhiteBalanceGains {
        levelsProcessing.whiteBalanceGains
    }
    public var blackLevelSubtracted: Bool { levelsProcessing.blackLevelSubtracted }
    public var normalized: Bool { levelsProcessing.normalized }

    /// A one-line summary for diagnostics.
    public var diagnosticDescription: String {
        "\(curve.diagnosticDescription); no longer linear-light encoded"
    }
}

/// Working-space RGB with every canonical user adjustment applied, the last of
/// them a nonlinear tone curve, and nothing else.
///
/// ```text
/// sRGB primaries, D65     unchanged since the working-space conversion
/// transfer function       NOT applied — this is not display-encoded
/// linear light            NO LONGER — a tone curve has been evaluated
/// Float32, interleaved    R, G, B per pixel, row-major
/// channel mix             applied
/// orientation             applied, as whole-pixel permutation
/// exposure                applied, as × 2^EV
/// levels                  applied, as (x − black) × 1/(white − black)
/// contrast                applied, as x^k / (x^k + (1−x)^k)
/// range policy            NOT applied — values outside 0…1 are ordinary here
/// quantisation            NOT applied
/// ```
///
/// ## Why it is not called linear anything
///
/// `LeveledLinearRGBImage` could still say "linear-light encoded": the levels
/// stage moved the origin, which cost it the *scene*-linear claim, but nothing
/// upstream of it had bent the scale. This stage bends the scale. Naming the
/// result `SceneLinear…` or `LinearLight…` would be precisely the kind of
/// plausible-looking label this project refuses — a reader would take it as a
/// licence to do linear arithmetic on values that no longer support it.
///
/// What it still *is* remains worth stating, because the list is short and
/// every item matters to the encoder that comes next: working-space RGB
/// coordinates, in the same primaries and white point, unclamped, floating
/// point, not yet transfer-encoded and not yet quantised.
///
/// ## The one type both destinations take
///
/// This is the end of the adjustment chain and the input to **both** encoders:
///
/// ```text
/// ToneCurvedRGBImage ─┬─ DisplayPreviewRenderer  → 8-bit sRGB, on screen
///                     └─ ExportImageEncoder      → 16-bit sRGB, in a file
/// ```
///
/// They differ in range policy, bit depth and destination, and in nothing
/// else. Every adjustment has already happened, identically, above this line.
/// For a full-resolution export it holds the sensor's own resolution; the same
/// type also holds a preview-sized rendition, and
/// `processing.reducedForPreview` says which — the export encoder refuses the
/// latter.
public struct ToneCurvedRGBImage: Equatable, Sendable {
    public static let channelCount = 3

    /// Width in pixels, **as viewed** — the orientation stage has already run.
    public let width: Int
    /// Height in pixels, as viewed.
    public let height: Int
    /// Interleaved RGB, row-major, `width × height × 3` values.
    public let values: [Float]
    /// What produced them, including the whole upstream chain by reference.
    public let processing: GlobalContrastProcessing

    public init(
        width: Int,
        height: Int,
        values: [Float],
        processing: GlobalContrastProcessing
    ) {
        self.width = width
        self.height = height
        self.values = values
        self.processing = processing
    }

    public var contrastAmount: Double { processing.contrastAmount }
    public var contrastExponent: Double { processing.contrastExponent }
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

/// A tone-curved image paired with the whole levelled state it was produced
/// from.
///
/// The last link in the `…ProcessedRAWImage` chain: the mosaics, the
/// camera-native image, the working-colour image, the mix, the orientation,
/// the exposure and the levels are all still reachable through `source`, so a
/// caller can change any adjustment and restart from exactly the right stage
/// without decoding again.
///
/// Use the bare-image overloads instead whenever the result is going to be
/// **retained**. Holding one of these alive at full resolution holds every
/// upstream buffer alive with it.
public struct ToneCurvedProcessedRAWImage: Sendable {
    /// The levelled, un-curved state this was produced from, unchanged.
    public let source: LeveledProcessedRAWImage
    /// The tone-curved image.
    public let image: ToneCurvedRGBImage

    /// Module-internal, deliberately: only `GlobalContrastApplier` pairs a
    /// levelled state with the curved image it produced from it.
    init(source: LeveledProcessedRAWImage, image: ToneCurvedRGBImage) {
        self.source = source
        self.image = image
    }

    /// The levelled image this curve was applied to. Changing the contrast
    /// must always start here.
    public var leveledImage: LeveledLinearRGBImage { source.image }
    /// The exposed, un-levelled image. Changing the levels starts here.
    public var exposedImage: ExposedSceneLinearRGBImage { source.exposedImage }
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
    public var processing: GlobalContrastProcessing { image.processing }
    /// The curve that produced `image`.
    public var curve: GlobalContrastCurve { image.processing.curve }
    /// The levels applied upstream.
    public var levels: LinearLevels { source.levels }
    /// The exposure applied further upstream.
    public var exposure: SceneLinearExposure { source.exposure }
    /// The orientation applied further upstream still.
    public var orientation: RAWImageOrientation { source.orientation }
    /// The creative mix applied above that.
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
