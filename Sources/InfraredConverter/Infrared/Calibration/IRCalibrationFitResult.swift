import Foundation

/// What one patch cost the fit.
///
/// The residual is `M · c − r`, in the reference dataset's own representation,
/// per channel and signed. Signed rather than absolute because the sign is
/// diagnostic: a chart whose residuals are all positive in blue is telling a
/// different story from one whose blue residuals scatter.
public struct IRCalibrationPatchResidual: Equatable, Sendable {

    public let patch: IRCalibrationTargetPatchID

    public let red: Double
    public let green: Double
    public let blue: Double

    public init(
        patch: IRCalibrationTargetPatchID, red: Double, green: Double, blue: Double
    ) throws(IRCalibrationError) {
        for (name, value) in [("red", red), ("green", green), ("blue", blue)]
        where !value.isFinite {
            throw .nonFiniteValue(field: "residual.\(patch).\(name)", value: value)
        }
        self.patch = patch
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The Euclidean length of the residual vector: how far this patch landed
    /// from where it should have, in reference space.
    public var magnitude: Double {
        (red * red + green * green + blue * blue).squareRoot()
    }

    public var components: [Double] { [red, green, blue] }
}

/// How well a transform fitted the measurements, derived rather than stored.
///
/// ## Derived, deliberately
///
/// Every number here is computed from the residual list. Nothing is stored
/// twice, so nothing can disagree: a calibration cannot claim an RMSE of 0.01
/// while carrying residuals that average 0.4, and a reader recomputing the
/// metrics gets the same answer the artefact reports.
///
/// The alternative — storing RMSE and maximum alongside the residuals — needs a
/// cross-field consistency check on every read, and the check is only ever as
/// good as somebody remembering to write it. Deriving removes the possibility
/// rather than policing it.
public struct IRCalibrationFitMetrics: Equatable, Sendable {

    public let residuals: [IRCalibrationPatchResidual]

    /// How many measured patches were excluded before the fit.
    ///
    /// Not derivable from the residuals — that is the point of carrying it.
    /// "RMSE 0.02 over 6 of 24 patches" and "RMSE 0.02 over 24 of 24" are very
    /// different claims, and the first is not a good calibration.
    public let excludedPatchCount: Int

    init(residuals: [IRCalibrationPatchResidual], excludedPatchCount: Int) {
        self.residuals = residuals.sorted { $0.patch < $1.patch }
        self.excludedPatchCount = excludedPatchCount
    }

    public var includedPatchCount: Int { residuals.count }

    /// Root mean square of the per-channel residuals, over every channel of
    /// every included patch.
    ///
    /// Per *channel*, not per patch: `sqrt(Σ e² / (3n))`. Averaging the
    /// per-patch magnitudes instead would report a number about a third larger
    /// for the same data, and the two are easy to confuse, so the definition is
    /// stated here rather than implied.
    public var rmse: Double {
        guard !residuals.isEmpty else { return 0 }
        let sum = residuals.reduce(0.0) { total, residual in
            total + residual.red * residual.red
                + residual.green * residual.green
                + residual.blue * residual.blue
        }
        return (sum / Double(residuals.count * 3)).squareRoot()
    }

    /// The largest per-patch residual magnitude.
    ///
    /// The number that catches a single badly measured patch that an average
    /// hides.
    public var maximumResidual: Double {
        residuals.map(\.magnitude).max() ?? 0
    }

    public var worstPatch: IRCalibrationTargetPatchID? {
        residuals.max { $0.magnitude < $1.magnitude }?.patch
    }

    /// Mean per-patch residual magnitude.
    public var meanResidual: Double {
        guard !residuals.isEmpty else { return 0 }
        return residuals.reduce(0.0) { $0 + $1.magnitude } / Double(residuals.count)
    }

    public var diagnosticDescription: String {
        String(
            format: "RMSE %.6f, max %.6f%@, over %d patches (%d excluded)",
            rmse,
            maximumResidual,
            worstPatch.map { " at \($0)" } ?? "",
            includedPatchCount,
            excludedPatchCount
        )
    }
}

/// Which algorithm produced a transform.
public struct IRCalibrationFitMethod: Equatable, Sendable {

    public let algorithm: String
    public let version: Int

    public init(algorithm: String, version: Int) {
        self.algorithm = algorithm
        self.version = version
    }

    /// The method this build fits with.
    public static let current = IRCalibrationFitMethod(
        algorithm: IRCalibrationMatrixSolver.algorithm,
        version: IRCalibrationMatrixSolver.algorithmVersion
    )

    public var identity: String { "\(algorithm)@v\(version)" }
}

/// A transform, the evidence it came from, and how well it fitted.
///
/// ```text
/// IRCalibrationFitResult
///  ├── matrix              camera RGB -> working RGB, output = M × input
///  ├── sourceMeasurementID the evidence this was derived from
///  ├── referenceDataset    identifier@version the residuals are measured against
///  ├── whiteBalancePolicy  the session balance the camera responses carried
///  ├── method              algorithm and version
///  ├── conditioning        how well-determined the solution was
///  ├── metrics             residuals, and everything derived from them
///  └── fittedAt            when
/// ```
///
/// Deliberately **not** a validated calibration, and deliberately not a
/// ``RAWCameraToWorkingColorTransform``. It is a number that came out of a
/// least-squares solve. Whether it may be applied to a photograph is a separate
/// question, answered by ``IRCalibrationStatus`` against evidence this project
/// has not yet collected, and the answer today is no. See
/// `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`.
public struct IRCalibrationFitResult: Equatable, Sendable {

    public let matrix: RAWColorMatrix3x3
    public let sourceMeasurementID: IRCalibrationMeasurementSetID
    public let referenceDataset: String
    public let whiteBalancePolicy: IRCalibrationWhiteBalancePolicy
    public let method: IRCalibrationFitMethod
    public let conditioning: IRCalibrationConditioning
    public let metrics: IRCalibrationFitMetrics
    public let fittedAt: Date

    public init(
        matrix: RAWColorMatrix3x3,
        sourceMeasurementID: IRCalibrationMeasurementSetID,
        referenceDataset: String,
        whiteBalancePolicy: IRCalibrationWhiteBalancePolicy,
        method: IRCalibrationFitMethod,
        conditioning: IRCalibrationConditioning,
        metrics: IRCalibrationFitMetrics,
        fittedAt: Date
    ) {
        self.matrix = matrix
        self.sourceMeasurementID = sourceMeasurementID
        self.referenceDataset = referenceDataset
        self.whiteBalancePolicy = whiteBalancePolicy
        self.method = method
        self.conditioning = conditioning
        self.metrics = metrics
        // Truncated to the precision the file format carries. See
        // `IRCalibrationTimestamp`.
        self.fittedAt = IRCalibrationTimestamp.recorded(fittedAt)
    }

    public var diagnosticDescription: String {
        """
        \(method.identity) from \(sourceMeasurementID) against \(referenceDataset) — \
        \(metrics.diagnosticDescription); \(conditioning.diagnosticDescription); \
        \(whiteBalancePolicy.diagnosticDescription)
        """
    }
}
