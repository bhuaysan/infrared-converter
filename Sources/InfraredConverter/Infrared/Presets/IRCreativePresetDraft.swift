import Foundation

/// A creative preset being written, as opposed to one that exists.
///
/// ```text
/// IRCreativePresetDraft    mutable, possibly invalid, what a form holds
/// IRCreativePreset         immutable, valid, what the library stores
/// ```
///
/// The split is `IRCaptureProfileDraft`'s, and exists for the same reason: the
/// domain type never has to become partially valid. A form has an empty name
/// until somebody types one, and a wavelength field containing `"72"` on the
/// way to `"720"`; an `IRCreativePreset` has neither of those states.
/// `makePreset(id:channelMix:)` is the single gate between the two.
///
/// ## The channel mix is not a field here
///
/// It is a parameter of the gate, not something this draft holds, because it
/// is not something the save form edits. A preset is saved **from the mix the
/// photograph is already showing**: the person authored it in the matrix
/// editor, looked at it, and decided to keep it. Putting a matrix into this
/// draft would make the save sheet a second channel-mix editor, and the
/// project has one.
///
/// So what a person types here is a name and, if they want, which filter
/// family they use the look with. See
/// `docs/decisions/0024-reusable-creative-presets.md`.
public struct IRCreativePresetDraft: Equatable, Sendable {

    /// What a person calls this preset. Never its identity.
    public var name: String

    /// The filter family the look is suggested for. `.unknown` is an ordinary,
    /// complete answer and is the default.
    ///
    /// Descriptive only: nothing in this project reads it, matches on it, or
    /// derives any processing from it.
    public var filter: IRFilterDraft

    public init(name: String = "", filter: IRFilterDraft = IRFilterDraft()) {
        self.name = name
        self.filter = filter
    }

    /// The draft for an existing preset, for renaming it or changing its hint.
    ///
    /// The identity is not carried, for `IRCaptureProfileDraft`'s reason: it
    /// belongs to the preset being replaced, and a draft that could change it
    /// would be a way to store one preset's definition at another's address.
    /// Nor is the channel mix, which an edit preserves untouched.
    public init(_ preset: IRCreativePreset) {
        self.init(name: preset.name, filter: IRFilterDraft(preset.filter))
    }

    /// Prefills the filter hint from a capture profile's filter.
    ///
    /// **A copy, once, because a person opened the save sheet.** The capture
    /// profile said which filter was on the lens; it is a reasonable first
    /// guess at which family the author would suggest the look for, and it
    /// saves retyping `720`.
    ///
    /// It is not a binding, and the distinction matters more than the
    /// convenience does. Once copied, the value is the draft's: editing the
    /// capture profile afterwards, renaming it, or deleting it changes nothing
    /// about this draft or about any preset saved from it. A preset that
    /// tracked a profile's filter would silently change what it claims to be
    /// suggested for, long after its author stopped thinking about it. See
    /// `docs/decisions/0024-reusable-creative-presets.md`, Decision 7.
    public mutating func useFilter(from profile: IRCaptureProfile) {
        filter = IRFilterDraft.prefilled(from: profile.filter)
    }

    /// The immutable preset this draft describes, under a given identity and
    /// carrying a given mix.
    ///
    /// The single gate between mutable form state and the domain type. The
    /// identity is a parameter because a draft never chooses one: creation is
    /// given a freshly generated identifier, and editing is given the
    /// identifier of the preset being replaced.
    ///
    /// - Parameter channelMix: the decision to store. Passed in — from the
    ///   photograph's current mix when creating, from the stored preset when
    ///   editing — so that saving a name can never alter a matrix.
    /// - Throws: `IRCreativePresetDraftError`.
    public func makePreset(
        id: IRCreativePresetID,
        channelMix: UserChannelMixAdjustment
    ) throws(IRCreativePresetDraftError) -> IRCreativePreset {
        guard !id.isReserved else {
            throw .reservedIdentifier(
                id: id, namespace: IRCreativePresetID.builtinNamespace
            )
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw .emptyName }

        let descriptor: IRFilterDescriptor
        do {
            descriptor = try filter.resolved()
        } catch {
            // Switched rather than caught per case, so a refusal added to
            // `IRFilterDraftError` is a compile error here rather than a
            // refusal that loses its meaning on the way out.
            switch error {
            case .emptyFilterName:
                throw .emptyFilterName
            case .missingNominalCutoff:
                throw .missingNominalCutoff
            case .invalidNominalCutoff(let token, let reason):
                throw .invalidNominalCutoff(token: token, reason: reason)
            }
        }

        return IRCreativePreset(
            id: id,
            name: trimmedName,
            channelMix: channelMix,
            filter: descriptor
        )
    }

    /// Why this draft cannot be saved yet, or `nil` when it can.
    ///
    /// The same gate as `makePreset(id:channelMix:)`, asked without committing
    /// to an identity, so a form can disable its Save button and explain
    /// itself without generating identifiers it may never use.
    ///
    /// A fixed stand-in identity is used rather than a fresh one: this is read
    /// on every keystroke, and minting a UUID per character would make an
    /// identity generator out of a validity check. The mix is likewise a
    /// stand-in: validity depends on the name and the hint, and never on which
    /// matrix is being saved.
    public var refusal: IRCreativePresetDraftError? {
        do {
            _ = try makePreset(id: Self.validationID, channelMix: .identity)
            return nil
        } catch {
            return error
        }
    }

    /// A well-formed, unreserved identity used only to ask whether a draft is
    /// valid. It is never saved and never reaches a preset.
    private static let validationID = try! IRCreativePresetID("user.draft-validation")
}

/// Why a creative preset draft could not become a preset.
///
/// Value-level refusals from the editor, kept apart from
/// `IRCreativePresetPersistenceError` — which is about files — and from
/// `IRCreativePresetError` — which is about identities and composition.
public enum IRCreativePresetDraftError: Error, Equatable {

    /// The display name is empty, or is only whitespace.
    case emptyName

    /// A named filter hint was chosen and no name was given.
    case emptyFilterName

    /// A long-pass filter hint was chosen and no cutoff was given.
    case missingNominalCutoff

    /// A cutoff was given that could not describe a real filter.
    case invalidNominalCutoff(token: String, reason: String)

    /// The identity offered is in a namespace user presets may not claim.
    case reservedIdentifier(id: IRCreativePresetID, namespace: String)
}

extension IRCreativePresetDraftError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Give the preset a name."
        case .emptyFilterName:
            return "Enter a name for the filter, or choose \"Unknown\"."
        case .missingNominalCutoff:
            return "Enter a nominal cutoff for the filter, or choose \"Unknown\"."
        case .invalidNominalCutoff:
            return "That is not a usable nominal filter cutoff."
        case .reservedIdentifier:
            return "That creative preset identifier is reserved."
        }
    }

    public var failureReason: String? {
        switch self {
        case .emptyName:
            return """
                The name is what you will recognise this look by. It is not the preset's \
                identity, so you can change it later, and photographs you have already \
                applied it to are unaffected either way.
                """
        case .emptyFilterName:
            return "The filter hint is set to a named product and has no name."
        case .missingNominalCutoff:
            return """
                The filter hint is set to a nominal long-pass cutoff and has no value. The \
                number is what the filter is sold as — a family label, not a measurement, \
                and not a calibration of this look for that filter.
                """
        case .invalidNominalCutoff(let token, let reason):
            return "\"\(token)\": \(reason)"
        case .reservedIdentifier(let id, let namespace):
            return """
                "\(id)" is in the "\(namespace)." namespace, which is reserved for presets \
                this application might ship.
                """
        }
    }
}
