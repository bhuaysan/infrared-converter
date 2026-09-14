import Foundation

// MARK: - How two numbers are judged to agree

/// The one rule by which a **stored** calibration number is judged to agree
/// with a **recomputed** one.
///
/// ## Why not exact equality
///
/// Bit-identical equality would work today, and the suite asserts that it does:
/// `IRCalibrationMatrixSolver` is deterministic — fixed traversal order, no
/// randomness, no iteration to a tolerance, no parallel reduction — and `+`,
/// `-`, `*`, `/` and `sqrt` on `Double` are correctly rounded by IEEE 754, so
/// the same evidence gives the same coefficients on any machine running this
/// build. The values also round-trip exactly through this project's JSON.
///
/// What exact equality would additionally assert is that they will *always*
/// do so — through every future compiler, standard library and architecture
/// this project is built on. That is a claim about software nobody has written
/// yet, and the cost of it being wrong falls on somebody's stored measurements:
/// a calibration that took a chart, a lamp and an afternoon becomes unreadable
/// because a re-derived coefficient moved in its last place.
///
/// So agreement is judged with a deliberately tiny tolerance. It exists to
/// absorb last-place drift in re-derived arithmetic, and for nothing else.
///
/// ## Why these numbers
///
/// ```text
/// relative   1e-12    ≈ 4500 × Double.ulpOfOne
/// absolute   1e-12    for values near zero, where a relative test says nothing
/// ```
///
/// The forward error of a 3x3 least-squares solve is bounded by roughly the
/// condition number of the normal equations times the machine epsilon. The
/// conditioning floor this solver enforces
/// (``IRCalibrationMatrixSolver/minimumNormalizedGramDeterminant``) admits data
/// whose worst case is of the order of `1e-14`; `1e-12` leaves roughly two
/// orders of magnitude of headroom above that.
///
/// It is far below anything a person could change and mean: a residual, a
/// coefficient or a determinant edited by hand differs in a digit that is
/// visible in the file, not in the thirteenth. An edit small enough to pass
/// this test is an edit that changes no number anybody reads.
///
/// The absolute term is needed because residuals are legitimately zero — an
/// exact fit has no error to report — and a relative comparison of `0` against
/// `3e-17` is a comparison of nothing. Residuals and reference values live in
/// the working representation, where the interesting magnitudes are of order
/// `1`, so an absolute floor of `1e-12` is the same claim as the relative one
/// at that scale.
///
/// **One definition, one place.** Every comparison of a stored calibration
/// number against a recomputed one goes through here; there is no second
/// tolerance anywhere in the calibration subsystem, and no bare `abs(a - b) <
/// something` at a call site.
public enum IRCalibrationFitAgreement {

    /// The permitted difference relative to the larger of the two magnitudes.
    public static let relativeTolerance = 1e-12

    /// The permitted difference for values at or near zero.
    public static let absoluteTolerance = 1e-12

    /// Whether a recomputed value may be accepted as the stored one.
    ///
    /// A non-finite value on either side never agrees: neither a stored `NaN`
    /// nor a recomputed one describes a fit.
    public static func agree(stored: Double, recomputed: Double) -> Bool {
        guard stored.isFinite, recomputed.isFinite else { return false }
        let difference = abs(stored - recomputed)
        if difference <= absoluteTolerance { return true }
        return difference <= relativeTolerance * max(abs(stored), abs(recomputed))
    }
}

// MARK: - What a verification can find

/// Why a stored fit could not be shown to follow from the evidence stored with
/// it.
///
/// Every case names what was expected and what was found, because the person
/// reading it is holding a file they cannot use and the useful question is
/// which number is wrong.
public enum IRCalibrationFitVerificationFailure: Error, Equatable {

    /// The fit names an algorithm or a version this build cannot reproduce.
    ///
    /// Refused rather than accepted unverified. A transform this build cannot
    /// re-derive is a transform whose relationship to its evidence is an
    /// assertion in a file, which is precisely the claim this subsystem exists
    /// to stop taking on trust.
    case unreproducibleMethod(algorithm: String, version: Int, reproducible: String)

    /// The evidence and the reference describe different targets, so their
    /// patch identifiers do not mean the same thing.
    case targetMismatch(measured: String, reference: String)

    /// The fit names other evidence than the evidence it was given.
    case evidenceMismatch(expected: String, found: String)

    /// The fit names another reference dataset revision than the one it was
    /// given.
    case referenceDatasetMismatch(expected: String, found: String)

    /// The fit records a session white balance the evidence does not.
    case whiteBalancePolicyMismatch(evidence: String, fit: String)

    /// Re-deriving the transform from the evidence was refused outright.
    ///
    /// The evidence in the file does not determine a transform at all — it is
    /// ill-conditioned, too small, missing reference values, or its neutral
    /// reference is unusable — so whatever matrix the file carries did not come
    /// from it.
    case refitRefused(IRCalibrationFitError)

    case matrixDisagrees(row: Int, column: Int, stored: Double, recomputed: Double)

    case residualCountDisagrees(stored: Int, recomputed: Int)

    case residualPatchDisagrees(position: Int, stored: String, recomputed: String)

    case residualDisagrees(patch: String, channel: String, stored: Double, recomputed: Double)

    case conditioningDisagrees(field: String, stored: Double, recomputed: Double)

    case sampleCountDisagrees(stored: Int, recomputed: Int)

    case excludedPatchCountDisagrees(stored: Int, recomputed: Int)
}

extension IRCalibrationFitVerificationFailure: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .unreproducibleMethod:
            return "This calibration was fitted by a method this version cannot reproduce."
        case .targetMismatch:
            return "The measurements and the reference values describe different targets."
        case .evidenceMismatch:
            return "This calibration's fit was not computed from the evidence stored with it."
        case .referenceDatasetMismatch:
            return "This calibration's fit was not computed against the reference stored with it."
        case .whiteBalancePolicyMismatch:
            return "This calibration's fit and its evidence disagree about the session white balance."
        case .refitRefused:
            return "This calibration's evidence does not determine a transform at all."
        case .matrixDisagrees:
            return "This calibration's matrix does not follow from its measurements."
        case .residualCountDisagrees, .residualPatchDisagrees, .residualDisagrees:
            return "This calibration's residuals do not follow from its measurements."
        case .conditioningDisagrees, .sampleCountDisagrees:
            return "This calibration's solver diagnostics do not follow from its measurements."
        case .excludedPatchCountDisagrees:
            return "This calibration disagrees with its evidence about how many patches were left out."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unreproducibleMethod(let algorithm, let version, let reproducible):
            return """
                The fit records "\(algorithm)@v\(version)"; this version can reproduce \
                "\(reproducible)". A calibration is only checkable if its matrix can be \
                re-derived from its evidence, so a fit this build cannot recompute is refused \
                rather than accepted on the strength of what the file says about itself.
                """

        case .targetMismatch(let measured, let reference):
            return """
                The measurements are of \(measured) and the reference values are for \
                \(reference), so no transform could have been fitted between them.
                """

        case .evidenceMismatch(let expected, let found):
            return """
                The stored evidence is "\(expected)" and the fit names "\(found)" as its \
                source.
                """

        case .referenceDatasetMismatch(let expected, let found):
            return """
                The stored reference dataset is "\(expected)" and the fit was computed against \
                "\(found)".
                """

        case .whiteBalancePolicyMismatch(let evidence, let fit):
            return """
                The evidence records \(evidence) and the fit was computed under \(fit). The \
                gains a session's neutral reference defines scale every channel of every \
                fitted patch, so the two cannot describe one calibration.
                """

        case .refitRefused(let error):
            return """
                Re-deriving the transform from the stored evidence was refused: \
                \(error.failureReason ?? String(describing: error)) The matrix in this file \
                therefore did not come from the measurements beside it.
                """

        case .matrixDisagrees(let row, let column, let stored, let recomputed):
            return """
                The coefficient at row \(row), column \(column) is \(stored); fitting the \
                stored measurements against the stored reference values produces \
                \(recomputed). A calibration's matrix is a conclusion drawn from its evidence, \
                and this one cannot be drawn from it.
                """

        case .residualCountDisagrees(let stored, let recomputed):
            return """
                The fit records \(stored) residuals and re-deriving it produces \(recomputed).
                """

        case .residualPatchDisagrees(let position, let stored, let recomputed):
            return """
                Residual \(position + 1) is recorded for patch "\(stored)" and re-deriving the \
                fit produces one for "\(recomputed)".
                """

        case .residualDisagrees(let patch, let channel, let stored, let recomputed):
            return """
                The \(channel) residual of patch "\(patch)" is \(stored); re-deriving the fit \
                produces \(recomputed). Residuals are the whole basis on which a calibration \
                claims to be any good, so they are checked against the evidence rather than \
                believed.
                """

        case .conditioningDisagrees(let field, let stored, let recomputed):
            return """
                The fit records \(field) = \(stored) and re-deriving it produces \(recomputed). \
                The conditioning describes how well the measurements determined the transform, \
                so a figure that does not come from them describes nothing.
                """

        case .sampleCountDisagrees(let stored, let recomputed):
            return """
                The fit says it was solved from \(stored) samples and the evidence admits \
                \(recomputed) patches to the fit.
                """

        case .excludedPatchCountDisagrees(let stored, let recomputed):
            return """
                The fit records \(stored) excluded patches and the evidence has \(recomputed). \
                "RMSE 0.02 over 6 of 24 patches" and "RMSE 0.02 over 24 of 24" are very \
                different claims.
                """
        }
    }
}

// MARK: - The verification

/// Checks that a stored fit is the fit its evidence produces.
///
/// ## What this exists to prevent
///
/// Without it, an `.ircalibration.json` could carry any nine numbers it liked
/// beside a set of honest measurements and a set of honest-looking residuals,
/// and every structural check would pass: the measurement identity matches, the
/// reference identity matches, there is one residual per fitted patch. The
/// artefact would look exactly like a calibration and its matrix would have
/// nothing to do with the chart it claims to describe.
///
/// So the transform is **recomputed** from the evidence and the reference, and
/// the stored matrix, residuals and solver diagnostics are held against it.
///
/// ```text
/// stored measurements + stored reference
///          ↓  IRCalibrationFitter.derive — the one authority
/// recomputed matrix, residuals, conditioning
///          ↓  IRCalibrationFitAgreement
/// agrees with the stored matrix, residuals, conditioning  —  or a typed refusal
/// ```
///
/// ## One implementation, not two
///
/// Verification calls ``IRCalibrationFitter/derive(measurements:reference:)``,
/// the same arithmetic `fit` uses. A second implementation written "to check
/// the first" would be a second definition of the white-balance derivation, the
/// green collapse and the solver, and the day the two disagreed there would be
/// no way to tell which was right. Recomputation catches a **tampered or
/// corrupted artefact**, which is what it is for; it does not claim to catch a
/// wrong solver.
///
/// ## Where it runs
///
/// In ``IRCalibration``'s initialiser, so it runs on every artefact this
/// project constructs — from a fresh fit, and from a decoded file, which is the
/// same path. A file cannot describe a calibration that could not have been
/// constructed in memory.
public struct IRCalibrationFitVerifier: Sendable {

    public init() {}

    public func verify(
        _ fit: IRCalibrationFitResult,
        measurements: IRCalibrationMeasurementSet,
        reference: IRCalibrationReferenceDataset
    ) throws(IRCalibrationFitVerificationFailure) {
        guard fit.method.isReproducibleByThisBuild else {
            throw .unreproducibleMethod(
                algorithm: fit.method.algorithm,
                version: fit.method.version,
                reproducible: IRCalibrationFitMethod.current.identity
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
                expected: measurements.id.rawValue, found: fit.sourceMeasurementID.rawValue
            )
        }
        guard fit.referenceDataset == reference.identity else {
            throw .referenceDatasetMismatch(
                expected: reference.identity, found: fit.referenceDataset
            )
        }
        // The session white balance is verified twice over, and deliberately:
        // the policies must agree, and the gains that policy defines are then
        // re-derived inside `derive` and reach every recomputed number below.
        // A fit computed under different gains cannot match the recomputed
        // matrix even when the two policies happen to read alike.
        guard fit.whiteBalancePolicy == measurements.whiteBalancePolicy else {
            throw .whiteBalancePolicyMismatch(
                evidence: measurements.whiteBalancePolicy.diagnosticDescription,
                fit: fit.whiteBalancePolicy.diagnosticDescription
            )
        }
        guard fit.metrics.excludedPatchCount == measurements.excludedPatchCount else {
            throw .excludedPatchCountDisagrees(
                stored: fit.metrics.excludedPatchCount,
                recomputed: measurements.excludedPatchCount
            )
        }

        let derived: IRCalibrationFitter.Derivation
        do {
            derived = try IRCalibrationFitter.derive(
                measurements: measurements, reference: reference
            )
        } catch {
            throw .refitRefused(error)
        }

        try Self.verifyMatrix(stored: fit.matrix, recomputed: derived.matrix)
        try Self.verifyResiduals(stored: fit.metrics.residuals, recomputed: derived.residuals)
        try Self.verifyConditioning(
            stored: fit.conditioning, recomputed: derived.conditioning
        )
    }

    private static func verifyMatrix(
        stored: RAWColorMatrix3x3, recomputed: RAWColorMatrix3x3
    ) throws(IRCalibrationFitVerificationFailure) {
        let storedRows = stored.rows
        let recomputedRows = recomputed.rows
        for row in 0..<RAWColorMatrix3x3.dimension {
            for column in 0..<RAWColorMatrix3x3.dimension {
                let a = storedRows[row][column]
                let b = recomputedRows[row][column]
                guard IRCalibrationFitAgreement.agree(stored: a, recomputed: b) else {
                    throw .matrixDisagrees(row: row, column: column, stored: a, recomputed: b)
                }
            }
        }
    }

    private static func verifyResiduals(
        stored: [IRCalibrationPatchResidual],
        recomputed: [IRCalibrationFitter.DerivedResidual]
    ) throws(IRCalibrationFitVerificationFailure) {
        guard stored.count == recomputed.count else {
            throw .residualCountDisagrees(stored: stored.count, recomputed: recomputed.count)
        }
        // `IRCalibrationFitMetrics` sorts what it stores, and
        // `IRCalibrationMeasurementSet` sorts the patches `derive` walks, so
        // both lists are in patch order and can be compared position by
        // position.
        let recomputedInOrder = recomputed.sorted { $0.patch < $1.patch }
        for (position, pair) in zip(stored, recomputedInOrder).enumerated() {
            let (stored, recomputed) = pair
            guard stored.patch == recomputed.patch else {
                throw .residualPatchDisagrees(
                    position: position,
                    stored: stored.patch.rawValue,
                    recomputed: recomputed.patch.rawValue
                )
            }
            let channels = [
                ("red", stored.red, recomputed.red),
                ("green", stored.green, recomputed.green),
                ("blue", stored.blue, recomputed.blue),
            ]
            for (channel, a, b) in channels {
                guard IRCalibrationFitAgreement.agree(stored: a, recomputed: b) else {
                    throw .residualDisagrees(
                        patch: stored.patch.rawValue, channel: channel, stored: a, recomputed: b
                    )
                }
            }
        }
    }

    private static func verifyConditioning(
        stored: IRCalibrationConditioning, recomputed: IRCalibrationConditioning
    ) throws(IRCalibrationFitVerificationFailure) {
        guard stored.sampleCount == recomputed.sampleCount else {
            throw .sampleCountDisagrees(
                stored: stored.sampleCount, recomputed: recomputed.sampleCount
            )
        }
        guard
            IRCalibrationFitAgreement.agree(
                stored: stored.normalizedGramDeterminant,
                recomputed: recomputed.normalizedGramDeterminant
            )
        else {
            throw .conditioningDisagrees(
                field: "the normalised Gram determinant",
                stored: stored.normalizedGramDeterminant,
                recomputed: recomputed.normalizedGramDeterminant
            )
        }
        guard stored.channelNorms.count == recomputed.channelNorms.count else {
            throw .conditioningDisagrees(
                field: "the number of channel norms",
                stored: Double(stored.channelNorms.count),
                recomputed: Double(recomputed.channelNorms.count)
            )
        }
        let names = ["red", "green", "blue"]
        for (index, pair) in zip(stored.channelNorms, recomputed.channelNorms).enumerated() {
            guard IRCalibrationFitAgreement.agree(stored: pair.0, recomputed: pair.1) else {
                throw .conditioningDisagrees(
                    field: "the \(index < names.count ? names[index] : "\(index)") channel norm",
                    stored: pair.0,
                    recomputed: pair.1
                )
            }
        }
    }
}
