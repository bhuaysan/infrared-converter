import Foundation

/// The black point and white point the **user** chose, as one validated
/// decision.
///
/// ```text
/// UserLevelsAdjustment       ← this type: an editing decision, validated and
///         │                    persisted
///         │  blackPoint, whitePoint, unchanged
///         ↓
/// LinearLevels               the arithmetic, shared by preview and export
///         ↓
/// LinearLevelsApplier        (x − black) × 1/(white − black), before the
///                            destination's range policy
/// ```
///
/// ## Why one type rather than two fields on `ImageAdjustments`
///
/// Because the invariant belongs to the pair. `blackPoint < whitePoint` cannot
/// be stated about either number alone, and two loose `Double`s would let a
/// record exist in which it is false — and would push the check out to every
/// reader of a sidecar, a control and a render.
///
/// Held together, the record either describes an interval or refuses to exist.
///
/// ## It performs no arithmetic
///
/// The subtraction and the scaling live in `LinearLevels`, which is the one
/// authority on what these two numbers do to a pixel, for both the preview and
/// the export. This type carries intent and validates it; the applicability
/// rule it enforces is `LinearLevels`'s own, asked of a constructed value
/// rather than restated here.
///
/// ## It is a state, not a history
///
/// Like every other adjustment: asking for a new pair replaces whatever was
/// asked for before. Applying `L2` after `L1` renders `L2(exposed)`, never
/// `L2(L1(exposed))` — the retained preview is upstream of this stage, so
/// there is nothing for a new decision to compose onto.
///
/// ## The value is kept exactly
///
/// Nothing here rounds. A control may quantise what it offers; the value the
/// adjustment holds is the decision that was made, and a hand-edited sidecar
/// may hold a finer one.
public struct UserLevelsAdjustment: Equatable, Sendable {

    /// The input value that becomes `0`.
    public let blackPoint: Double

    /// The input value that becomes `1`.
    public let whitePoint: Double

    /// Black `0`, white `1` — mathematically the identity, and what a freshly
    /// opened file gets.
    public static let neutral = UserLevelsAdjustment(
        validatedBlackPoint: 0, whitePoint: 1
    )

    /// Validates a pair of levels.
    ///
    /// ## The supported domain, and why it has no photographic limit
    ///
    /// ```text
    /// blackPoint finite
    /// whitePoint finite
    /// blackPoint < whitePoint
    /// the span and its reciprocal are both representable
    /// ```
    ///
    /// That is all of it, and every clause is derived from IEEE 754 rather than
    /// from photography. This pipeline carries extended values deliberately:
    /// white balance, a creative mix with negative coefficients and highlight
    /// headroom all produce working coordinates outside `0…1` in both
    /// directions, so `black = −0.25, white = 2.0` is a useful setting rather
    /// than an error, and it is accepted.
    ///
    /// The last clause is the only one that is not obvious, and it is not a
    /// safety margin invented to feel careful. Two endpoints about `1e308`
    /// apart overflow the subtraction, which makes the scale exactly `0` and
    /// would render every pixel black while every number involved stayed
    /// finite. Two endpoints closer than about `1e-308` overflow the
    /// reciprocal, which would turn every finite input into an infinity.
    /// Neither is a decision a person can mean, and both are refused by name.
    ///
    /// A slider's range is a different thing entirely and never reaches this
    /// type. See `LevelsControlScale`.
    ///
    /// - Throws: `ImageAdjustmentError.nonFiniteLevelsBound` for NaN or an
    ///   infinity, `.levelsNotOrdered` when the black point is not below the
    ///   white point, and `.levelsSpanNotRepresentable` when the interval's
    ///   arithmetic is not representable. All three name the values refused,
    ///   and none clamps, reorders or substitutes anything.
    public init(blackPoint: Double, whitePoint: Double) throws {
        guard blackPoint.isFinite else {
            throw ImageAdjustmentError.nonFiniteLevelsBound(
                field: "blackPoint", value: blackPoint
            )
        }
        guard whitePoint.isFinite else {
            throw ImageAdjustmentError.nonFiniteLevelsBound(
                field: "whitePoint", value: whitePoint
            )
        }
        guard blackPoint < whitePoint else {
            throw ImageAdjustmentError.levelsNotOrdered(
                blackPoint: blackPoint, whitePoint: whitePoint
            )
        }
        // The applicability rule is `LinearLevels`'s, asked rather than
        // restated: a second copy of it here could disagree with the stage
        // that actually runs the arithmetic.
        let levels = LinearLevels(blackPoint: blackPoint, whitePoint: whitePoint)
        guard levels.span.isFinite, levels.scale.isFinite else {
            throw ImageAdjustmentError.levelsSpanNotRepresentable(
                blackPoint: blackPoint,
                whitePoint: whitePoint,
                span: levels.span,
                scale: levels.scale
            )
        }
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
    }

    private init(validatedBlackPoint blackPoint: Double, whitePoint: Double) {
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
    }

    /// Whether this adjustment has no effect on the image: black exactly `0`
    /// and white exactly `1`.
    public var isIdentity: Bool { blackPoint == 0 && whitePoint == 1 }

    /// The interval's width, `whitePoint − blackPoint`.
    public var span: Double { whitePoint - blackPoint }

    /// The pair as a control or an inspector shows it.
    ///
    /// Three decimals, because that is what a person reads at these
    /// magnitudes; the values themselves are not rounded.
    public var levelsDescription: String {
        String(format: "black %.3f, white %.3f", blackPoint, whitePoint)
    }
}

// MARK: - Persistence

/// ## The wire format
///
/// A JSON object of two numbers, under the record's `levels` key:
///
/// ```json
/// "levels" : {
///   "blackPoint" : 0.05,
///   "whitePoint" : 1.2
/// }
/// ```
///
/// An object rather than a two-element array, and one key rather than two at
/// the record's top level: the pair is one decision and a reader can see that
/// it is. Both fields are required — there is no value a missing black point
/// could be defaulted to that is not a guess about what the person meant.
///
/// Decoding refuses exactly what construction refuses, through the same
/// initialiser. Strict JSON has no NaN or infinity literal, so the non-finite
/// refusal is reachable only through `init(blackPoint:whitePoint:)`, which is
/// the path the decoder takes.
extension UserLevelsAdjustment: Codable {
    private enum CodingKeys: String, CodingKey {
        case blackPoint
        case whitePoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            blackPoint: Self.require(.blackPoint, in: container),
            whitePoint: Self.require(.whitePoint, in: container)
        )
    }

    /// Reads one required bound, turning absence — or an explicit `null` —
    /// into the typed refusal rather than a `DecodingError`. It never yields a
    /// default.
    private static func require(
        _ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double {
        guard let value = try container.decodeIfPresent(Double.self, forKey: key) else {
            throw ImageAdjustmentError.missingLevelsField(field: key.stringValue)
        }
        return value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blackPoint, forKey: .blackPoint)
        try container.encode(whitePoint, forKey: .whitePoint)
    }
}
