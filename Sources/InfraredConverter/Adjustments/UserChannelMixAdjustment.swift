import Foundation

/// The creative channel mix the **user** asked for.
///
/// ```text
/// IRChannelMix                    a complete processing instruction:
///                                 working space + matrix + provenance
///                 ▲
///                 │  derived, never stored
///                 │
/// UserChannelMixAdjustment        ← this type: an editing decision,
///                                 persisted, and small enough to be
/// ```
///
/// ## Why this is not `IRChannelMix`
///
/// It produces one, and it is deliberately a different type. `IRChannelMix`
/// is a processing value: it pairs a matrix with the working colour space the
/// coefficients were authored for and with the provenance that says what the
/// matrix may be claimed to be. Persisting that directly would put two things
/// on disk that do not belong there:
///
/// ```text
/// the working colour space    one exists, fixed by ADR 0006. Writing it would
///                             invite a sidecar that names a second one.
/// a matrix for a built-in     a record could then say "redBlueSwap" and carry
///                             coefficients that are not the swap, and no
///                             publicly constructible value would round-trip.
/// ```
///
/// So the persisted form names the **decision** — identity, the red/blue
/// swap, or nine explicit coefficients — and `mix` derives the processing
/// value from it. One direction, computed, so the two can never disagree.
///
/// ## It is a state, not a history
///
/// Exactly as `UserOrientationAdjustment` is. There is no "swap again" and no
/// composition: asking for a mix replaces whatever was asked for before, which
/// is what makes `M2 × (M1 × image)` unrepresentable rather than merely
/// discouraged. Mixes never compose (ADR 0007, Decision 27), and the editing
/// model is the first place that has to be true.
///
/// ## Identity is a real decision
///
/// `.identity` means "the user asked for no creative remapping", and it is a
/// state a person can deliberately arrive at and save — it is what the mix
/// control's Identity option produces. It is not "the user never chose", which
/// is a question this type cannot answer and does not pretend to.
///
/// A freshly opened file with no sidecar gets `.identity` as well, and that is
/// an application-layer choice rather than a guess about the photograph: the
/// red/blue swap is the canonical infrared rendering, and nothing here knows
/// whether a given RAW file is an infrared capture. See
/// `docs/decisions/0016-interactive-channel-mixer.md`.
public enum UserChannelMixAdjustment: Equatable, Sendable {
    /// No creative remapping. The creative stage is still traversed, and the
    /// provenance records that it was asked for nothing.
    case identity
    /// The canonical first infrared creative operation: output red takes input
    /// blue and output blue takes input red.
    case redBlueSwap
    /// Nine coefficients chosen deliberately, in the convention
    /// `RAWColorMatrix3x3` documents: rows are output channels, columns are
    /// input channels.
    ///
    /// There is no user interface for this today and this milestone does not
    /// build one. It exists because the adjustment model has to be able to
    /// carry the mix the processing stage can already apply, and because a
    /// persisted format that cannot express it would need a schema version to
    /// gain it later.
    case explicit(RAWColorMatrix3x3)

    /// Which of the three shapes this is — and the token it persists as.
    ///
    /// One value serves both because the alternative is two lists to keep in
    /// agreement. A UI control can switch over it without unpacking a matrix,
    /// and the wire format is `rawValue`.
    public enum Kind: String, CaseIterable, Sendable {
        case identity
        case redBlueSwap
        /// Nine explicit coefficients. Named for what is on disk beside it
        /// rather than for `explicit`, because the token's job is to say that
        /// a `matrix` field must be read.
        case matrix
    }

    public var kind: Kind {
        switch self {
        case .identity: return .identity
        case .redBlueSwap: return .redBlueSwap
        case .explicit: return .matrix
        }
    }

    /// The two decisions a user can reach from the workspace's controls.
    ///
    /// `.explicit` is deliberately absent: it is persistable and applicable,
    /// and there is no matrix editor to produce one.
    public static let selectableCases: [UserChannelMixAdjustment] = [
        .identity, .redBlueSwap
    ]

    // MARK: - The processing value

    /// The complete processing instruction this decision means.
    ///
    /// Derived, never stored, so the persisted decision and the matrix that
    /// runs can never drift apart. The working colour space comes from
    /// `IRChannelMix`'s own factories, which is where the project's one
    /// working space is named.
    public var mix: IRChannelMix {
        switch self {
        case .identity: return .identity
        case .redBlueSwap: return .redBlueSwap
        case .explicit(let matrix): return .explicit(matrix: matrix)
        }
    }

    /// The matrix this decision applies.
    public var matrix: RAWColorMatrix3x3 { mix.matrix }

    // MARK: - Facts about the adjustment

    /// Whether this adjustment leaves every channel where it was.
    ///
    /// A statement about the **net effect on the image**, not about how the
    /// decision was made: an `.explicit` matrix that happens to be the
    /// identity reports `true` here and is still not equal to `.identity`,
    /// because the two carry different provenance and persist differently.
    public var isIdentity: Bool { matrix.isIdentity }

    /// A short label for a control, worded from the user's point of view.
    public var shortDescription: String {
        switch self {
        case .identity: return "Identity"
        case .redBlueSwap: return "Red/Blue Swap"
        case .explicit: return "Explicit Matrix"
        }
    }

    /// A longer label for diagnostics, provenance and the inspector.
    public var diagnosticDescription: String {
        switch self {
        case .identity:
            return "identity (no creative remapping)"
        case .redBlueSwap:
            return "red/blue swap (creative infrared rendering)"
        case .explicit:
            return "explicit 3×3 matrix (creative; no calibration claim)"
        }
    }
}

// MARK: - Persistence

/// ## The wire format
///
/// ```json
/// { "kind" : "identity" }
/// { "kind" : "redBlueSwap" }
/// { "kind" : "matrix", "matrix" : [ 0, 0, 1, 0, 1, 0, 1, 0, 0 ] }
/// ```
///
/// A keyed object rather than a bare string, because one of the three cases
/// carries data and a format that changes shape between cases is worse than
/// one that always has a `kind`. The tokens are `Kind.rawValue`, so there is
/// one list of them.
///
/// The working colour space is **not** written. Exactly one exists, it is a
/// project invariant (ADR 0006), and a field naming it would suggest a sidecar
/// could select another. When a second working space exists, that is a schema
/// version, not a field somebody adds.
///
/// The shape is exact per kind:
///
/// ```text
/// identity       token only          a "matrix" key is refused
/// redBlueSwap    token only          a "matrix" key is refused
/// matrix         token + nine finite coefficients
/// ```
///
/// A built-in carrying a `matrix` is refused rather than read with the numbers
/// ignored, even when the numbers are the built-in's own. Only the `matrix`
/// key is policed this way, because it is the one that contradicts the token;
/// an unrelated extra key is not this type's concern.
///
/// The matrix is nine `Double`s, **row-major**, in the convention
/// `RAWColorMatrix3x3` fixes: `[m00, m01, m02, m10, m11, m12, m20, m21, m22]`.
/// A record with any other number of coefficients is refused, and so is one
/// whose coefficients are not all finite — the same contract the matrix type
/// enforces at construction, restated here so the refusal names the sidecar
/// rather than a processing stage.
extension UserChannelMixAdjustment: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case matrix
    }

    /// How many coefficients a persisted matrix has. Row-major, 3×3.
    public static let persistedCoefficientCount = 9

    /// The nine coefficients this adjustment persists, or `nil` for a
    /// built-in, which persists as its token alone.
    public var persistedMatrix: [Double]? {
        guard case .explicit(let matrix) = self else { return nil }
        return [
            matrix.m00, matrix.m01, matrix.m02,
            matrix.m10, matrix.m11, matrix.m12,
            matrix.m20, matrix.m21, matrix.m22,
        ]
    }

    /// Builds an explicit adjustment from persisted coefficients, refusing
    /// anything that is not nine finite numbers.
    ///
    /// Public because it is the one place the array form is interpreted, and
    /// because it is the only way to exercise the non-finite refusal: strict
    /// JSON has no NaN or infinity literal, so a test that wants to prove the
    /// check exists has to reach it here.
    ///
    /// - Throws: `ImageAdjustmentError.malformedChannelMixMatrix` for the
    ///   wrong number of coefficients, and
    ///   `.nonFiniteChannelMixCoefficient` for one that is not a finite
    ///   number.
    public static func explicit(
        persistedMatrix coefficients: [Double]
    ) throws -> UserChannelMixAdjustment {
        guard coefficients.count == persistedCoefficientCount else {
            throw ImageAdjustmentError.malformedChannelMixMatrix(
                coefficientCount: coefficients.count,
                expected: persistedCoefficientCount
            )
        }
        for (index, value) in coefficients.enumerated() where !value.isFinite {
            throw ImageAdjustmentError.nonFiniteChannelMixCoefficient(
                index: index, value: value
            )
        }
        // Finiteness is the matrix type's whole contract and has just been
        // established, so this cannot throw. It is still `try` rather than
        // `try!`: these numbers came off a disk, and if the primitive's
        // contract ever grows, its own typed refusal is the right thing to
        // surface rather than a trap.
        return .explicit(
            try RAWColorMatrix3x3(
                m00: coefficients[0], m01: coefficients[1], m02: coefficients[2],
                m10: coefficients[3], m11: coefficients[4], m12: coefficients[5],
                m20: coefficients[6], m21: coefficients[7], m22: coefficients[8]
            )
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let token = try container.decodeIfPresent(String.self, forKey: .kind) else {
            throw ImageAdjustmentError.missingChannelMixField(field: "kind")
        }
        guard let kind = Kind(rawValue: token) else {
            // Never `.identity`: a token we cannot read and a deliberate
            // decision to remap nothing are different facts.
            throw ImageAdjustmentError.unknownChannelMixKind(token: token)
        }

        switch kind {
        case .identity, .redBlueSwap:
            // A built-in is its token and nothing else. A record that names
            // one and carries coefficients says two different things about
            // one matrix, and there is no reading of it that is not a guess:
            // ignoring the numbers renders the token, trusting them renders
            // something the token does not name. Refused, whatever the
            // numbers are — even the built-in's own.
            guard !container.contains(.matrix) else {
                throw ImageAdjustmentError.unexpectedChannelMixField(
                    field: CodingKeys.matrix.stringValue, kind: token
                )
            }
            self = kind == .identity ? .identity : .redBlueSwap
        case .matrix:
            guard let coefficients = try container.decodeIfPresent(
                [Double].self, forKey: .matrix
            ) else {
                throw ImageAdjustmentError.missingChannelMixField(field: "matrix")
            }
            self = try Self.explicit(persistedMatrix: coefficients)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        // Written only for the case that has one. A built-in's matrix is
        // derived from its token, so persisting it would create a second
        // authority for the same nine numbers.
        if let coefficients = persistedMatrix {
            try container.encode(coefficients, forKey: .matrix)
        }
    }
}
