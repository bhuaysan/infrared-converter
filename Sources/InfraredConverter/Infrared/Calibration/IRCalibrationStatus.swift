import Foundation

/// What a calibration artefact is entitled to claim.
///
/// ```text
/// experimental   measured, and something a validated calibration must record is missing
/// measured       complete evidence, a fit that converged, residuals reported
/// validated      measured, and it meets a documented acceptance criterion
/// ```
///
/// Three levels rather than a Boolean, because "not validated" covers two very
/// different situations: evidence that is incomplete, and evidence that is
/// complete but has not been held against any standard. Collapsing them would
/// make an honest, carefully made measurement indistinguishable from a sloppy
/// one.
///
/// **Derived, never stored.** There is no `isValidated` field anywhere in this
/// subsystem — it is computed from the evidence, the fit and the acceptance
/// criteria every time it is asked for. A stored flag is a second authority
/// that can disagree with the data it describes, and when it does, it is the
/// flag that gets believed.
public enum IRCalibrationStatus: String, Equatable, Sendable, Comparable {

    case experimental
    case measured
    case validated

    private var rank: Int {
        switch self {
        case .experimental: return 0
        case .measured: return 1
        case .validated: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .experimental: return "Experimental"
        case .measured: return "Measured"
        case .validated: return "Validated"
        }
    }

    /// Whether this status permits a calibration to be applied to photographs
    /// as a validated infrared calibration.
    ///
    /// Only `.validated` does, and reaching `.validated` requires acceptance
    /// criteria this project has not established. See
    /// ``IRCalibrationAcceptanceCriteria/project``.
    public var isValidatedInfraredCalibration: Bool { self == .validated }
}

/// Something a validated calibration must record, and this one does not.
public enum IRCalibrationEvidenceGap: Equatable, Sendable {

    case illuminantUnknown
    case illuminantNotMeasured
    case sensorConversionUnknown
    case filterNotDescribed
    case bodyScopeClaimedWithoutSerial
    case tooFewIncludedPatches(included: Int, minimum: Int)
    case clippedSamplesInIncludedPatches(patches: [String])
    case noDegreesOfFreedom

    public var shortDescription: String {
        switch self {
        case .illuminantUnknown:
            return "the illumination was not recorded"
        case .illuminantNotMeasured:
            return "the illuminant was asserted rather than measured"
        case .sensorConversionUnknown:
            return "the sensor conversion was not recorded"
        case .filterNotDescribed:
            return "the filter was not described"
        case .bodyScopeClaimedWithoutSerial:
            return "a specific body is claimed and no serial number was recorded"
        case .tooFewIncludedPatches(let included, let minimum):
            return "only \(included) patches were fitted, and \(minimum) are required"
        case .clippedSamplesInIncludedPatches(let patches):
            return "clipped samples were fitted from, in \(patches.joined(separator: ", "))"
        case .noDegreesOfFreedom:
            return "the fit has no degrees of freedom, so its residuals are zero by construction"
        }
    }
}

/// When a measured calibration may be called validated.
///
/// ## Why this project's criteria are `nil`
///
/// There is no justified acceptance threshold for an infrared false-colour
/// calibration here, and there is no honest way to invent one. "RMSE below
/// 0.02" would be a number chosen because it sounded small — and a threshold
/// chosen that way does the opposite of what a threshold is for: it converts a
/// residual a person could have judged for themselves into a verdict the
/// software appears to have justified.
///
/// So ``project`` is `nil`, and with it no calibration ever reaches
/// `.validated`. The system computes and reports residuals; it does not declare
/// success. A calibration that is complete and fitted is `.measured`, which is
/// exactly what it is.
///
/// The type exists — rather than the status simply never being `.validated` —
/// because the mechanism has to be in place, tested, and visibly waiting for
/// the one thing it is missing. The day a threshold can be justified from real
/// measurements across real bodies, it is a documented value here and nothing
/// else changes.
public struct IRCalibrationAcceptanceCriteria: Equatable, Sendable {

    public let maximumRMSE: Double
    public let maximumResidual: Double
    public let minimumIncludedPatches: Int

    /// Whether validation requires the illuminant to have been *measured*
    /// rather than asserted.
    public let requiresMeasuredIlluminant: Bool

    public init(
        maximumRMSE: Double,
        maximumResidual: Double,
        minimumIncludedPatches: Int,
        requiresMeasuredIlluminant: Bool
    ) {
        self.maximumRMSE = maximumRMSE
        self.maximumResidual = maximumResidual
        self.minimumIncludedPatches = minimumIncludedPatches
        self.requiresMeasuredIlluminant = requiresMeasuredIlluminant
    }

    /// The criteria this project applies: **none**.
    ///
    /// Not a placeholder to be filled in casually. Changing this from `nil`
    /// makes production calibrations claim validation, and is a decision that
    /// belongs in an ADR with the measurements that justify it.
    public static let project: IRCalibrationAcceptanceCriteria? = nil

    public func accepts(
        metrics: IRCalibrationFitMetrics, illuminant: IRCalibrationIlluminant
    ) -> Bool {
        guard metrics.includedPatchCount >= minimumIncludedPatches else { return false }
        guard metrics.rmse <= maximumRMSE else { return false }
        guard metrics.maximumResidual <= maximumResidual else { return false }
        if requiresMeasuredIlluminant, !illuminant.isMeasured { return false }
        return true
    }
}

/// The completeness rules a validated calibration must satisfy, independently
/// of how well it fitted.
///
/// A perfect fit to inadequately documented evidence is still not a validated
/// calibration: if nobody wrote down what was lighting the chart, the transform
/// cannot be said to hold under any particular illumination, however small its
/// residuals are.
public enum IRCalibrationEvidenceCompleteness {

    /// The fewest included patches evidence must carry to be complete.
    ///
    /// Distinct from ``IRCalibrationMatrixSolver/minimumSamples``, which is
    /// what the arithmetic needs. This is what a *claim* needs, and it is
    /// deliberately not the full 24: a chart with several patches legitimately
    /// excluded for clipping is a normal outcome the protocol expects, and
    /// demanding all of them would push somebody towards relaxing the clipping
    /// rule instead.
    public static let minimumIncludedPatches = 12

    public static func gaps(
        measurements: IRCalibrationMeasurementSet,
        reference: IRCalibrationReferenceDataset,
        fit: IRCalibrationFitResult
    ) -> [IRCalibrationEvidenceGap] {
        var gaps: [IRCalibrationEvidenceGap] = []

        switch measurements.illuminant {
        case .unknown:
            gaps.append(.illuminantUnknown)
        case .d65, .d50, .namedOther:
            gaps.append(.illuminantNotMeasured)
        case .measuredSPD:
            break
        }

        if !measurements.captureContext.sensorConversion.isKnown {
            gaps.append(.sensorConversionUnknown)
        }
        if !measurements.captureContext.filter.isDescribed {
            gaps.append(.filterNotDescribed)
        }
        if measurements.captureContext.camera.scope == .specificBody,
           measurements.captureContext.camera.serialNumber == nil {
            gaps.append(.bodyScopeClaimedWithoutSerial)
        }

        let included = fit.metrics.includedPatchCount
        if included < minimumIncludedPatches {
            gaps.append(
                .tooFewIncludedPatches(included: included, minimum: minimumIncludedPatches)
            )
        }
        if fit.conditioning.degreesOfFreedom == 0 {
            gaps.append(.noDegreesOfFreedom)
        }

        let clipped = measurements.includedPatches
            .filter { $0.clippedSampleCount > 0 }
            .map(\.patch.rawValue)
        if !clipped.isEmpty {
            gaps.append(.clippedSamplesInIncludedPatches(patches: clipped))
        }

        // The reference dataset's own completeness is enforced by its
        // initialiser — identifier, version and source are all required — so
        // there is nothing left to check here. Restated rather than silently
        // omitted, so that a later reader does not assume it was forgotten.
        _ = reference

        return gaps
    }

    /// The status this evidence and fit justify.
    ///
    /// ```text
    /// gaps present                            -> .experimental
    /// complete, no criteria established       -> .measured
    /// complete, criteria not met              -> .measured
    /// complete, criteria met                  -> .validated
    /// ```
    ///
    /// Note what the third line does **not** say: a calibration that misses a
    /// criterion is not demoted to `.experimental`. Its evidence is complete
    /// and its fit converged; what it lacks is a verdict, not a measurement.
    public static func status(
        measurements: IRCalibrationMeasurementSet,
        reference: IRCalibrationReferenceDataset,
        fit: IRCalibrationFitResult,
        criteria: IRCalibrationAcceptanceCriteria? = IRCalibrationAcceptanceCriteria.project
    ) -> IRCalibrationStatus {
        let gaps = gaps(measurements: measurements, reference: reference, fit: fit)
        guard gaps.isEmpty else { return .experimental }
        guard let criteria else { return .measured }
        return criteria.accepts(
            metrics: fit.metrics, illuminant: measurements.illuminant
        ) ? .validated : .measured
    }
}
