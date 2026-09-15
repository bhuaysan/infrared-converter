import SwiftUI

/// The creative 3×3 channel-mixer editor: nine coefficients, labelled by what
/// they do.
///
/// ## What this view decides
///
/// Nothing about the image. It edits a `ChannelMixMatrixDraft` — nine strings
/// — and, when they are nine numbers, hands
/// `UserChannelMixAdjustment.explicit` to `DocumentState`. The matrix is
/// applied by `IRChannelMixer`, to the retained pre-mix scene-linear preview,
/// exactly as the built-in mixes are: authoring one changes which
/// `UserChannelMixAdjustment` is canonical and nothing else about the
/// pipeline.
///
/// ## The convention is shown, not translated
///
/// Rows are output channels and columns are input channels, which is
/// `RAWColorMatrix3x3`'s own convention, and the three equations are printed
/// above the grid so that a person can see which cell is which coefficient:
///
/// ```text
///              input R   input G   input B
/// output R       m00       m01       m02
/// output G       m10       m11       m12
/// output B       m20       m21       m22
/// ```
///
/// Transposing it for typing convenience was rejected: a user who reads the
/// equations here and the matrix in the sidecar must see the same nine numbers
/// in the same nine places.
///
/// ## What is deliberately absent
///
/// ```text
/// clamping to 0…1        negative and amplifying coefficients are ordinary
///                         infrared mixes
/// row normalisation      a row that does not sum to 1 is a brightness
///                         decision, and repairing it would author a matrix
///                         the user did not type
/// a luminance lock       same reason
/// a singularity guard    a monochrome collapse is a legitimate creative mix
/// a "Calibrated" claim   this is creative colour, not a measured transform
/// ```
///
/// The only numeric requirement is the matrix primitive's own: every
/// coefficient is finite. A field holding something that is not a finite
/// number is marked, and a complete draft that holds `inf` or `nan` is
/// **refused by the matrix** with its own typed error rather than quietly
/// repaired.
///
/// See `docs/decisions/0023-authoring-a-creative-channel-mix.md`.
struct ChannelMixEditorView: View {

    /// The mix in force when the editor opened — the fields start from its
    /// matrix, so "Custom Matrix…" opens on what is on screen.
    let current: UserChannelMixAdjustment

    /// Commits an authored matrix as the photograph's canonical mix.
    let apply: (UserChannelMixAdjustment) -> Void

    @State private var draft: ChannelMixMatrixDraft
    @State private var refusal: String?
    @Environment(\.dismiss) private var dismiss

    init(
        current: UserChannelMixAdjustment,
        apply: @escaping (UserChannelMixAdjustment) -> Void
    ) {
        self.current = current
        self.apply = apply
        _draft = State(initialValue: ChannelMixMatrixDraft(current))
    }

    private static let channels = ChannelMixMatrixDraft.channels

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Creative Channel Mixer")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            Text("""
                A 3×3 mix of the working RGB channels. Creative infrared colour — not a \
                camera or filter calibration, and not a measured transform.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            equations
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            grid
                .padding(.horizontal, 20)

            Text("""
                Rows are output channels, columns are input channels. Negative \
                coefficients, values above 1, rows that do not sum to 1 and \
                colour-collapsing matrices are all allowed and are left exactly as \
                typed: nothing here normalises, clamps or preserves luminance.
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
                        "Every cell needs a number before the mix can be applied.",
                        systemImage: "pencil"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Matrix", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isComplete)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    /// The convention, written the way the processing stage performs it.
    @ViewBuilder
    private var equations: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.channels, id: \.storageOffset) { output in
                Text(Self.equation(for: output))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private static func equation(for output: RAWLinearRGBChannel) -> String {
        let row = output.storageOffset
        let terms = channels.map { input in
            "m\(row)\(input.storageOffset)·\(ChannelMixMatrixDraft.label(for: input))"
        }
        return "\(ChannelMixMatrixDraft.label(for: output))out = "
            + terms.joined(separator: " + ")
    }

    /// The labelled grid. One `TextField` per coefficient, bound to the
    /// draft's text rather than to a number, so a half-typed cell stays
    /// half-typed instead of resolving to zero.
    @ViewBuilder
    private var grid: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("")
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(Self.channels, id: \.storageOffset) { input in
                    Text("input \(ChannelMixMatrixDraft.label(for: input))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Self.channels, id: \.storageOffset) { output in
                GridRow {
                    Text("output \(ChannelMixMatrixDraft.label(for: output))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(Self.channels, id: \.storageOffset) { input in
                        coefficientField(output: output, input: input)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func coefficientField(
        output: RAWLinearRGBChannel, input: RAWLinearRGBChannel
    ) -> some View {
        let isCoefficient = draft.isCoefficient(output: output, input: input)
        TextField(
            "m\(output.storageOffset)\(input.storageOffset)",
            text: Binding(
                get: { draft[output: output, input: input] },
                set: { text in
                    draft[output: output, input: input] = text
                    // A refusal describes the draft that was submitted. Once
                    // any cell changes it no longer does, so it goes.
                    refusal = nil
                }
            )
        )
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: 88)
        .foregroundStyle(isCoefficient ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
        .help(isCoefficient
            ? """
                Row \(output.storageOffset), column \(input.storageOffset): how much \
                input \(ChannelMixMatrixDraft.label(for: input)) contributes to output \
                \(ChannelMixMatrixDraft.label(for: output))
                """
            : "Not a finite number yet")
        .accessibilityLabel("""
            Output \(ChannelMixMatrixDraft.label(for: output)) from input \
            \(ChannelMixMatrixDraft.label(for: input))
            """)
    }

    /// Commits the nine fields, or reports the primitive's refusal.
    ///
    /// The refusal is the matrix type's own — the existing numeric contract —
    /// rather than a rule restated here. Nothing is applied when it throws,
    /// and the canonical adjustment is left as it was.
    private func commit() {
        do {
            guard let adjustment = try draft.adjustment() else {
                // The button is disabled in this state; reaching it would mean
                // a cell stopped being a number between the check and the tap.
                refusal = "Every cell needs a number before the mix can be applied."
                return
            }
            apply(adjustment)
            dismiss()
        } catch let error as RAWProcessingError {
            refusal = error.errorDescription ?? "That matrix was refused."
        } catch {
            refusal = error.localizedDescription
        }
    }
}
