import Foundation

/// The stable identity of a reusable creative preset.
///
/// ```text
/// user.3f8c1a02-0b7e-4f8a-9a3e-2f1c6d5b4a90
/// ```
///
/// ## Why this is not `IRCaptureProfileID`
///
/// The two spell identifiers the same way, and they identify different kinds
/// of thing:
///
/// ```text
/// IRCaptureProfileID    what camera, conversion and filter a photograph was made with
/// IRCreativePresetID    a reusable starting point for a creative channel mix
/// ```
///
/// A separate type, rather than a shared one, because the compiler is then the
/// thing that stops a preset identity being handed to the profile registry or a
/// profile identity being looked up in the preset library. They are never
/// interchangeable, nothing resolves one against the other, and no file
/// contains both. See `docs/decisions/0024-reusable-creative-presets.md`.
///
/// ## Why identity is not the display name
///
/// The same reason `IRCaptureProfileID` gives. A preset's name is something a
/// person writes and later rewrites — "720 sky", then "720 sky (warm)", then
/// "Summer sky" — and an identity derived from it would change with it. Two
/// presets a person calls "720 nm" are also two presets, and a name-derived
/// identity would make them one.
///
/// It is equally not a file path. A path is a location: it changes when a
/// library moves between machines, and two presets copied to the same place
/// would collide.
///
/// ## The syntax, and why it is validated
///
/// ```text
/// <namespace> "." <segment> [ "." <segment> … ]
///
/// namespace   the first segment; "user" for presets a person defines,
///             "builtin" reserved for any this project might one day ship
/// segment     1–64 characters of a–z, 0–9 and "-"
/// total       at most 128 characters
/// ```
///
/// Lowercase only, and no dot-free identifiers, so that case-varying spellings
/// of one identity cannot compare unequal while meaning the same thing.
/// Validation happens once, at the boundary: the identifier is also the
/// filename a preset is stored under, and a value that has been through here
/// contains no path separator and cannot spell `.` or `..`.
public struct IRCreativePresetID: Hashable, Sendable {

    /// The identifier exactly as it is written and persisted.
    public let rawValue: String

    /// The longest identifier this type accepts.
    public static let maximumLength = 128

    /// The longest single dot-separated segment this type accepts.
    public static let maximumSegmentLength = 64

    /// Builds an identifier, refusing anything that is not well-formed.
    ///
    /// - Throws: `IRCreativePresetError.invalidPresetID`.
    public init(_ rawValue: String) throws(IRCreativePresetError) {
        try Self.validate(rawValue)
        self.rawValue = rawValue
    }

    /// The first segment: `user` for a preset a person defined.
    ///
    /// Descriptive, not authoritative. Nothing grants a preset privileges for
    /// having a particular namespace.
    public var namespace: String {
        String(rawValue.prefix { $0 != "." })
    }

    private static func validate(_ rawValue: String) throws(IRCreativePresetError) {
        guard !rawValue.isEmpty else {
            throw .invalidPresetID(
                token: rawValue, reason: "A creative preset identifier cannot be empty."
            )
        }
        guard rawValue.count <= maximumLength else {
            throw .invalidPresetID(
                token: rawValue,
                reason: """
                    A creative preset identifier may be at most \(maximumLength) characters; \
                    this one is \(rawValue.count).
                    """
            )
        }

        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else {
            throw .invalidPresetID(
                token: rawValue,
                reason: """
                    A creative preset identifier must be namespace-qualified, such as \
                    "user.my-preset".
                    """
            )
        }

        for segment in segments {
            guard !segment.isEmpty else {
                throw .invalidPresetID(
                    token: rawValue, reason: "A creative preset identifier has an empty segment."
                )
            }
            guard segment.count <= maximumSegmentLength else {
                throw .invalidPresetID(
                    token: rawValue,
                    reason: """
                        The segment "\(segment)" is \(segment.count) characters; at most \
                        \(maximumSegmentLength) are allowed.
                        """
                )
            }
            for character in segment where !isAllowed(character) {
                throw .invalidPresetID(
                    token: rawValue,
                    reason: """
                        "\(character)" is not allowed in a creative preset identifier; use \
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

extension IRCreativePresetID: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - Persistence

/// Persisted as the bare string, because that is what it is. Matching is
/// exact; the namespace is a convention for humans.
extension IRCreativePresetID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Namespaces, and who may claim them

extension IRCreativePresetID {

    /// The namespace reserved for presets a build of this application ships.
    ///
    /// **This build ships none.** It is reserved anyway, and in one direction
    /// only: nothing stops a future build adding `builtin.` presets, and
    /// nothing lets a user preset claim one. A stored preset calling itself
    /// `builtin.something` would shadow a definition the application would
    /// later author, and a menu entry would then apply a matrix nobody in this
    /// project wrote.
    ///
    /// What such a built-in preset would have to be is the interesting part,
    /// and it is why there are none: a preset shipped under a wavelength name
    /// would have to carry nine coefficients, and no measured or otherwise
    /// established basis for a universal "720 nm matrix" exists in this
    /// project. See `docs/decisions/0024-reusable-creative-presets.md`.
    public static let builtinNamespace = "builtin"

    /// The namespace `generatedUserID()` produces, and the one a person's own
    /// presets are expected to use.
    ///
    /// Not enforced on the way in: a preset file carrying, say, a `vendor.`
    /// identity is readable by this build, because a future namespace must not
    /// be unreadable for syntactic reasons. Only `builtin.` is refused.
    public static let userNamespace = "user"

    /// Whether this identity belongs to a namespace a user preset may not
    /// claim.
    public var isReserved: Bool { namespace == Self.builtinNamespace }

    /// A fresh, stable identity for a preset a person is creating.
    ///
    /// ```text
    /// user.550e8400-e29b-41d4-a716-446655440000
    /// ```
    ///
    /// A UUID rather than a slug of the display name: renaming a preset must
    /// change its name and nothing else, and two presets that happen to share a
    /// name are still two presets.
    ///
    /// A UUID's canonical spelling is lowercase hexadecimal and hyphens, which
    /// is a subset of what a segment already allows, so the result validates by
    /// construction — `try!` is honest here, and a test asserts it over many
    /// draws rather than once.
    public static func generatedUserID() -> IRCreativePresetID {
        try! IRCreativePresetID("\(userNamespace).\(UUID().uuidString.lowercased())")
    }
}
