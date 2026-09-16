import Foundation

/// The three text fields of the monochrome channel-mix editor, while they are
/// being typed.
///
/// ## Why text, for the same reason the matrix editor uses it
///
/// A coefficient is a finite `Double`; half-typed text is not one. `-`, `.`,
/// `1e` and an empty field are all states a person passes through on the way
/// to a number:
///
/// ```text
/// ""      not a number        the field is empty
/// "-"     not a number        a negative contribution, first keystroke
/// "1e"    not a number        an exponent, half typed
/// "-0.5"  a coefficient
/// "inf"   a number, not finite — refused by the matrix, not by this type
/// ```
///
/// A `TextField` bound to a `Double` would resolve each of those to something,
/// most likely zero, and write it into the canonical adjustment — so clearing
/// a field to retype it would silently render a different image. This holds
/// the strings, and produces an adjustment only when there is one to produce.
/// The canonical state is never replaced by an editing state, and nothing here
/// is persisted.
///
/// ## It is not a second monochrome model
///
/// It parses three strings and hands them to `IRMonochromeMix`, which builds
/// the one matrix type, which becomes the one persisted adjustment. There is
/// no monochrome adjustment, no monochrome image and no monochrome sidecar
/// field for this to be the editing form of — it is a keyboard in front of
/// `UserChannelMixAdjustment.explicit`.
///
/// ## What it deliberately does not do
///
/// No clamping to `0…1`, no requirement that the three sum to one, no
/// automatic normalisation and no rejection of a negative contribution. Those
/// are all legitimate creative infrared authoring decisions (ADR 0007), and an
/// editor that quietly repaired them would author a mix the user did not type.
/// The only numeric rule is the matrix primitive's own — every coefficient
/// finite — and it is enforced there.
struct MonochromeMixDraft: Equatable {

    /// The three input channels, in the order the editor shows them and the
    /// order the matrix's columns are in.
    static let channels: [RAWLinearRGBChannel] = [.red, .green, .blue]

    /// Three strings, indexed by the channel's position in one interleaved
    /// `R G B` pixel.
    private var texts: [String]

    /// Seeds the fields from three coefficients.
    init(_ mix: IRMonochromeMix) {
        texts = Self.channels.map { channel in
            // The matrix editor's own formatter, so a coefficient that
            // round-trips through one editor round-trips through the other.
            ChannelMixMatrixDraft.text(for: mix.contribution(of: channel))
        }
    }

    /// Seeds the fields from the mix in force.
    ///
    /// When that mix is already monochrome — three identical matrix rows,
    /// however it was authored — its coefficients are recovered exactly.
    /// Otherwise the editor starts at `Equal RGB`: there is no meaningful way
    /// to read three monochrome contributions out of an arbitrary colour
    /// matrix, and inventing them would put numbers in front of a person that
    /// describe nothing they chose.
    init(seeding adjustment: UserChannelMixAdjustment) {
        self.init(IRMonochromeMix(recognising: adjustment) ?? .equalRGB)
    }

    /// The text of one field.
    subscript(contribution channel: RAWLinearRGBChannel) -> String {
        get { texts[channel.storageOffset] }
        set { texts[channel.storageOffset] = newValue }
    }

    /// The number a field currently holds, or `nil` if its text is not a
    /// number at all.
    ///
    /// Parsing is `Double`'s own, on the trimmed text, exactly as the matrix
    /// editor parses: `1.5`, `-2`, `1e-3` and `1.` are numbers, and `""`,
    /// `-`, `,` and `1,5` are not. A decimal comma is deliberately not
    /// accepted, for the reason `ChannelMixMatrixDraft` gives.
    func number(_ channel: RAWLinearRGBChannel) -> Double? {
        Double(self[contribution: channel].trimmingCharacters(in: .whitespaces))
    }

    /// Whether a field holds a value the matrix would accept: a number, and a
    /// finite one. The editor marks a field that does not; the refusal itself
    /// belongs to `RAWColorMatrix3x3`.
    func isCoefficient(_ channel: RAWLinearRGBChannel) -> Bool {
        number(channel)?.isFinite ?? false
    }

    /// Whether all three fields hold a number — finite or not.
    ///
    /// This decides whether there is anything to commit. A complete draft
    /// holding `inf` is committed and **refused**, with the matrix's own typed
    /// error, rather than being silently uncommittable: a person who typed
    /// `inf` deserves to be told why.
    var isComplete: Bool {
        Self.channels.allSatisfy { number($0) != nil }
    }

    /// The channels whose text is not a finite coefficient — what the editor
    /// marks.
    var invalidFields: [RAWLinearRGBChannel] {
        Self.channels.filter { !isCoefficient($0) }
    }

    /// The three contributions these fields describe, or `nil` while any of
    /// them is not yet a number.
    ///
    /// No clamping, no normalisation: the numbers are the ones typed.
    func monochromeMix() -> IRMonochromeMix? {
        guard let red = number(.red),
              let green = number(.green),
              let blue = number(.blue)
        else { return nil }
        return IRMonochromeMix(red: red, green: green, blue: blue)
    }

    /// The adjustment these three fields author.
    ///
    /// `nil` while any field is not yet a number — the editing state, which
    /// replaces nothing. Otherwise `.explicit`, built through
    /// `RAWColorMatrix3x3`'s validating initialiser, which throws
    /// `RAWProcessingError.invalidColorMatrix3x3` for a coefficient that is
    /// not finite.
    ///
    /// Always `.explicit`, even when the resulting nine numbers happen to
    /// match a built-in. Collapsing an authored matrix into a built-in would
    /// rewrite the person's provenance — the rule the matrix editor and the
    /// persisted format both keep (ADR 0016, Decision 6).
    func adjustment() throws -> UserChannelMixAdjustment? {
        guard let mix = monochromeMix() else { return nil }
        return try mix.adjustment()
    }

    /// The channel's letter, for the editor's field labels. The matrix
    /// editor's, so both editors name a channel the same way.
    static func label(for channel: RAWLinearRGBChannel) -> String {
        ChannelMixMatrixDraft.label(for: channel)
    }

    /// The word the editor uses for a channel in a field label.
    static func name(for channel: RAWLinearRGBChannel) -> String {
        switch channel {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}
