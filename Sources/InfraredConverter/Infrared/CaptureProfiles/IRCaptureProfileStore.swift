import Foundation

/// Where reusable capture-profile **definitions** are kept between sessions.
///
/// ```text
/// PhotographProcessingStore    one photograph's state, beside its RAW file
/// IRCaptureProfileStore        reusable profile definitions, application-owned
/// ```
///
/// Two artefacts with two lifetimes, two schemas and two locations, so two
/// stores. Merging them would put a shared definition inside every photograph's
/// sidecar, which is precisely the duplication a profile **reference** exists to
/// avoid: editing one profile would then leave a stale copy beside every
/// photograph ever adjusted under it. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
///
/// The invariant this store exists to keep working:
///
/// ```text
/// sidecar             → IRCaptureProfileID       a reference
/// registry / library  → IRCaptureProfile         the definition
/// ```
///
/// ## Three operations, deliberately
///
/// Load everything, save one, delete one. It is not a database and must not
/// grow into one: there are as many profiles as a photographer has cameras and
/// filters, the files are a few hundred bytes each, and every question worth
/// asking is answered by loading them all.
///
/// ## Loading does not fail as a whole
///
/// `loadAll()` returns both halves — what loaded and what refused — rather than
/// throwing. One corrupt file must not make every valid profile disappear, and
/// it must not be silently skipped either. See `IRCaptureProfileLibraryLoad`.
public protocol IRCaptureProfileStore: Sendable {

    /// Every stored profile, and every stored thing that would not load.
    func loadAll() -> IRCaptureProfileLibraryLoad

    /// Writes one profile, replacing whatever definition was stored under its
    /// identity.
    ///
    /// The replacement must be atomic **at the profile's own path**: a reader
    /// must never observe a half-written definition there, and a write that
    /// fails partway must leave the previous definition in place. That is a
    /// statement about the replacement, not about durability — no store is
    /// asked to promise what survives a power loss.
    ///
    /// Saving the same identity twice is an **edit**, and it is the only way to
    /// change a stored definition: a new immutable value replaces the old one
    /// whole. There is no partially mutated shared object anywhere.
    ///
    /// - Throws: `IRCaptureProfilePersistenceError.reservedIdentifier` for a
    ///   profile claiming a built-in identity,
    ///   `.unsupportedProcessingBasis` for one whose basis has no wire format,
    ///   and `.cannotWrite` or `.cannotCreateDirectory` for a file that could
    ///   not be put where it belongs.
    func save(_ profile: IRCaptureProfile) throws(IRCaptureProfilePersistenceError)

    /// Removes the stored definition with this identity.
    ///
    /// Removing a profile a photograph references is permitted and is not
    /// repaired: no sidecar is rewritten, nothing is scanned, and such a
    /// photograph will refuse to open until another profile is assigned to it.
    /// The interface says so before this is called; this layer does not
    /// pretend it can know which photographs are affected.
    ///
    /// Deleting an identity that is not stored is **not** an error: the
    /// requested end state — no profile with that identity — already holds.
    ///
    /// - Throws: `IRCaptureProfilePersistenceError.cannotDelete`, and
    ///   `.reservedIdentifier` for a built-in profile, which is a value rather
    ///   than a file and cannot be removed at all.
    func delete(_ id: IRCaptureProfileID) throws(IRCaptureProfilePersistenceError)
}

/// What one pass over the profile storage found: the profiles, and the
/// refusals.
///
/// ```text
/// profiles    definitions that loaded, and may be used
/// failures    per-file typed refusals, each naming what it is about
/// ```
///
/// Both halves, always. The two alternatives are each worse in their own way:
/// throwing on the first bad file would make one corrupt profile hide an entire
/// library, and ignoring bad files would let a profile a person spent time
/// creating vanish without a word — and take every photograph that references
/// it with it.
///
/// The built-in profile is not in here. It is a value this build ships, it
/// cannot fail to load, and it is composed into the registry beside whatever
/// this found. A profile library that is entirely unreadable still leaves an
/// application that renders photographs.
public struct IRCaptureProfileLibraryLoad: Sendable {

    /// The definitions that loaded, in the order the store produced them.
    public let profiles: [IRCaptureProfile]

    /// Everything that did not, each as its own typed refusal.
    public let failures: [IRCaptureProfilePersistenceError]

    public init(
        profiles: [IRCaptureProfile] = [],
        failures: [IRCaptureProfilePersistenceError] = []
    ) {
        self.profiles = profiles
        self.failures = failures
    }

    /// Whether anything refused. The interface reports this without having to
    /// decide what a failure means.
    public var hasFailures: Bool { !failures.isEmpty }

    /// One line for a banner: "1 capture profile could not be loaded."
    ///
    /// Deliberately a count and not a decoder's description. The detail is
    /// available per failure, and belongs behind a disclosure rather than in
    /// the first sentence a person reads.
    public var failureSummary: String? {
        guard hasFailures else { return nil }
        return failures.count == 1
            ? "1 capture profile could not be loaded."
            : "\(failures.count) capture profiles could not be loaded."
    }
}
