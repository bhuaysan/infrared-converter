import Foundation
import Observation

/// The application's one owner of creative-preset definitions.
///
/// ```text
/// IRCreativePresetStore      files on disk
/// IRCreativePresetLibrary    ← this: store + composed list + load failures
/// ChannelMixControl          offers them; applying one calls setChannelMix
/// ```
///
/// ## Why a single owner
///
/// The reason `IRCaptureProfileLibrary` gives: the alternative is every window
/// reading the Application Support folder for itself, so that a preset saved in
/// one window is invisible in the other until a restart.
///
/// ## Why there is no registry type beside it
///
/// A capture profile needs one, because a photograph's sidecar holds a
/// **reference** and something has to resolve it — at open, during a render, on
/// an export. A preset is never referenced by anything: it is read once, at the
/// moment a person clicks it, and what reaches the photograph is the resolved
/// `UserChannelMixAdjustment`. So there is a list, composed here, and no
/// resolution step anywhere in the pipeline. See
/// `docs/decisions/0024-reusable-creative-presets.md`.
///
/// ## Concurrency
///
/// `@MainActor`, and the file operations are synchronous — the same judgement
/// `IRCaptureProfileLibrary` and `DocumentState.write` make, for the same
/// reason: a few hundred bytes of JSON per preset, a handful of files, read at
/// launch and rewritten when somebody presses Save.
///
/// The rule that follows: **the list is replaced only after the write has
/// returned.** A preset that could not be deleted is still installed, and the
/// in-memory library says so, because the two may not disagree after a reported
/// success.
///
/// ## What it does not do
///
/// It does not watch the folder, import, export, sync, share or merge. It does
/// not apply a preset — only a person does that, through the channel-mix
/// control. And it never touches a photograph: no preset operation can change a
/// white balance, an orientation, a mix, an exposure or a capture profile, and
/// deleting every preset in it changes no photograph's rendering, because each
/// photograph's sidecar holds the mix itself.
@MainActor
@Observable
public final class IRCreativePresetLibrary {

    /// Every preset that loaded, in display order.
    public private(set) var presets: [IRCreativePreset] = []

    /// Everything in the library that would not load, each as its own typed
    /// refusal.
    ///
    /// Reported rather than swallowed, and it does not stop the rest of the
    /// library from working. A corrupt file is one missing preset, not a
    /// missing library.
    public private(set) var loadFailures: [IRCreativePresetPersistenceError] = []

    /// Increments whenever `presets` is replaced. The one thing an observer can
    /// compare cheaply.
    public private(set) var version = 0

    /// Where definitions are kept, or `nil` when this machine has no library.
    ///
    /// `nil` is not an error state to recover from: it means the
    /// application-owned storage location could not be determined at all, the
    /// channel mixer still works in full, and every operation that would need a
    /// file refuses with `libraryUnavailable` rather than pretending to
    /// succeed.
    private let store: (any IRCreativePresetStore)?

    /// The reason there is no store, when there is none. Reported on every
    /// load, because it does not stop being true between them.
    private let unavailable: IRCreativePresetPersistenceError?

    /// Builds a library over a store and loads it once.
    public init(
        store: (any IRCreativePresetStore)?,
        unavailable: IRCreativePresetPersistenceError? = nil
    ) {
        self.store = store
        self.unavailable = unavailable
        reload()
    }

    /// The library this application runs with: presets from Application
    /// Support.
    ///
    /// A location that cannot be determined is reported as a load failure and
    /// leaves a working, empty library.
    public static func applicationSupport() -> IRCreativePresetLibrary {
        do {
            let directory = try FileIRCreativePresetStore.applicationSupportDirectory()
            return IRCreativePresetLibrary(
                store: FileIRCreativePresetStore(directory: directory)
            )
        } catch {
            return IRCreativePresetLibrary(store: nil, unavailable: error)
        }
    }

    // MARK: - Reading

    /// Whether the library holds nothing a person could apply.
    public var isEmpty: Bool { presets.isEmpty }

    /// The preset with this identity, if it is installed.
    public func preset(for id: IRCreativePresetID) -> IRCreativePreset? {
        presets.first { $0.id == id }
    }

    /// Re-reads the whole library from the store and recomposes the list.
    ///
    /// Called at initialisation, and after every successful write, so that what
    /// is in memory is what is on disk rather than what was intended to be. The
    /// alternative — patching the in-memory list and trusting it — is how a
    /// library and a folder come to disagree.
    public func reload() {
        guard let store else {
            presets = []
            loadFailures = unavailable.map { [$0] } ?? []
            version += 1
            return
        }

        let load = store.loadAll()
        let composed = Self.compose(load.presets)

        presets = composed.presets
        loadFailures = load.failures + composed.failures + (unavailable.map { [$0] } ?? [])
        version += 1
    }

    /// Puts loaded presets into display order, refusing any identity claimed
    /// more than once.
    ///
    /// **Refused, never resolved.** If two definitions claimed one identity and
    /// this picked one, which mix a menu entry applied would depend on the
    /// order a folder happened to be enumerated in — an answer nobody chose,
    /// that can differ between machines, and whose only symptom is a photograph
    /// that comes out wrong. Both are dropped and the ambiguity is reported.
    ///
    /// The file store makes this unreachable through itself, because a file's
    /// name is its identity and a payload that disagrees is refused. It is here
    /// because this is what composes sources — today one, tomorrow perhaps more
    /// — and composition is where ambiguity can actually arise.
    ///
    /// ## Display order
    ///
    /// By name, case- and diacritic-insensitively, then by identity. Names are
    /// deliberately **not** unique — two presets may both be called "720 sky",
    /// because a name is not an identity — so the identity is the tiebreak that
    /// makes the order total. Nothing about this order depends on the file
    /// system.
    static func compose(
        _ loaded: [IRCreativePreset]
    ) -> (presets: [IRCreativePreset], failures: [IRCreativePresetPersistenceError]) {
        var countsByID: [IRCreativePresetID: Int] = [:]
        for preset in loaded {
            countsByID[preset.id, default: 0] += 1
        }

        let ambiguous = countsByID.filter { $0.value > 1 }
        let failures = ambiguous.keys
            .sorted { $0.rawValue < $1.rawValue }
            .map { IRCreativePresetPersistenceError.duplicateIdentifier(id: $0, paths: []) }

        let admitted = loaded
            .filter { ambiguous[$0.id] == nil }
            .sorted { first, second in
                let order = first.name.localizedCaseInsensitiveCompare(second.name)
                if order != .orderedSame { return order == .orderedAscending }
                return first.id.rawValue < second.id.rawValue
            }

        return (admitted, failures)
    }

    // MARK: - Writing

    /// Saves a preset, creating it or replacing the definition already stored
    /// under its identity.
    ///
    /// One operation for both, because they are the same operation: an edit
    /// constructs a **new immutable value with the same identity** and replaces
    /// the stored definition whole.
    ///
    /// ## Editing a preset changes no photograph
    ///
    /// Not now and not later. A photograph developed with this preset holds the
    /// resolved `UserChannelMixAdjustment` in its own sidecar; nothing about it
    /// points back here. Renaming a preset, changing its filter hint, replacing
    /// its matrix or deleting it outright leaves every existing photograph
    /// rendering exactly as it was. That is a deliberate property of the design
    /// rather than an accident of this milestone, and it is the reason a
    /// sidecar stores the decision instead of a reference.
    ///
    /// - Throws: `IRCreativePresetPersistenceError`. The list is replaced only
    ///   after the write has returned, so a failed save leaves the library
    ///   exactly as it was.
    public func save(
        _ preset: IRCreativePreset
    ) throws(IRCreativePresetPersistenceError) {
        guard let store else { throw .libraryUnavailable(underlying: Unavailable()) }
        try store.save(preset)
        Log.ui.info(
            """
            Saved creative preset \(preset.id.rawValue, privacy: .public) \
            (\(preset.channelMix.diagnosticDescription, privacy: .public))
            """
        )
        reload()
    }

    /// Creates a preset from a draft and a mix, under a freshly generated
    /// identity.
    ///
    /// The identity is generated here and never derived from the name, so two
    /// presets a person calls the same thing are two presets and renaming one
    /// is only a rename.
    ///
    /// - Parameter channelMix: the decision to store — the photograph's current
    ///   mix, at the moment the person pressed Save.
    /// - Returns: the preset as it was stored.
    /// - Throws: `IRCreativePresetDraftError` for a draft that does not
    ///   describe a preset, `IRCreativePresetPersistenceError` for one that
    ///   could not be written.
    @discardableResult
    public func create(
        _ draft: IRCreativePresetDraft, channelMix: UserChannelMixAdjustment
    ) throws -> IRCreativePreset {
        let preset = try draft.makePreset(id: .generatedUserID(), channelMix: channelMix)
        try save(preset)
        return preset
    }

    /// Replaces the definition stored under an existing identity.
    ///
    /// The identity is the caller's, and it is **preserved**: renaming a preset
    /// changes its name and nothing else.
    ///
    /// - Parameter channelMix: the mix the replacement carries. Pass the stored
    ///   preset's own to rename it without touching its matrix; that is what
    ///   the library interface does.
    /// - Throws: as `create(_:channelMix:)` does.
    @discardableResult
    public func update(
        _ draft: IRCreativePresetDraft,
        id: IRCreativePresetID,
        channelMix: UserChannelMixAdjustment
    ) throws -> IRCreativePreset {
        let preset = try draft.makePreset(id: id, channelMix: channelMix)
        try save(preset)
        return preset
    }

    /// Removes a preset from the library.
    ///
    /// **No photograph is affected.** Nothing is scanned, because there is
    /// nothing to scan for: a photograph never refers to a preset. Every image
    /// ever developed with this look keeps that look.
    ///
    /// - Throws: `IRCreativePresetPersistenceError`. The list is replaced only
    ///   after the removal has returned, so a preset whose file could not be
    ///   deleted is still installed and the library still says so.
    public func delete(
        _ id: IRCreativePresetID
    ) throws(IRCreativePresetPersistenceError) {
        guard let store else { throw .libraryUnavailable(underlying: Unavailable()) }
        try store.delete(id)
        Log.ui.info("Deleted creative preset \(id.rawValue, privacy: .public)")
        reload()
    }

    /// Stands in for an underlying error when there is no store at all.
    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? {
            "No preset storage location is available on this machine."
        }
    }
}
