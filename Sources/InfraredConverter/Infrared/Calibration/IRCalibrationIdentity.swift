import Foundation

/// The syntax the calibration domain's identifiers share.
///
/// ```text
/// <namespace> "." <uuid or segment> [ "." <segment> … ]
///
/// segment   1–64 characters of a–z, 0–9 and "-"
/// total     at most 128 characters
/// ```
///
/// Deliberately the same shape as ``IRCaptureProfileID``, for the same
/// reasons: lowercase only, so two spellings of one identity cannot compare
/// unequal; namespace-qualified, so an unqualified token cannot collide with
/// something else's; filesystem-safe by construction, because a segment
/// contains no separator and `.` and `..` are unrepresentable.
///
/// It is a separate validator rather than a shared one because sharing would
/// have meant reshaping `IRCaptureProfileID`, whose rules are load-bearing for
/// every photograph sidecar already written. Two small validators that agree
/// are cheaper than one refactor that has to be right the first time.
enum CalibrationIdentifierSyntax {

    static let maximumLength = 128
    static let maximumSegmentLength = 64

    /// Validates `rawValue`, requiring its first segment to be `namespace`.
    ///
    /// The namespace is fixed per identifier type rather than free, unlike a
    /// capture profile's. There is exactly one kind of thing in each of these
    /// namespaces and no vendor or built-in variant to leave room for, and a
    /// fixed namespace means a store can tell from a filename alone which kind
    /// of artefact it is looking at.
    static func validate(
        _ rawValue: String, namespace: String, kind: String
    ) throws(IRCalibrationError) {
        func refuse(_ reason: String) -> IRCalibrationError {
            .invalidIdentifier(kind: kind, token: rawValue, reason: reason)
        }

        guard !rawValue.isEmpty else {
            throw refuse("A \(kind) identifier cannot be empty.")
        }
        guard rawValue.count <= maximumLength else {
            throw refuse("""
                A \(kind) identifier may be at most \(maximumLength) characters; this one \
                is \(rawValue.count).
                """)
        }

        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else {
            throw refuse("""
                A \(kind) identifier must be namespace-qualified, such as \
                "\(namespace).550e8400-e29b-41d4-a716-446655440000".
                """)
        }
        guard segments[0] == namespace else {
            throw refuse("""
                A \(kind) identifier is in the "\(namespace)." namespace; this one claims \
                "\(segments[0])."
                """)
        }

        for segment in segments {
            guard !segment.isEmpty else {
                throw refuse("A \(kind) identifier has an empty segment.")
            }
            guard segment.count <= maximumSegmentLength else {
                throw refuse("""
                    The segment "\(segment)" is \(segment.count) characters; at most \
                    \(maximumSegmentLength) are allowed.
                    """)
            }
            for character in segment where !isAllowed(character) {
                throw refuse("""
                    "\(character)" is not allowed in a \(kind) identifier; use lowercase \
                    a–z, 0–9 and "-".
                    """)
            }
        }
    }

    static func isAllowed(_ character: Character) -> Bool {
        character.isASCII && (character.isLowercase || character.isNumber || character == "-")
    }

    static func generated(namespace: String) -> String {
        "\(namespace).\(UUID().uuidString.lowercased())"
    }
}

/// The stable identity of one calibration artefact: a measurement set, the
/// reference it was fitted against, and the transform that fitting produced.
///
/// ```text
/// calibration.550e8400-e29b-41d4-a716-446655440000
/// ```
///
/// Generated, never derived from a display name — a calibration's name is
/// something a person rewrites, and every profile that referenced it would
/// lose it silently. Not a path either: a path is a location, it changes when a
/// library moves between machines, and it leaks a directory layout into
/// whatever stores the reference. The same reasoning as
/// ``IRCaptureProfileID``, for the same kind of artefact.
///
/// **Re-fitting the same evidence produces a new identity.** The measurement
/// set keeps its own (``IRCalibrationMeasurementSetID``), and the new
/// calibration names it as its source, so measurement history is preserved
/// rather than overwritten. See
/// `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`.
public struct IRCalibrationID: Hashable, Sendable {

    public static let namespace = "calibration"

    public let rawValue: String

    public init(_ rawValue: String) throws(IRCalibrationError) {
        try CalibrationIdentifierSyntax.validate(
            rawValue, namespace: Self.namespace, kind: "calibration"
        )
        self.rawValue = rawValue
    }

    /// A fresh identity for a calibration that is about to be created.
    public static func generated() -> IRCalibrationID {
        try! IRCalibrationID(CalibrationIdentifierSyntax.generated(namespace: namespace))
    }
}

extension IRCalibrationID: CustomStringConvertible {
    public var description: String { rawValue }
}

extension IRCalibrationID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The stable identity of one set of measurements — what a camera actually
/// produced, in front of one target, under one illumination, on one occasion.
///
/// ```text
/// measurement.9c8f6b0d-2e4a-4d1b-8f3c-77a0b9d5e611
/// ```
///
/// Separate from ``IRCalibrationID`` because the two have different lifetimes.
/// Evidence is a historical fact and is never revised; a fit is a derivation
/// from it and may be redone — with a better solver, a corrected reference
/// dataset, or a different patch selection. Giving the fit the evidence's
/// identity would make "the calibration" ambiguous the first time anybody
/// refitted anything.
public struct IRCalibrationMeasurementSetID: Hashable, Sendable {

    public static let namespace = "measurement"

    public let rawValue: String

    public init(_ rawValue: String) throws(IRCalibrationError) {
        try CalibrationIdentifierSyntax.validate(
            rawValue, namespace: Self.namespace, kind: "measurement set"
        )
        self.rawValue = rawValue
    }

    public static func generated() -> IRCalibrationMeasurementSetID {
        try! IRCalibrationMeasurementSetID(
            CalibrationIdentifierSyntax.generated(namespace: namespace)
        )
    }
}

extension IRCalibrationMeasurementSetID: CustomStringConvertible {
    public var description: String { rawValue }
}

extension IRCalibrationMeasurementSetID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
