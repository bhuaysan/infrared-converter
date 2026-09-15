import Foundation

/// The nine text fields of the creative channel-mix editor, while they are
/// being typed.
///
/// ## Why text, and why a type of its own
///
/// `UserChannelMixAdjustment.explicit` carries a `RAWColorMatrix3x3`, whose
/// contract is that every coefficient is a finite `Double`. Half-typed text is
/// not that. `-`, `.`, `1e`, and an empty field are all states a person passes
/// through on the way to a number, and none of them is a coefficient:
///
/// ```text
/// ""      not a number        the field is empty
/// "-"     not a number        a negative coefficient, first keystroke
/// "1e"    not a number        an exponent, half typed
/// "1.5"   a coefficient
/// "inf"   a number, not finite — refused by the matrix, not by this type
/// ```
///
/// Binding a `TextField` directly to a `Double` would resolve each of those to
/// something — zero, most likely — and write it into the canonical adjustment,
/// so a user clearing a field to retype it would silently render a different
/// matrix. This type holds the strings instead, and produces an adjustment
/// only when there is one to produce. The canonical state is never replaced by
/// an editing state.
///
/// ## It is not a second matrix type
///
/// Nothing here stores coefficients, mixes anything, or knows what the working
/// colour space is. It parses text and hands the numbers to
/// `RAWColorMatrix3x3` — the project's one matrix — which is what refuses a
/// value that is not finite. There is exactly one creative-mix value type
/// (`IRChannelMix`), one user state (`UserChannelMixAdjustment`) and one
/// implementation (`IRChannelMixer`); this is a keyboard, not a fourth
/// authority.
///
/// ## Convention: rows are outputs
///
/// Addressed by output and input channel rather than by a flat index, so that
/// the editor cannot transpose the matrix by mistake:
///
/// ```text
/// Rout = m00·R + m01·G + m02·B      draft[output: .red,   input: .green] is m01
/// Gout = m10·R + m11·G + m12·B
/// Bout = m20·R + m21·G + m22·B
/// ```
///
/// ## What it deliberately does not do
///
/// No clamping, no row normalisation, no luminance preservation, no rejection
/// of a singular or colour-collapsing matrix. Negative coefficients,
/// coefficients above one, rows that do not sum to one and matrices with a
/// zero determinant are all legitimate creative mixes (ADR 0007), and a
/// creative editor that quietly repaired them would be authoring a matrix the
/// user did not type.
struct ChannelMixMatrixDraft: Equatable {

    /// The three channels, in the order the matrix's rows and columns are in.
    static let channels: [RAWLinearRGBChannel] = [.red, .green, .blue]

    /// Nine strings, row-major: the row is the output channel.
    private var texts: [String]

    /// Seeds the fields from the matrix the adjustment currently applies —
    /// including a built-in's, so that "Custom Matrix…" opens on the mix in
    /// force rather than on an unrelated identity.
    init(_ adjustment: UserChannelMixAdjustment) {
        self.init(matrix: adjustment.matrix)
    }

    init(matrix: RAWColorMatrix3x3) {
        texts = matrix.rows.flatMap { $0.map(Self.text(for:)) }
    }

    /// The text of one field.
    subscript(output output: RAWLinearRGBChannel, input input: RAWLinearRGBChannel) -> String {
        get { texts[Self.index(output: output, input: input)] }
        set { texts[Self.index(output: output, input: input)] = newValue }
    }

    private static func index(
        output: RAWLinearRGBChannel, input: RAWLinearRGBChannel
    ) -> Int {
        output.storageOffset * RAWColorMatrix3x3.dimension + input.storageOffset
    }

    /// The number a field currently holds, or `nil` if its text is not a
    /// number at all.
    ///
    /// Parsing is `Double`'s own, on the trimmed text, so `1.5`, `-2`, `1e-3`
    /// and `1.` are numbers and `""`, `-`, `,` and `1,5` are not. A decimal
    /// comma is deliberately not accepted: guessing a locale's separator would
    /// make `1,5` mean one value on one machine and nothing on another.
    func number(output: RAWLinearRGBChannel, input: RAWLinearRGBChannel) -> Double? {
        Double(self[output: output, input: input].trimmingCharacters(in: .whitespaces))
    }

    /// Whether a field holds a value the matrix would accept.
    ///
    /// `false` both for text that is not a number and for a number that is not
    /// finite — `inf`, `nan` and an overflowing literal such as `1e400`. The
    /// editor marks such a field; the refusal itself is the matrix's.
    func isCoefficient(output: RAWLinearRGBChannel, input: RAWLinearRGBChannel) -> Bool {
        number(output: output, input: input)?.isFinite ?? false
    }

    /// Whether every field holds a number — finite or not.
    ///
    /// This is what decides whether there is anything to commit. A draft that
    /// is complete but holds `inf` is committed and **refused**, with the
    /// matrix's own typed error, rather than being silently uncommittable: a
    /// person who typed `inf` deserves to be told why, not to look at a
    /// greyed-out button.
    var isComplete: Bool {
        Self.channels.allSatisfy { output in
            Self.channels.allSatisfy { input in
                number(output: output, input: input) != nil
            }
        }
    }

    /// The fields whose text is not a finite coefficient, as output/input
    /// pairs — what the editor marks.
    var invalidFields: [(output: RAWLinearRGBChannel, input: RAWLinearRGBChannel)] {
        Self.channels.flatMap { output in
            Self.channels.compactMap { input in
                isCoefficient(output: output, input: input)
                    ? nil
                    : (output: output, input: input)
            }
        }
    }

    /// The adjustment these nine fields describe.
    ///
    /// `nil` while any field is not yet a number — the editing state, which
    /// replaces nothing. Otherwise `.explicit`, built through
    /// `RAWColorMatrix3x3`'s own validating initialiser, which throws
    /// `RAWProcessingError.invalidColorMatrix3x3` for a coefficient that is
    /// not finite.
    ///
    /// Always `.explicit`, even when the nine numbers happen to be the
    /// identity or the red/blue swap. A typed matrix is a matrix the person
    /// authored, and collapsing it into a built-in would rewrite their
    /// provenance — the same rule the persisted format enforces in both
    /// directions (ADR 0016, Decision 6).
    func adjustment() throws -> UserChannelMixAdjustment? {
        var coefficients = [Double]()
        for output in Self.channels {
            for input in Self.channels {
                guard let value = number(output: output, input: input) else { return nil }
                coefficients.append(value)
            }
        }
        return .explicit(
            try RAWColorMatrix3x3(
                m00: coefficients[0], m01: coefficients[1], m02: coefficients[2],
                m10: coefficients[3], m11: coefficients[4], m12: coefficients[5],
                m20: coefficients[6], m21: coefficients[7], m22: coefficients[8]
            )
        )
    }

    /// How a coefficient is written into a field.
    ///
    /// Shortest exact form: an integral value loses its `.0` and everything
    /// else uses `Double`'s own round-tripping description, so opening the
    /// editor on a saved matrix and pressing Apply commits the same nine
    /// numbers rather than a rounded copy of them.
    static func text(for value: Double) -> String {
        guard value.isFinite else { return String(value) }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// The channel's letter, for the editor's row and column headings.
    static func label(for channel: RAWLinearRGBChannel) -> String {
        String(channel.colorDescriptionLetter)
    }
}
