import Foundation

/// The stable identity of a reusable infrared capture profile.
///
/// ```text
/// builtin.uncalibrated
/// user.olympus-epl3-720nm
/// user.3f8c1a02-0b7e-4f8a-9a3e-2f1c6d5b4a90
/// ```
///
/// ## Why identity is not the display name
///
/// A profile's name is something a person writes and later rewrites — "720 nm",
/// then "720 nm (Hoya R72)", then "Summer 720". Every photograph that
/// referenced it by name would lose its profile the moment the name changed,
/// silently, and the only visible symptom would be a different rendering. So
/// the reference a sidecar stores is this value, and the name is free to
/// change without breaking a single photograph.
///
/// It is equally not a file path. A path is a location, not an identity: it
/// changes when a library is moved between machines, it leaks a user's
/// directory layout into every sidecar, and two profiles copied to the same
/// place would collide. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`.
///
/// ## The syntax, and why it is validated
///
/// ```text
/// <namespace> "." <segment> [ "." <segment> … ]
///
/// namespace   the first segment; "builtin" for profiles this build ships,
///             "user" for profiles a person defines
/// segment     1–64 characters of a–z, 0–9 and "-"
/// total       at most 128 characters
/// ```
///
/// Lowercase only, and no dot-free identifiers: an unqualified `uncalibrated`
/// would eventually collide with somebody's profile of the same name, and
/// case-varying spellings of one identity (`Builtin.Uncalibrated`) would
/// compare unequal while meaning the same thing. Validation happens once, at
/// the boundary, so no later code has to wonder whether an identifier it is
/// holding is well-formed.
///
/// The namespace itself is **not** restricted to a known set. A future build
/// that ships, say, a `vendor.` namespace must not be unreadable by this one
/// for syntactic reasons; whether a given identifier names a profile that
/// exists is a separate question, answered by `IRCaptureProfileRegistry` and
/// answered explicitly.
public struct IRCaptureProfileID: Hashable, Sendable {

    /// The identifier exactly as it is written and persisted.
    public let rawValue: String

    /// The longest identifier this type accepts.
    public static let maximumLength = 128

    /// The longest single dot-separated segment this type accepts.
    public static let maximumSegmentLength = 64

    /// Builds an identifier, refusing anything that is not well-formed.
    ///
    /// - Throws: `IRCaptureProfileError.invalidProfileID`.
    public init(_ rawValue: String) throws {
        try Self.validate(rawValue)
        self.rawValue = rawValue
    }

    /// The first segment: `builtin` for a profile this build ships, `user` for
    /// one a person defined.
    ///
    /// Descriptive, not authoritative. Nothing grants a profile privileges for
    /// having a particular namespace; the registry decides what exists.
    public var namespace: String {
        String(rawValue.prefix { $0 != "." })
    }

    private static func validate(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw IRCaptureProfileError.invalidProfileID(
                token: rawValue, reason: "A capture profile identifier cannot be empty."
            )
        }
        guard rawValue.count <= maximumLength else {
            throw IRCaptureProfileError.invalidProfileID(
                token: rawValue,
                reason: """
                    A capture profile identifier may be at most \(maximumLength) characters; \
                    this one is \(rawValue.count).
                    """
            )
        }

        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else {
            throw IRCaptureProfileError.invalidProfileID(
                token: rawValue,
                reason: """
                    A capture profile identifier must be namespace-qualified, such as \
                    "builtin.uncalibrated" or "user.my-profile".
                    """
            )
        }

        for segment in segments {
            guard !segment.isEmpty else {
                throw IRCaptureProfileError.invalidProfileID(
                    token: rawValue, reason: "A capture profile identifier has an empty segment."
                )
            }
            guard segment.count <= maximumSegmentLength else {
                throw IRCaptureProfileError.invalidProfileID(
                    token: rawValue,
                    reason: """
                        The segment "\(segment)" is \(segment.count) characters; at most \
                        \(maximumSegmentLength) are allowed.
                        """
                )
            }
            for character in segment where !isAllowed(character) {
                throw IRCaptureProfileError.invalidProfileID(
                    token: rawValue,
                    reason: """
                        "\(character)" is not allowed in a capture profile identifier; use \
                        lowercase a–z, 0–9 and "-".
                        """
                )
            }
        }
    }

    private static func isAllowed(_ character: Character) -> Bool {
        character.isASCII && (character.isLowercase || character.isNumber || character == "-")
    }
}

extension IRCaptureProfileID: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - The identifiers this build ships

extension IRCaptureProfileID {
    /// The one profile every build of this application guarantees:
    /// `builtin.uncalibrated`.
    ///
    /// A literal, built through the checked initialiser at first use, so that a
    /// malformed constant would fail its own validation rather than sneak past
    /// it. `try!` is honest here — the string is right above it and cannot vary
    /// at runtime — and a test asserts it round-trips.
    public static let builtinUncalibrated = try! IRCaptureProfileID("builtin.uncalibrated")
}

// MARK: - Persistence

/// Persisted as the bare string, because that is what it is. A nested object
/// would imply the identity has parts a reader should interpret, and it does
/// not: the namespace is a convention for humans, and matching is exact.
extension IRCaptureProfileID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
