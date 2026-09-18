import Foundation

/// The global contrast the **user** asked for, as one normalised amount.
///
/// ```text
/// UserContrastAdjustment      ← this type: an editing decision, validated and
///         │                     persisted
///         │  amount, unchanged
///         ↓
/// GlobalContrastCurve         the arithmetic, shared by preview and export
///         ↓
/// GlobalContrastApplier       x^k / (x^k + (1−x)^k), after levels and before
///                             the destination's range policy
/// ```
///
/// ## The amount is a control scale, not a physical quantity
///
/// `+0.35` does not mean "35 % more contrast", "35 % more slope" or "35 % more
/// luminance". It means one thing only, and it means it exactly:
///
/// ```text
/// k = 2^amount
/// ```
///
/// which is the exponent the curve is built from. `+1` gives `k = 2`, `−1`
/// gives `k = 0.5`, and `0` gives `k = 1`, which is the identity. Everything a
/// person can say about what the slider "does" follows from that one mapping,
/// and this type deliberately does not restate it — `GlobalContrastCurve` is
/// the only place `2^amount` is written.
///
/// The workspace slider shows `−100 … +100` because hundredths read better
/// than two decimal places; that is presentation, and it lives in
/// `ContrastControlScale`.
///
/// ## Why the bound is different in kind from the levels bounds
///
/// ```text
/// UserLevelsAdjustment     domain derived from IEEE 754 — what the arithmetic
///                          can represent, and nothing else
///
/// UserContrastAdjustment   domain is −1 … +1 by definition of the control
/// ```
///
/// The levels bounds had to be derived, because an affine remap is meaningful
/// for any ordered pair a person might mean and only the representability of
/// the span rules anything out. This is the opposite case. The curve evaluates
/// perfectly well at `k = 2^5`, so nothing about the arithmetic picks `±1` —
/// **the definition of the control does**. `amount ∈ [−1, +1]` is part of what
/// this adjustment *is*, in the way that "eight orientations" is part of what
/// an orientation adjustment is.
///
/// Stating it here rather than in a slider is what makes it a definition. A
/// value outside it is **refused**, never clamped: a clamp would render a
/// different photograph from the one the record describes, and nothing would
/// say so.
///
/// ## It performs no arithmetic
///
/// No `pow`, no `exp2`, no midpoint. The curve lives in
/// `GlobalContrastCurve`, which is the one authority on what this number does
/// to a pixel, for the preview and the export alike. See
/// `docs/decisions/0027-global-contrast-tone-curve.md`.
///
/// ## It is a state, not a history
///
/// Like every other adjustment: asking for a new amount replaces whatever was
/// asked for before. Applying `C2` after `C1` renders `C2(levelled)`, never
/// `C2(C1(levelled))` — the retained preview is upstream of this stage, so
/// there is nothing for a new decision to compose onto. Curves emphatically do
/// not compose into a curve of the same family, which is exactly why the
/// distinction is worth stating: `C1` then `C2` is not `C1 + C2`.
///
/// ## The value is kept exactly
///
/// Nothing here rounds. A control may quantise what it offers — the workspace
/// slider moves in hundredths — but the value the adjustment holds is the
/// decision that was made, and a hand-edited sidecar may hold a finer one.
public struct UserContrastAdjustment: Equatable, Sendable {

    /// The amounts a record may hold.
    ///
    /// Part of the control's definition rather than a limit discovered in the
    /// arithmetic; see the type's documentation.
    public static let supportedRange: ClosedRange<Double> = -1...1

    /// No contrast. The curve's exponent is `2^0 = 1`, which is the identity
    /// over the whole extended domain.
    public static let neutral = UserContrastAdjustment(validatedAmount: 0)

    /// The normalised contrast amount, in `−1 … +1`.
    public let amount: Double

    /// Validates an amount.
    ///
    /// - Throws: `ImageAdjustmentError.nonFiniteContrastAdjustment` for NaN or
    ///   an infinity, and `.contrastAdjustmentOutOfRange` for a finite value
    ///   outside `supportedRange`. Both name the value that was refused, and
    ///   neither clamps it.
    public init(amount: Double) throws {
        guard amount.isFinite else {
            throw ImageAdjustmentError.nonFiniteContrastAdjustment(amount: amount)
        }
        guard Self.supportedRange.contains(amount) else {
            throw ImageAdjustmentError.contrastAdjustmentOutOfRange(
                amount: amount, supported: Self.supportedRange
            )
        }
        self.amount = amount
    }

    private init(validatedAmount amount: Double) {
        self.amount = amount
    }

    /// Whether this adjustment has no effect on the image: exactly `0`.
    ///
    /// Exact equality, and `-0.0 == 0` is true in IEEE 754, so a negative zero
    /// is the identity as well — which it is, since `2^-0.0` is exactly `1`.
    public var isIdentity: Bool { amount == 0 }

    /// The value as the control shows it: `−100 … +100`, signed.
    ///
    /// Presentation only. It rounds for display and the stored amount does
    /// not change; see `ContrastControlScale`.
    public var signedDescription: String {
        String(format: "%+.0f", (amount == 0 ? 0 : amount) * 100)
    }

    /// A one-line summary for diagnostics, naming both the amount and the
    /// exponent it produces — because the exponent is the part that means
    /// something arithmetically.
    public var diagnosticDescription: String {
        String(
            format: "contrast %+.3f (k = %.6f)",
            amount == 0 ? 0 : amount,
            GlobalContrastCurve(amount: amount).exponent
        )
    }
}

// MARK: - Persistence

/// ## The wire format
///
/// A bare JSON number, under the record's `contrast` key:
///
/// ```json
/// "contrast" : 0.35
/// ```
///
/// A bare number rather than an object, for the reason `exposureEV` is one:
/// the decision *is* one number, and an object would invent a second place for
/// something to be wrong. The levels are an object because that decision is a
/// pair with an invariant between its halves; this one is not.
///
/// The exponent `k` is deliberately **not** written. It is derived from the
/// amount by `GlobalContrastCurve`, and persisting both would create a record
/// that could disagree with itself.
///
/// Decoding refuses a value outside `supportedRange` with the same typed error
/// construction does. Strict JSON has no NaN or infinity literal, so the
/// non-finite refusal is reachable only through `init(amount:)`, which is the
/// path the decoder takes.
extension UserContrastAdjustment: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(amount: Double(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try amount.encode(to: encoder)
    }
}
