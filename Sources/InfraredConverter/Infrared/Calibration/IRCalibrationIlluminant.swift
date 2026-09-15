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

    /// The recorded identity, compactly and unambiguously.
    ///
    /// Distinct from ``shortDescription``, which is a label: `.d65` and
    /// `.namedOther("D65")` both read as "D65" there, and the whole point of a
    /// compatibility refusal is to say which of the two a record carries. Used
    /// in the typed errors, where a person is holding two artefacts that will
    /// not go together and the useful question is what each of them actually
    /// says.
    public var identityDescription: String {
        switch self {
        case .d65: return "D65, asserted"
        case .d50: return "D50, asserted"
        case .namedOther(let name): return "the source named \"\(name)\""
        case .measuredSPD(let reference): return "the measured SPD recorded at \"\(reference)\""
        case .unknown: return "an illuminant nobody recorded"
        }
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

// MARK: - Validating a recorded identity

extension IRCalibrationIlluminant {

    /// The one place an illuminant's recorded identity is checked and
    /// normalised, and the only shape in which one enters a calibration
    /// artefact.
    ///
    /// ``IRCalibrationMeasurementSet`` and ``IRCalibrationReferenceDataset``
    /// are the two domain boundaries that create calibration evidence, and
    /// both call this in their initialisers. Decoding a persisted record goes
    /// through those same initialisers, so a file cannot carry an illuminant
    /// that could not have been constructed in memory — there is no second
    /// validation on the persistence path, and deliberately so.
    ///
    /// ## What it refuses
    ///
    /// The two cases carrying text carry the *entire* identity of the
    /// illuminant in that text. `.namedOther("")` and
    /// `.measuredSPD(reference: "   ")` are records that say nothing while
    /// occupying the place where the experiment's illumination is supposed to
    /// be described, and an empty `.measuredSPD` is worse than merely useless:
    /// ``isMeasured`` would report `true` for it, so it would satisfy the one
    /// illuminant condition ``IRCalibrationAcceptanceCriteria`` can require
    /// while pointing at no measurement at all.
    ///
    /// ## What it normalises
    ///
    /// Outer whitespace, and nothing else — the same trimming
    /// ``IRCalibrationReferenceDataset`` and ``IRCalibrationProvenance``
    /// already apply to the text a person types. After trimming, the identity
    /// is **exact and case-sensitive**: `"LED Panel A"` and `"led panel a"`
    /// are two different records. These are evidence identifiers rather than
    /// search terms, and case folding them would be a matching rule this
    /// project has no basis for — the person who wrote one of the two meant
    /// what they wrote.
    ///
    /// `.d65`, `.d50` and `.unknown` carry no text and are returned unchanged.
    /// Normalisation is idempotent, so re-validating an already-validated
    /// value — which ``IRCalibrationMeasurementSet/excluding(_:because:)``
    /// does — changes nothing.
    public func validated(field: String) throws(IRCalibrationError) -> IRCalibrationIlluminant {
        switch self {
        case .d65, .d50, .unknown:
            return self

        case .namedOther(let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw .missingRequiredField(
                    field: "\(field).name",
                    reason: """
                        A named illuminant is named by that text and by nothing else, so an \
                        empty one records that somebody chose to describe the illumination \
                        and then described none of it. Either name the source or record it \
                        as unknown, which is an honest answer the status rules already \
                        account for.
                        """
                )
            }
            return .namedOther(name)

        case .measuredSPD(let reference):
            let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reference.isEmpty else {
                throw .missingRequiredField(
                    field: "\(field).reference",
                    reason: """
                        A measured SPD is carried here by reference — a file, an instrument \
                        reading, a document — because nothing in this project consumes a \
                        spectrum. An empty reference points at no measurement while still \
                        reporting itself as measured illumination, which is the strongest \
                        claim this type can make and the one least able to survive it.
                        """
                )
            }
            return .measuredSPD(reference: reference)
        }
    }
}
