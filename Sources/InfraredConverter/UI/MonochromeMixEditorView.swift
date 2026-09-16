import SwiftUI

/// The monochrome channel-mix editor: three contribution coefficients, applied
/// as an ordinary creative 3×3 mix.
///
/// ## What this view decides
///
/// Nothing about the image, and nothing new about the pipeline. It edits a
/// `MonochromeMixDraft` — three strings — and, when they are three numbers,
/// hands `UserChannelMixAdjustment.explicit` to `DocumentState.setChannelMix`,
/// the same entry point the built-in mixes, the matrix editor and the creative
/// presets all use. The matrix it builds has three identical rows:
///
/// ```text
///          ⎡ r g b ⎤         Rout = r·R + g·G + b·B
/// output = ⎢ r g b ⎥   so    Gout = r·R + g·G + b·B
///          ⎣ r g b ⎦         Bout = r·R + g·G + b·B
/// ```
///
/// so all three output channels carry the same scene-linear value. That is the
/// whole mechanism: there is no monochrome stage, no saturation control and no
/// new persisted state. See
/// `docs/decisions/0025-monochrome-channel-mix-authoring.md`.
///
/// ## Applying replaces
///
/// A channel mix is canonical state rather than command history, so applying a
/// monochrome mix over an existing one yields `M2`, never `M2 × M1`. The view
/// says so in as many words, because a person who has just authored a colour
/// mix would otherwise have to guess.
///
/// ## What is deliberately absent
///
/// ```text
/// normalisation to r+g+b = 1   a scale is a brightness decision the person
///                              is entitled to make
/// clamping to 0…1              negative and amplifying contributions are
///                              ordinary infrared authoring
/// a luminance preset           no Rec. 709, Rec. 601 or perceptual weighting:
///                              this is infrared false colour, whose channels
///                              do not carry those meanings
/// a filter or wavelength       nothing here reads a capture profile, and no
///                              coefficient is derived from 590/665/720/830 nm
/// ```
///
/// The only numeric requirement is the matrix primitive's own — every
/// coefficient finite. A field holding anything else is marked, and a complete
/// draft holding `inf` or `nan` is **refused by the matrix** with its own
/// typed error rather than quietly repaired.
struct MonochromeMixEditorView: View {

    /// The mix in force when the editor opened. The fields start from its
    /// coefficients when it is already monochrome, and from `Equal RGB` when
    /// it is not.
    let current: UserChannelMixAdjustment

    /// Commits the authored matrix as the photograph's canonical mix.
    let apply: (UserChannelMixAdjustment) -> Void

    @State private var draft: MonochromeMixDraft
    @State private var refusal: String?
    @Environment(\.dismiss) private var dismiss

    init(
        current: UserChannelMixAdjustment,
        apply: @escaping (UserChannelMixAdjustment) -> Void
    ) {
        self.current = current
        self.apply = apply
        _draft = State(initialValue: MonochromeMixDraft(seeding: current))
    }

    private static let channels = MonochromeMixDraft.channels

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Monochrome Channel Mix")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            Text("""
                One weighted sum of the working RGB channels, written to all three output \
                channels. Creative infrared authoring — not a luminance formula, and not a \
                camera, filter or calibration claim.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            equation
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            fields
                .padding(.horizontal, 20)

            startingPoints
                .padding(.horizontal, 20)
                .padding(.top, 14)

            Text("""
                All three output channels use the same weighted sum, so the result is \
                achromatic. Negative contributions, values above 1 and weights that do not \
                sum to 1 are all allowed and are left exactly as typed: nothing here \
                normalises or clamps. Applying replaces the current channel mix.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            Spacer(minLength: 12)

            Divider()

            HStack(spacing: 12) {
                if let refusal {
                    Label(refusal, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !draft.isComplete {
                    Label(
                        "Every contribution needs a number before the mix can be applied.",
                        systemImage: "pencil"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Monochrome", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isComplete)
            }
            .padding(16)
        }
        .frame(width: 420)
    }

    /// The single equation, written the way the processing stage performs it.
    @ViewBuilder
    private var equation: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rout = Gout = Bout = r·R + g·G + b·B")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// One labelled field per input channel, bound to the draft's text rather
    /// than to a number, so a half-typed contribution stays half-typed instead
    /// of resolving to zero.
    @ViewBuilder
    private var fields: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(Self.channels, id: \.storageOffset) { channel in
                GridRow {
                    Text("\(MonochromeMixDraft.name(for: channel)) contribution")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    contributionField(channel)
                }
            }
        }
    }

    @ViewBuilder
    private func contributionField(_ channel: RAWLinearRGBChannel) -> some View {
        let isCoefficient = draft.isCoefficient(channel)
        let letter = MonochromeMixDraft.label(for: channel)
        TextField(
            letter,
            text: Binding(
                get: { draft[contribution: channel] },
                set: { text in
                    draft[contribution: channel] = text
                    // A refusal describes the draft that was submitted. Once
                    // any field changes it no longer does, so it goes.
                    refusal = nil
                }
            )
        )
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: 110)
        .foregroundStyle(isCoefficient ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
        .help(isCoefficient
            ? "How much input \(letter) contributes to the single output value"
            : "Not a finite number yet")
        .accessibilityLabel(
            "\(MonochromeMixDraft.name(for: channel)) contribution"
        )
    }

    /// The four fixed starting points. Each one only fills the three fields;
    /// nothing is applied until Apply.
    @ViewBuilder
    private var startingPoints: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(IRMonochromeMix.startingPoints) { point in
                    Button(point.name) {
                        draft = MonochromeMixDraft(point.mix)
                        refusal = nil
                    }
                }
            }
            Text("""
                Starting points only — they fill the fields and change nothing until you \
                apply. Equal RGB is the arithmetic mean (R + G + B) ÷ 3, not a perceptual \
                or colorimetric luminance.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Commits the three fields, or reports the primitive's refusal.
    ///
    /// The refusal is `RAWColorMatrix3x3`'s own — the existing numeric
    /// contract — rather than a rule restated here. Nothing is applied when it
    /// throws, and the canonical adjustment is left as it was.
    private func commit() {
        do {
            guard let adjustment = try draft.adjustment() else {
                // The button is disabled in this state; reaching it would mean
                // a field stopped being a number between the check and the tap.
                refusal = "Every contribution needs a number before the mix can be applied."
                return
            }
            apply(adjustment)
            dismiss()
        } catch let error as RAWProcessingError {
            refusal = error.errorDescription ?? "That mix was refused."
        } catch {
            refusal = error.localizedDescription
        }
    }
}
