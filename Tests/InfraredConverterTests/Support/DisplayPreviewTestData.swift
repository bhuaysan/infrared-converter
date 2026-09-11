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

    /// Settings with everything spelled out. There is no default in the
    /// production API and none is invented here either — the exposure is
    /// always passed.
    static func settings(exposureEV: Double) -> DisplayRenderSettings {
        DisplayRenderSettings(
            exposureEV: exposureEV,
            rangePolicy: .hardClipToDisplayRange,
            encoding: .sRGB
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
    static func referenceSample(sceneLinear: Float, exposureEV: Double) -> UInt8 {
        let exposed = Double(sceneLinear) * exp2(exposureEV)
        let clipped = min(max(exposed, 0), 1)
        return referenceQuantize(referenceEncode(clipped))
    }
}
