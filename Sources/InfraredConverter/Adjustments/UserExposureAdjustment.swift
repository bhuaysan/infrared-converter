import Foundation

/// The exposure compensation the **user** asked for, in photographic stops.
///
/// ```text
/// UserExposureAdjustment          ← this type: an editing decision, validated
///         │                         and persisted
///         │  ev, unchanged
///         ↓
/// DisplayRenderSettings.exposureEV  the processing instruction
///         ↓
/// DisplayPreviewRenderer          linear RGB × 2^EV, before the range policy
/// ```
///
/// ## Why a type, and not a `Double`
///
/// A bare `Double` in `ImageAdjustments` would say nothing about what the
/// number means or which numbers are allowed, and every reader of a sidecar,
/// a control and a render would have to know both. This type states them once:
///
/// ```text
/// meaning     exposure compensation in EV; +1 doubles linear light
/// neutral     0 EV, which multiplies by exactly 1
/// allowed     finite, and within supportedRange
/// ```
///
/// It performs **no arithmetic**. The multiplication by `2^EV` lives in
/// `DisplayPreviewRenderer`, which already did it before exposure was a user
/// decision; a second exposure primitive here would be two authorities for one
/// multiplication. See `docs/decisions/0017-interactive-exposure.md`.
///
/// ## It is a state, not a history
///
/// Like the other adjustments: asking for `+1.2 EV` replaces whatever was asked
/// for before. A slider burst is a sequence of states, and only the newest one
/// means anything.
///
/// ## The value is kept exactly
///
/// Nothing here rounds. A control may quantise what it offers — the workspace
/// slider moves in twentieths of a stop — but the value the adjustment holds is
/// the decision that was made, and a recipe or a hand-edited sidecar may hold a
/// finer one.
public struct UserExposureAdjustment: Equatable, Sendable {

    /// The exposure values a record may hold.
    ///
    /// A **validity bound on a persisted decision**, not a creative limit and
    /// not a slider range. It is chosen from the pipeline, not from habit:
    ///
    /// ```text
    /// +10 EV   ×1024   lifts a value ten stops below white level to display
    ///                  white. The reference camera records 12 bits, so that is
    ///                  a sample of about 4 in 4095 — anything further up the
    ///                  scale is lifting quantisation noise, not the photograph.
    /// −10 EV   ÷1024   brings a value a thousand times white level down to
    ///                  display white — far beyond the headroom white balance
    ///                  and a creative mix leave above 1 in practice.
    /// ```
    ///
    /// Symmetric, with exactly representable endpoints, and far from any
    /// numerical edge: `2^±10` is exact, and no finite scene-linear value of
    /// realistic magnitude overflows `Float32` when scaled by it. The renderer
    /// still refuses a non-finite result of its own; this bound is not what
    /// protects it.
    ///
    /// A value outside it is **refused**, never clamped: a clamp would render a
    /// different photograph from the one the record describes.
    public static let supportedRange: ClosedRange<Double> = -10...10

    /// No exposure compensation. Multiplies linear light by exactly `1`.
    public static let neutral = UserExposureAdjustment(validatedEV: 0)

    /// The compensation in stops. `+1` doubles linear light, `−1` halves it.
    public let ev: Double

    /// Validates a compensation.
    ///
    /// - Throws: `ImageAdjustmentError.nonFiniteExposureAdjustment` for NaN or
    ///   an infinity, and `.exposureAdjustmentOutOfRange` for a finite value
    ///   outside `supportedRange`. Both name the value that was refused.
    public init(ev: Double) throws {
        guard ev.isFinite else {
            throw ImageAdjustmentError.nonFiniteExposureAdjustment(ev: ev)
        }
        guard Self.supportedRange.contains(ev) else {
            throw ImageAdjustmentError.exposureAdjustmentOutOfRange(
                ev: ev, supported: Self.supportedRange
            )
        }
        self.ev = ev
    }

    private init(validatedEV ev: Double) {
        self.ev = ev
    }

    /// Whether this compensation has no effect on the image: exactly `0 EV`.
    public var isIdentity: Bool { ev == 0 }

    /// The value as a control or an inspector shows it: `+1.25 EV`.
    ///
    /// Two decimals, because that is what a person reads; the value itself is
    /// not rounded. A negative zero is shown as `+0.00`, since it multiplies by
    /// exactly the same `1`.
    public var signedDescription: String {
        String(format: "%+.2f EV", ev == 0 ? 0 : ev)
    }
}

// MARK: - Persistence

/// ## The wire format
///
/// A bare JSON number, under the record's `exposureEV` key:
///
/// ```json
/// "exposureEV" : 1.25
/// ```
///
/// `1.25` always means `+1.25 EV`. The unit is in the key and nowhere else — a
/// string unit beside the number would be a second place for it to be wrong.
///
/// Decoding refuses a value outside `supportedRange` with the same typed error
/// construction does. Strict JSON has no NaN or infinity literal, so the
/// non-finite refusal is reachable only through `init(ev:)`, which is the path
/// the decoder takes.
extension UserExposureAdjustment: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(ev: Double(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try ev.encode(to: encoder)
    }
}
