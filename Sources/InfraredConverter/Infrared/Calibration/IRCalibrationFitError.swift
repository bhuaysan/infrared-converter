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
