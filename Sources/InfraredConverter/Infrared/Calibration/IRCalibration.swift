import Foundation

/// One calibration artefact: the evidence, the reference it was fitted
/// against, and the transform that fitting produced — checked against each
/// other.
///
/// ```text
/// IRCalibration
///  ├── id             calibration.<uuid>
///  ├── name           a person's label; identity does not depend on it
///  ├── measurements   what the camera produced (immutable evidence)
///  ├── reference      what it was supposed to produce
///  └── fit            the transform, and how well it fitted
/// ```
///
/// ## Why all three travel together
///
/// A matrix on its own justifies nothing. The central claim this subsystem
/// exists to make possible is:
///
/// > The project must be able to explain why a calibration is valid without
/// > pointing only at its matrix. Its evidence must state what was measured,
/// > under what conditions, against which reference, how the transform was
/// > fitted, and how well it fit.
///
/// Splitting the three into separate files that reference each other by
/// identity would make an artefact that can lose its own evidence — and a
/// calibration whose evidence is missing is a matrix, which is the thing that
/// justifies nothing. So one artefact carries all three, and the consistency
/// between them is checked when it is constructed rather than assumed when it
/// is read.
///
/// ## Re-fitting
///
/// The measurement set keeps its own identity. Re-fitting the same evidence —
/// with a better solver, a corrected reference dataset, a different patch
/// selection — produces a **new** `IRCalibration` with a new
/// ``IRCalibrationID``, carrying the same ``IRCalibrationMeasurementSet`` with
/// the same ``IRCalibrationMeasurementSetID``. Nothing is mutated and no
/// history is lost; two calibrations simply name one measurement as their
/// source.
public struct IRCalibration: Equatable, Sendable, Identifiable {

    public let id: IRCalibrationID
    public let name: String
    public let measurements: IRCalibrationMeasurementSet
    public let reference: IRCalibrationReferenceDataset
    public let fit: IRCalibrationFitResult

    public init(
        id: IRCalibrationID,
        name: String,
        measurements: IRCalibrationMeasurementSet,
        reference: IRCalibrationReferenceDataset,
        fit: IRCalibrationFitResult
    ) throws(IRCalibrationError) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw .missingRequiredField(
                field: "calibration.name",
                reason: "A calibration needs a label a person can recognise it by."
            )
        }

        guard measurements.target == reference.target else {
            throw .targetMismatch(
                measured: measurements.target.displayName,
                reference: reference.target.displayName
            )
        }
        guard fit.sourceMeasurementID == measurements.id else {
            throw .evidenceMismatch(
                expected: measurements.id.rawValue,
                found: fit.sourceMeasurementID.rawValue
            )
        }
        guard fit.referenceDataset == reference.identity else {
            throw .referenceDatasetMismatch(
                expected: reference.identity, found: fit.referenceDataset
            )
        }
        guard fit.whiteBalancePolicy == measurements.whiteBalancePolicy else {
            throw .inconsistentResiduals(
                reason: """
                    The fit was computed under \(fit.whiteBalancePolicy.diagnosticDescription), \
                    and the evidence records \
                    \(measurements.whiteBalancePolicy.diagnosticDescription).
                    """
            )
        }

        // The consistency rule that matters most: a calibration claiming n
        // patches must carry n residuals, for exactly those patches. Without
        // it, "how well did it fit?" has no answer that can be checked.
        let includedPatches = Set(measurements.includedPatches.map(\.patch))
        let residualPatches = Set(fit.metrics.residuals.map(\.patch))
        guard includedPatches == residualPatches else {
            let missing = includedPatches.subtracting(residualPatches).map(\.rawValue).sorted()
            let extra = residualPatches.subtracting(includedPatches).map(\.rawValue).sorted()
            throw .inconsistentResiduals(
                reason: """
                    \(measurements.includedPatchCount) patches were fitted and \
                    \(fit.metrics.residuals.count) residuals are recorded\
                    \(missing.isEmpty ? "" : "; no residual for \(missing.joined(separator: ", "))")\
                    \(extra.isEmpty ? "" : "; a residual for \(extra.joined(separator: ", ")), which was not fitted").
                    """
            )
        }
        guard fit.metrics.excludedPatchCount == measurements.excludedPatchCount else {
            throw .inconsistentResiduals(
                reason: """
                    The metrics record \(fit.metrics.excludedPatchCount) excluded patches and \
                    the evidence has \(measurements.excludedPatchCount).
                    """
            )
        }

        self.id = id
        self.name = name
        self.measurements = measurements
        self.reference = reference
        self.fit = fit
    }

    /// What this calibration is entitled to claim, derived from its own
    /// contents.
    ///
    /// Recomputed on every access rather than stored, so nothing can carry a
    /// status its evidence does not support. With this project's acceptance
    /// criteria — there are none — the best any calibration reaches is
    /// `.measured`.
    public var status: IRCalibrationStatus {
        IRCalibrationEvidenceCompleteness.status(
            measurements: measurements, reference: reference, fit: fit
        )
    }

    /// What is missing before this could be a validated calibration.
    public var evidenceGaps: [IRCalibrationEvidenceGap] {
        IRCalibrationEvidenceCompleteness.gaps(
            measurements: measurements, reference: reference, fit: fit
        )
    }

    /// **`false` for every calibration this project can currently produce.**
    ///
    /// Derived from ``status``, which is derived from the evidence, the fit and
    /// the acceptance criteria — and the criteria are `nil`, deliberately. See
    /// ``IRCalibrationAcceptanceCriteria/project``.
    public var isValidatedInfraredCalibration: Bool {
        status.isValidatedInfraredCalibration
    }

    /// The fitted matrix.
    ///
    /// Deliberately **not** a ``RAWCameraToWorkingColorTransform``. Nothing in
    /// this project turns a calibration into a pipeline stage yet, because no
    /// calibration is validated and a transform built from an unvalidated one
    /// would be applied to photographs. See
    /// `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`.
    public var matrix: RAWColorMatrix3x3 { fit.matrix }

    public var diagnosticDescription: String {
        """
        \(name) [\(id)] — \(status.displayName)
        evidence:  \(measurements.diagnosticDescription)
        reference: \(reference.diagnosticDescription)
        fit:       \(fit.diagnosticDescription)
        gaps:      \(evidenceGaps.isEmpty ? "none" : evidenceGaps.map(\.shortDescription).joined(separator: "; "))
        """
    }
}
