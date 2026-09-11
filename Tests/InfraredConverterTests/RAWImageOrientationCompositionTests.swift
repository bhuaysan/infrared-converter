import Testing
import Foundation
@testable import InfraredConverter

/// The orientation algebra, exhaustively.
///
/// Orientation composition is about to become persisted editing state: a
/// user's correction is stored as one canonical orientation, derived by
/// composing whatever they pressed. If composition is wrong, the stored state
/// is wrong, and it is wrong in the quietest possible way — the eight
/// orientations are closed under composition, so a mistake produces a valid,
/// well-formed, plausible-looking picture that is simply not the one asked
/// for.
///
/// ## The oracle is not the thing being tested
///
/// `composed(with:)` is computed from the canonical mirror-then-rotate
/// decomposition. Nothing here checks it against that decomposition. Every
/// expected result is produced one of two independent ways:
///
/// - **pixels** — apply A with `ImageOrienter`, apply B to the result, and
///   compare with applying `a.composed(with: b)` once;
/// - **coordinates** — compose the two `sourceCoordinate` mappings by hand on
///   a non-square grid and compare with the composed orientation's mapping.
///
/// Both agree with each other and neither consults the composition table.
@Suite("RAWImageOrientation composition")
struct RAWImageOrientationCompositionTests {

    /// A 3 × 2 image in which every pixel is unique and no symmetry exists,
    /// so no orientation can be mistaken for another.
    ///
    /// ```text
    /// A B C
    /// D E F
    /// ```
    static let asymmetricRows = ["ABC", "DEF"]

    /// Applies one orientation to the asymmetric image and reads the result
    /// back as rows of labels.
    static func applied(_ orientation: RAWImageOrientation) throws -> [String] {
        let image = OrientationTestData.labelled(asymmetricRows)
        return OrientationTestData.labels(
            of: try ImageOrienter().apply(to: image, orientation: orientation)
        )
    }

    /// Applies a whole sequence, one genuine pixel permutation at a time.
    ///
    /// This is the oracle for "apply A, then B": it does exactly that, with no
    /// reference to any composition arithmetic.
    static func appliedInTurn(_ orientations: [RAWImageOrientation]) throws -> [String] {
        var image = OrientationTestData.labelled(asymmetricRows)
        for orientation in orientations {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
            image = OrientationTestData.reinterpretedAsChannelMixed(oriented)
        }
        return OrientationTestData.labels(
            of: try ImageOrienter().apply(to: image, orientation: .upright)
        )
    }

    // MARK: - The canonical decomposition, derived from pixels

    /// The mirror-then-rotate table in `quarterTurnsClockwise` is a claim
    /// about pixel behaviour, so it is checked against pixel behaviour.
    ///
    /// The mirrored half is the part that is easy to get wrong: a horizontal
    /// mirror followed by **one** quarter turn clockwise is `.transverse`, and
    /// **three** gives `.transposed`. Swapping those two is invisible on a
    /// symmetrical subject.
    @Test("Every orientation equals its own mirror-then-rotate decomposition")
    func theCanonicalDecompositionIsWhatThePixelsDo() throws {
        for orientation in RAWImageOrientation.allCases {
            var steps: [RAWImageOrientation] = []
            if orientation.isMirrored { steps.append(.mirroredHorizontally) }
            steps.append(
                contentsOf: Array(
                    repeating: .rotated90Clockwise, count: orientation.quarterTurnsClockwise
                )
            )

            #expect(
                try Self.appliedInTurn(steps) == Self.applied(orientation),
                """
                \(orientation) should equal mirror=\(orientation.isMirrored) then \
                \(orientation.quarterTurnsClockwise) quarter turns clockwise
                """
            )
        }
    }

    @Test("The eight canonical decompositions are distinct and round-trip")
    func theDecompositionIsABijection() {
        var seen = Set<String>()
        for orientation in RAWImageOrientation.allCases {
            #expect((0...3).contains(orientation.quarterTurnsClockwise))
            seen.insert("\(orientation.isMirrored)-\(orientation.quarterTurnsClockwise)")
            #expect(
                RAWImageOrientation.composing(
                    mirroredHorizontally: orientation.isMirrored,
                    quarterTurnsClockwise: orientation.quarterTurnsClockwise
                ) == orientation
            )
        }
        #expect(seen.count == 8)
    }

    /// Quarter turns are reduced modulo four, negatives included, so there is
    /// no input `composing` can refuse and no code path that clamps.
    @Test("Quarter turns wrap in both directions")
    func quarterTurnsWrap() {
        for turns in -12...12 {
            for mirrored in [false, true] {
                let wrapped = RAWImageOrientation.composing(
                    mirroredHorizontally: mirrored, quarterTurnsClockwise: turns
                )
                let reduced = RAWImageOrientation.composing(
                    mirroredHorizontally: mirrored,
                    quarterTurnsClockwise: ((turns % 4) + 4) % 4
                )
                #expect(wrapped == reduced, "turns \(turns), mirrored \(mirrored)")
            }
        }
    }

    // MARK: - All 64 pairs, against real pixel permutations

    /// The convention under test, stated once: `a.composed(with: b)` means
    /// **apply a, then b**.
    @Test("All 64 compositions equal applying the two in turn")
    func everyCompositionMatchesTwoRealPermutations() throws {
        var checked = 0
        for first in RAWImageOrientation.allCases {
            for second in RAWImageOrientation.allCases {
                let composed = first.composed(with: second)
                #expect(
                    try Self.appliedInTurn([first, second]) == Self.applied(composed),
                    "\(first) then \(second) should be \(composed)"
                )
                checked += 1
            }
        }
        #expect(checked == 64)
    }

    /// The same 64 pairs again, with a completely different oracle: the
    /// destination-to-source coordinate mappings composed by hand, on a
    /// deliberately non-square grid so a transposed result cannot hide.
    @Test("All 64 compositions equal composing the coordinate mappings")
    func everyCompositionMatchesComposedCoordinateMappings() {
        let width = 7
        let height = 3

        for first in RAWImageOrientation.allCases {
            for second in RAWImageOrientation.allCases {
                let composed = first.composed(with: second)

                let afterFirst = first.outputDimensions(
                    sourceWidth: width, sourceHeight: height
                )
                let afterSecond = second.outputDimensions(
                    sourceWidth: afterFirst.width, sourceHeight: afterFirst.height
                )
                let direct = composed.outputDimensions(
                    sourceWidth: width, sourceHeight: height
                )
                #expect(
                    direct.width == afterSecond.width && direct.height == afterSecond.height,
                    "\(first) then \(second): geometry"
                )

                for row in 0..<afterSecond.height {
                    for column in 0..<afterSecond.width {
                        // Destination asks the second stage, which asks the
                        // first: g_composed = g_first ∘ g_second.
                        let middle = second.sourceCoordinate(
                            row: row,
                            column: column,
                            sourceWidth: afterFirst.width,
                            sourceHeight: afterFirst.height
                        )
                        let expected = first.sourceCoordinate(
                            row: middle.row,
                            column: middle.column,
                            sourceWidth: width,
                            sourceHeight: height
                        )
                        let actual = composed.sourceCoordinate(
                            row: row, column: column, sourceWidth: width, sourceHeight: height
                        )
                        #expect(
                            actual == expected,
                            "\(first) then \(second) at (\(row), \(column))"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Group laws

    @Test("Upright is the identity from both sides")
    func uprightIsTheIdentity() {
        for orientation in RAWImageOrientation.allCases {
            #expect(orientation.composed(with: .upright) == orientation)
            #expect(RAWImageOrientation.upright.composed(with: orientation) == orientation)
        }
    }

    @Test("Every orientation composed with its inverse is upright, from both sides")
    func inversesCancelFromBothSides() throws {
        for orientation in RAWImageOrientation.allCases {
            #expect(orientation.composed(with: orientation.inverse) == .upright)
            #expect(orientation.inverse.composed(with: orientation) == .upright)

            // And the pixels agree: applying an orientation and then its
            // inverse restores the original layout exactly.
            #expect(try Self.appliedInTurn([orientation, orientation.inverse])
                == Self.asymmetricRows)
            #expect(try Self.appliedInTurn([orientation.inverse, orientation])
                == Self.asymmetricRows)
        }
    }

    /// Only the two quarter turns have an inverse that is not themselves.
    @Test("The inverse table is the expected one")
    func theInverseTableIsExplicit() {
        #expect(RAWImageOrientation.upright.inverse == .upright)
        #expect(RAWImageOrientation.rotated90Clockwise.inverse == .rotated270Clockwise)
        #expect(RAWImageOrientation.rotated270Clockwise.inverse == .rotated90Clockwise)
        #expect(RAWImageOrientation.rotated180.inverse == .rotated180)
        #expect(RAWImageOrientation.mirroredHorizontally.inverse == .mirroredHorizontally)
        #expect(RAWImageOrientation.mirroredVertically.inverse == .mirroredVertically)
        #expect(RAWImageOrientation.transposed.inverse == .transposed)
        #expect(RAWImageOrientation.transverse.inverse == .transverse)
    }

    @Test("Every reflection is its own inverse, and every rotation is not a reflection")
    func reflectionsAreInvolutions() throws {
        for orientation in RAWImageOrientation.allCases where orientation.isMirrored {
            #expect(orientation.composed(with: orientation) == .upright)
            #expect(try Self.appliedInTurn([orientation, orientation]) == Self.asymmetricRows)
        }
        // A rotation composed with itself is the identity only for the half
        // turn, which is the property that separates the two families.
        for orientation in RAWImageOrientation.allCases where !orientation.isMirrored {
            let squared = orientation.composed(with: orientation)
            #expect((squared == .upright) == (orientation == .upright || orientation == .rotated180))
        }
    }

    @Test("Four quarter turns return to the identity, in either direction")
    func fourQuarterTurnsCycle() throws {
        for step in [RAWImageOrientation.rotated90Clockwise, .rotated270Clockwise] {
            var accumulated = RAWImageOrientation.upright
            var intermediates: [RAWImageOrientation] = []
            for _ in 0..<4 {
                accumulated = accumulated.composed(with: step)
                intermediates.append(accumulated)
            }
            #expect(accumulated == .upright)
            // The three intermediate states are all distinct and none is the
            // identity — a cycle of length four, not a no-op repeated.
            #expect(Set(intermediates.dropLast().map(\.exifOrientation)).count == 3)
            #expect(!intermediates.dropLast().contains(.upright))
            #expect(try Self.appliedInTurn(Array(repeating: step, count: 4))
                == Self.asymmetricRows)
        }

        // Three quarter turns one way equal one the other way.
        #expect(
            RAWImageOrientation.rotated90Clockwise
                .composed(with: .rotated90Clockwise)
                .composed(with: .rotated90Clockwise) == .rotated270Clockwise
        )
    }

    @Test("Two half turns return to the identity")
    func twoHalfTurnsCycle() throws {
        #expect(RAWImageOrientation.rotated180.composed(with: .rotated180) == .upright)
        #expect(try Self.appliedInTurn([.rotated180, .rotated180]) == Self.asymmetricRows)
    }

    /// Associativity over all 512 triples. Without it, "compose as you go"
    /// and "compose at the end" could disagree, and the UI does the former
    /// while every test does the latter.
    @Test("Composition is associative")
    func compositionIsAssociative() {
        for a in RAWImageOrientation.allCases {
            for b in RAWImageOrientation.allCases {
                for c in RAWImageOrientation.allCases {
                    #expect(
                        a.composed(with: b).composed(with: c)
                            == a.composed(with: b.composed(with: c)),
                        "\(a), \(b), \(c)"
                    )
                }
            }
        }
    }

    // MARK: - Order matters, and reflections are the proof

    /// Rotations commute with each other, so a suite built only from quarter
    /// turns would pass with the arguments swapped. These pairs would not.
    @Test("Reflection and rotation do not commute, with pixel evidence")
    func reflectionAndRotationDoNotCommute() throws {
        let cases: [(RAWImageOrientation, RAWImageOrientation, RAWImageOrientation)] = [
            (.transposed, .rotated90Clockwise, .mirroredHorizontally),
            (.rotated90Clockwise, .transposed, .mirroredVertically),
            (.mirroredHorizontally, .rotated90Clockwise, .transverse),
            (.rotated90Clockwise, .mirroredHorizontally, .transposed),
            (.mirroredVertically, .rotated270Clockwise, .transverse),
            (.rotated270Clockwise, .mirroredVertically, .transposed),
        ]

        for (first, second, expected) in cases {
            #expect(first.composed(with: second) == expected, "\(first) then \(second)")
            #expect(
                try Self.appliedInTurn([first, second]) == Self.applied(expected),
                "\(first) then \(second) pixels"
            )
            // Reversing the order gives a different, equally valid orientation
            // — which is the whole hazard.
            #expect(second.composed(with: first) != expected)
        }
    }

    @Test("Rotations do commute, so they cannot prove an order convention")
    func rotationsCommute() {
        let rotations: [RAWImageOrientation] =
            [.upright, .rotated90Clockwise, .rotated180, .rotated270Clockwise]
        for a in rotations {
            for b in rotations {
                #expect(a.composed(with: b) == b.composed(with: a))
            }
        }
    }

    // MARK: - Closure

    /// The set is closed, and the two structural facts about a composition
    /// follow the expected parities. This is what lets an adjustment be stored
    /// as one canonical state rather than a history of presses.
    @Test("Composition is closed, and parities behave")
    func compositionIsClosed() {
        for a in RAWImageOrientation.allCases {
            for b in RAWImageOrientation.allCases {
                let composed = a.composed(with: b)
                #expect(RAWImageOrientation.allCases.contains(composed))
                #expect(composed.isMirrored == (a.isMirrored != b.isMirrored))
                #expect(composed.swapsDimensions == (a.swapsDimensions != b.swapsDimensions))
            }
        }
    }

    /// Every orientation is reachable from the identity by the operations a
    /// user interface offers, so no state can be entered and not left.
    @Test("The UI operations generate all eight states")
    func theUIOperationsGenerateTheWholeGroup() {
        let generators: [RAWImageOrientation] = [
            .rotated90Clockwise, .rotated270Clockwise, .rotated180,
            .mirroredHorizontally, .mirroredVertically,
        ]
        var reached: Set<Int> = [RAWImageOrientation.upright.exifOrientation]
        var frontier: [RAWImageOrientation] = [.upright]
        while let current = frontier.popLast() {
            for generator in generators {
                let next = current.composed(with: generator)
                if reached.insert(next.exifOrientation).inserted {
                    frontier.append(next)
                }
            }
        }
        #expect(reached.count == 8)
    }
}
