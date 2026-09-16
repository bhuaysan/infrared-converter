import Testing
import Foundation
@testable import InfraredConverter

/// The three text fields of the monochrome editor, and what they may become.
///
/// The arithmetic of a mix is `IRChannelMixer`'s, the shape of a monochrome
/// matrix is `IRMonochromeMix`'s, and what a coefficient is allowed to be is
/// `RAWColorMatrix3x3`'s. What is tested here is the editing boundary: that
/// three numbers a person types arrive as `UserChannelMixAdjustment.explicit`
/// with exactly those numbers in all nine positions, and that half-typed text
/// replaces nothing.
@Suite("Monochrome mix draft")
struct MonochromeMixDraftTests {

    static func draft(_ red: String, _ green: String, _ blue: String) -> MonochromeMixDraft {
        var draft = MonochromeMixDraft(.equalRGB)
        draft[contribution: .red] = red
        draft[contribution: .green] = green
        draft[contribution: .blue] = blue
        return draft
    }

    // MARK: - Three valid strings resolve

    @Test("Three finite strings become an explicit matrix with identical rows")
    func threeStringsBecomeAnExplicitMatrix() throws {
        let adjustment = try #require(try Self.draft("1.5", "-0.25", "0.125").adjustment())

        guard case .explicit(let matrix) = adjustment else {
            Issue.record("Expected .explicit, got \(adjustment)")
            return
        }
        #expect(matrix.rows == [
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
        ])
        #expect(adjustment.kind == .matrix)
        #expect(adjustment.mix.source == .explicit)
    }

    /// Red is the first column, green the second, blue the third. This is the
    /// assertion that fails if the fields are ever wired in another order.
    @Test("Each field lands in its own column")
    func eachFieldLandsInItsOwnColumn() throws {
        let adjustment = try #require(try Self.draft("7", "8", "9").adjustment())
        #expect(adjustment.matrix.m00 == 7)
        #expect(adjustment.matrix.m01 == 8)
        #expect(adjustment.matrix.m02 == 9)
        #expect(adjustment.matrix.m10 == 7)
        #expect(adjustment.matrix.m21 == 8)
        #expect(adjustment.matrix.m22 == 9)
    }

    @Test("Whitespace around a number is accepted; a decimal comma is not")
    func whitespaceIsTrimmedAndACommaIsNot() throws {
        #expect(try Self.draft("  0.5 ", "0.25", "0.25").adjustment() != nil)
        #expect(try Self.draft("1,5", "0", "0").adjustment() == nil)
    }

    @Test("Exponent and trailing-point forms are numbers")
    func exponentAndTrailingPointAreNumbers() throws {
        let adjustment = try #require(try Self.draft("1e-3", "1.", ".5").adjustment())
        #expect(adjustment.matrix.m00 == 0.001)
        #expect(adjustment.matrix.m01 == 1)
        #expect(adjustment.matrix.m02 == 0.5)
    }

    // MARK: - Malformed and non-finite input

    /// Every state a person passes through on the way to a number resolves to
    /// nothing at all, rather than to zero.
    @Test("Half-typed text is not a coefficient and produces no adjustment")
    func halfTypedTextProducesNothing() throws {
        for text in ["", " ", "-", ".", "1e", "abc", "1,5", "--1"] {
            let draft = Self.draft(text, "0.5", "0.5")
            #expect(draft.number(.red) == nil, "\(text) must not be a number")
            #expect(!draft.isCoefficient(.red), "\(text) must not be a coefficient")
            #expect(!draft.isComplete, "\(text) must leave the draft incomplete")
            #expect(draft.invalidFields == [.red])
            #expect(try draft.adjustment() == nil, "\(text) must author nothing")
        }
    }

    /// The draft's own zero-guard. A field cleared to be retyped must not
    /// silently mean "no contribution".
    @Test("An emptied field means nothing, never zero")
    func anEmptiedFieldIsNotZero() throws {
        var draft = MonochromeMixDraft(IRMonochromeMix(red: 1, green: 2, blue: 3))
        draft[contribution: .green] = ""
        #expect(try draft.adjustment() == nil)
        #expect(draft.monochromeMix() == nil)
        // The other two fields are untouched and still say what they said.
        #expect(draft[contribution: .red] == "1")
        #expect(draft[contribution: .blue] == "3")
    }

    /// A complete draft holding `inf` is committed and refused by the matrix,
    /// rather than being quietly uncommittable behind a greyed-out button.
    @Test("A non-finite number completes the draft and is refused by the matrix")
    func aNonFiniteNumberIsRefusedByTheMatrix() throws {
        for text in ["inf", "-inf", "nan", "1e400"] {
            let draft = Self.draft(text, "0.5", "0.5")
            #expect(draft.number(.red) != nil, "\(text) parses as a number")
            #expect(!draft.isCoefficient(.red), "\(text) is not finite")
            // Complete, so the editor's Apply is enabled …
            #expect(draft.isComplete, "\(text) completes the draft")
            // … and the refusal is the matrix primitive's own typed error.
            #expect(throws: RAWProcessingError.self) { _ = try draft.adjustment() }
        }
    }

    // MARK: - Nothing is normalised or clamped

    @Test("Negative, amplifying and non-unit-sum contributions are all valid")
    func unusualContributionsAreValid() throws {
        let adjustment = try #require(try Self.draft("1.5", "-0.5", "0.25").adjustment())
        #expect(adjustment.matrix.rows == [
            [1.5, -0.5, 0.25],
            [1.5, -0.5, 0.25],
            [1.5, -0.5, 0.25],
        ])
        // 1.25, not renormalised to 1.
        #expect(adjustment.matrix.m00 + adjustment.matrix.m01 + adjustment.matrix.m02 == 1.25)
    }

    @Test("Three zeroes are a legitimate, deliberately black mix")
    func threeZeroesAreValid() throws {
        let adjustment = try #require(try Self.draft("0", "0", "0").adjustment())
        #expect(adjustment.matrix.rows == [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
    }

    // MARK: - Seeding

    @Test("An already-monochrome mix seeds the fields with its own contributions")
    func anAlreadyMonochromeMixSeedsItself() throws {
        let existing = try IRMonochromeMix(red: 0.5, green: 0.4, blue: 0.1).adjustment()
        let draft = MonochromeMixDraft(seeding: existing)

        #expect(draft[contribution: .red] == "0.5")
        #expect(draft[contribution: .green] == "0.4")
        #expect(draft[contribution: .blue] == "0.1")
        // Opening and applying without typing commits the very same matrix.
        #expect(try draft.adjustment() == existing)
    }

    /// Where the matrix came from cannot change the seeding, because seeding
    /// reads the coefficients and nothing else.
    @Test("A restored or preset matrix seeds the same way a typed one does")
    func provenanceDoesNotChangeSeeding() throws {
        let restored = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0.5, 0.4, 0.1, 0.5, 0.4, 0.1, 0.5, 0.4, 0.1]
        )
        let fromPreset = IRCreativePreset(
            id: try IRCreativePresetID("user.seed-test"),
            name: "Mono",
            channelMix: restored
        ).channelMix

        for adjustment in [restored, fromPreset] {
            let draft = MonochromeMixDraft(seeding: adjustment)
            #expect(draft[contribution: .red] == "0.5")
            #expect(draft[contribution: .green] == "0.4")
            #expect(draft[contribution: .blue] == "0.1")
        }
    }

    /// No inference from an arbitrary colour matrix: the editor starts at the
    /// equal mean rather than at invented weights.
    @Test("A non-monochrome mix seeds Equal RGB, inferring nothing")
    func aNonMonochromeMixSeedsEqualRGB() throws {
        let colourful = UserChannelMixAdjustment.explicit(
            try RAWColorMatrix3x3(
                m00: 1.5, m01: -0.25, m02: 0.75,
                m10: 0.5, m11: 2.0, m12: -1.25,
                m20: -0.125, m21: 0.375, m22: 3.0
            )
        )
        for adjustment in [colourful, .identity, .redBlueSwap] {
            let draft = MonochromeMixDraft(seeding: adjustment)
            #expect(draft.monochromeMix() == .equalRGB)
        }
    }

    // MARK: - The draft is editing state alone

    /// It carries no adjustment, no document and no store, so there is nothing
    /// for a keystroke to write into. Changing a field changes the draft and
    /// leaves the value it was seeded from exactly as it was.
    @Test("Editing a field leaves the mix it was seeded from untouched")
    func editingLeavesTheSeedUntouched() throws {
        let seed = try IRMonochromeMix(red: 0.5, green: 0.4, blue: 0.1).adjustment()
        var draft = MonochromeMixDraft(seeding: seed)
        draft[contribution: .red] = "0.9"

        // The seed is a value; the draft is a separate value.
        #expect(seed.matrix.m00 == 0.5)
        #expect(try #require(try draft.adjustment()).matrix.m00 == 0.9)
        // And a second draft seeded from the same adjustment is unaffected.
        #expect(MonochromeMixDraft(seeding: seed)[contribution: .red] == "0.5")
    }

    /// A starting-point button replaces the three fields and nothing else —
    /// the same operation the view performs.
    @Test("A starting point fills the fields and authors only when applied")
    func aStartingPointOnlyFillsTheFields() throws {
        for point in IRMonochromeMix.startingPoints {
            let draft = MonochromeMixDraft(point.mix)
            #expect(draft.monochromeMix() == point.mix)
            #expect(try draft.adjustment() == (try point.mix.adjustment()))
        }
    }

    /// A number is written into a field in its shortest exact form, so opening
    /// the editor on a saved mix and applying it commits the same numbers
    /// rather than a rounded copy.
    @Test("A seeded field round-trips its coefficient exactly")
    func aSeededFieldRoundTripsExactly() throws {
        let awkward = IRMonochromeMix(red: 1.0 / 3.0, green: -0.1, blue: 1e-8)
        let draft = MonochromeMixDraft(awkward)
        #expect(draft.monochromeMix() == awkward)
        #expect(try #require(try draft.adjustment()) == (try awkward.adjustment()))
    }
}
