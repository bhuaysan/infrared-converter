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
