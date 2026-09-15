import Foundation

/// The representation reference values are expressed in.
///
/// One case, and it is the project's working representation: a calibration
/// transform's codomain is where the pipeline's camera-to-working stage
/// delivers, so a reference expressed anywhere else would be fitted in the
/// wrong space. See `docs/decisions/0006-working-color-space.md`.
public enum IRCalibrationReferenceColorSpace: String, Equatable, Sendable, Codable {

    /// sRGB primaries, D65 white point, **linear** transfer function, Float32,
    /// no clipping to `0...1`.
    ///
    /// Linear is not negotiable. Fitting a matrix to gamma-encoded numbers
    /// fits it to the encoding rather than to the light, and the result is not
    /// a linear transform of anything.
    case extendedLinearSRGB

    public var displayName: String {
        switch self {
        case .extendedLinearSRGB: return "Extended linear sRGB"
        }
    }
}

/// One reference value: the linear RGB a patch is supposed to become.
public struct IRCalibrationReferenceRGB: Equatable, Sendable {

    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) throws(IRCalibrationError) {
        for (name, value) in [("red", red), ("green", green), ("blue", blue)] {
            guard value.isFinite else {
                throw .nonFiniteValue(field: "reference.\(name)", value: value)
            }
            guard value >= 0 else {
                throw .negativeValue(field: "reference.\(name)", value: value)
            }
        }
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var components: [Double] { [red, green, blue] }
}

/// The values a fit aims at, with the provenance that makes them checkable.
///
/// ```text
/// identifier   what dataset this is
/// version      which revision of it
/// source       where it came from, in words somebody can follow
/// colorSpace   the representation the values are in
/// illuminant   the illuminant the values are defined for
/// target       the chart the patch identifiers belong to
/// values       patch -> linear RGB
/// ```
///
/// ## The infrared caveat, stated where it cannot be missed
///
/// A visible-light colour target's published reference values are **not**
/// physical truth for an infrared capture. A ColorChecker patch's Lab value
/// describes how it reflects light a person can see. Behind a 720 nm long-pass
/// filter the camera is recording something else entirely, and two patches that
/// are visually very different can be nearly identical there.
///
/// So a reference dataset in this project is not "what the chart is". It is
/// **the rendering somebody decided those patches should produce** — a defined
/// false-colour target. That is a legitimate, useful and reproducible
/// objective, and it is not colour accuracy. The distinction is the whole
/// reason this type carries `source` and `version` rather than being a table of
/// constants somewhere in the code.
///
/// ## Why this project ships none
///
/// No reference dataset is bundled. There is no measured infrared reference for
/// any camera, conversion or filter here, and inventing one — or borrowing
/// visible-light values and calling them infrared reference — would manufacture
/// exactly the false confidence this subsystem exists to prevent. Tests
/// construct synthetic datasets and say so in their names. See
/// `docs/calibration-protocol.md` for what a real one has to contain.
public struct IRCalibrationReferenceDataset: Equatable, Sendable {

    public let identifier: String
    public let version: String
    public let source: String
    public let colorSpace: IRCalibrationReferenceColorSpace
    public let illuminant: IRCalibrationIlluminant
    public let target: IRCalibrationTarget
    public let values: [IRCalibrationTargetPatchID: IRCalibrationReferenceRGB]

    public init(
        identifier: String,
        version: String,
        source: String,
        colorSpace: IRCalibrationReferenceColorSpace = .extendedLinearSRGB,
        illuminant: IRCalibrationIlluminant,
        target: IRCalibrationTarget,
        values: [IRCalibrationTargetPatchID: IRCalibrationReferenceRGB]
    ) throws(IRCalibrationError) {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !identifier.isEmpty else {
            throw .missingRequiredField(
                field: "referenceDataset.identifier",
                reason: """
                    A fit's residuals are distances to these values, so a calibration has to \
                    be able to say which values it was fitted to.
                    """
            )
        }
        guard !version.isEmpty else {
            throw .missingRequiredField(
                field: "referenceDataset.version",
                reason: """
                    Reference values get corrected. Without a version, two calibrations \
                    fitted against different revisions of one dataset are indistinguishable.
                    """
            )
        }
        guard !source.isEmpty else {
            throw .missingRequiredField(
                field: "referenceDataset.source",
                reason: """
                    Reference values with no stated origin cannot be checked by anybody, and \
                    a calibration is only as reviewable as the numbers it aimed at.
                    """
            )
        }
        guard !values.isEmpty else { throw .emptyReferenceDataset }

        // The other domain boundary that creates calibration evidence — the
        // reference values are defined *under* an illuminant, and that
        // statement is as much a part of the dataset as the numbers. Checked
        // and normalised by the same rule the measurement set uses, so the two
        // identities a fit compares were produced the same way.
        let illuminant = try illuminant.validated(field: "referenceDataset.illuminant")

        for patch in values.keys.sorted() where !target.contains(patch) {
            throw .unknownTargetPatch(
                patch: patch.rawValue, target: target.displayName
            )
        }

        self.identifier = identifier
        self.version = version
        self.source = source
        self.colorSpace = colorSpace
        self.illuminant = illuminant
        self.target = target
        self.values = values
    }

    public var identity: String { "\(identifier)@\(version)" }

    public func value(
        for patch: IRCalibrationTargetPatchID
    ) -> IRCalibrationReferenceRGB? {
        values[patch]
    }

    public var patchIDs: [IRCalibrationTargetPatchID] { values.keys.sorted() }

    public var diagnosticDescription: String {
        """
        \(identity) — \(values.count) patches of \(target.displayName), \
        \(colorSpace.displayName), \(illuminant.diagnosticDescription), from \(source)
        """
    }
}
