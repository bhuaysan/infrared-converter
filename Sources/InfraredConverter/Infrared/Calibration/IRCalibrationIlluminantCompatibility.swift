import Foundation

/// The one rule by which a measurement illuminant and a reference illuminant
/// are judged to describe the same recorded illumination.
///
/// ## Why this is a rule and not an `==` at three call sites
///
/// A calibration pairs two things that were decided separately: evidence
/// recorded under whatever was lighting the chart, and reference values
/// somebody defined under some illuminant of their own. Both artefacts carry an
/// ``IRCalibrationIlluminant``, and until this type existed nothing held the
/// two against each other — a fit could aim measurements made under a tungsten
/// lamp at values defined for D65 and report small residuals about it.
///
/// The rule has to hold in three places — the fitter, the calibration
/// artefact's initialiser and the fit verifier — and the one thing that must
/// not happen is three slightly different versions of it. So the rule lives
/// here, each layer asks this type and throws its own typed refusal, and the
/// explanation a person reads is written once.
///
/// ## The rule
///
/// > Two calibration illuminants are compatible only when their **recorded
/// > identity** is exactly the same.
///
/// ```text
/// .d65              ↔ .d65                      compatible
/// .d50              ↔ .d50                      compatible
/// .namedOther("X")  ↔ .namedOther("X")          compatible
/// .measuredSPD("X") ↔ .measuredSPD("X")         compatible
/// .unknown          ↔ .unknown                  compatible, structurally
///
/// .d65              ↔ .d50                      refused
/// .d65              ↔ .measuredSPD("d65.spd")   refused
/// .namedOther("A")  ↔ .namedOther("B")          refused
/// .measuredSPD("A") ↔ .measuredSPD("B")         refused
/// .unknown          ↔ anything recorded         refused
/// ```
///
/// ## What "same recorded identity" is not
///
/// It is **not** a claim that the two are physically the same light. Two
/// records saying "LED panel A" are two people's words, and this project has
/// no way to check them. What the rule guarantees is narrower and worth
/// exactly what it says: nothing here pairs evidence with reference values
/// that *state* different illumination.
///
/// The converse matters more, because it is the failure being prevented. This
/// project does not read spectral power distributions and compares none, so it
/// cannot show that a measured SPD is D65, that two differently named lamps
/// match, or that one standard illuminant approximates another. A file called
/// `d65-measurement.csv` proves nothing about its contents; a lamp named
/// "Daylight LED" is a name. Inferring equivalence from any of that would be
/// inventing a spectral comparison the project has not performed, which is the
/// class of false confidence this whole subsystem exists to prevent.
///
/// ## Why `.unknown ↔ .unknown` is allowed through
///
/// Not because two unrecorded illuminants are known to match — they are not
/// known to be anything. It is allowed because refusing it would stop somebody
/// fitting a transform to data they already have, and the arithmetic is
/// perfectly well defined on it. What such a calibration may *claim* is a
/// separate question already answered elsewhere: `.unknown` produces the
/// ``IRCalibrationEvidenceGap/illuminantUnknown`` gap, so the artefact's status
/// is `.experimental` and stays there. It is constructible, and it is not
/// evidence of anything holding under any particular light.
///
/// Nothing derives a standard illuminant from `.unknown`, in either direction.
public enum IRCalibrationIlluminantCompatibility {

    /// Whether evidence recorded under `measurement` may be fitted against
    /// reference values defined for `reference`.
    ///
    /// Exact identity, and deliberately nothing cleverer. The text of
    /// ``IRCalibrationIlluminant/namedOther(_:)`` and
    /// ``IRCalibrationIlluminant/measuredSPD(reference:)`` is normalised once,
    /// where evidence is constructed — see
    /// ``IRCalibrationIlluminant/validated(field:)`` — so the comparison here
    /// is between two already-normalised identities and needs no trimming,
    /// case folding or matching rules of its own. These are evidence
    /// identifiers, not search terms.
    public static func areCompatible(
        measurement: IRCalibrationIlluminant, reference: IRCalibrationIlluminant
    ) -> Bool {
        measurement == reference
    }

    /// The explanation every layer's refusal carries, written once.
    ///
    /// Takes the two ``IRCalibrationIlluminant/identityDescription`` strings
    /// rather than the illuminants themselves, so that a typed error can store
    /// what it reports and still be `Equatable`.
    public static func refusalReason(measurement: String, reference: String) -> String {
        """
        The measurements were recorded under \(measurement) and the reference values are \
        defined for \(reference). An infrared response is the product of the source's \
        spectrum and the sensor's sensitivity beyond the filter's cutoff, and daylight, \
        tungsten and an LED panel differ there far more than they do in the visible — one \
        source may emit almost nothing above 700 nm where another emits copiously. \
        Reference values defined under one illuminant therefore do not describe what a \
        camera records under another. This project reads no spectral power distributions \
        and compares none, so it infers no equivalence between differently recorded \
        sources: a file named after a standard illuminant is not that illuminant, and two \
        lamps with different names are two lamps. Two calibration illuminants are \
        compatible here only when their recorded identity is exactly the same — which is \
        a statement about the record, not a proof that two spectra are identical.
        """
    }
}
