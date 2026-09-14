import Foundation

/// One patch of a calibration target, by its identifier on that target.
///
/// Identifiers are the target's own, not this project's invention: for a
/// ColorChecker Classic they are the standard row-major numbering, written
/// zero-padded so that sorting a JSON object's keys and sorting the patches
/// give the same order.
public struct IRCalibrationTargetPatchID: Hashable, Sendable, Comparable {

    public static let maximumLength = 32

    public let rawValue: String

    public init(_ rawValue: String) throws(IRCalibrationError) {
        func refuse(_ reason: String) -> IRCalibrationError {
            .invalidIdentifier(kind: "target patch", token: rawValue, reason: reason)
        }
        guard !rawValue.isEmpty else {
            throw refuse("A patch identifier cannot be empty.")
        }
        guard rawValue.count <= Self.maximumLength else {
            throw refuse("""
                A patch identifier may be at most \(Self.maximumLength) characters; this one \
                is \(rawValue.count).
                """)
        }
        for character in rawValue where !Self.isAllowed(character) {
            throw refuse("""
                "\(character)" is not allowed in a patch identifier; use lowercase a–z, 0–9 \
                and "-".
                """)
        }
        self.rawValue = rawValue
    }

    private static func isAllowed(_ character: Character) -> Bool {
        character.isASCII && (character.isLowercase || character.isNumber || character == "-")
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension IRCalibrationTargetPatchID: CustomStringConvertible {
    public var description: String { rawValue }
}

extension IRCalibrationTargetPatchID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A physical calibration target this project knows the **layout** of.
///
/// ```text
/// colorCheckerClassic24    4 rows x 6 columns, row-major, patches "01"…"24"
/// ```
///
/// ## What a target is, and what it is not
///
/// A target here is a *geometry and a patch vocabulary*: how many patches there
/// are, how they are arranged on the chart, and what each one is called. That
/// is what the measurement path needs in order to turn four marked corners into
/// twenty-four regions, and it is a physical fact about a piece of card.
///
/// It carries **no reference values**. Those are a separate artefact
/// (``IRCalibrationReferenceDataset``) with their own identity, version,
/// colour space, illuminant and provenance, for two reasons. The published
/// values for a visible-light chart are somebody else's data with their own
/// licensing, and — far more importantly — **they are not physical truth for an
/// infrared capture**. A ColorChecker's patches are characterised for how they
/// reflect visible light; what they do beyond 700 nm is not what their
/// published Lab values say, and pretending otherwise would be the single
/// worst mistake this subsystem could make. See
/// `docs/calibration-protocol.md`.
///
/// One target is modelled, deliberately. Generalising to arbitrary charts
/// before one has been measured once would be designing against imagined
/// requirements.
public enum IRCalibrationTarget: String, Equatable, Sendable, CaseIterable, Codable {

    /// The 24-patch ColorChecker Classic, in its standard 4x6 arrangement.
    ///
    /// Row-major from the top left as the chart is normally held (landscape,
    /// the neutral row along the bottom). Patch `"19"` is the white end of
    /// that neutral row and `"24"` the black end.
    case colorCheckerClassic24

    public var rows: Int {
        switch self {
        case .colorCheckerClassic24: return 4
        }
    }

    public var columns: Int {
        switch self {
        case .colorCheckerClassic24: return 6
        }
    }

    public var patchCount: Int { rows * columns }

    public var displayName: String {
        switch self {
        case .colorCheckerClassic24: return "ColorChecker Classic 24"
        }
    }

    /// The patch identifiers, in row-major order from the top-left corner.
    ///
    /// Order matters: it is how a chart outline's grid cells are paired with
    /// patch identities, so it must be stated once here rather than assumed at
    /// each call site.
    public var patchIDs: [IRCalibrationTargetPatchID] {
        (1...patchCount).map { index in
            try! IRCalibrationTargetPatchID(String(format: "%02d", index))
        }
    }

    public func contains(_ patch: IRCalibrationTargetPatchID) -> Bool {
        patchIDs.contains(patch)
    }

    /// The grid position of a patch, or `nil` when it is not on this target.
    public func position(
        of patch: IRCalibrationTargetPatchID
    ) -> (row: Int, column: Int)? {
        guard let index = patchIDs.firstIndex(of: patch) else { return nil }
        return (row: index / columns, column: index % columns)
    }

    /// The patch a person would normally pick as the calibration session's
    /// neutral reference, when they have not named one themselves.
    ///
    /// The **second** neutral patch rather than the first. On a ColorChecker
    /// Classic the white patch is the one most likely to be clipped in an
    /// exposure set for the coloured patches, and a neutral reference measured
    /// from clipped samples is not a neutral reference at all. This is a
    /// suggestion a caller may ignore; nothing applies it automatically.
    public var suggestedNeutralPatch: IRCalibrationTargetPatchID {
        switch self {
        case .colorCheckerClassic24: return try! IRCalibrationTargetPatchID("20")
        }
    }

    public var diagnosticDescription: String {
        "\(displayName) (\(rows)x\(columns), \(patchCount) patches, layout only — no reference values)"
    }
}
