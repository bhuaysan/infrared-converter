import Foundation

/// The per-colour-plane gains a calibration session's white balance defines.
///
/// ```text
/// unbalanced                  every plane keeps a gain of exactly 1
/// neutralPatch(<patch>)       every plane the neutral reference measured has a gain
/// ```
///
/// ## Why this is a type rather than a dictionary
///
/// The two cases look identical when they are both `[Int: Double]`: an
/// unbalanced session is an empty dictionary, and a balanced session is a
/// dictionary that happens to contain the planes the neutral patch measured.
/// A lookup of the form `gains[plane] ?? 1` then reads correctly in one case
/// and silently wrongly in the other — a plane the neutral reference did not
/// measure is left unbalanced while every other plane is scaled, and nothing
/// says so.
///
/// Carrying the basis makes the two distinguishable at the point of use.
/// Under ``Basis/unbalanced`` a gain of `1` is the answer, stated rather than
/// defaulted. Under ``Basis/neutralPatch(_:)`` a missing gain is a refusal,
/// because the session asserted a white balance and this plane is not in it.
///
/// See `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`.
public struct IRCalibrationSessionGains: Equatable, Sendable {

    public enum Basis: Equatable, Sendable {

        /// No session white balance: the fit reads the camera's raw normalised
        /// responses, and a gain of `1` is semantically correct for every
        /// plane.
        case unbalanced

        /// Gains derived from one named neutral patch of the target.
        case neutralPatch(IRCalibrationTargetPatchID)
    }

    public let basis: Basis

    /// The gain for each colour plane the neutral reference measured. Empty
    /// under ``Basis/unbalanced``.
    public let byColorPlane: [Int: Double]

    /// No session white balance.
    public static let unbalanced = IRCalibrationSessionGains(
        basis: .unbalanced, byColorPlane: [:]
    )

    init(neutralPatch: IRCalibrationTargetPatchID, byColorPlane: [Int: Double]) {
        self.init(basis: .neutralPatch(neutralPatch), byColorPlane: byColorPlane)
    }

    private init(basis: Basis, byColorPlane: [Int: Double]) {
        self.basis = basis
        self.byColorPlane = byColorPlane
    }

    public var isUnbalanced: Bool { basis == .unbalanced }

    public var neutralPatch: IRCalibrationTargetPatchID? {
        guard case .neutralPatch(let patch) = basis else { return nil }
        return patch
    }

    /// The gain to apply to one colour plane of one patch, or a refusal.
    ///
    /// Never a silent `1`: under an active neutral-patch policy a plane with
    /// no gain is a plane the session's white balance does not cover, and
    /// leaving it at unity would produce a transform balanced in two of its
    /// channels and not in the third.
    func gain(
        forColorPlane plane: Int, of patch: IRCalibrationTargetPatchID
    ) throws(IRCalibrationFitError) -> Double {
        switch basis {
        case .unbalanced:
            return 1
        case .neutralPatch(let neutral):
            guard let gain = byColorPlane[plane] else {
                throw .missingWhiteBalanceGain(
                    patch: patch.rawValue, colorPlane: plane, neutralPatch: neutral.rawValue
                )
            }
            return gain
        }
    }

    public var diagnosticDescription: String {
        switch basis {
        case .unbalanced:
            return "no session white balance; every plane at gain 1"
        case .neutralPatch(let patch):
            let planes = byColorPlane.keys.sorted()
                .map { "\($0): \(String(format: "%.4f", byColorPlane[$0] ?? 0))" }
                .joined(separator: ", ")
            return "gains from neutral patch \"\(patch)\" — \(planes)"
        }
    }
}
