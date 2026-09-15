import Testing
import Foundation
@testable import InfraredConverter

/// The nine text fields of the creative mixer, and what they may become.
///
/// The arithmetic of a mix is `IRChannelMixer`'s and is covered by its own
/// suites; what the coefficients are allowed to be is `RAWColorMatrix3x3`'s
/// and `IRChannelMix`'s. What is tested here is the editing boundary: that a
/// matrix a person types arrives as `UserChannelMixAdjustment.explicit` with
/// exactly the nine numbers typed, in the matrix's own convention, and that
/// half-typed text replaces nothing.
@Suite("Channel-mix matrix draft")
struct ChannelMixMatrixDraftTests {

    private static func draft(_ texts: [String]) -> ChannelMixMatrixDraft {
        var draft = ChannelMixMatrixDraft(.identity)
        var index = 0
        for output in ChannelMixMatrixDraft.channels {
            for input in ChannelMixMatrixDraft.channels {
                draft[output: output, input: input] = texts[index]
                index += 1
            }
        }
        return draft
    }

    // MARK: - An authored matrix reaches the canonical adjustment

    /// Nine distinct, deliberately asymmetric coefficients, so that a
    /// transposition or a permuted cell cannot pass.
    @Test("An authored asymmetric matrix becomes .explicit with those nine numbers")
    func anAuthoredMatrixBecomesExplicit() throws {
        let typed = [
            "0.1", "0.2", "0.3",
            "0.4", "0.5", "0.6",
            "0.7", "0.8", "0.9",
        ]
        let adjustment = try #require(try Self.draft(typed).adjustment())

        guard case .explicit(let matrix) = adjustment else {
            Issue.record("Expected an explicit matrix, got \(adjustment)")
            return
        }
        #expect(matrix.m00 == 0.1)
        #expect(matrix.m01 == 0.2)
        #expect(matrix.m02 == 0.3)
        #expect(matrix.m10 == 0.4)
        #expect(matrix.m11 == 0.5)
        #expect(matrix.m12 == 0.6)
        #expect(matrix.m20 == 0.7)
        #expect(matrix.m21 == 0.8)
        #expect(matrix.m22 == 0.9)
        // And it is the creative processing value, in the one working space.
        #expect(adjustment.mix.source == .explicit)
        #expect(adjustment.mix.workingColorSpace == .extendedLinearSRGB)
        #expect(adjustment.kind == .matrix)
    }

    /// Rows are output channels and columns are input channels, which is the
    /// convention of the matrix, the sidecar and the processing stage. This is
    /// the test that fails if the editor is ever transposed for convenience.
    @Test("A cell is addressed by output row and input column, never transposed")
    func cellsAreAddressedByOutputThenInput() throws {
        var draft = ChannelMixMatrixDraft(.identity)
        // "How much input blue contributes to output red" is m02.
        draft[output: .red, input: .blue] = "3"
        draft[output: .blue, input: .red] = "-1"

        let adjustment = try #require(try draft.adjustment())
        #expect(adjustment.matrix.m02 == 3)
        #expect(adjustment.matrix.m20 == -1)
        #expect(adjustment.matrix.m01 == 0)
        #expect(adjustment.matrix.m10 == 0)

        // Reading a cell back gives the text that was written to it, and the
        // untouched cells are still the identity's.
        #expect(draft[output: .red, input: .blue] == "3")
        #expect(draft[output: .red, input: .red] == "1")
        #expect(draft[output: .green, input: .blue] == "0")
    }

    /// Values a visible-light editor would reject, which are ordinary infrared
    /// mixes. Nothing clamps, normalises or repairs them.
    @Test("Negative, amplifying, non-normalised and singular matrices are accepted")
    func unconventionalCoefficientsAreAccepted() throws {
        let cases: [(name: String, texts: [String])] = [
            (
                "negative and above one",
                ["1.8", "-0.4", "-0.4", "-0.2", "1.4", "-0.2", "2.5", "0", "-1.5"]
            ),
            (
                "rows summing well above one",
                ["3", "3", "3", "2", "2", "2", "4", "4", "4"]
            ),
            (
                "a monochrome collapse, which is singular",
                ["0.3", "0.6", "0.1", "0.3", "0.6", "0.1", "0.3", "0.6", "0.1"]
            ),
            (
                "a zero matrix",
                ["0", "0", "0", "0", "0", "0", "0", "0", "0"]
            ),
            (
                "exponent and leading-plus notation",
                ["1e2", "-1E-3", "+2", "0", "1", "0", "0", "0", "1."]
            ),
        ]

        for (name, texts) in cases {
            let adjustment = try #require(try Self.draft(texts).adjustment(), "\(name)")
            #expect(adjustment.kind == .matrix, "\(name)")
            // The exact numbers, in order, with nothing rewritten.
            let expected = texts.map { Double($0)! }
            #expect(adjustment.matrix.rows.flatMap { $0 } == expected, "\(name)")
        }

        // The collapse really is singular, and is applied anyway.
        let collapse = try #require(try Self.draft(cases[2].texts).adjustment())
        #expect(collapse.matrix.determinant == 0)
    }

    // MARK: - Editing states replace nothing

    /// Text a person is still typing yields no adjustment at all — not a zero,
    /// not an identity, and nothing that could be committed over the canonical
    /// mix.
    @Test("A cell that is not yet a number yields no adjustment, and no zero")
    func halfTypedTextYieldsNothing() throws {
        for partial in ["", " ", "-", ".", "-.", "+", "1e", "e5", "abc", "1,5", "--1"] {
            var draft = ChannelMixMatrixDraft(.redBlueSwap)
            draft[output: .green, input: .green] = partial

            #expect(!draft.isComplete, "\(partial.debugDescription) should be incomplete")
            #expect(try draft.adjustment() == nil, "\(partial.debugDescription)")
            #expect(
                !draft.isCoefficient(output: .green, input: .green),
                "\(partial.debugDescription)"
            )
            // Only that cell is in question; the rest are still coefficients.
            #expect(draft.invalidFields.count == 1, "\(partial.debugDescription)")
            #expect(draft.invalidFields[0].output == .green)
            #expect(draft.invalidFields[0].input == .green)
        }
    }

    @Test("Surrounding whitespace is not an editing error")
    func whitespaceIsTrimmed() throws {
        var draft = ChannelMixMatrixDraft(.identity)
        draft[output: .red, input: .green] = "  -0.25  "

        #expect(draft.isCoefficient(output: .red, input: .green))
        let adjustment = try #require(try draft.adjustment())
        #expect(adjustment.matrix.m01 == -0.25)
    }

    // MARK: - Non-finite values are refused by the matrix, not repaired

    /// A complete draft holding a number that is not finite is committed and
    /// refused, with the matrix primitive's own typed error naming the cell.
    /// It is never silently replaced by zero, one, or the previous mix.
    @Test("A non-finite coefficient is refused by the existing numeric contract")
    func nonFiniteCoefficientsAreRefused() throws {
        for text in ["inf", "-inf", "nan", "1e400", "infinity"] {
            var draft = ChannelMixMatrixDraft(.identity)
            draft[output: .blue, input: .green] = text

            // It parses as a number, so the draft is complete...
            #expect(draft.isComplete, "\(text)")
            // ...but it is not a coefficient, and the editor marks it.
            #expect(!draft.isCoefficient(output: .blue, input: .green), "\(text)")

            var thrown: RAWProcessingError?
            do {
                _ = try draft.adjustment()
                Issue.record("\(text) should have been refused")
            } catch let error as RAWProcessingError {
                thrown = error
            }
            guard case .invalidColorMatrix3x3(let row, let column, let value) =
                try #require(thrown) else {
                Issue.record("\(text): expected an invalid-matrix refusal")
                return
            }
            // Row 2, column 1 — output blue from input green.
            #expect(row == 2, "\(text)")
            #expect(column == 1, "\(text)")
            #expect(!value.isFinite, "\(text)")
        }
    }

    // MARK: - Seeding, and what an authored matrix is not

    /// The editor opens on the mix in force, so a person adjusting the swap
    /// starts from the swap's own coefficients rather than from an identity.
    @Test("A draft is seeded from the mix in force, in shortest exact form")
    func aDraftIsSeededFromTheCurrentMix() throws {
        let identity = ChannelMixMatrixDraft(.identity)
        #expect(identity[output: .red, input: .red] == "1")
        #expect(identity[output: .red, input: .green] == "0")
        #expect(try identity.adjustment()?.matrix == RAWColorMatrix3x3.identity)

        let swap = ChannelMixMatrixDraft(.redBlueSwap)
        #expect(swap[output: .red, input: .blue] == "1")
        #expect(swap[output: .red, input: .red] == "0")
        #expect(swap[output: .green, input: .green] == "1")
        #expect(try swap.adjustment()?.matrix == UserChannelMixAdjustment.redBlueSwap.matrix)
    }

    /// A saved matrix reopened in the editor and applied unchanged commits the
    /// same nine numbers, not a rounded copy of them.
    @Test("Seeding round-trips an awkward matrix exactly")
    func seedingRoundTripsExactly() throws {
        let awkward = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [
                0.1234567890123, -1.0 / 3.0, 2.718281828459045,
                1e-9, 12345.6789, -0.000123456,
                1.0 / 7.0, 0.5, -2,
            ]
        )
        let reapplied = try #require(try ChannelMixMatrixDraft(awkward).adjustment())
        #expect(reapplied == awkward)
        #expect(reapplied.matrix.rows.flatMap { $0 } == awkward.matrix.rows.flatMap { $0 })
    }

    /// Provenance is what the person did, not what the numbers happen to
    /// equal. A typed identity is an authored matrix that has no effect — not
    /// `.identity`, which is the decision to remap nothing.
    @Test("A typed matrix stays .explicit even when it equals a built-in")
    func anAuthoredBuiltInMatrixStaysExplicit() throws {
        let typedIdentity = try #require(
            try Self.draft(["1", "0", "0", "0", "1", "0", "0", "0", "1"]).adjustment()
        )
        #expect(typedIdentity.kind == .matrix)
        #expect(typedIdentity != .identity)
        #expect(typedIdentity.matrix.isIdentity)
        #expect(typedIdentity.mix.source == .explicit)

        let typedSwap = try #require(
            try Self.draft(["0", "0", "1", "0", "1", "0", "1", "0", "0"]).adjustment()
        )
        #expect(typedSwap.kind == .matrix)
        #expect(typedSwap != .redBlueSwap)
        #expect(typedSwap.matrix == UserChannelMixAdjustment.redBlueSwap.matrix)
        #expect(typedSwap.mix.source == .explicit)

        // And neither is offered as a menu choice: the built-ins are chosen by
        // name, a matrix is authored.
        #expect(!UserChannelMixAdjustment.selectableCases.contains(typedIdentity))
        #expect(!UserChannelMixAdjustment.selectableCases.contains(typedSwap))
    }

    // MARK: - An authored matrix persists as the existing explicit record

    /// No new persisted representation: an authored matrix round-trips through
    /// the sidecar's existing `matrix` record, with its nine coefficients in
    /// the same row-major order, and reads back as `.explicit`.
    @Test("An authored matrix round-trips through the existing persisted form")
    func anAuthoredMatrixRoundTripsThroughTheExistingForm() throws {
        let authored = try #require(
            try Self.draft(
                ["1.8", "-0.4", "-0.4", "-0.2", "1.4", "-0.2", "2.5", "0", "-1.5"]
            ).adjustment()
        )

        let data = try JSONEncoder().encode(authored)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["kind"] as? String == "matrix")
        #expect(
            object["matrix"] as? [Double]
                == [1.8, -0.4, -0.4, -0.2, 1.4, -0.2, 2.5, 0, -1.5]
        )
        #expect(object.count == 2)

        let decoded = try JSONDecoder().decode(UserChannelMixAdjustment.self, from: data)
        #expect(decoded == authored)
        #expect(decoded.kind == .matrix)
    }
}
