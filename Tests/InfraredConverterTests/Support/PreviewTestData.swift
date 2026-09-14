import Foundation
@testable import InfraredConverter

/// Fixtures for the preview-reduction stage: a working-colour image built from
/// bare values, and the provenance record that belongs with it.
///
/// Deliberately separate from `IRChannelMixerTests`'s private helpers, so the
/// reduction suites do not depend on another suite's internals.
enum PreviewTestData {

    static func workingColorProcessing(
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor
    ) -> RAWWorkingColorProcessing {
        RAWWorkingColorProcessing(
            transform: transform,
            demosaicProcessing: RAWDemosaicProcessing(
                algorithm: .bilinearBayer,
                sourcePattern: RAWBayerCellPattern(
                    topLeft: .red, topRight: .green, bottomLeft: .green, bottomRight: .blue
                ),
                whiteBalanceProcessing: RAWWhiteBalanceProcessing(
                    gains: RAWWhiteBalanceGains(plane0: 2, plane1: 1, plane2: 3, plane3: 1),
                    gainSource: .explicit,
                    linearProcessing: RAWLinearProcessing(
                        whiteLevelPolicy: .metadataMaximum, whiteLevel: 4095
                    )
                )
            )
        )
    }

    /// A working-colour image from interleaved `R G B` values.
    static func working(
        width: Int,
        height: Int,
        values: [Float],
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor
    ) -> WorkingColorRGBImage {
        WorkingColorRGBImage(
            width: width,
            height: height,
            values: values,
            processing: workingColorProcessing(transform: transform)
        )
    }

    /// A working-colour image whose samples are generated per pixel and
    /// channel, so a test can describe a field rather than type one out.
    static func working(
        width: Int,
        height: Int,
        sample: (_ row: Int, _ column: Int, _ channel: Int) -> Float
    ) -> WorkingColorRGBImage {
        var values: [Float] = []
        values.reserveCapacity(width * height * 3)
        for row in 0..<height {
            for column in 0..<width {
                for channel in 0..<3 {
                    values.append(sample(row, column, channel))
                }
            }
        }
        return working(width: width, height: height, values: values)
    }

    /// A reduced scene-linear preview from interleaved `R G B` values.
    ///
    /// It is the **pre-mix** type, which is what a `WorkspacePreviewPipeline`
    /// source holds. `method` says the values were not resampled, which is
    /// true: a test builds them directly.
    static func preview(
        width: Int,
        height: Int,
        values: [Float],
        policy: PreviewResolutionPolicy = PreviewResolutionPolicy(maximumLongestEdge: 2048)
    ) -> SceneLinearPreviewImage {
        SceneLinearPreviewImage(
            width: width,
            height: height,
            values: values,
            processing: SceneLinearPreviewProcessing(
                resolution: PreviewResolution(
                    sourceWidth: width,
                    sourceHeight: height,
                    width: width,
                    height: height,
                    policy: policy,
                    method: .unreduced
                ),
                workingColorProcessing: workingColorProcessing()
            )
        )
    }

    /// A reduced preview whose samples are generated per pixel and channel.
    static func preview(
        width: Int,
        height: Int,
        sample: (_ row: Int, _ column: Int, _ channel: Int) -> Float
    ) -> SceneLinearPreviewImage {
        var values: [Float] = []
        values.reserveCapacity(width * height * 3)
        for row in 0..<height {
            for column in 0..<width {
                for channel in 0..<3 {
                    values.append(sample(row, column, channel))
                }
            }
        }
        return preview(width: width, height: height, values: values)
    }

    /// A white-balance estimate with plausible, self-consistent contents, for
    /// a source that is built by hand rather than processed.
    ///
    /// Both initialisers it uses are module-internal, which is the point of
    /// them: only `RAWWhiteBalanceEstimator` mints an estimate in production,
    /// and a test reaching them through `@testable` is doing so deliberately.
    /// The numbers agree with each other — every gain is `targetMean` over its
    /// own plane's mean — so a reader of a fixture is not shown a measurement
    /// that could not have happened.
    static func whiteBalanceEstimate(
        region: RAWActiveAreaRegion = RAWActiveAreaRegion(
            originRow: 0, originColumn: 0, width: 2, height: 2
        )
    ) -> RAWWhiteBalanceEstimate {
        let target = 0.5
        let means = [0.25, 0.5, 0.125, 0.5]
        func plane(_ index: Int) -> RAWColorPlaneStatistics {
            RAWColorPlaneStatistics(sampleCount: 1, mean: means[index])
        }
        return RAWWhiteBalanceEstimate(
            gains: RAWWhiteBalanceGains(
                plane0: Float(target / means[0]),
                plane1: Float(target / means[1]),
                plane2: Float(target / means[2]),
                plane3: Float(target / means[3])
            ),
            provenance: RAWNeutralPatchWhiteBalanceSource(
                region: region,
                scalePolicy: .preserveStrongestMeasuredPlane,
                statistics: RAWNeutralPatchStatistics(
                    plane0: plane(0), plane1: plane(1), plane2: plane(2), plane3: plane(3)
                ),
                targetMean: target
            )
        )
    }

    /// A prepared workspace source wrapping a synthetic pre-mix preview, so a
    /// test can exercise `render` without decoding anything.
    ///
    /// The metadata records `flip` 0, so the file's own orientation is upright
    /// and the effective orientation is whatever the user asked for.
    static func source(
        _ preview: SceneLinearPreviewImage,
        url: URL = URL(fileURLWithPath: "/tmp/synthetic-preview.orf"),
        whiteBalance: UserWhiteBalanceAdjustment = .defaultNeutralPatch
    ) -> WorkspacePreviewPipeline.Source {
        var metadata = RAWTestData.metadata()
        metadata.geometry.flip = 0
        return WorkspacePreviewPipeline.Source(
            preview: preview,
            metadata: metadata,
            url: url,
            captureProfile: .builtinUncalibrated,
            whiteBalance: whiteBalance,
            estimate: whiteBalanceEstimate()
        )
    }

    /// A deliberately non-symmetric matrix with exact binary-fraction
    /// coefficients, so that arithmetic on it is exactly representable.
    static func asymmetricMatrix() throws -> RAWColorMatrix3x3 {
        try RAWColorMatrix3x3(
            m00: 1.5, m01: -0.25, m02: 0.75,
            m10: 0.5, m11: 2.0, m12: -1.25,
            m20: -0.125, m21: 0.375, m22: 3.0
        )
    }
}
