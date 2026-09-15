import Foundation

/// The physical infrared filter a photograph was taken through, as far as
/// anyone actually knows.
///
/// ```text
/// unknown                              nobody recorded which filter, if any
/// longPass(nominalCutoffNanometers:)   a filter sold as "720 nm", "590 nm", …
/// named("Hoya R72")                    a product, identified by name only
/// ```
///
/// ## This is metadata. It is not a spectral model.
///
/// A filter acts **during capture**, before the sensor samples anything. By the
/// time this application sees a file, whatever the filter did is already baked
/// into the numbers, and no descriptor here inverts it. `CLAUDE.md` puts it
/// plainly: a wavelength label such as `720 nm` identifies a *filter family*,
/// and it does not characterise the recorded image.
///
/// So the field below is called `nominalCutoffNanometers` rather than anything
/// with "exact" in it. A marketed 720 nm long-pass filter is not a step
/// function at 720 nm: it has a transition band tens of nanometres wide, a
/// passband that is not flat, and per-batch variation, and two manufacturers'
/// "720 nm" filters are not interchangeable. The number is what the box says.
///
/// Two consequences follow, and both are deliberate:
///
/// - Nothing in this project matches profiles by wavelength. A profile for a
///   720 nm capture is not automatically valid for another 720 nm capture on
///   another body with another conversion.
/// - Carrying a wavelength does **not** make a profile calibrated. See
///   `IRCaptureProcessingBasis`, which is the only thing that decides what
///   happens to pixels.
public enum IRFilterDescriptor: Equatable, Sendable {

    /// No filter is recorded. Neither "no filter was used" nor "a filter was
    /// used"; simply unrecorded.
    case unknown

    /// A long-pass filter sold under a nominal cutoff wavelength, in
    /// nanometres.
    ///
    /// Build one through `longPass(nominalNanometers:)`, which refuses a value
    /// that could not describe a real filter. The case itself takes the
    /// validated number; the factory is the only way to obtain one from
    /// arbitrary input.
    case longPass(nominalCutoffNanometers: Double)

    /// A filter identified only by product name, because no wavelength is
    /// known or because the product does not have a single meaningful one.
    case named(String)

    /// The narrowest and widest nominal cutoffs this type accepts, in
    /// nanometres.
    ///
    /// Deliberately generous: it exists to reject nonsense — zero, negatives,
    /// infinities, a value that is plainly a wavelength in metres or a
    /// frequency — not to express an opinion about which infrared filters are
    /// reasonable. Filters are sold from roughly 550 nm well past 1000 nm.
    public static let supportedNominalCutoffNanometers: ClosedRange<Double> = 200...2000

    /// Nominal cutoffs that are commonly sold, offered as **typing shortcuts**
    /// and nothing else.
    ///
    /// ```text
    /// 590 nm   665 nm   720 nm   830 nm
    /// ```
    ///
    /// These four are the families a person is most likely to own, so a form
    /// can offer them beside a free-text field instead of making somebody type
    /// `720` every time. Three things they are deliberately not:
    ///
    /// ```text
    /// not a closed set    any cutoff in the supported range is equally valid,
    ///                     and `.named` covers products with no single number
    /// not a calibration   there is no "720 nm matrix" in this project, and
    ///                     nothing here maps a number to any processing
    /// not a match key     nothing selects a profile, a preset or a transform
    ///                     by comparing wavelengths
    /// ```
    ///
    /// Ordered ascending, so a menu built from it is deterministic.
    public static let commonNominalCutoffsNanometers: [Double] = [590, 665, 720, 830]

    /// A long-pass filter, refusing a nominal cutoff that cannot describe one.
    ///
    /// Deliberately labelled differently from the case it builds. An overload
    /// that differed from the case's implicit factory only by `throws` would be
    /// ambiguous at every call site, and the one that silently won would be the
    /// one that validates nothing.
    ///
    /// - Throws: `IRCaptureProfileDescriptorError.invalidNominalCutoff`.
    public static func longPass(
        nominalNanometers nanometers: Double
    ) throws -> IRFilterDescriptor {
        guard nanometers.isFinite else {
            throw IRCaptureProfileDescriptorError.invalidNominalCutoff(
                nanometers: nanometers,
                reason: "A nominal cutoff must be a finite number of nanometres."
            )
        }
        guard supportedNominalCutoffNanometers.contains(nanometers) else {
            throw IRCaptureProfileDescriptorError.invalidNominalCutoff(
                nanometers: nanometers,
                reason: """
                    A nominal cutoff is expected between \
                    \(supportedNominalCutoffNanometers.lowerBound) and \
                    \(supportedNominalCutoffNanometers.upperBound) nanometres.
                    """
            )
        }
        return .longPass(nominalCutoffNanometers: nanometers)
    }

    /// The nominal cutoff, for the one case that has one.
    public var nominalCutoffNanometers: Double? {
        guard case .longPass(let nanometers) = self else { return nil }
        return nanometers
    }

    /// Whether anything at all is recorded about the filter.
    public var isKnown: Bool { self != .unknown }

    /// A label for the inspector. Worded so that the nominal wavelength cannot
    /// be read as a measurement of this photograph.
    public var shortDescription: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .longPass(let nanometers):
            return "\(Self.format(nanometers)) nm nominal long-pass"
        case .named(let name):
            return name
        }
    }

    /// A longer label for diagnostics and provenance reports.
    public var diagnosticDescription: String {
        switch self {
        case .unknown:
            return "unknown filter (none recorded)"
        case .longPass(let nanometers):
            return """
                \(Self.format(nanometers)) nm nominal long-pass filter \
                (a family label, not a measured spectral response)
                """
        case .named(let name):
            return "filter named \"\(name)\" (identity only; no spectral data)"
        }
    }

    private static func format(_ nanometers: Double) -> String {
        nanometers == nanometers.rounded()
            ? String(Int(nanometers))
            : String(format: "%.1f", nanometers)
    }
}

/// Why a descriptive part of a capture profile could not be built.
///
/// Small on purpose, and separate from `IRCaptureProfileError`: these are
/// value-level refusals from the descriptor types, not failures to resolve or
/// apply a profile.
public enum IRCaptureProfileDescriptorError: Error, Equatable {
    /// A nominal filter cutoff that could not describe a real filter.
    case invalidNominalCutoff(nanometers: Double, reason: String)
}

extension IRCaptureProfileDescriptorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidNominalCutoff:
            return "That is not a usable nominal filter cutoff."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidNominalCutoff(let nanometers, let reason):
            return "\(nanometers): \(reason)"
        }
    }
}
