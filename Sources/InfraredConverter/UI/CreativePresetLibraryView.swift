import SwiftUI

/// The creative preset library: what is saved, and the four things a person can
/// do with one.
///
/// ```text
/// 590 nm Gold              590 nm nominal long-pass   explicit 3×3
/// Hoya R72 Variant         Hoya R72                   explicit 3×3
/// My 720 nm Blue Sky       720 nm nominal long-pass   explicit 3×3
/// Swap Only                — no filter recorded —     red/blue swap
///
/// [ Apply to Photograph ]  [ Open in Matrix Editor… ]  [ Rename… ]  [ Delete… ]
/// ```
///
/// ## What it is not
///
/// Not a settings application, not an importer and not a marketplace. There is
/// no drag and drop, no share button, no package format, no sync, no search and
/// no sort control: a preset is a small JSON file in an application-owned
/// folder, presented in one deterministic order.
///
/// ## Applying is explicit, and it is the only thing that touches a photograph
///
/// Nothing here happens on its own. No preset is applied because a photograph's
/// capture profile names the same wavelength, because a file was opened, or
/// because a preset was created. When a person does apply one, it goes to
/// `DocumentState.setChannelMix` — the same entry point the menu's Identity and
/// Red/Blue Swap use — and the photograph's sidecar then records the resolved
/// mix, exactly as it would have if the matrix had been typed by hand.
///
/// ## Deleting one changes no photograph
///
/// Unlike deleting a capture profile, which leaves photographs unable to open
/// until they are reassigned, deleting a preset costs a person a shortcut and
/// nothing else. No photograph refers to a preset: each one holds the resolved
/// `UserChannelMixAdjustment` in its own sidecar. The alert says so, because a
/// person who has met the capture-profile warning has every reason to expect
/// this one to be worse. See
/// `docs/decisions/0024-reusable-creative-presets.md`.
struct CreativePresetLibraryView: View {
    let library: IRCreativePresetLibrary
    let documentState: DocumentState

    @State private var selection: IRCreativePresetID?
    @State private var renaming: IRCreativePreset?
    @State private var inspecting: IRCreativePreset?
    @State private var pendingDeletion: IRCreativePreset?
    @State private var failure: FailureMessage?
    @Environment(\.dismiss) private var dismiss

    private struct FailureMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            loadFailureBanner
            list
            Divider()
            actions
        }
        .frame(width: 580, height: 480)
        .sheet(item: $renaming) { preset in
            CreativePresetSaveView(
                mode: .rename(preset.id),
                draft: IRCreativePresetDraft(preset),
                // The stored preset's own mix, carried through untouched: a
                // rename changes a name and a hint, and never a matrix.
                channelMix: preset.channelMix,
                save: { draft in
                    try library.update(
                        draft, id: preset.id, channelMix: preset.channelMix
                    )
                }
            )
        }
        .sheet(item: $inspecting) { preset in
            // The existing matrix editor, seeded with the preset's
            // coefficients. There is deliberately no second editor: this is how
            // a preset's mix is inspected, and its Apply sets the **open
            // photograph's** mix, leaving the stored preset as it is.
            ChannelMixEditorView(
                current: preset.channelMix,
                apply: documentState.setChannelMix
            )
        }
        .alert(item: $pendingDeletion) { preset in
            Alert(
                title: Text("Delete “\(preset.name)”?"),
                message: Text("""
                    Photographs you developed with this preset are not affected in any way. \
                    Each one stores the channel mix itself, not a reference to this preset, \
                    so every image still renders exactly as it does now. What you lose is \
                    the shortcut.
                    """),
                primaryButton: .destructive(Text("Delete Preset")) { delete(preset) },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $failure) { failure in
            Alert(
                title: Text(failure.title),
                message: failure.detail.map(Text.init),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Creative Presets")
                .font(.title3.weight(.semibold))
            Text("""
                A preset is a channel mix you saved to use again. Applying one replaces the \
                photograph's mix; it changes nothing else — not the white balance, the \
                exposure, the rotation or the capture profile. A filter recorded on a preset \
                is a note about what its author used it with, not a calibration and not a \
                rule: nothing is applied automatically because a wavelength matches.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    @ViewBuilder
    private var loadFailureBanner: some View {
        if !library.loadFailures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    summary(library.loadFailures),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)

                ForEach(Array(library.loadFailures.enumerated()), id: \.offset) { _, failure in
                    Text(failureDetail(failure))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var list: some View {
        if library.isEmpty {
            VStack(spacing: 6) {
                Text("No presets yet")
                    .foregroundStyle(.secondary)
                Text("""
                    Develop a channel mix you like, then choose “Save Current Mix as \
                    Preset…” in the Channel Mix menu.
                    """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
        } else {
            List(selection: $selection) {
                ForEach(library.presets) { preset in
                    row(preset).tag(preset.id)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ preset: IRCreativePreset) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                Text(preset.channelMix.diagnosticDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let label = preset.filterLabel {
                // Worded and placed as a context label. The help text is where
                // the number is explained, because a badge has no room to.
                badge(label)
                    .help("""
                        A filter family the author suggests this look for. A nominal \
                        wavelength is not a measured spectral response, and this preset is \
                        not calibrated for that filter.
                        """)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preset.diagnosticDescription)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Apply to Photograph") {
                guard let preset = selectedPreset else { return }
                apply(preset)
            }
            .disabled(selectedPreset == nil || !documentState.canAdjust)
            .help("""
                Replaces the photograph's channel mix with this preset's. Nothing else \
                changes, and the mix is not combined with the one already in force.
                """)

            Button("Open in Matrix Editor…") {
                inspecting = selectedPreset
            }
            .disabled(selectedPreset == nil || !documentState.canAdjust)
            .help("""
                Shows this preset's nine coefficients in the channel mixer. Applying from \
                there sets the photograph's mix; the preset itself is unchanged.
                """)

            Button("Rename…") { renaming = selectedPreset }
                .disabled(selectedPreset == nil)
                .help("""
                    Changes the name and the filter note. The preset keeps its identity, and \
                    no photograph is affected either way.
                    """)

            Button("Delete…") { pendingDeletion = selectedPreset }
                .disabled(selectedPreset == nil)

            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private var selectedPreset: IRCreativePreset? {
        guard let selection else { return nil }
        return library.preset(for: selection)
    }

    /// The one path from this view to a photograph.
    ///
    /// A preset resolves to a `UserChannelMixAdjustment`, and that value goes to
    /// the same `setChannelMix` every other mix control uses. Nothing is
    /// composed with the current mix, no matrix is applied here, and no other
    /// adjustment is touched.
    private func apply(_ preset: IRCreativePreset) {
        documentState.setChannelMix(preset.channelMix)
    }

    private func delete(_ preset: IRCreativePreset) {
        do {
            try library.delete(preset.id)
            selection = nil
        } catch {
            failure = FailureMessage(
                title: error.errorDescription ?? "The preset could not be deleted.",
                detail: error.failureReason
            )
        }
    }

    // MARK: - Wording

    private func summary(_ failures: [IRCreativePresetPersistenceError]) -> String {
        failures.count == 1
            ? "1 preset could not be loaded."
            : "\(failures.count) presets could not be loaded."
    }

    private func failureDetail(_ failure: IRCreativePresetPersistenceError) -> String {
        let headline = failure.errorDescription ?? "A preset could not be loaded."
        guard let reason = failure.failureReason else { return headline }
        return "\(headline) \(reason)"
    }
}
