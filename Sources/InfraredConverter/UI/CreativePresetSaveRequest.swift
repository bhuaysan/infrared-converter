import Foundation

/// One request to save the photograph's channel mix as a preset: the mix, as
/// it was at the moment a person asked.
///
/// ## Why this is a value rather than a pair of reads
///
/// "Save the mix that is on screen" sounds like one sentence and is two
/// questions, asked at two different times:
///
/// ```text
/// the sheet opens      which mix is this sheet about?
/// Save is pressed      which mix is written to the library?
/// ```
///
/// A person types a name in between, and a name takes seconds. In those
/// seconds the photograph's mix can change — a preset applied from the same
/// menu, a matrix committed in the editor, a render settling — and if the two
/// questions are answered by reading `DocumentState` twice, the second answer
/// is not the first. The sheet would then show one matrix and store another,
/// with nothing said.
///
/// So the mix is read **once**, here, and this value is what both the sheet and
/// the save use. There is one snapshot and therefore one answer.
///
/// ```text
/// Button tapped  →  CreativePresetSaveRequest(snapshotOf:)   reads the document once
///                          ↓                    ↓
///                    displayed by          commit(_:to:)     writes the same value
///                 CreativePresetSaveView
/// ```
///
/// It is not a second channel-mix representation. The field is an ordinary
/// `UserChannelMixAdjustment` — the project's one user-facing mix state — held
/// still for the life of a sheet. See
/// `docs/decisions/0024-reusable-creative-presets.md`.
///
/// ## Why it is `Identifiable`
///
/// Because the sheet is presented with `.sheet(item:)` rather than
/// `.sheet(isPresented:)`, and that is part of the fix rather than a style
/// choice. A presented-by-`Bool` sheet re-evaluates its content closure
/// whenever the parent's body re-renders, so a snapshot taken *inside* that
/// closure is re-taken on every re-render and is not a snapshot at all. Bound
/// to an item, the value is stored in `@State` when the button is tapped and
/// SwiftUI hands that same value back for as long as the sheet lives.
struct CreativePresetSaveRequest: Identifiable {

    /// Distinguishes one save request from the next. A fresh identity per tap,
    /// so asking again after cancelling presents a new sheet rather than
    /// reviving the old one.
    let id = UUID()

    /// The mix this request is about: the photograph's, as it was when the
    /// request was made.
    ///
    /// Shown by the sheet and written by `commit(_:to:)` — the same value in
    /// both places, which is the whole point of the type.
    let channelMix: UserChannelMixAdjustment

    /// The form's starting state: an empty name, and a filter note prefilled
    /// from the capture profile when it records one.
    let draft: IRCreativePresetDraft

    /// What the filter note was prefilled from, for the sheet to say so, or
    /// `nil` when nothing was prefilled.
    let prefilledFrom: String?

    init(
        channelMix: UserChannelMixAdjustment,
        draft: IRCreativePresetDraft = IRCreativePresetDraft(),
        prefilledFrom: String? = nil
    ) {
        self.channelMix = channelMix
        self.draft = draft
        self.prefilledFrom = prefilledFrom
    }

    /// The request a document produces when somebody asks to save its mix.
    ///
    /// **The one and only read of `DocumentState` in this flow.** Everything
    /// afterwards — what the sheet displays, what the library stores — comes
    /// from the value this builds.
    ///
    /// The capture profile's filter is copied here for the same reason and with
    /// the same meaning as every other field: it is a prefill, taken once,
    /// which editing or deleting that profile afterwards cannot reach. See
    /// ADR 0024, Decision 7.
    @MainActor
    init(snapshotOf documentState: DocumentState) {
        let profile = documentState.captureProfile
        let hasFilter = documentState.canAdjust && profile.filter.isKnown

        var draft = IRCreativePresetDraft()
        if hasFilter { draft.useFilter(from: profile) }

        self.init(
            channelMix: documentState.channelMixAdjustment,
            draft: draft,
            prefilledFrom: hasFilter
                ? "the capture profile “\(profile.name)”"
                : nil
        )
    }

    /// Stores the preset, carrying the **snapshotted** mix rather than
    /// whatever the document holds now.
    ///
    /// `self.channelMix`, deliberately and unmissably: a re-read of the
    /// document here is the defect this type exists to make unrepresentable,
    /// and there is no document in scope to re-read.
    ///
    /// The name and filter note are the caller's, because those are what the
    /// person edited while the sheet was open. The mix is not, because it is
    /// not something the sheet edits.
    ///
    /// Saving a preset touches no photograph: it writes to the preset library
    /// and nothing else.
    ///
    /// - Throws: `IRCreativePresetDraftError` for a draft that does not
    ///   describe a preset, `IRCreativePresetPersistenceError` for one that
    ///   could not be written.
    @MainActor
    @discardableResult
    func commit(
        _ edited: IRCreativePresetDraft, to library: IRCreativePresetLibrary
    ) throws -> IRCreativePreset {
        try library.create(edited, channelMix: channelMix)
    }
}
