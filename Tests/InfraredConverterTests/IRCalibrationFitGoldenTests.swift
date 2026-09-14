import Testing
import Foundation
@testable import InfraredConverter

/// A frozen fit: fixed evidence, fixed reference values, fixed coefficients.
///
/// ## What this guards
///
/// `IRCalibrationFitMethod.current` names an algorithm *and a version*
/// (`least-squares-3x3@v1`), and every stored calibration carries it. A
/// calibration constructed from a file re-derives its transform through that
/// method and refuses it unless the stored numbers agree, so the method
/// version is the project's promise that a given algorithm applied to given
/// evidence produces given coefficients — for as long as it keeps that name.
///
/// Nothing in the other suites holds that promise. They assert *properties*:
/// that an exact fit recovers the matrix it was synthesised from, that
/// residuals are small, that degenerate data is refused. Every one of those
/// would survive a change to the green collapse, to the gain normalisation, or
/// to the elimination order — and a build that changed one of those without
/// bumping the method version would silently refuse every calibration anybody
/// had already stored.
///
/// So this pins the numbers. It is expected to fail if the arithmetic changes,
/// and the correct response to it failing is to decide deliberately: either
/// the change was a defect, or `IRCalibrationFitMethod` needs a new version
/// and the artefacts written under the old one need re-fitting.
///
/// The evidence below is synthetic and is not a measurement of any camera.
@Suite("IR calibration fit golden values")
struct IRCalibrationFitGoldenTests {

    /// Six patches, written out rather than generated, so the inputs are
    /// visible in the same file as the outputs. Plane means are
    /// `(plane 0 red, plane 1 green, plane 2 blue, plane 3 green)`.
    static let planeMeans: [(Double, Double, Double, Double)] = [
        (0.500, 0.520, 0.480, 0.540),
        (0.310, 0.180, 0.090, 0.200),
        (0.120, 0.260, 0.410, 0.240),
        (0.440, 0.390, 0.150, 0.370),
        (0.190, 0.330, 0.280, 0.350),
        (0.260, 0.150, 0.360, 0.170),
    ]

    /// Reference values written out as constants, not synthesised by applying
    /// a matrix through the fitter's own arithmetic. A reference derived
    /// through `cameraRGB` would move whenever `cameraRGB` moved, and the
    /// golden would follow it instead of catching it.
    static let referenceRGB: [(Double, Double, Double)] = [
        (0.900, 0.910, 0.890),
        (0.430, 0.190, 0.070),
        (0.110, 0.330, 0.620),
        (0.610, 0.480, 0.120),
        (0.180, 0.420, 0.330),
        (0.300, 0.140, 0.480),
    ]

    /// Patch `01` is the session's neutral reference, so the gains are pinned
    /// too: the golden covers the white balance, the green collapse and the
    /// solver together, which is what a stored calibration's verification
    /// re-runs.
    static func measurements() throws -> IRCalibrationMeasurementSet {
        var patches: [IRCalibrationPatchMeasurement] = []
        for (index, means) in planeMeans.enumerated() {
            patches.append(
                try IRCalibrationPatchMeasurement(
                    patch: CalibrationTestData.patch(index + 1),
                    region: RAWActiveAreaRegion(
                        originRow: 0, originColumn: 0, width: 20, height: 20
                    ),
                    planes: [
                        try IRCalibrationPlaneMeasurement(
                            colorPlane: 0, channel: .red, sampleCount: 100,
                            mean: means.0, clippedSampleCount: 0
                        ),
                        try IRCalibrationPlaneMeasurement(
                            colorPlane: 1, channel: .green, sampleCount: 100,
                            mean: means.1, clippedSampleCount: 0
                        ),
                        try IRCalibrationPlaneMeasurement(
                            colorPlane: 2, channel: .blue, sampleCount: 100,
                            mean: means.2, clippedSampleCount: 0
                        ),
                        try IRCalibrationPlaneMeasurement(
                            colorPlane: 3, channel: .green, sampleCount: 100,
                            mean: means.3, clippedSampleCount: 0
                        ),
                    ]
                )
            )
        }

        return try IRCalibrationMeasurementSet(
            id: CalibrationTestData.measurementID(),
            measuredAt: CalibrationTestData.measuredAt,
            target: .colorCheckerClassic24,
            illuminant: .d65,
            captureContext: CalibrationTestData.context(),
            colorPlaneSignature: CalibrationTestData.bayerSignature,
            normalization: CalibrationTestData.normalization(),
            whiteBalancePolicy: .neutralPatch(CalibrationTestData.patch(1)),
            patches: patches,
            provenance: CalibrationTestData.provenance()
        )
    }

    static func reference() throws -> IRCalibrationReferenceDataset {
        var values: [IRCalibrationTargetPatchID: IRCalibrationReferenceRGB] = [:]
        for (index, rgb) in referenceRGB.enumerated() {
            values[CalibrationTestData.patch(index + 1)] = try IRCalibrationReferenceRGB(
                red: rgb.0, green: rgb.1, blue: rgb.2
            )
        }
        return try IRCalibrationReferenceDataset(
            identifier: "synthetic.golden",
            version: "1",
            source: "Written out in the test suite; not a measurement of anything.",
            illuminant: .d65,
            target: .colorCheckerClassic24,
            values: values
        )
    }

    @Test("least-squares-3x3@v1 produces exactly these coefficients from this evidence")
    func goldenFit() throws {
        let fit = try IRCalibrationFitter().fit(
            measurements: try Self.measurements(),
            reference: try Self.reference(),
            now: CalibrationTestData.fittedAt
        )

        #expect(fit.method == .current)
        #expect(fit.method.algorithm == "least-squares-3x3")
        #expect(fit.method.version == 1)

        // The tolerance is `1e-12`, not a comfortable one. These are Double
        // operations on six exact decimal inputs; the last bits may differ
        // between architectures, and nothing else may.
        let expectedMatrix: [[Double]] = [
            [1.3969577474345363, 0.08830500816814264, -0.1204074886152283],
            [-0.20949666600974257, 1.6640631882331485, -0.05700988830271668],
            [-0.1432630687383394, 0.05158863102648697, 1.4261820154908023],
        ]
        for (row, expected) in expectedMatrix.enumerated() {
            for (column, value) in expected.enumerated() {
                #expect(abs(fit.matrix.rows[row][column] - value) < 1e-12)
            }
        }

        #expect(
            abs(fit.conditioning.normalizedGramDeterminant - 0.018680080992897984) < 1e-12
        )
        let expectedNorms = [0.8759326001468378, 0.8310810267819396, 0.8979586223763322]
        #expect(fit.conditioning.channelNorms.count == 3)
        for (index, norm) in expectedNorms.enumerated() {
            #expect(abs(fit.conditioning.channelNorms[index] - norm) < 1e-12)
        }
        #expect(fit.conditioning.sampleCount == 6)
        #expect(fit.conditioning.degreesOfFreedom == 3)

        // One residual per fitted patch, in fitted order, each pinned.
        let expectedResiduals: [[Double]] = [
            [-0.16297815582677655, -0.15531941768282775, -0.16936590799936702],
            [0.042593818352858526, 0.05602048952208566, 0.036416869580356545],
            [0.03802554702661824, 0.0408895341049621, 0.03241466184839792],
            [0.06773374854222713, 0.05565125110143199, 0.07258019937237775],
            [0.09931147080415936, 0.09539505432096435, 0.10771727711270773],
            [0.05788422988245362, 0.04913462381291728, 0.0657784408950175],
        ]
        #expect(fit.metrics.residuals.count == expectedResiduals.count)
        for (index, residual) in fit.metrics.residuals.enumerated() {
            #expect(residual.patch == CalibrationTestData.patch(index + 1))
            #expect(abs(residual.red - expectedResiduals[index][0]) < 1e-12)
            #expect(abs(residual.green - expectedResiduals[index][1]) < 1e-12)
            #expect(abs(residual.blue - expectedResiduals[index][2]) < 1e-12)
        }
    }

    /// The same numbers reached the other way: a calibration assembled from
    /// this fit re-derives it on construction and accepts it. If the solver
    /// changes without the method version changing, this fails beside the
    /// golden above rather than at a user's next file open.
    @Test("The golden fit verifies against its own evidence")
    func goldenFitVerifies() throws {
        let measurements = try Self.measurements()
        let reference = try Self.reference()
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )

        #expect(throws: Never.self) {
            try IRCalibration(
                id: CalibrationTestData.calibrationID(),
                name: "Golden",
                measurements: measurements,
                reference: reference,
                fit: fit
            )
        }
    }
}
