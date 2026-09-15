import Foundation

/// Where reusable creative-preset **definitions** are kept between sessions.
///
/// ```text
/// PhotographProcessingStore    one photograph's state, beside its RAW file
/// IRCaptureProfileStore        reusable capture profiles, application-owned
/// IRCreativePresetStore        reusable creative presets, application-owned
/// ```
///
/// Three artefacts with three lifetimes, three schemas and three locations, so
/// three stores.
///
/// ## The invariant this store exists to keep, and the one it does not need
///
/// A capture-profile store has to keep working because a photograph's sidecar
/// holds a profile **reference**, and a missing definition means a photograph
/// that will not open. Nothing of the kind is true here:
///
/// ```text
/// sidecar → UserChannelMixAdjustment     the resolved decision, always
/// library → IRCreativePreset             a place a person keeps a decision to reuse
/// ```
///
/// A photograph never refers to a preset. So this store losing a file, or all
/// of them, costs a person a shortcut and costs no photograph anything: every
/// image still renders exactly as it did, because the mix it renders with is
/// in its own sidecar. That is the point of resolving a preset at the moment it
/// is applied rather than at the moment it is rendered. See
/// `docs/decisions/0024-reusable-creative-presets.md`.
///
/// ## Three operations, deliberately
///
/// Load everything, save one, delete one. It is not a database and must not
/// grow into one: there are as many presets as a photographer has looks they
/// like, the files are a few hundred bytes each, and every question worth
/// asking is answered by loading them all. No search, no sync, no import, no
/// export, no sharing.
///
/// ## Loading does not fail as a whole
///
/// `loadAll()` returns both halves — what loaded and what refused — rather than
/// throwing. One corrupt file must not make every valid preset disappear, and
/// it must not be silently skipped either.
public protocol IRCreativePresetStore: Sendable {

    /// Every stored preset, and every stored thing that would not load.
    func loadAll() -> IRCreativePresetLibraryLoad

    /// Writes one preset, replacing whatever definition was stored under its
    /// identity.
    ///
    /// The replacement must be atomic **at the preset's own path**: a reader
    /// must never observe a half-written definition there, and a write that
    /// fails partway must leave the previous definition in place.
    ///
    /// Saving the same identity twice is an **edit**, and it is the only way to
    /// change a stored definition: a new immutable value replaces the old one
    /// whole.
    ///
    /// - Throws: `IRCreativePresetPersistenceError.reservedIdentifier` for a
    ///   preset claiming a reserved identity, and `.cannotWrite` or
    ///   `.cannotCreateDirectory` for a file that could not be put where it
    ///   belongs.
    func save(_ preset: IRCreativePreset) throws(IRCreativePresetPersistenceError)

    /// Removes the stored definition with this identity.
    ///
    /// **No photograph is affected, ever.** Photographs that were developed
    /// with this preset keep the channel mix they were given: it is in each
    /// one's own sidecar as an ordinary `UserChannelMixAdjustment`, and nothing
    /// about it refers back to here. Deleting a preset removes a shortcut, not
    /// a rendering.
    ///
    /// Deleting an identity that is not stored is **not** an error: the
    /// requested end state — no preset with that identity — already holds.
    ///
    /// - Throws: `IRCreativePresetPersistenceError.cannotDelete`.
    func delete(_ id: IRCreativePresetID) throws(IRCreativePresetPersistenceError)
}

/// What one pass over the preset storage found: the presets, and the refusals.
///
/// ```text
/// presets     definitions that loaded, and may be applied
/// failures    per-file typed refusals, each naming what it is about
/// ```
///
/// Both halves, always. Throwing on the first bad file would make one corrupt
/// preset hide an entire library, and ignoring bad files would let a preset a
/// person spent time creating vanish without a word.
public struct IRCreativePresetLibraryLoad: Sendable {

    /// The definitions that loaded, in the order the store produced them.
    public let presets: [IRCreativePreset]

    /// Everything that did not, each as its own typed refusal.
    public let failures: [IRCreativePresetPersistenceError]

    public init(
        presets: [IRCreativePreset] = [],
        failures: [IRCreativePresetPersistenceError] = []
    ) {
        self.presets = presets
        self.failures = failures
    }

    /// Whether anything refused.
    public var hasFailures: Bool { !failures.isEmpty }

    /// One line for a banner: "1 preset could not be loaded."
    public var failureSummary: String? {
        guard hasFailures else { return nil }
        return failures.count == 1
            ? "1 preset could not be loaded."
            : "\(failures.count) presets could not be loaded."
    }
}
