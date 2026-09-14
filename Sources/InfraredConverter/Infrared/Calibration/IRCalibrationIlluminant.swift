import Foundation

/// What was illuminating the target when it was photographed.
///
/// ```text
/// d65              a standardised daylight illuminant, asserted because it was arranged
/// d50              likewise
/// namedOther(…)    a named source this project does not model ("tungsten", "LED panel X")
/// measuredSPD(…)   a measured spectral power distribution, by reference
/// unknown          nobody recorded it
/// ```
///
/// ## Why this is not a detail
///
/// For an infrared capture the illuminant is not a colour-temperature nicety —
/// it is most of the experiment. A silicon sensor behind a 720 nm long-pass
/// filter is recording the part of the source's spectrum that a person cannot
/// see, and daylight, tungsten and an LED panel differ there far more
/// dramatically than they do in the visible. An LED panel may emit almost
/// nothing above 700 nm; tungsten emits copiously. A transform fitted under one
/// and applied under another is not a calibration, it is a coincidence.
///
/// So this is recorded explicitly, and `.unknown` is a real answer that
/// `IRCalibrationStatus` treats as an incompleteness rather than a default.
/// **Do not claim `.d65` because a photograph was taken outdoors.** Daylight
/// varies with time, season, cloud and surroundings, and its infrared content
/// varies with all of them; D65 is a defined spectrum, not a synonym for
/// "outside".
public enum IRCalibrationIlluminant: Equatable, Sendable {

    case d65

    case d50

    /// A source named by whoever made the measurement, which this project does
    /// not model and makes no spectral claim about.
    case namedOther(String)

    /// A measured spectral power distribution, identified by reference — a
    /// file, an instrument reading, a document. The reference is carried; the
    /// spectrum itself is not, because nothing here consumes one.
    case measuredSPD(reference: String)

    /// Nobody recorded it.
    ///
    /// Honest, and deliberately not a placeholder for a guess.
    case unknown

    public var isKnown: Bool { self != .unknown }

    /// Whether the illumination was *measured* rather than asserted.
    ///
    /// `.d65` arranged with a lamp somebody bought is an assertion; a recorded
    /// SPD is evidence. Both are far better than `.unknown`, and they are not
    /// the same thing.
    public var isMeasured: Bool {
        if case .measuredSPD = self { return true }
        return false
    }

    public var shortDescription: String {
        switch self {
        case .d65: return "D65"
        case .d50: return "D50"
        case .namedOther(let name): return name
        case .measuredSPD(let reference): return "Measured SPD (\(reference))"
        case .unknown: return "Unknown"
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case .d65:
            return "D65, asserted (a standard daylight illuminant, not a measured spectrum)"
        case .d50:
            return "D50, asserted (a standard illuminant, not a measured spectrum)"
        case .namedOther(let name):
            return "illuminant named \"\(name)\" (identity only; no spectral data)"
        case .measuredSPD(let reference):
            return "measured spectral power distribution, recorded at \"\(reference)\""
        case .unknown:
            return """
                illumination not recorded — the infrared content of the source is therefore \
                unknown, and no calibration measured under it can claim more than that it \
                was measured
                """
        }
    }
}
