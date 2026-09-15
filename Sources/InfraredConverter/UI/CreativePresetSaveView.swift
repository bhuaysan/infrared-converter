import SwiftUI

/// Saving the mix that is on screen as a reusable preset, or renaming one that
/// already exists.
///
/// ## What this view decides
///
/// A name, and optionally which filter family the author suggests the look for.
/// It never decides a matrix: the mix being saved is handed in, already
/// authored, already applied and already visible in the photograph. A save
/// sheet that could also edit coefficients would be a second channel-mix
/// editor, and this project has one.
///
/// ```text
/// Name              [ My 720 nm Blue Sky        ]
/// Filter hint       [ Long-pass (nominal nm) ▾ ] [ 720 ]  590 665 720 830
///
/// Mix being saved   explicit 3×3 matrix (creative; no calibration claim)
/// ```
///
/// ## The filter hint says what it is
///
/// A nominal wavelength identifies a **filter family**. It is not a measured
/// spectral response, two products sold as "720 nm" are not interchangeable,
/// and a preset carrying the label is not calibrated for that filter — it is a
/// look somebody liked and wrote a number beside. The sheet says so in as many
/// words, because the one place a person is most likely to read the number as a
/// claim is the moment they type it.
///
/// Nothing consults the hint. It selects nothing, enables nothing and disables
/// nothing, and no preset is ever applied because a photograph's capture
/// profile happens to name the same wavelength.
///
/// ## The capture profile's filter is a prefill
///
/// When the open photograph's capture profile records a filter, the field
/// starts there — it is a reasonable first guess and saves retyping `720`. It
/// is copied once, when the sheet opens, and is then the draft's own: editing
/// or deleting that capture profile afterwards changes nothing here and nothing
/// about a preset saved from here. See
/// `docs/decisions/0024-reusable-creative-presets.md`.
struct CreativePresetSaveView: View {

    /// Whether this sheet creates a preset or replaces an existing definition.
    enum Mode: Equatable {
        /// Save the photograph's current mix as a new preset.
        case create
        /// Replace the definition stored under this identity, keeping its mix.
        case rename(IRCreativePresetID)

        var title: String {
            switch self {
            case .create: return "Save Mix as Preset"
            case .rename: return "Rename Preset"
            }
        }

        var confirmation: String {
            switch self {
            case .create: return "Save Preset"
            case .rename: return "Save Changes"
            }
        }
    }

    let mode: Mode

    /// The mix this preset will carry.
    ///
    /// Handed in rather than read from a document, so that what is saved is the
    /// decision the person was looking at when they pressed the menu item, and
    /// not whatever the mix has become by the time they finish typing a name.
    let channelMix: UserChannelMixAdjustment

    /// Where the filter hint's prefill came from, when it came from somewhere.
    /// Shown so the copy is visible rather than mysterious.
    let prefilledFrom: String?

    /// Stores the preset. Throws whatever the library throws.
    let save: (IRCreativePresetDraft) throws -> IRCreativePreset

    @State private var draft: IRCreativePresetDraft
    @State private var refusal: String?
    @Environment(\.dismiss) private var dismiss

    /// The sheet for saving a photograph's current mix, built from the
    /// snapshot taken when the person asked.
    ///
    /// **The create path has this initialiser and no other, deliberately.** The
    /// designated one below takes the displayed mix and the save action as two
    /// separate arguments, which is exactly the shape that allowed them to
    /// disagree: the sheet showed the snapshot while the save re-read the
    /// document, so a mix changed during typing was shown and not stored. Here
    /// there is one argument, and the displayed value and the committed value
    /// are the same field of it. They cannot drift apart because there is
    /// nothing to drift.
    ///
    /// The designated initialiser remains for renaming, where the mix is the
    /// stored preset's and the action replaces a definition rather than
    /// creating one.
    @MainActor
    init(request: CreativePresetSaveRequest, library: IRCreativePresetLibrary) {
        self.init(
            mode: .create,
            draft: request.draft,
            channelMix: request.channelMix,
            prefilledFrom: request.prefilledFrom,
            save: { edited in try request.commit(edited, to: library) }
        )
    }

    init(
        mode: Mode,
        draft: IRCreativePresetDraft,
        channelMix: UserChannelMixAdjustment,
        prefilledFrom: String? = nil,
        save: @escaping (IRCreativePresetDraft) throws -> IRCreativePreset
    ) {
        self.mode = mode
        self.channelMix = channelMix
        self.prefilledFrom = prefilledFrom
        self.save = save
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            form
            Spacer(minLength: 12)
            Divider()
            actions
        }
        .frame(width: 480)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mode.title)
                .font(.title3.weight(.semibold))
            Text("""
                A preset is a creative starting point you can apply to other photographs. \
                It is not a calibration, and it changes nothing about a photograph you have \
                already developed.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("Name") {
                TextField("My 720 nm Blue Sky", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            filterSection

            LabeledContent("Mix") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channelMix.diagnosticDescription)
                    if case .rename = mode {
                        Text("Renaming leaves this mix exactly as it is.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Filter") {
                Picker("Filter", selection: $draft.filter.kind) {
                    ForEach(IRFilterDraft.Kind.allCases) { kind in
                        Text(kind.shortDescription).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            switch draft.filter.kind {
            case .unknown:
                caption("""
                    No filter recorded. A preset without a filter hint is a preset about a \
                    look rather than about equipment, and it can be applied to anything.
                    """)

            case .longPass:
                HStack(spacing: 8) {
                    TextField("720", text: $draft.filter.nominalCutoffNanometers)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text("nm nominal")
                        .foregroundStyle(.secondary)
                    ForEach(IRFilterDescriptor.commonNominalCutoffsNanometers, id: \.self) { value in
                        Button(String(Int(value))) {
                            draft.filter.nominalCutoffNanometers = String(Int(value))
                        }
                        .buttonStyle(.link)
                    }
                }
                caption("""
                    A family label, not a measurement: the number is what the filter is sold \
                    as. Two products sold as the same wavelength are not interchangeable, \
                    this preset is not calibrated for that filter, and nothing is ever \
                    applied automatically because a wavelength matches. Any cutoff is \
                    allowed — the four shortcuts are only common ones.
                    """)

            case .named:
                TextField("Hoya R72", text: $draft.filter.name)
                    .textFieldStyle(.roundedBorder)
                caption("""
                    A product name, recorded as context. No spectral data is implied or \
                    stored.
                    """)
            }

            if let prefilledFrom {
                caption("""
                    Filled in from \(prefilledFrom). It is a copy: changing or deleting that \
                    capture profile later will not change this preset.
                    """)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let message = refusal ?? draft.refusal?.errorDescription {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(mode.confirmation, action: commit)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.refusal != nil)
        }
        .padding(16)
    }

    /// Stores the preset, or reports the refusal the library gave.
    ///
    /// Nothing is applied to any photograph here: saving a preset is a library
    /// operation, and the mix it carries is already the one on screen.
    private func commit() {
        do {
            _ = try save(draft)
            dismiss()
        } catch let error as IRCreativePresetDraftError {
            refusal = error.errorDescription
        } catch let error as IRCreativePresetPersistenceError {
            refusal = error.errorDescription
        } catch {
            refusal = error.localizedDescription
        }
    }
}
