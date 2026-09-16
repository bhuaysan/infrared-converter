import Foundation

/// Three contribution coefficients that author a **monochrome** creative
/// channel mix: one weighted sum of the working RGB channels, written to all
/// three output channels.
///
/// ## Monochrome is not a stage
///
/// Nothing in the pipeline knows this type exists. It builds a
/// `RAWColorMatrix3x3` whose three rows are identical, and that matrix runs
/// through `IRChannelMixer` exactly as any other creative mix does:
///
/// ```text
///          ⎡ r g b ⎤   ⎡ R ⎤       Rout = r·R + g·G + b·B
/// output = ⎢ r g b ⎥ × ⎢ G ⎥  so   Gout = r·R + g·G + b·B
///          ⎣ r g b ⎦   ⎣ B ⎦       Bout = r·R + g·G + b·B
/// ```
///
/// Because the rows are identical, every output channel receives the same
/// scene-linear value, which is what makes the result achromatic. That is an
/// arithmetic consequence of the nine coefficients, not a mode the renderer is
/// put into — there is no monochrome stage, no monochrome image type, no
/// monochrome provenance and no monochrome persisted field. A photograph
/// developed through this helper is indistinguishable, in everything that is
/// stored or rendered, from one where the same nine numbers were typed into
/// the 3×3 matrix editor. See
/// `docs/decisions/0025-monochrome-channel-mix-authoring.md`.
///
/// ## Authoring convenience, in both directions
///
/// Its whole responsibility is the translation between three coefficients and
/// nine, and back:
///
/// ```text
/// matrix()                 (r, g, b)  →  three identical rows
/// init?(recognising:)      three identical rows  →  (r, g, b)
/// ```
///
/// Recognition is what lets the editor open on the mix already in force,
/// whoever produced it — the matrix editor, a sidecar, a creative preset. It
/// asks the matrix what its coefficients are and nothing else, so there is no
/// provenance to consult and nothing to get wrong.
///
/// ## Double, like the matrix
///
/// Coefficients are `Double` because `RAWColorMatrix3x3`'s are, and this type
/// exists to produce one. Narrowing to `Float` here would mean a matrix
/// recognised and immediately re-authored could come back with different
/// numbers. The per-pixel arithmetic narrows where it always did, inside
/// `IRChannelMixer`.
///
/// ## What is deliberately absent
///
/// No normalisation, no clamping, no positivity requirement and no
/// brightness correction. `r + g + b` may be anything at all; negative
/// contributions and contributions above one are ordinary infrared authoring
/// decisions, and the only numeric rule is the matrix primitive's own — every
/// coefficient finite — enforced by `RAWColorMatrix3x3` at construction rather
/// than restated here (ADR 0007, ADR 0023).
///
/// None of the starting points below is a luminance formula, and no
/// coefficient here is derived from a filter, a wavelength or a camera.
struct IRMonochromeMix: Equatable, Sendable {

    /// How much input **red** contributes to the single output value.
    let red: Double
    /// How much input **green** contributes.
    let green: Double
    /// How much input **blue** contributes.
    let blue: Double

    /// Takes the three coefficients as given.
    ///
    /// Unvalidated on purpose: finiteness is `RAWColorMatrix3x3`'s contract
    /// and is enforced where the matrix is built, so this type has no second,
    /// competing numeric rule. A non-finite coefficient here simply cannot
    /// produce a matrix.
    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// One coefficient by input channel.
    func contribution(of channel: RAWLinearRGBChannel) -> Double {
        switch channel {
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }

    // MARK: - Three coefficients to nine

    /// The 3×3 matrix these three coefficients describe: the same row, three
    /// times.
    ///
    /// - Throws: `RAWProcessingError.invalidColorMatrix3x3` for a coefficient
    ///   that is not finite — the matrix primitive's own refusal, naming the
    ///   row and column, rather than a rule this type restates.
    func matrix() throws -> RAWColorMatrix3x3 {
        try RAWColorMatrix3x3(
            m00: red, m01: green, m02: blue,
            m10: red, m11: green, m12: blue,
            m20: red, m21: green, m22: blue
        )
    }

    /// The canonical user adjustment these coefficients author.
    ///
    /// Always `.explicit`, never a built-in and never a case of its own: the
    /// persisted decision is the nine coefficients, and nothing records that a
    /// person reached them through the monochrome editor rather than by typing
    /// them.
    func adjustment() throws -> UserChannelMixAdjustment {
        .explicit(try matrix())
    }

    // MARK: - Nine coefficients back to three

    /// Recovers the three contributions from a matrix whose rows are
    /// identical, or `nil` when they are not.
    ///
    /// Equality is `Double`'s own, on the stored coefficients, exactly as
    /// `RAWColorMatrix3x3.isIdentity` compares. There is deliberately no
    /// tolerance: an epsilon would let a colour transform whose rows merely
    /// resemble each other be reopened as monochrome and then rewritten as
    /// something the person never authored. `-0.0` and `+0.0` compare equal,
    /// which is the same treatment every other coefficient comparison in the
    /// project gives them.
    init?(recognising matrix: RAWColorMatrix3x3) {
        guard matrix.m00 == matrix.m10, matrix.m10 == matrix.m20,
              matrix.m01 == matrix.m11, matrix.m11 == matrix.m21,
              matrix.m02 == matrix.m12, matrix.m12 == matrix.m22
        else { return nil }
        self.init(red: matrix.m00, green: matrix.m01, blue: matrix.m02)
    }

    /// Recovers the three contributions from the matrix an adjustment applies,
    /// whatever produced it — the matrix editor, a sidecar, a creative preset.
    ///
    /// Neither built-in is monochrome: the identity's rows are three different
    /// rows, and so are the red/blue swap's. So this answers `nil` for both
    /// without special-casing either, which is the point of reading the matrix
    /// rather than the case.
    init?(recognising adjustment: UserChannelMixAdjustment) {
        self.init(recognising: adjustment.matrix)
    }

    // MARK: - Starting points

    /// Equal contribution from each channel: the arithmetic mean of the three
    /// working RGB values, `(R + G + B) / 3`.
    ///
    /// **Not** a luminance. It is not Rec. 709, Rec. 601 or any other
    /// visible-light weighting, and it is not perceptual, brightness-corrected
    /// or "natural". This application develops infrared false colour, whose
    /// channels do not carry the visible-light meanings such formulae are
    /// defined against, so an equal mean is offered as what it arithmetically
    /// is and nothing more.
    static let equalRGB = IRMonochromeMix(
        red: 1.0 / 3.0, green: 1.0 / 3.0, blue: 1.0 / 3.0
    )

    /// The working red channel alone.
    static let redOnly = IRMonochromeMix(red: 1, green: 0, blue: 0)

    /// The working green channel alone.
    static let greenOnly = IRMonochromeMix(red: 0, green: 1, blue: 0)

    /// The working blue channel alone.
    static let blueOnly = IRMonochromeMix(red: 0, green: 0, blue: 1)

    /// A named starting point the editor offers as a button.
    struct StartingPoint: Equatable, Sendable, Identifiable {
        /// What the button says. Also its identity — these are four fixed
        /// constants, not user data, so there is no identifier to generate.
        let name: String
        let mix: IRMonochromeMix

        var id: String { name }
    }

    /// The four starting points, in the order the editor offers them.
    ///
    /// Authoring shortcuts and nothing else: no wavelength, filter, camera or
    /// capture profile selects among them, and none of them is applied
    /// automatically.
    static let startingPoints: [StartingPoint] = [
        StartingPoint(name: "Equal RGB", mix: .equalRGB),
        StartingPoint(name: "Red Only", mix: .redOnly),
        StartingPoint(name: "Green Only", mix: .greenOnly),
        StartingPoint(name: "Blue Only", mix: .blueOnly),
    ]

    /// How the mix reads in a diagnostic, worded so that it cannot be taken
    /// for a colorimetric claim.
    var diagnosticDescription: String {
        "monochrome authoring mix: \(red)·R + \(green)·G + \(blue)·B, written to all "
            + "three output channels (creative; no luminance or calibration claim)"
    }
}
