import Foundation

/// Where profile **definitions** live, as distinct from the photograph-level
/// fact that one is selected.
///
/// ```text
/// registry    id → definition          one per application
/// sidecar     "this photograph uses id" one per photograph
/// ```
///
/// Keeping them apart is what makes profiles reusable at all. If a sidecar
/// carried the whole definition, editing a profile would leave every photograph
/// already adjusted under it holding a stale copy, and the same profile would
/// be duplicated once per frame with no way to tell the copies apart. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 6.
///
/// ## Built-in only, in this milestone
///
/// This is an immutable value built once from a fixed list. There is no
/// user-profile directory, no profile JSON schema and no profile editor, which
/// is a deliberate scope choice rather than an oversight: the milestone's
/// purpose is the architecture and the photograph-level selection, and a
/// profile manager would have dwarfed both. The domain model is shaped for
/// user profiles — a namespaced identity, a definition that is pure data, a
/// lookup that already refuses unknown identifiers — and none of it assumes
/// the set is fixed.
///
/// One consequence is worth stating because a later milestone must not lose it:
/// **the set of profiles cannot change while an export runs**, so an export
/// does not have to defend against a definition being edited underneath it. It
/// defends anyway, by carrying the resolved `IRCaptureProfile` rather than an
/// identifier to look up later, which is the behaviour a mutable registry would
/// require.
public struct IRCaptureProfileRegistry: Sendable {

    /// Every profile this registry knows, keyed by identity.
    private let profilesByID: [IRCaptureProfileID: IRCaptureProfile]

    /// Builds a registry, refusing two profiles that claim one identity.
    ///
    /// - Throws: `IRCaptureProfileError.duplicateProfileID`.
    public init(profiles: [IRCaptureProfile]) throws {
        var byID: [IRCaptureProfileID: IRCaptureProfile] = [:]
        for profile in profiles {
            guard byID[profile.id] == nil else {
                throw IRCaptureProfileError.duplicateProfileID(id: profile.id)
            }
            byID[profile.id] = profile
        }
        self.profilesByID = byID
    }

    /// The unchecked initialiser the built-in registry uses.
    ///
    /// Private, because its only safe caller is the one below: a literal list
    /// whose identities are visible in the source and pinned by a test.
    private init(uncheckedProfiles profiles: [IRCaptureProfile]) {
        self.profilesByID = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.id, $0) }
        )
    }

    /// The registry this application runs with: the built-in profiles, and
    /// nothing else.
    public static let builtin = IRCaptureProfileRegistry(
        uncheckedProfiles: [.builtinUncalibrated]
    )

    /// The profile that a photograph with no saved selection gets, and that
    /// every historical sidecar migrates to.
    ///
    /// Guaranteed to exist in every registry: it is returned as a value rather
    /// than looked up, so no registry — not even one a test builds without it —
    /// can leave the application with nothing to render.
    public var uncalibratedProfile: IRCaptureProfile { .builtinUncalibrated }

    /// The profile with this identity.
    ///
    /// - Throws: `IRCaptureProfileError.unknownProfile` when nothing has that
    ///   identity. Never a substitute: a photograph that names a profile this
    ///   build does not have must say so, not be rendered under a different one
    ///   that happens to be installed.
    public func profile(for id: IRCaptureProfileID) throws -> IRCaptureProfile {
        guard let profile = profilesByID[id] else {
            throw IRCaptureProfileError.unknownProfile(id: id)
        }
        return profile
    }

    /// Whether this registry has a profile with that identity.
    public func contains(_ id: IRCaptureProfileID) -> Bool {
        profilesByID[id] != nil
    }

    /// Every profile, in a deterministic order.
    ///
    /// Sorted by identity rather than by name, so the order does not change
    /// when somebody renames a profile, and does not depend on a dictionary's
    /// hashing. A picker built from this shows the same list twice running.
    public var allProfiles: [IRCaptureProfile] {
        profilesByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// How many profiles this registry holds.
    public var count: Int { profilesByID.count }
}
