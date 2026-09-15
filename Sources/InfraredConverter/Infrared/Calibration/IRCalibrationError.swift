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

    /// The evidence was recorded under one illuminant and the reference values
    /// are defined for another.
    ///
    /// Semantic rather than arithmetic, which is why it needs its own refusal:
    /// the fit over such a pair converges perfectly well and its residuals look
    /// like any other, so nothing in the matrix self-verification can find it.
    /// See ``IRCalibrationIlluminantCompatibility``.
    case illuminantMismatch(measured: String, reference: String)

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

    /// A colour-plane signature that cannot describe a sensor layout a 3x3
    /// transform can be fitted from.
    case invalidColorPlaneSignature(reason: String)

    /// A patch measured on a colour plane the recorded signature does not
    /// have.
    ///
    /// Refused rather than ignored: a plane nobody expected carries a mean
    /// that would be collapsed into one of the three channels, and a reader
    /// has no way to tell whether the signature or the measurement is the
    /// mistake.
    case unexpectedColorPlane(patch: String, colorPlane: Int)

    /// A patch whose plane is measured as a different channel from the one the
    /// signature says that plane is.
    case colorPlaneChannelMismatch(
        patch: String, colorPlane: Int, expected: String, found: String
    )

    /// A patch admitted to the fit that does not carry every expected plane.
    case incompletePatchMeasurement(patch: String, missing: [Int])

    /// A patch whose recorded incompleteness is not the incompleteness it has.
    case inconsistentPatchExclusion(patch: String, claimed: [Int], missing: [Int])

    /// A chart quadrilateral that cannot produce patch regions.
    case invalidChartGeometry(reason: String)

    /// The stored matrix, residuals or solver diagnostics do not follow from
    /// the stored evidence and reference dataset.
    ///
    /// The refusal that makes a calibration an *artefact* rather than a matrix
    /// with paperwork beside it: the transform is recomputed from the evidence
    /// when a calibration is constructed, and a fit that cannot be re-derived
    /// is not accepted. See ``IRCalibrationFitVerifier``.
    case unverifiableFit(IRCalibrationFitVerificationFailure)
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
        case .illuminantMismatch:
            return "The measurements and the reference values describe different illumination."
        case .evidenceMismatch:
            return "This calibration's fit was not computed from the evidence stored with it."
        case .referenceDatasetMismatch:
            return "This calibration's fit was not computed against the reference stored with it."
        case .inconsistentResiduals:
            return "This calibration's error metrics do not match its measurements."
        case .invalidColorPlaneSignature:
            return "That is not a usable sensor colour-plane signature."
        case .unexpectedColorPlane:
            return "A calibration patch was measured on a colour plane the sensor has not."
        case .colorPlaneChannelMismatch:
            return "A calibration patch disagrees with the sensor about what a colour plane is."
        case .incompletePatchMeasurement:
            return "A fitted calibration patch is missing a colour plane."
        case .inconsistentPatchExclusion:
            return "A calibration patch records the wrong missing colour planes."
        case .invalidChartGeometry:
            return "That is not a usable calibration chart outline."
        case .unverifiableFit(let failure):
            return failure.errorDescription
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
                "\(patch)" appears twice. Which of the two a reader should believe would \
                otherwise depend on ordering nobody chose — and where the duplicate is a \
                residual, the second copy silently doubles that patch's weight in every \
                metric derived from the list.
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

        case .illuminantMismatch(let measured, let reference):
            return IRCalibrationIlluminantCompatibility.refusalReason(
                measurement: measured, reference: reference
            )

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

        case .invalidColorPlaneSignature(let reason):
            return reason

        case .unexpectedColorPlane(let patch, let plane):
            return """
                Patch "\(patch)" carries a measurement of colour plane \(plane), which this \
                sensor layout does not have. One of the two is wrong and nothing in the \
                evidence says which, so neither is believed.
                """

        case .colorPlaneChannelMismatch(let patch, let plane, let expected, let found):
            return """
                The sensor layout says colour plane \(plane) is \(expected), and patch \
                "\(patch)" records it as \(found). A plane relabelled after the fact would \
                move a measured response into another channel of the fit, which is the one \
                edit to evidence that changes a transform while leaving every number in the \
                file looking plausible.
                """

        case .incompletePatchMeasurement(let patch, let missing):
            return """
                Patch "\(patch)" is admitted to the fit and has no measurement of colour \
                plane\(missing.count == 1 ? "" : "s") \
                \(missing.map(String.init).joined(separator: ", ")). Fitting it would collapse \
                a channel from fewer planes than the sensor has — on an RGGB layout, a green \
                response taken from one of the two green phases — and the artefact would say \
                nothing about it. An incomplete patch may exist only as explicitly excluded \
                evidence.
                """

        case .inconsistentPatchExclusion(let patch, let claimed, let missing):
            let claimedText = claimed.isEmpty
                ? "none" : claimed.map(String.init).joined(separator: ", ")
            let missingText = missing.isEmpty
                ? "none" : missing.map(String.init).joined(separator: ", ")
            return """
                Patch "\(patch)" records that colour plane\(claimed.count == 1 ? "" : "s") \
                \(claimedText) were not sampled, and the planes actually absent from it are \
                \(missingText). An exclusion is the evidence's own account of why a patch is \
                not fitted, and one that describes a different patch from the one it is \
                attached to is worse than none.
                """

        case .invalidChartGeometry(let reason):
            return reason

        case .unverifiableFit(let failure):
            return failure.failureReason
        }
    }
}
