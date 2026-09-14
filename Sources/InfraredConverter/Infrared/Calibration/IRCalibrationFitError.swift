import Foundation

/// Refusals from the calibration **solver** and the fit that drives it.
///
/// Every one of them describes data that does not determine a transform. None
/// of them is a bug report: a chart photographed badly, or a reference dataset
/// missing half its values, is an ordinary thing that happens and the right
/// answer is to say so rather than to emit coefficients.
///
/// The failure this whole enum exists to prevent is a solver that "succeeds"
/// on degenerate input — producing enormous coefficients that fit the
/// measurements exactly and generalise to nothing.
public enum IRCalibrationFitError: Error, Equatable {

    /// Fewer patches than a 3x3 transform can be determined from.
    case insufficientSamples(found: Int, minimum: Int)

    /// Every measured patch was excluded, so there is nothing to fit.
    case noIncludedPatches

    /// A patch admitted to the fit has no reference value.
    case missingReferenceValue(patch: String)

    /// A patch admitted to the fit has no measured samples of some channel.
    case missingChannelResponse(patch: String, channel: String)

    /// The session names a neutral reference that was never measured.
    ///
    /// `IRCalibrationMeasurementSet` refuses this when the evidence is built,
    /// so it is a second line rather than the first. It exists because the
    /// fitter must not depend on having been handed evidence somebody else
    /// already checked.
    case unmeasuredNeutralReference(patch: String)

    /// The session's neutral reference is a patch the evidence excluded.
    ///
    /// The evidence may record it — a clipped or badly sampled neutral patch
    /// is a fact about what happened — but a fit may not use it. Every gain it
    /// defines multiplies every patch in the fit, so an unusable neutral
    /// reference does not spoil one patch, it decides the white balance of the
    /// whole transform.
    case excludedNeutralReference(patch: String, exclusion: IRCalibrationPatchExclusion)

    /// The session's neutral reference contains at least one clipped sample.
    ///
    /// Deliberately independent of
    /// ``IRCalibrationClippingPolicy/maximumClippedSampleFraction``. That
    /// tolerance is a statement about an *ordinary* patch, one of many, whose
    /// influence on the fit is bounded by the other patches around it. The
    /// neutral reference is not one of many: the gains it defines multiply
    /// every channel of every patch admitted to the fit, so a censored sample
    /// inside it does not perturb one row of the least-squares problem, it
    /// displaces the white balance of the whole transform.
    ///
    /// So a tolerance that leaves a patch *included* — one clipped sample in
    /// four hundred, under a fraction of `0.01` — is still not a tolerance for
    /// a patch that is about to set the session's white balance. Zero is the
    /// only defensible threshold here, and it is a definition rather than a
    /// tuned constant.
    case clippedNeutralReference(patch: String, clippedSamples: Int, totalSamples: Int)

    /// The session's neutral reference does not carry every colour plane the
    /// sensor layout produced.
    ///
    /// A second line rather than the first: `IRCalibrationMeasurementSet`
    /// refuses an *included* patch that is incomplete against the recorded
    /// signature, and this fitter refuses an *excluded* neutral reference, so
    /// valid evidence cannot reach here. It exists because the fitter must not
    /// depend on having been handed evidence somebody else already checked —
    /// and because what it prevents is the quietest failure in this
    /// subsystem: gains derived from three planes of a four-plane layout,
    /// balancing green from one phase and scaling every patch of the fit by
    /// the result.
    case incompleteNeutralReference(patch: String, missingColorPlanes: [Int])

    /// A colour plane the session's white balance defines no gain for.
    ///
    /// Under a neutral-patch policy this is a refusal rather than a gain of
    /// `1`: a transform balanced in two channels and left unity in the third
    /// is not the transform the recorded policy describes.
    case missingWhiteBalanceGain(patch: String, colorPlane: Int, neutralPatch: String)

    case nonFiniteSample(patch: String, field: String, value: Double)

    /// A camera channel that is zero across every patch.
    ///
    /// Nothing can be learned about how that channel maps into the working
    /// space, and its column of the transform would be arbitrary.
    case zeroChannelVariation(channel: String)

    /// The measured responses are too nearly collinear to determine a unique
    /// transform.
    ///
    /// The classic cause is a chart photographed so that most patches respond
    /// almost identically — which, behind a deep infrared filter, is a very
    /// real possibility rather than a theoretical one.
    case illConditioned(normalizedGramDeterminant: Double, minimum: Double)

    /// Elimination could not proceed: the normal equations are singular.
    case singularNormalEquations(reason: String)

    /// The arithmetic produced a coefficient that is not a finite number.
    case nonFiniteCoefficient(row: Int, column: Int)
}

extension IRCalibrationFitError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .insufficientSamples:
            return "There are too few usable patches to fit a calibration."
        case .noIncludedPatches:
            return "Every measured patch was excluded, so there is nothing to fit."
        case .missingReferenceValue:
            return "A patch being fitted has no reference value."
        case .missingChannelResponse:
            return "A patch being fitted has no measured response in one channel."
        case .unmeasuredNeutralReference:
            return "The calibration session's neutral reference was never measured."
        case .excludedNeutralReference:
            return "The calibration session's neutral reference is not usable."
        case .clippedNeutralReference:
            return "The calibration session's neutral reference contains clipped samples."
        case .incompleteNeutralReference:
            return "The calibration session's neutral reference is missing a colour plane."
        case .missingWhiteBalanceGain:
            return "The calibration session's white balance does not cover one colour plane."
        case .nonFiniteSample:
            return "A measured value is not a finite number."
        case .zeroChannelVariation:
            return "One camera channel measured zero across every patch."
        case .illConditioned:
            return "These measurements do not determine a unique transform."
        case .singularNormalEquations:
            return "These measurements do not determine a unique transform."
        case .nonFiniteCoefficient:
            return "The fit produced a coefficient that is not a finite number."
        }
    }

    public var failureReason: String? {
        switch self {
        case .insufficientSamples(let found, let minimum):
            return """
                \(found) usable patch\(found == 1 ? "" : "es"), and \(minimum) are required. \
                Three is the algebraic minimum for a 3x3 transform — with exactly three the \
                fit passes through every point and has no residual to report, which is not a \
                measurement of anything. The fourth is what makes the error metrics mean \
                something.
                """

        case .noIncludedPatches:
            return """
                Every patch was excluded — most often because the chart was exposed so that \
                its patches clipped. A calibration cannot be fitted from censored samples, so \
                the answer is a new capture rather than a relaxed rule.
                """

        case .missingReferenceValue(let patch):
            return """
                Patch "\(patch)" was measured and admitted to the fit, and the reference \
                dataset has no value for it. Fitting it towards a value that was made up \
                would be the failure this whole subsystem exists to prevent.
                """

        case .missingChannelResponse(let patch, let channel):
            return """
                Patch "\(patch)" has no measured \(channel) samples. Its region contains no \
                site of that colour filter, which means it is too small or too badly aligned \
                to contain whole CFA cells.
                """

        case .unmeasuredNeutralReference(let patch):
            return """
                The session states that patch "\(patch)" is its neutral reference, and no \
                measurement of that patch is in the evidence. The gains it defines cannot be \
                re-derived, so the fit would not be reproducible from what was recorded.
                """

        case .excludedNeutralReference(let patch, let exclusion):
            return """
                The session's neutral reference is patch "\(patch)", which the evidence \
                excluded: \(exclusion.shortDescription). Its gains scale every channel of \
                every patch in the fit, so using it would let data the evidence marked \
                unusable set the white balance of the whole transform. The evidence keeps \
                the measurement; what it cannot do is fit from it. Re-photograph the chart, \
                or fit the session unbalanced.
                """

        case .clippedNeutralReference(let patch, let clipped, let total):
            return """
                The session's neutral reference is patch "\(patch)", and \(clipped) of its \
                \(total) samples were recorded at or above saturation. The general clipping \
                tolerance does not apply to it: an ordinary patch that survives that \
                tolerance contributes one row to the fit, while the neutral reference defines \
                the gains that scale every channel of every fitted patch — so a censored \
                sample in it would set the white balance of the whole transform from a value \
                the sensor did not actually record. The evidence keeps the measurement; what \
                it cannot do is fit from it. Re-expose the capture so the neutral patch sits \
                clear of saturation and photograph the chart again, or fit the session \
                unbalanced.
                """

        case .incompleteNeutralReference(let patch, let missing):
            return """
                The session's neutral reference is patch "\(patch)", and it carries no \
                measurement of colour plane\(missing.count == 1 ? "" : "s") \
                \(missing.map(String.init).joined(separator: ", ")). Every plane of the layout \
                contributes a gain, and every gain scales every fitted patch, so a neutral \
                reference measured on fewer planes than the sensor has would balance a \
                channel from part of itself and leave nothing in the artefact saying which \
                part.
                """

        case .missingWhiteBalanceGain(let patch, let plane, let neutral):
            return """
                Patch "\(patch)" was measured on colour plane \(plane), and the neutral \
                reference "\(neutral)" defines no gain for that plane. Leaving it at 1 while \
                every other plane is scaled would produce a transform that is balanced in \
                some channels and not in others, and nothing in the artefact would say so.
                """

        case .nonFiniteSample(let patch, let field, let value):
            return """
                Patch "\(patch)" has \(field) = \(value). Fitting is done in Double and one \
                non-finite input propagates into all nine coefficients.
                """

        case .zeroChannelVariation(let channel):
            return """
                The \(channel) response is zero for every patch, so there is nothing to learn \
                about how \(channel) maps into the working space and that column of the \
                transform would be arbitrary. Behind a deep infrared filter this can mean \
                the capture is simply too dark, rather than that the channel is dead.
                """

        case .illConditioned(let determinant, let minimum):
            return """
                The measured responses are too nearly collinear: the normalised Gram \
                determinant is \(determinant), below the \(minimum) this solver requires. A \
                transform fitted to them would be determined by rounding rather than by the \
                data, and would produce very large coefficients that fit these patches \
                exactly and nothing else. Photograph a target whose patches actually differ \
                from one another in this part of the spectrum.
                """

        case .singularNormalEquations(let reason):
            return """
                \(reason) No transform is uniquely determined by this data, and no \
                regularisation was applied to manufacture one: a fit stabilised by an \
                undocumented prior is not a measurement.
                """

        case .nonFiniteCoefficient(let row, let column):
            return """
                The coefficient at row \(row), column \(column) is not finite. The inputs were \
                all finite, so this is an overflow in the normal equations — usually measured \
                responses spanning an implausible range.
                """
        }
    }
}
