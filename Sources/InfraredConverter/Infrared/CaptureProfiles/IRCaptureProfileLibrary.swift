import Foundation
import Observation

/// The application's one owner of capture-profile definitions.
///
/// ```text
/// IRCaptureProfileStore      files on disk
/// IRCaptureProfileLibrary    ← this: store + registry + load failures, in one place
/// IRCaptureProfileRegistry   an immutable value a document resolves against
/// DocumentState              consumes the registry; never reads the folder
/// ```
///
/// ## Why a single owner
///
/// Because the alternative is every `DocumentState` reading the Application
/// Support folder for itself. Two documents would then hold two registries
/// built at two moments, a profile created in one window would be invisible in
/// the other until a restart, and "which definition does this photograph
/// resolve to?" would have as many answers as there are windows.
///
/// So this type owns the store, holds the composed registry, and is the only
/// thing that replaces it. `DocumentState` is handed the registry and consumes
/// it. See `docs/decisions/0021-user-capture-profile-library.md`.
///
/// ## Concurrency
///
/// `@MainActor`, and the file operations are synchronous.
///
/// Three things have to stay in step — the folder, the registry, and the
/// interface showing both — and doing that with one actor is a guarantee rather
/// than an arrangement. The cost is a few hundred bytes of JSON per profile, a
/// handful of files, read at launch and rewritten when somebody presses Save;
/// it is the same judgement `DocumentState.write` makes about a sidecar, for
/// the same reason, and the same one that would have to be revisited if a
/// library ever grew large enough to measure.
///
/// The rule that follows: **the registry is replaced only after the write has
/// returned.** A profile that could not be deleted is still installed, and the
/// in-memory library says so, because the two may not disagree after a reported
/// success.
///
/// ## What it does not do
///
/// It does not watch the folder, import, export, sync or merge. It does not
/// assign a profile to a photograph — only a person does that, through
/// `DocumentState.setCaptureProfile`. And it never touches a photograph's
/// adjustments: a white balance, an orientation, a channel mix and an exposure
/// belong to one frame, and no profile operation may reach them.
@MainActor
@Observable
public final class IRCaptureProfileLibrary {

    /// The composed registry: the built-in profiles and every user profile that
    /// loaded.
    public private(set) var registry: IRCaptureProfileRegistry

    /// Everything in the library that would not load, each as its own typed
    /// refusal.
    ///
    /// Reported rather than swallowed, and it does not stop the rest of the
    /// library from working. A corrupt file is one missing profile, not a
    /// missing library.
    public private(set) var loadFailures: [IRCaptureProfilePersistenceError] = []

    /// Increments whenever `registry` is replaced.
    ///
    /// The one thing an observer can compare. `IRCaptureProfileRegistry` is a
    /// value with no `Equatable` conformance — profiles contain closures'
    /// worth of nothing, but comparing whole registries to decide whether to
    /// re-resolve would be doing by search what a counter does by construction
    /// — so a document watches this and asks the library for the new registry
    /// when it changes.
    public private(set) var version = 0

    /// Where definitions are kept, or `nil` when this machine has no library.
    ///
    /// `nil` is not an error state to recover from: it means the
    /// application-owned storage location could not be determined at all, the
    /// built-in profile still works, and every operation that would need a file
    /// refuses with `libraryUnavailable` rather than pretending to succeed.
    private let store: (any IRCaptureProfileStore)?

    /// The profiles this build ships, composed in front of the loaded ones.
    private let builtins: [IRCaptureProfile]

    /// The reason there is no store, when there is none. Reported on every
    /// load, because it does not stop being true between them.
    private let unavailable: IRCaptureProfilePersistenceError?

    /// The built-in-only registry, used before a load and whenever a load
    /// cannot produce a usable one.
    private var builtinOnlyRegistry: IRCaptureProfileRegistry {
        (try? IRCaptureProfileRegistry(builtins: builtins, userProfiles: [])) ?? .builtin
    }

    /// Builds a library over a store and loads it once.
    ///
    /// Loading at initialisation, rather than lazily on first use, is the
    /// choice this milestone makes: a document may be opened immediately, and a
    /// photograph whose sidecar names a user profile must resolve it on the
    /// first attempt rather than refusing to open because the library had not
    /// got round to loading. A filesystem watcher is deliberately out of scope.
    public init(
        store: (any IRCaptureProfileStore)?,
        builtins: [IRCaptureProfile] = IRCaptureProfileRegistry.builtinProfiles,
        unavailable: IRCaptureProfilePersistenceError? = nil
    ) {
        self.store = store
        self.builtins = builtins
        self.unavailable = unavailable
        // Assigned before `reload()` because a stored property may not be read
        // until every one of them has a value; `reload()` replaces it
        // immediately.
        self.registry = .builtin
        reload()
    }

    /// The library this application runs with: user profiles from Application
    /// Support, composed with the built-in ones.
    ///
    /// A location that cannot be determined is reported as a load failure and
    /// leaves a working built-in-only library, because the built-in profile is
    /// a value rather than a file.
    public static func applicationSupport() -> IRCaptureProfileLibrary {
        do {
            let directory = try FileIRCaptureProfileStore.applicationSupportDirectory()
            return IRCaptureProfileLibrary(
                store: FileIRCaptureProfileStore(directory: directory)
            )
        } catch {
            return IRCaptureProfileLibrary(store: nil, unavailable: error)
        }
    }

    // MARK: - Reading

    /// Every profile, in display order: built-in first, then user profiles by
    /// name.
    public var profilesForDisplay: [IRCaptureProfile] { registry.profilesForDisplay }

    /// The profiles a person defined, in display order.
    public var userProfiles: [IRCaptureProfile] { registry.userProfiles }

    /// Whether this identity belongs to a profile this build ships, and
    /// therefore cannot be renamed, edited or deleted.
    public func isBuiltin(_ id: IRCaptureProfileID) -> Bool {
        builtins.contains { $0.id == id }
    }

    /// Re-reads the whole library from the store and recomposes the registry.
    ///
    /// Called at initialisation, and after every successful write, so that what
    /// is in memory is what is on disk rather than what was intended to be. It
    /// is cheap, and the alternative — patching the in-memory list and trusting
    /// it — is how a registry and a folder come to disagree.
    public func reload() {
        guard let store else {
            // No library on this machine. The built-in profile is unaffected:
            // it is a value this build holds rather than a file it reads.
            registry = builtinOnlyRegistry
            loadFailures = unavailable.map { [$0] } ?? []
            version += 1
            return
        }

        let load = store.loadAll()
        var failures = load.failures

        do {
            registry = try IRCaptureProfileRegistry(
                builtins: builtins, userProfiles: load.profiles
            )
        } catch let error as IRCaptureProfileError {
            // The store already refuses two files claiming one identity, and a
            // user profile may not claim a built-in identity, so reaching this
            // means a store implementation broke one of those rules. The
            // built-in profiles are kept and the user ones are not: an
            // ambiguous library must not decide anything about a photograph.
            Log.ui.error(
                """
                Capture profile library composition refused: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            registry = builtinOnlyRegistry
            if case .duplicateProfileID(let id) = error {
                failures.append(.duplicateIdentifier(id: id, paths: []))
            }
        } catch {
            registry = builtinOnlyRegistry
        }

        loadFailures = failures + (unavailable.map { [$0] } ?? [])
        version += 1
    }

    // MARK: - Writing

    /// Saves a profile, creating it or replacing the definition already stored
    /// under its identity.
    ///
    /// One operation for both, because they are the same operation: an edit
    /// constructs a **new immutable value with the same identity** and replaces
    /// the stored definition whole. Nothing is mutated in place, and there is
    /// no moment at which a half-updated definition is visible.
    ///
    /// ## Editing changes what every referencing photograph resolves to
    ///
    /// A profile is a shared object. Changing its filter, its conversion or its
    /// camera changes the definition that every photograph referencing it will
    /// resolve to the next time it is opened. In this milestone every persisted
    /// profile shares one processing basis, so such an edit is descriptive and
    /// cannot change a pixel — but the rule is stated here because the day a
    /// second basis can be persisted it will not be. The interface says so
    /// where a person edits.
    ///
    /// - Throws: `IRCaptureProfilePersistenceError`. The registry is replaced
    ///   only after the write has returned, so a failed save leaves the library
    ///   exactly as it was.
    public func save(
        _ profile: IRCaptureProfile
    ) throws(IRCaptureProfilePersistenceError) {
        guard let store else { throw .libraryUnavailable(underlying: Unavailable()) }
        guard !isBuiltin(profile.id) else {
            throw .reservedIdentifier(
                id: profile.id, namespace: IRCaptureProfileID.builtinNamespace
            )
        }
        try store.save(profile)
        Log.ui.info(
            """
            Saved capture profile \(profile.id.rawValue, privacy: .public) \
            (\(profile.processingBasis.shortDescription, privacy: .public), \
            calibrated: \(profile.isValidatedInfraredCalibration ? "yes" : "no", privacy: .public))
            """
        )
        reload()
    }

    /// Creates a profile from a draft, under a freshly generated identity.
    ///
    /// The identity is generated here and never derived from the name: a name
    /// is rewritten, and every photograph referencing a name-derived identity
    /// would lose its profile the moment somebody did.
    ///
    /// - Returns: the profile as it was stored, so a caller can show it or
    ///   assign it.
    /// - Throws: `IRCaptureProfileDraftError` for a draft that does not
    ///   describe a profile, `IRCaptureProfilePersistenceError` for one that
    ///   could not be written.
    @discardableResult
    public func create(_ draft: IRCaptureProfileDraft) throws -> IRCaptureProfile {
        let profile = try draft.makeProfile(id: .generatedUserID())
        try save(profile)
        return profile
    }

    /// Replaces the definition stored under an existing identity.
    ///
    /// The identity is the caller's, and it is **preserved**: renaming a
    /// profile changes its name and nothing else, so every sidecar that
    /// references it still resolves. That is the whole reason identity is not
    /// the display name.
    ///
    /// - Throws: as `create(_:)` does.
    @discardableResult
    public func update(
        _ draft: IRCaptureProfileDraft, id: IRCaptureProfileID
    ) throws -> IRCaptureProfile {
        let profile = try draft.makeProfile(id: id)
        try save(profile)
        return profile
    }

    /// Removes a profile from the library.
    ///
    /// ## What this cannot do, and says so rather than pretending
    ///
    /// Photograph sidecars may still reference the deleted identity, and
    /// nothing here scans for them: they are wherever the photographs are, on
    /// whatever volumes, and a library operation that went looking would be
    /// slow, incomplete and wrong the moment a disk was unplugged. Such a
    /// photograph refuses to open until another profile is assigned to it —
    /// which is a refusal with a remedy, and far better than silently rendering
    /// it under a profile nobody chose. The interface warns before this is
    /// called.
    ///
    /// A built-in profile is refused: it is a value this build holds, not a
    /// file, and there is nothing to remove.
    ///
    /// - Throws: `IRCaptureProfilePersistenceError`. The registry is replaced
    ///   only after the removal has returned, so a profile whose file could not
    ///   be deleted is still installed and the library still says so.
    public func delete(
        _ id: IRCaptureProfileID
    ) throws(IRCaptureProfilePersistenceError) {
        guard let store else { throw .libraryUnavailable(underlying: Unavailable()) }
        guard !isBuiltin(id) else {
            throw .reservedIdentifier(
                id: id, namespace: IRCaptureProfileID.builtinNamespace
            )
        }
        try store.delete(id)
        Log.ui.info("Deleted capture profile \(id.rawValue, privacy: .public)")
        reload()
    }

    /// Stands in for an underlying error when there is no store at all.
    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? {
            "No capture profile storage location is available on this machine."
        }
    }
}
