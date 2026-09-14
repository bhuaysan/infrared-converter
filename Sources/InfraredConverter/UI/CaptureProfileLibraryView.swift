import SwiftUI

/// The capture-profile library: what is installed, and the four things a person
/// can do to it.
///
/// ```text
/// Uncalibrated / Generic        Built-in
/// My Olympus E-PL3 — R72        User
/// My Full Spectrum 590          User
///
/// [ New… ]  [ New from Current Camera… ]  [ Edit ]  [ Delete ]
/// ```
///
/// ## What it is not
///
/// Not a settings application, and not an importer. There is no drag and drop,
/// no share button, no package format and no sync: a profile is a small JSON
/// file in an application-owned folder, and moving one between machines is a
/// milestone of its own rather than a button somebody adds on the way past.
///
/// ## Two things this view refuses to do
///
/// The built-in profile cannot be renamed, edited or deleted. It is a value
/// this build holds rather than a file, it is what every historical photograph
/// migrates to, and it is the one profile guaranteed to exist however badly the
/// library is doing.
///
/// A profile the open photograph is using cannot be deleted while it is using
/// it. The alternative — deleting it and leaving the document rendering under a
/// definition that is no longer installed — is a state whose only symptom
/// appears the next time that file is opened. Reassigning the photograph first
/// is one click, and it makes the consequence visible while the person is still
/// thinking about it. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
struct CaptureProfileLibraryView: View {
    let library: IRCaptureProfileLibrary
    let documentState: DocumentState

    @State private var selection: IRCaptureProfileID?
    @State private var editor: EditorRequest?
    @State private var pendingDeletion: IRCaptureProfile?
    @State private var failure: FailureMessage?
    @Environment(\.dismiss) private var dismiss

    private struct EditorRequest: Identifiable {
        let id = UUID()
        let mode: CaptureProfileEditorView.Mode
        let draft: IRCaptureProfileDraft
    }

    private struct FailureMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            loadFailureBanner
            profileList
            Divider()
            actions
        }
        .frame(width: 560, height: 480)
        .sheet(item: $editor) { request in
            CaptureProfileEditorView(
                mode: request.mode,
                draft: request.draft,
                currentCamera: documentState.currentCameraIdentity,
                assign: assignAction(for: request.mode),
                save: { draft in
                    switch request.mode {
                    case .create:
                        return try library.create(draft)
                    case .edit(let id):
                        return try library.update(draft, id: id)
                    }
                }
            )
        }
        .alert(item: $pendingDeletion) { profile in
            Alert(
                title: Text("Delete “\(profile.name)”?"),
                message: Text("""
                    Photographs that reference this profile will no longer open with their \
                    saved processing state until another profile is assigned to them. \
                    Nothing is scanned and no photograph is changed: their settings stay \
                    exactly as they are, and each one can be reopened under another profile.
                    """),
                primaryButton: .destructive(Text("Delete Profile")) { delete(profile) },
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
            Text("Capture Profiles")
                .font(.title3.weight(.semibold))
            Text("""
                A capture profile describes how a photograph was made — the camera, what was \
                done to its sensor, and the filter. One profile can be used by any number of \
                photographs; each photograph keeps its own white balance, rotation, channel \
                mix and exposure.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
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

                // The detail, each failure naming what it is about. Not a
                // decoder's description as the first thing a person reads, and
                // not hidden either: a profile somebody spent time creating
                // must never vanish without a word.
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

    private var profileList: some View {
        List(selection: $selection) {
            ForEach(library.profilesForDisplay) { profile in
                row(profile)
                    .tag(profile.id)
            }
        }
        .listStyle(.inset)
    }

    private func row(_ profile: IRCaptureProfile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(profile.diagnosticDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if library.isBuiltin(profile.id) {
                badge("Built-in")
            } else if documentState.captureProfile.id == profile.id,
                      documentState.canAdjust {
                badge("In use")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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
            Button("New…") { editor = EditorRequest(mode: .create, draft: newDraft()) }

            if documentState.currentCameraIdentity != nil {
                Button("New from Current Camera…") {
                    editor = EditorRequest(mode: .create, draft: newDraft(usingCurrentCamera: true))
                }
                .help("""
                    Fills in the make and model of the open photograph's camera. The \
                    conversion and the filter are yours to describe: nothing about them can \
                    be read from the file.
                    """)
            }

            Button("Edit…") {
                guard let profile = selectedEditableProfile else { return }
                editor = EditorRequest(
                    mode: .edit(profile.id), draft: IRCaptureProfileDraft(profile)
                )
            }
            .disabled(selectedEditableProfile == nil)
            .help(editHelp)

            Button("Delete…") {
                guard let profile = selectedEditableProfile else { return }
                pendingDeletion = profile
            }
            .disabled(!canDeleteSelection)
            .help(deleteHelp)

            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - What the selection allows

    private var selectedProfile: IRCaptureProfile? {
        guard let selection else { return nil }
        return try? library.registry.profile(for: selection)
    }

    /// The selected profile, when it is one a person may change at all.
    private var selectedEditableProfile: IRCaptureProfile? {
        guard let profile = selectedProfile, !library.isBuiltin(profile.id) else { return nil }
        return profile
    }

    /// Whether the open photograph is currently processed under the selection.
    private var selectionIsInUse: Bool {
        guard let profile = selectedEditableProfile, documentState.canAdjust else { return false }
        return documentState.captureProfile.id == profile.id
    }

    private var canDeleteSelection: Bool {
        selectedEditableProfile != nil && !selectionIsInUse
    }

    private var editHelp: String {
        if selectedProfile != nil, selectedEditableProfile == nil {
            return "The built-in profile cannot be changed."
        }
        return """
            Editing a profile changes it for every photograph that uses it, the next time \
            each one is opened.
            """
    }

    private var deleteHelp: String {
        if selectedProfile != nil, selectedEditableProfile == nil {
            return "The built-in profile cannot be deleted."
        }
        if selectionIsInUse {
            return """
                The open photograph is using this profile. Assign it another one first, so \
                that what happens to it is a choice rather than a surprise the next time it \
                is opened.
                """
        }
        return "Photographs that use this profile will not open until they are reassigned."
    }

    // MARK: - Actions

    /// A blank draft, or one with the open photograph's camera filled in.
    private func newDraft(usingCurrentCamera: Bool = false) -> IRCaptureProfileDraft {
        var draft = IRCaptureProfileDraft()
        if usingCurrentCamera, let camera = documentState.currentCameraIdentity {
            draft.useCamera(make: camera.make, model: camera.model)
        }
        return draft
    }

    /// Offering to use a newly created profile for the open photograph — only
    /// for a new one, and only when there is a photograph that could take it.
    ///
    /// Editing an existing profile does not offer it: the photograph either
    /// already uses that profile or deliberately does not, and a button that
    /// changed which would be doing a second thing under the name of the first.
    private func assignAction(
        for mode: CaptureProfileEditorView.Mode
    ) -> ((IRCaptureProfile) -> Void)? {
        guard case .create = mode, documentState.canAdjust else { return nil }
        return { profile in documentState.setCaptureProfile(profile) }
    }

    private func delete(_ profile: IRCaptureProfile) {
        do {
            try library.delete(profile.id)
            selection = nil
        } catch {
            failure = FailureMessage(
                title: error.errorDescription ?? "The capture profile could not be deleted.",
                detail: error.failureReason
            )
        }
    }

    // MARK: - Wording

    private func summary(_ failures: [IRCaptureProfilePersistenceError]) -> String {
        failures.count == 1
            ? "1 capture profile could not be loaded."
            : "\(failures.count) capture profiles could not be loaded."
    }

    private func failureDetail(_ failure: IRCaptureProfilePersistenceError) -> String {
        let headline = failure.errorDescription ?? "A capture profile could not be loaded."
        guard let reason = failure.failureReason else { return headline }
        return "\(headline) \(reason)"
    }
}
