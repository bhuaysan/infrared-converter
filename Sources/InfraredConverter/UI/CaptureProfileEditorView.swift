import SwiftUI

/// The form for one capture profile: what camera, what conversion, what
/// filter — and, stated plainly, that none of it is a calibration.
///
/// ## What this view decides
///
/// Nothing. It edits an `IRCaptureProfileDraft`, which is mutable, possibly
/// invalid form state; the draft is the only thing that knows how to become an
/// `IRCaptureProfile`, and the library is the only thing that writes one. No
/// view here builds a matrix, chooses an identifier, or decides whether a
/// profile is valid.
///
/// ## What is deliberately not on this form
///
/// ```text
/// a 3×3 matrix field         there is no measured data, and a field for one
///                            would invite people to paste numbers nobody
///                            measured and call the result a calibration
/// a "Calibrated" checkbox    validation is something this project performs and
///                            reports, never something a user asserts
/// a processing-basis picker  every profile this version creates is explicitly
///                            uncalibrated; a chooser would imply otherwise
/// a spectral curve           a capture profile is context, not a filter model
/// ```
///
/// The calibration row is shown as a **fact**, read from the draft's basis
/// rather than written into this file, so the day a basis genuinely is
/// validated the form says so because it is true. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
struct CaptureProfileEditorView: View {

    /// Whether this is a new profile or a replacement for one that exists.
    ///
    /// It changes the title, the button, and one sentence of explanation — and
    /// nothing else, because creating and editing really are the same
    /// operation: a new immutable definition is written under an identity that
    /// is either freshly generated or preserved.
    enum Mode {
        case create
        /// Editing the definition stored under this identity. The identity is
        /// **kept**: renaming a profile must not orphan a single photograph.
        case edit(IRCaptureProfileID)
    }

    let mode: Mode

    /// The camera the open photograph records, offered as a prefill. `nil`
    /// when nothing is open or the file names no camera.
    let currentCamera: (make: String, model: String)?

    /// Writes the profile and returns it as stored.
    let save: (IRCaptureProfileDraft) throws -> IRCaptureProfile

    /// Assigns a just-saved profile to the open photograph. `nil` when there is
    /// no photograph that could take one.
    ///
    /// Optional, and behind its own button, because saving a profile and
    /// changing what a photograph is processed under are two decisions. See
    /// `docs/decisions/0021-user-capture-profile-library.md`.
    let assign: ((IRCaptureProfile) -> Void)?

    @State private var draft: IRCaptureProfileDraft
    @State private var failure: FailureMessage?
    @Environment(\.dismiss) private var dismiss

    init(
        mode: Mode,
        draft: IRCaptureProfileDraft,
        currentCamera: (make: String, model: String)? = nil,
        assign: ((IRCaptureProfile) -> Void)? = nil,
        save: @escaping (IRCaptureProfileDraft) throws -> IRCaptureProfile
    ) {
        self.mode = mode
        self.currentCamera = currentCamera
        self.assign = assign
        self.save = save
        _draft = State(initialValue: draft)
    }

    /// A refusal, kept as a title and a detail rather than flattened to one
    /// string, so the first line a person reads is not a decoder's description.
    private struct FailureMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Form {
                Section("Name") {
                    TextField("Name", text: $draft.name)
                        .accessibilityLabel("Capture profile name")
                    Text("""
                        What you will recognise this configuration by. The profile's \
                        identity is separate and never changes, so renaming it later \
                        affects no photograph.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                cameraSection
                conversionSection
                filterSection
                processingSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let refusal = draft.refusal {
                    Label(
                        refusal.errorDescription ?? "This profile is not complete.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(refusal.failureReason ?? "")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let assign {
                    Button("Save and Use for This Photograph") {
                        commit(then: assign)
                    }
                    .disabled(draft.refusal != nil)
                }
                Button(saveTitle) { commit(then: nil) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.refusal != nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 620)
        .alert(item: $failure) { failure in
            Alert(
                title: Text(failure.title),
                message: failure.detail.map(Text.init),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var title: String {
        switch mode {
        case .create: return "New Capture Profile"
        case .edit: return "Edit Capture Profile"
        }
    }

    private var saveTitle: String {
        switch mode {
        case .create: return "Save Profile"
        case .edit: return "Save Changes"
        }
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraSection: some View {
        Section("Camera") {
            Picker("Applies to", selection: $draft.cameraScope) {
                ForEach(IRCaptureProfileDraft.CameraScope.allCases) { scope in
                    Text(scope.shortDescription).tag(scope)
                }
            }

            if draft.cameraScope == .specificCamera {
                TextField("Make", text: $draft.cameraMake)
                TextField("Model", text: $draft.cameraModel)

                if let currentCamera {
                    Button("Use the Open Photograph's Camera") {
                        draft.useCamera(make: currentCamera.make, model: currentCamera.model)
                    }
                    Text("\(currentCamera.make) \(currentCamera.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("""
                    A profile that names a camera is checked against each photograph's \
                    make and model, exactly. It is a check, never a suggestion: nothing \
                    here picks a profile for you.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sensor conversion

    @ViewBuilder
    private var conversionSection: some View {
        Section("Sensor Conversion") {
            Picker("Conversion", selection: $draft.conversionKind) {
                ForEach(IRCaptureProfileDraft.ConversionKind.allCases) { kind in
                    Text(kind.shortDescription).tag(kind)
                }
            }

            if draft.conversionKind.hasVendor {
                TextField("Converted by (optional)", text: $draft.conversionVendor)
            }

            if draft.conversionKind.hasInternalFilter {
                filterFields(
                    "Internal filter",
                    filter: $draft.internalFilter
                )
            }

            Text("""
                What was done to the body, which is a different fact from the filter on \
                the lens. Two bodies of one model do not share infrared behaviour after \
                conversion, which is why the converter is worth recording.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - External filter

    @ViewBuilder
    private var filterSection: some View {
        Section("Filter on the Lens") {
            filterFields("Filter", filter: $draft.filter)

            Text("""
                A nominal wavelength is what the filter is sold as — a family label with a \
                transition band tens of nanometres wide — and not a measurement of this \
                capture. A profile can record either the nominal cutoff or a product name; \
                this version does not store both at once.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func filterFields(
        _ label: String, filter: Binding<IRCaptureProfileDraft.FilterDraft>
    ) -> some View {
        Picker(label, selection: filter.kind) {
            ForEach(IRCaptureProfileDraft.FilterDraft.Kind.allCases) { kind in
                Text(kind.shortDescription).tag(kind)
            }
        }

        switch filter.wrappedValue.kind {
        case .unknown:
            EmptyView()
        case .longPass:
            TextField(
                "Nominal cutoff (nm)", text: filter.nominalCutoffNanometers
            )
            .accessibilityLabel("\(label) nominal cutoff in nanometres")
        case .named:
            TextField("Product name", text: filter.name)
                .accessibilityLabel("\(label) product name")
        }
    }

    // MARK: - Processing

    @ViewBuilder
    private var processingSection: some View {
        Section("Processing") {
            LabeledContent(
                "Camera → working",
                value: IRCaptureProfileDraft.processingBasis.shortDescription
            )
            LabeledContent(
                "Calibration",
                value: IRCaptureProfileDraft.isValidatedInfraredCalibration ? "Validated" : "No"
            )
            Text("""
                Every profile this version creates renders camera-native sensor values \
                straight into the working space. That is a defined starting point, not a \
                measured infrared colour calibration, and naming a filter or a camera does \
                not make it one.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Saving

    /// Writes the profile, and only then does whatever was asked for next.
    ///
    /// A failure keeps the sheet open with the draft intact. Dismissing on a
    /// failed save would throw away everything a person had typed and leave
    /// them looking at a library that does not contain what they just wrote.
    private func commit(then next: ((IRCaptureProfile) -> Void)?) {
        do {
            let profile = try save(draft)
            next?(profile)
            dismiss()
        } catch let error as IRCaptureProfileDraftError {
            failure = FailureMessage(
                title: error.errorDescription ?? "This profile is not complete.",
                detail: error.failureReason
            )
        } catch let error as IRCaptureProfilePersistenceError {
            failure = FailureMessage(
                title: error.errorDescription ?? "The capture profile could not be saved.",
                detail: error.failureReason
            )
        } catch {
            failure = FailureMessage(
                title: "The capture profile could not be saved.",
                detail: error.localizedDescription
            )
        }
    }
}
