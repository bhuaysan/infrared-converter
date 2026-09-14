import Foundation

/// Refusals from the calibration **domain model**: identities, targets,
/// reference datasets, measurement sets, and the consistency rules that hold
/// a calibration artefact together.
///
/// Separate from ``IRCalibrationFitError`` and ``IRCalibrationMeasurementError``
/// because the three answer different questions. This one says "that is not a
/// well-formed record"; the fit error says "that data does not determine a
/// transform"; the measurement error says "that file did not yield usable
/// responses". Flattening them would leave a caller unable to tell a typo from
/// a degenerate chart.
public enum IRCalibrationError: Error, Equatable {

    case invalidIdentifier(kind: String, token: String, reason: String)

    /// A patch identifier that the target does not define.
    case unknownTargetPatch(patch: String, target: String)

    /// The same patch measured or referenced twice in one collection.
    case duplicateTargetPatch(patch: String)

    case emptyMeasurementSet

    case emptyReferenceDataset

    /// A field whose value a person can see and correct, left empty.
    case missingRequiredField(field: String, reason: String)

    case nonFiniteValue(field: String, value: Double)

    /// A negative reference or measured response where only non-negative
    /// values are meaningful.
    case negativeValue(field: String, value: Double)

    /// A finite, correctly signed value outside the range its field admits.
    ///
    /// Distinct from ``negativeValue`` because the two say different things: a
    /// negative response is a recording fault, and a 5000 nm filter cutoff is a
    /// typo. Collapsing them would report one as the other.
    case valueOutOfRange(field: String, value: Double, reason: String)

    /// The measurement set and the reference dataset describe different
    /// targets, so their patch identifiers do not mean the same thing.
    case targetMismatch(measured: String, reference: String)

    /// A fit result whose source evidence is not the evidence it was stored
    /// with.
    case evidenceMismatch(expected: String, found: String)

    /// A fit result whose reference dataset is not the one it was stored with.
    case referenceDatasetMismatch(expected: String, found: String)

    /// The residual list and the included-patch list disagree.
    ///
    /// A calibration claiming 24 patches must not carry 23 residuals. This is
    /// the check that makes "how well did it fit?" answerable from the
    /// artefact alone.
    case inconsistentResiduals(reason: String)

    /// A chart quadrilateral that cannot produce patch regions.
    case invalidChartGeometry(reason: String)
}

extension IRCalibrationError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "That is not a valid calibration identifier."
        case .unknownTargetPatch:
            return "That calibration target has no such patch."
        case .duplicateTargetPatch:
            return "A calibration patch appears more than once."
        case .emptyMeasurementSet:
            return "A calibration measurement set contains no patches."
        case .emptyReferenceDataset:
            return "A calibration reference dataset contains no values."
        case .missingRequiredField:
            return "This calibration record is missing something it must record."
        case .nonFiniteValue:
            return "A calibration value is not a finite number."
        case .negativeValue:
            return "A calibration value is negative where it cannot be."
        case .valueOutOfRange:
            return "A calibration value is outside the range it may take."
        case .targetMismatch:
            return "The measurements and the reference values describe different targets."
        case .evidenceMismatch:
            return "This calibration's fit was not computed from the evidence stored with it."
        case .referenceDatasetMismatch:
            return "This calibration's fit was not computed against the reference stored with it."
        case .inconsistentResiduals:
            return "This calibration's error metrics do not match its measurements."
        case .invalidChartGeometry:
            return "That is not a usable calibration chart outline."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidIdentifier(let kind, let token, let reason):
            return "\"\(token)\" is not a \(kind) identifier: \(reason)"

        case .unknownTargetPatch(let patch, let target):
            return """
                "\(patch)" is not a patch of \(target). A measurement of a patch the target \
                does not have cannot be paired with a reference value, and inventing which \
                patch was meant would silently change what was fitted.
                """

        case .duplicateTargetPatch(let patch):
            return """
                "\(patch)" appears twice. Which of the two measurements a fit used would \
                otherwise depend on ordering nobody chose.
                """

        case .emptyMeasurementSet:
            return """
                Evidence with no patches in it records nothing, and a calibration derived \
                from it would be a matrix with no measurement behind it.
                """

        case .emptyReferenceDataset:
            return """
                A reference dataset is what a fit aims at. With no values in it there is \
                nothing to fit towards.
                """

        case .missingRequiredField(let field, let reason):
            return "\"\(field)\" is required: \(reason)"

        case .nonFiniteValue(let field, let value):
            return """
                "\(field)" is \(value). Calibration arithmetic is done in Double and every \
                input to it must be finite; a non-finite one propagates into every \
                coefficient of the result.
                """

        case .negativeValue(let field, let value):
            return """
                "\(field)" is \(value). A measured response and a reference intensity are \
                both quantities of light, and a negative one is a recording fault rather \
                than a dark colour.
                """

        case .valueOutOfRange(let field, let value, let reason):
            return "\"\(field)\" is \(value): \(reason)"

        case .targetMismatch(let measured, let reference):
            return """
                The measurements are of \(measured) and the reference values are for \
                \(reference). Patch "01" means a different colour on each, so pairing them \
                would fit the transform to the wrong thing.
                """

        case .evidenceMismatch(let expected, let found):
            return """
                The stored evidence is "\(expected)" and the fit names "\(found)" as its \
                source. A calibration whose metrics were computed from measurements it does \
                not carry cannot be checked by anybody reading it.
                """

        case .referenceDatasetMismatch(let expected, let found):
            return """
                The stored reference dataset is "\(expected)" and the fit was computed \
                against "\(found)". Residuals are distances to reference values, so they \
                mean nothing without the reference they were measured from.
                """

        case .inconsistentResiduals(let reason):
            return """
                \(reason) Error metrics are the whole basis on which a calibration claims to \
                be any good, so they are recomputed from the residual list rather than \
                stored twice, and the residual list must correspond to the patches that were \
                actually fitted.
                """

        case .invalidChartGeometry(let reason):
            return reason
        }
    }
}
