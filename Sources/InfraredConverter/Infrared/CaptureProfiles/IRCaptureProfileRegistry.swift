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
/// ## Built-in profiles, plus whatever the user has defined
///
/// This is an immutable **value**, composed from two sources:
///
/// ```text
/// builtins       the profiles this build ships — today, builtin.uncalibrated
/// userProfiles   definitions loaded from the profile library
/// ```
///
/// Composition, not merging: an identity claimed by both sources, or by two
/// user profiles, is refused at construction rather than resolved by "last one
/// wins". Which of two definitions a photograph meant would otherwise depend on
/// an ordering nobody chose. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
///
/// The value itself never changes. A profile created, edited or deleted
/// produces a **new registry**, installed through one controlled path
/// (`IRCaptureProfileLibrary`), which is what lets a document decide what the
/// change costs it instead of discovering a definition had been mutated
/// underneath it.
///
/// One consequence is worth stating because it is now load-bearing rather than
/// incidental: **the registry an export was started with cannot change while it
/// runs**, because an export carries the resolved `IRCaptureProfile` rather
/// than an identifier to look up later. Editing a profile mid-export therefore
/// affects the *next* export and not the running one.
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

    /// The built-in profiles, and nothing else.
    ///
    /// What the application runs with before a profile library is loaded, what
    /// a library that is entirely unreadable falls back to, and what every test
    /// that does not care about user profiles gets.
    public static let builtin = IRCaptureProfileRegistry(
        uncheckedProfiles: [.builtinUncalibrated]
    )

    /// The profiles this build ships. Guaranteed present in every composed
    /// registry.
    public static let builtinProfiles: [IRCaptureProfile] = [.builtinUncalibrated]

    /// Composes the built-in profiles with definitions loaded from the profile
    /// library.
    ///
    /// The built-ins go in first and are not optional: a library that fails to
    /// load entirely still leaves an application that can render photographs,
    /// because `builtin.uncalibrated` is a value this build holds rather than a
    /// file it reads.
    ///
    /// - Throws: `IRCaptureProfileError.duplicateProfileID` when one identity
    ///   is claimed twice — across the two sources or within either of them.
    ///   Nothing is dropped to make a duplicate go away.
    public init(
        builtins: [IRCaptureProfile] = IRCaptureProfileRegistry.builtinProfiles,
        userProfiles: [IRCaptureProfile]
    ) throws {
        try self.init(profiles: builtins + userProfiles)
    }

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

    /// Every profile, ordered the way a person reading a list expects rather
    /// than the way a machine stores them.
    ///
    /// ```text
    /// built-in profiles first, by identity
    /// then user profiles, by display name
    /// ```
    ///
    /// Deliberately separate from `allProfiles`, which is sorted by identity
    /// and is the deterministic listing anything mechanical should use. This
    /// one is sorted by a **mutable** field, so it changes when somebody
    /// renames a profile — which is exactly right for a menu and exactly wrong
    /// for anything that has to be reproducible. Ties are broken by identity so
    /// two profiles sharing a name still have a stable order.
    public var profilesForDisplay: [IRCaptureProfile] {
        allProfiles.sorted { first, second in
            if first.id.isReserved != second.id.isReserved {
                return first.id.isReserved
            }
            let byName = first.name.localizedStandardCompare(second.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return first.id.rawValue < second.id.rawValue
        }
    }

    /// Every profile that is not built in, in display order.
    public var userProfiles: [IRCaptureProfile] {
        profilesForDisplay.filter { !$0.id.isReserved }
    }
}
