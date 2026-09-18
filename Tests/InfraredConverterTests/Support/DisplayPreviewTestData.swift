import Foundation
@testable import InfraredConverter

/// Builders and an independent reference implementation for the display
/// rendering suites.
///
/// The reference arithmetic here is written from the specification — the sRGB
/// standard's two-branch encoding, and `round(x × 255)` — and never by calling
/// the production code. Tests that compared the renderer against itself would
/// pass whatever it did.
enum DisplayPreviewTestData {

    // MARK: - Building input

    /// Provenance for a channel-mixed image, with an upstream chain rich
    /// enough that a stage which overwrote it would be visible.
    static func channelMixProcessing(
        mix: IRChannelMix = .identity,
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor,
        gains: RAWWhiteBalanceGains = RAWWhiteBalanceGains(
            plane0: 2, plane1: 1, plane2: 3, plane3: 1
        ),
        whiteLevel: UInt32 = 4095
    ) -> IRChannelMixProcessing {
        IRChannelMixProcessing(
            mix: mix,
            workingColorProcessing: RAWWorkingColorProcessing(
                transform: transform,
                demosaicProcessing: RAWDemosaicProcessing(
                    algorithm: .bilinearBayer,
                    sourcePattern: RAWBayerCellPattern(
                        topLeft: .red, topRight: .green, bottomLeft: .green, bottomRight: .blue
                    ),
                    whiteBalanceProcessing: RAWWhiteBalanceProcessing(
                        gains: gains,
                        gainSource: .explicit,
                        linearProcessing: RAWLinearProcessing(
                            whiteLevelPolicy: .metadataMaximum, whiteLevel: whiteLevel
                        )
                    )
                )
            )
        )
    }

    /// Provenance for an oriented image: the orientation the geometry stage
    /// applied, over a channel-mix history rich enough that a stage which
    /// overwrote it would be visible.
    static func orientationProcessing(
        orientation: RAWImageOrientation = .upright,
        mix: IRChannelMix = .identity,
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor,
        gains: RAWWhiteBalanceGains = RAWWhiteBalanceGains(
            plane0: 2, plane1: 1, plane2: 3, plane3: 1
        ),
        whiteLevel: UInt32 = 4095
    ) -> ImageOrientationProcessing {
        ImageOrientationProcessing(
            orientation: orientation,
            channelMixProcessing: channelMixProcessing(
                mix: mix, transform: transform, gains: gains, whiteLevel: whiteLevel
            )
        )
    }

    /// A channel-mixed image from interleaved `R G B` values: the orientation
    /// stage's input, and the display stage's input one stage further back.
    static func channelMixedImage(
        width: Int,
        height: Int,
        values: [Float],
        processing: IRChannelMixProcessing? = nil
    ) -> IRChannelMixedRGBImage {
        IRChannelMixedRGBImage(
            width: width,
            height: height,
            values: values,
            processing: processing ?? channelMixProcessing()
        )
    }

    /// An oriented scene-linear image from interleaved `R G B` values: what
    /// the display renderer actually consumes.
    static func image(
        width: Int,
        height: Int,
        values: [Float],
        processing: ImageOrientationProcessing? = nil
    ) -> OrientedSceneLinearRGBImage {
        OrientedSceneLinearRGBImage(
            width: width,
            height: height,
            values: values,
            processing: processing ?? orientationProcessing()
        )
    }

    /// One pixel, for hand-computable arithmetic.
    static func pixel(
        _ red: Float, _ green: Float, _ blue: Float
    ) -> OrientedSceneLinearRGBImage {
        image(width: 1, height: 1, values: [red, green, blue])
    }

    /// Provenance for an exposed image, over an orientation history rich
    /// enough that a stage which overwrote it would be visible.
    static func exposureProcessing(
        exposureEV: Double = 0,
        orientation: RAWImageOrientation = .upright,
        mix: IRChannelMix = .identity,
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor,
        gains: RAWWhiteBalanceGains = RAWWhiteBalanceGains(
            plane0: 2, plane1: 1, plane2: 3, plane3: 1
        ),
        whiteLevel: UInt32 = 4095
    ) -> SceneLinearExposureProcessing {
        SceneLinearExposureProcessing(
            exposure: SceneLinearExposure(ev: exposureEV),
            orientationProcessing: orientationProcessing(
                orientation: orientation, mix: mix, transform: transform,
                gains: gains, whiteLevel: whiteLevel
            )
        )
    }

    /// Provenance for a levelled image — what the display renderer now
    /// consumes — over the whole upstream chain.
    static func levelsProcessing(
        blackPoint: Double = 0,
        whitePoint: Double = 1,
        exposureEV: Double = 0,
        orientation: RAWImageOrientation = .upright,
        mix: IRChannelMix = .identity,
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor,
        gains: RAWWhiteBalanceGains = RAWWhiteBalanceGains(
            plane0: 2, plane1: 1, plane2: 3, plane3: 1
        ),
        whiteLevel: UInt32 = 4095
    ) -> LinearLevelsProcessing {
        LinearLevelsProcessing(
            levels: LinearLevels(blackPoint: blackPoint, whitePoint: whitePoint),
            exposureProcessing: exposureProcessing(
                exposureEV: exposureEV, orientation: orientation, mix: mix,
                transform: transform, gains: gains, whiteLevel: whiteLevel
            )
        )
    }

    /// An exposed scene-linear image from interleaved `R G B` values: the
    /// levels stage's input.
    static func exposedImage(
        width: Int,
        height: Int,
        values: [Float],
        processing: SceneLinearExposureProcessing? = nil
    ) -> ExposedSceneLinearRGBImage {
        ExposedSceneLinearRGBImage(
            width: width,
            height: height,
            values: values,
            processing: processing ?? exposureProcessing()
        )
    }

    /// A levelled linear-light image from interleaved `R G B` values: what the
    /// display renderer actually consumes.
    static func leveledImage(
        width: Int,
        height: Int,
        values: [Float],
        processing: LinearLevelsProcessing? = nil
    ) -> LeveledLinearRGBImage {
        LeveledLinearRGBImage(
            width: width,
            height: height,
            values: values,
            processing: processing ?? levelsProcessing()
        )
    }

    /// One levelled pixel, for hand-computable arithmetic.
    static func leveledPixel(
        _ red: Float, _ green: Float, _ blue: Float
    ) -> LeveledLinearRGBImage {
        leveledImage(width: 1, height: 1, values: [red, green, blue])
    }

    /// Provenance for a tone-curved image — what the display renderer now
    /// consumes — over the whole upstream chain.
    static func contrastProcessing(
        contrastAmount: Double = 0,
        blackPoint: Double = 0,
        whitePoint: Double = 1,
        exposureEV: Double = 0,
        orientation: RAWImageOrientation = .upright,
        mix: IRChannelMix = .identity,
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor,
        gains: RAWWhiteBalanceGains = RAWWhiteBalanceGains(
            plane0: 2, plane1: 1, plane2: 3, plane3: 1
        ),
        whiteLevel: UInt32 = 4095
    ) -> GlobalContrastProcessing {
        GlobalContrastProcessing(
            curve: GlobalContrastCurve(amount: contrastAmount),
            levelsProcessing: levelsProcessing(
                blackPoint: blackPoint, whitePoint: whitePoint,
                exposureEV: exposureEV, orientation: orientation, mix: mix,
                transform: transform, gains: gains, whiteLevel: whiteLevel
            )
        )
    }

    /// A tone-curved image from interleaved `R G B` values: what the display
    /// renderer actually consumes.
    static func toneCurvedImage(
        width: Int,
        height: Int,
        values: [Float],
        processing: GlobalContrastProcessing? = nil
    ) -> ToneCurvedRGBImage {
        ToneCurvedRGBImage(
            width: width,
            height: height,
            values: values,
            processing: processing ?? contrastProcessing()
        )
    }

    /// One tone-curved pixel, for hand-computable arithmetic.
    static func toneCurvedPixel(
        _ red: Float, _ green: Float, _ blue: Float
    ) -> ToneCurvedRGBImage {
        toneCurvedImage(width: 1, height: 1, values: [red, green, blue])
    }

    /// The two adjustment stages the display renderer no longer performs, run
    /// by the **production** stages.
    ///
    /// It exists so that a suite whose subject is clipping, encoding and
    /// quantisation can still be written in terms of a scene-linear input and
    /// an exposure, and so that what it feeds the renderer is what the
    /// workspace would feed it — not a hand-assembled buffer that happens to
    /// look similar. Nothing here reimplements exposure, levels or the curve.
    static func develop(
        _ image: OrientedSceneLinearRGBImage,
        exposureEV: Double = 0,
        blackPoint: Double = 0,
        whitePoint: Double = 1,
        contrastAmount: Double = 0,
        cancellation: ProcessingCancellation = .none
    ) throws -> ToneCurvedRGBImage {
        try GlobalContrastApplier().apply(
            to: LinearLevelsApplier().apply(
                to: SceneLinearExposer().apply(
                    to: image,
                    exposure: SceneLinearExposure(ev: exposureEV),
                    cancellation: cancellation
                ),
                levels: LinearLevels(blackPoint: blackPoint, whitePoint: whitePoint),
                cancellation: cancellation
            ),
            curve: GlobalContrastCurve(amount: contrastAmount),
            cancellation: cancellation
        )
    }

    /// The same, from raw component values.
    static func developedPixel(
        _ red: Float, _ green: Float, _ blue: Float,
        exposureEV: Double = 0,
        blackPoint: Double = 0,
        whitePoint: Double = 1,
        contrastAmount: Double = 0
    ) throws -> ToneCurvedRGBImage {
        try develop(
            pixel(red, green, blue),
            exposureEV: exposureEV, blackPoint: blackPoint, whitePoint: whitePoint,
            contrastAmount: contrastAmount
        )
    }

    /// The destination settings, with everything spelled out. There is no
    /// default in the production API; this is the test suites' one copy of the
    /// application's choice.
    static let settings = DisplayRenderSettings(
        rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
    )

    /// The interactive render chain's last four stages, run in order by the
    /// **production** types: exposure, levels, contrast, then display
    /// encoding.
    ///
    /// The display renderer no longer applies exposure — `SceneLinearExposer`,
    /// `LinearLevelsApplier` and `GlobalContrastApplier` are stages of their
    /// own, between the orientation and the encoder — so a suite whose subject
    /// is clipping, encoding or quantisation needs all four to get from a
    /// scene-linear input to a preview. This composes them exactly as
    /// `WorkspacePreviewPipeline.render` does, and reimplements none of them.
    static func renderPreview(
        _ image: OrientedSceneLinearRGBImage,
        exposureEV: Double = 0,
        blackPoint: Double = 0,
        whitePoint: Double = 1,
        contrastAmount: Double = 0,
        cancellation: ProcessingCancellation = .none
    ) throws -> DisplayEncodedPreviewImage {
        try DisplayPreviewRenderer().render(
            develop(
                image,
                exposureEV: exposureEV,
                blackPoint: blackPoint,
                whitePoint: whitePoint,
                contrastAmount: contrastAmount,
                cancellation: cancellation
            ),
            settings: settings,
            cancellation: cancellation
        )
    }

    // MARK: - The reference implementation

    /// The sRGB opto-electronic transfer function, written from the standard.
    ///
    /// ```text
    /// if x <= 0.0031308:  12.92 × x
    /// else:               1.055 × x^(1 / 2.4) − 0.055
    /// ```
    ///
    /// Deliberately **not** `pow(x, 1 / 2.2)`: that is a different curve, and
    /// a gamma-2.2 oracle would agree with a gamma-2.2 bug.
    static func referenceEncode(_ displayLinear: Double) -> Double {
        displayLinear <= 0.003_130_8
            ? 12.92 * displayLinear
            : 1.055 * pow(displayLinear, 1.0 / 2.4) - 0.055
    }

    /// Round-to-nearest quantisation to eight bits, written from the policy.
    static func referenceQuantize(_ encoded: Double) -> UInt8 {
        UInt8((encoded * 255).rounded())
    }

    /// The whole per-component pipeline, from scene-linear coordinate to
    /// 8-bit sample, computed independently of the renderer.
    ///
    /// Exposure, then levels, then the clip, then the transfer function, then
    /// quantisation — written from the specification in that order, because
    /// the order is part of what is being checked.
    ///
    /// The narrowing is deliberate and matches the production convention: each
    /// stage narrows to `Float32` exactly once, so this oracle reproduces the
    /// rounding the pipeline actually performs rather than an idealised
    /// `Double` result the pipeline never computes.
    static func referenceSample(
        sceneLinear: Float,
        exposureEV: Double,
        blackPoint: Double = 0,
        whitePoint: Double = 1
    ) -> UInt8 {
        let exposed = Float(Double(sceneLinear) * exp2(exposureEV))
        let leveled = Float((Double(exposed) - blackPoint) * (1 / (whitePoint - blackPoint)))
        let clipped = min(max(Double(leveled), 0), 1)
        return referenceQuantize(referenceEncode(clipped))
    }
}
