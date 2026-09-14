import Foundation

/// Refusals from the calibration **measurement** path: turning a RAW file and
/// a chart outline into per-patch responses.
public enum IRCalibrationMeasurementError: Error, Equatable {

    /// The sensor layout has no per-sample colour mosaic to measure planes in.
    case unsupportedSensorLayout(reason: String)

    /// A colour plane whose filter colour is not R, G or B.
    ///
    /// Refused rather than mapped onto the nearest RGB channel, exactly as the
    /// demosaicer refuses it: an RGBE or CMY mosaic is not a Bayer RGB mosaic,
    /// and pretending otherwise would invent colour in the one place where
    /// inventing colour is least excusable.
    case unsupportedColorPlane(colorPlane: Int, letter: String)

    /// The file records no camera make or model, so the measurement cannot say
    /// what it is a measurement of.
    case cameraUnidentified

    /// Every patch was excluded during measurement.
    case allPatchesExcluded(reason: String)
}

extension IRCalibrationMeasurementError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .unsupportedSensorLayout:
            return "This sensor layout cannot be measured in the mosaic domain."
        case .unsupportedColorPlane:
            return "This sensor has a colour filter the calibration path does not model."
        case .cameraUnidentified:
            return "This file does not say which camera took it."
        case .allPatchesExcluded:
            return "No patch of the chart could be measured."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unsupportedSensorLayout(let reason):
            return reason

        case .unsupportedColorPlane(let colorPlane, let letter):
            return """
                Colour plane \(colorPlane) is described as "\(letter)", which is not one of \
                R, G or B. A calibration fits a 3x3 transform of red, green and blue, and \
                mapping a fourth filter onto one of them would invent a response nobody \
                measured.
                """

        case .cameraUnidentified:
            return """
                A calibration is a claim about one camera and filter combination, and one \
                that cannot name its camera cannot be checked against a profile or applied \
                to a photograph.
                """

        case .allPatchesExcluded(let reason):
            return reason
        }
    }
}
