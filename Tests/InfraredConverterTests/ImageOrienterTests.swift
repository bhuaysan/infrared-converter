import Testing
import Foundation
@testable import InfraredConverter

/// The orientation stage's geometry, exhaustively, on a deliberately
/// asymmetric image whose every pixel is uniquely identifiable.
///
/// ## Why the expected layouts are written out
///
/// ```text
/// source         A B C
///                D E F
/// ```
///
/// Six of the eight orientations move every pixel, and a symmetrical test
/// image would let most of them pass while the code did something else. So the
/// expected arrangement for each case is written in the test source as it
/// looks on screen, and compared as such. A test that computed its expectation
/// from the same mapping table the implementation uses would agree with any
/// bug in that table.
///
/// ## No LibRaw, no fixture, no metadata
///
/// Nothing here opens a file. The stage takes an orientation and an image; how
/// a caller chose the orientation is `RAWImageOrientationTests`' subject, and
/// the fixture-backed end-to-end check is separate again.
@Suite("ImageOrienter geometry")
struct ImageOrienterTests {

    /// The source for every layout assertion below.
    ///
    /// ```text
    /// A B C
    /// D E F
    /// ```
    static let source = ["ABC", "DEF"]

    /// Every orientation's expected result, written as it looks.
    ///
    /// The four transposing cases are 2 wide and 3 high; the other four are
    /// 3 wide and 2 high.
    static let expected: [(RAWImageOrientation, [String])] = [
        (.upright, [
            "ABC",
            "DEF",
        ]),
        (.mirroredHorizontally, [
            "CBA",
            "FED",
        ]),
        (.rotated180, [
            "FED",
            "CBA",
        ]),
        (.mirroredVertically, [
            "DEF",
            "ABC",
        ]),
        (.transposed, [
            "AD",
            "BE",
            "CF",
        ]),
        (.rotated90Clockwise, [
            "DA",
            "EB",
            "FC",
        ]),
        (.transverse, [
            "FC",
            "EB",
            "DA",
        ]),
        (.rotated270Clockwise, [
            "CF",
            "BE",
            "AD",
        ]),
    ]

    // MARK: - The eight arrangements

    @Test("Every orientation produces exactly its documented arrangement")
    func everyOrientationArrangesPixelsExactly() throws {
        let image = OrientationTestData.labelled(Self.source)

        for (orientation, layout) in Self.expected {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)

            #expect(oriented.width == layout[0].count, "\(orientation) width")
            #expect(oriented.height == layout.count, "\(orientation) height")
            #expect(OrientationTestData.labels(of: oriented) == layout, "\(orientation)")
            #expect(oriented.isGeometryConsistent)
            #expect(oriented.orientation == orientation)
        }

        // Every case is covered, and no case is covered twice.
        #expect(Set(Self.expected.map(\.0)) == Set(RAWImageOrientation.allCases))
        #expect(Self.expected.count == 8)
    }

    /// The two easiest cases to confuse. Both swap the dimensions; one is a
    /// reflection and one is a rotation, and they share no pixel position
    /// except the two on the diagonal they are reflected about.
    @Test("Transpose and a quarter turn are different arrangements")
    func transposeIsNotAQuarterTurn() throws {
        let image = OrientationTestData.labelled(Self.source)
        let transposed = try ImageOrienter().apply(to: image, orientation: .transposed)
        let turned = try ImageOrienter().apply(to: image, orientation: .rotated90Clockwise)

        #expect(OrientationTestData.labels(of: transposed) == ["AD", "BE", "CF"])
        #expect(OrientationTestData.labels(of: turned) == ["DA", "EB", "FC"])
        #expect(transposed.values != turned.values)

        // Same for the other reflection/rotation pair that swaps dimensions.
        let transverse = try ImageOrienter().apply(to: image, orientation: .transverse)
        let counterTurned = try ImageOrienter()
            .apply(to: image, orientation: .rotated270Clockwise)
        #expect(OrientationTestData.labels(of: transverse) == ["FC", "EB", "DA"])
        #expect(OrientationTestData.labels(of: counterTurned) == ["CF", "BE", "AD"])
        #expect(transverse.values != counterTurned.values)
    }

    /// The two mirrors keep their dimensions, which is exactly why they are
    /// easy to swap for each other.
    @Test("The two mirrors reflect about the axes they are named for")
    func mirrorsReflectTheRightAxis() throws {
        let image = OrientationTestData.labelled(Self.source)
        let horizontal = try ImageOrienter()
            .apply(to: image, orientation: .mirroredHorizontally)
        let vertical = try ImageOrienter().apply(to: image, orientation: .mirroredVertically)

        // Mirrored horizontally: left and right exchange, rows stay put.
        #expect(OrientationTestData.labels(of: horizontal) == ["CBA", "FED"])
        // Mirrored vertically: top and bottom exchange, columns stay put.
        #expect(OrientationTestData.labels(of: vertical) == ["DEF", "ABC"])
        #expect(horizontal.width == 3 && horizontal.height == 2)
        #expect(vertical.width == 3 && vertical.height == 2)
    }

    // MARK: - It is a permutation

    /// No pixel invented, none lost, none duplicated — on an image where every
    /// pixel is distinguishable, so a duplicate is detectable.
    @Test("Every orientation is a permutation: nothing missing, nothing repeated")
    func everyOrientationIsAPermutation() throws {
        let image = OrientationTestData.labelled(["ABCD", "EFGH", "IJKL"])
        let sourceLabels = Set("ABCDEFGHIJKL")

        for orientation in RAWImageOrientation.allCases {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
            let produced = OrientationTestData.labels(of: oriented).joined()

            #expect(produced.count == 12, "\(orientation) count")
            #expect(Set(produced) == sourceLabels, "\(orientation) set")
            // A set comparison alone would not catch a duplicate paired with a
            // loss of some other pixel, so the counts are checked too.
            #expect(Set(produced).count == produced.count, "\(orientation) duplicates")
            #expect(oriented.values.count == image.values.count)
            #expect(oriented.pixelCount == image.pixelCount)
        }
    }

    /// Applying an orientation and then the one that undoes it returns the
    /// original geometry and the original numbers.
    ///
    /// Each pair is applied to the **original** image both times, never
    /// chained — `ImageOrienter` has no way to chain, which is the point of
    /// the reprocessing suite. Here the inverse is applied to the oriented
    /// result deliberately, using the bare-image entry point, to prove the
    /// mapping itself is invertible.
    @Test("Each orientation's documented inverse restores the original")
    func orientationsAreInvertible() throws {
        let inverses: [(RAWImageOrientation, RAWImageOrientation)] = [
            (.upright, .upright),
            (.mirroredHorizontally, .mirroredHorizontally),
            (.rotated180, .rotated180),
            (.mirroredVertically, .mirroredVertically),
            (.transposed, .transposed),
            (.transverse, .transverse),
            // The only pair that is not self-inverse.
            (.rotated90Clockwise, .rotated270Clockwise),
            (.rotated270Clockwise, .rotated90Clockwise),
        ]
        let image = OrientationTestData.labelled(Self.source)
        let orienter = ImageOrienter()

        for (orientation, inverse) in inverses {
            let oriented = try orienter.apply(to: image, orientation: orientation)
            // Round-trip through the bare-image entry point: the oriented
            // result is re-expressed as a mix-stage image so the inverse can
            // be applied to it. This is a mapping check, not a supported
            // pipeline path.
            let asInput = OrientationTestData.image(
                width: oriented.width,
                height: oriented.height,
                values: oriented.values
            )
            let restored = try orienter.apply(to: asInput, orientation: inverse)

            #expect(restored.width == image.width, "\(orientation)")
            #expect(restored.height == image.height, "\(orientation)")
            #expect(restored.values == image.values, "\(orientation)")
            #expect(OrientationTestData.labels(of: restored) == Self.source, "\(orientation)")
        }
    }

    // MARK: - Degenerate but valid geometries

    @Test("A single pixel survives every orientation unchanged")
    func onePixelIsUnchanged() throws {
        let image = OrientationTestData.labelled(["A"])

        for orientation in RAWImageOrientation.allCases {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
            #expect(oriented.width == 1, "\(orientation)")
            #expect(oriented.height == 1, "\(orientation)")
            #expect(oriented.values == image.values, "\(orientation)")
        }
    }

    /// A single row becomes a single column for the four transposing
    /// orientations, and the order within it is the thing to get wrong.
    @Test("A 4×1 row orients into the documented row or column")
    func aSingleRowOrients() throws {
        let image = OrientationTestData.labelled(["ABCD"])
        let expected: [(RAWImageOrientation, [String])] = [
            (.upright, ["ABCD"]),
            (.mirroredHorizontally, ["DCBA"]),
            (.rotated180, ["DCBA"]),
            (.mirroredVertically, ["ABCD"]),
            (.transposed, ["A", "B", "C", "D"]),
            (.rotated90Clockwise, ["A", "B", "C", "D"]),
            (.transverse, ["D", "C", "B", "A"]),
            (.rotated270Clockwise, ["D", "C", "B", "A"]),
        ]

        for (orientation, layout) in expected {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
            #expect(oriented.width == layout[0].count, "\(orientation) width")
            #expect(oriented.height == layout.count, "\(orientation) height")
            #expect(OrientationTestData.labels(of: oriented) == layout, "\(orientation)")
        }
    }

    /// A single column, which is where a `w − 1` written where an `h − 1`
    /// belongs stops being invisible.
    @Test("A 1×4 column orients into the documented column or row")
    func aSingleColumnOrients() throws {
        let image = OrientationTestData.labelled(["A", "B", "C", "D"])
        let expected: [(RAWImageOrientation, [String])] = [
            (.upright, ["A", "B", "C", "D"]),
            (.mirroredHorizontally, ["A", "B", "C", "D"]),
            (.rotated180, ["D", "C", "B", "A"]),
            (.mirroredVertically, ["D", "C", "B", "A"]),
            (.transposed, ["ABCD"]),
            (.rotated90Clockwise, ["DCBA"]),
            (.transverse, ["DCBA"]),
            (.rotated270Clockwise, ["ABCD"]),
        ]

        for (orientation, layout) in expected {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
            #expect(oriented.width == layout[0].count, "\(orientation) width")
            #expect(oriented.height == layout.count, "\(orientation) height")
            #expect(OrientationTestData.labels(of: oriented) == layout, "\(orientation)")
        }
    }

    /// An even-sided square: the one shape where a width/height mix-up cannot
    /// show up in the dimensions, so the arrangement has to be checked
    /// directly.
    @Test("A square image still distinguishes all eight orientations")
    func aSquareStillDistinguishesEveryOrientation() throws {
        let image = OrientationTestData.labelled(["AB", "CD"])
        let expected: [(RAWImageOrientation, [String])] = [
            (.upright, ["AB", "CD"]),
            (.mirroredHorizontally, ["BA", "DC"]),
            (.rotated180, ["DC", "BA"]),
            (.mirroredVertically, ["CD", "AB"]),
            (.transposed, ["AC", "BD"]),
            (.rotated90Clockwise, ["CA", "DB"]),
            (.transverse, ["DB", "CA"]),
            (.rotated270Clockwise, ["BD", "AC"]),
        ]

        var produced = Set<[String]>()
        for (orientation, layout) in expected {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
            #expect(OrientationTestData.labels(of: oriented) == layout, "\(orientation)")
            produced.insert(layout)
        }
        // Eight genuinely different arrangements of the same four pixels.
        #expect(produced.count == 8)
    }

    // MARK: - Values are moved, never computed

    /// The guarantee that makes orientation lossless: a component's `Float`
    /// bit pattern is identical before and after.
    ///
    /// Compared by `bitPattern`, not by `==`. `-0.0 == 0.0` is `true`, so an
    /// equality check would pass for an implementation that computed
    /// `0 × r + 0 × g + 1 × b` instead of copying, and quietly lost the sign
    /// of every negative zero.
    @Test("Every component's bit pattern survives every orientation")
    func componentBitPatternsSurvive() throws {
        let awkward: [Float] = [
            -0.0, 0.0, 1.0,
            -1.5, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNormalMagnitude,
            .infinity, -.infinity, Float(bitPattern: 0x7FC0_0001),
            3.14159, -2.71828, 1e-30,
            0.1, 0.2, 0.3,
        ]
        let image = OrientationTestData.image(width: 3, height: 2, values: awkward)
        let sourcePatterns = awkward.map(\.bitPattern).sorted()

        for orientation in RAWImageOrientation.allCases {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
            // The same multiset of bit patterns, exactly.
            #expect(oriented.values.map(\.bitPattern).sorted() == sourcePatterns,
                    "\(orientation)")

            // And each destination pixel's three patterns match its source
            // pixel's, in order — a channel rotation would keep the multiset.
            for row in 0..<oriented.height {
                for column in 0..<oriented.width {
                    let source = orientation.sourceCoordinate(
                        row: row,
                        column: column,
                        sourceWidth: image.width,
                        sourceHeight: image.height
                    )
                    let expected = try #require(
                        image.pixel(row: source.row, column: source.column)
                    )
                    let actual = try #require(oriented.pixel(row: row, column: column))
                    #expect(actual.red.bitPattern == expected.red.bitPattern)
                    #expect(actual.green.bitPattern == expected.green.bitPattern)
                    #expect(actual.blue.bitPattern == expected.blue.bitPattern)
                }
            }
        }
    }

    /// Non-finite components pass through untouched. The stage reads no value
    /// as a number, so it has no standing to refuse one; that boundary belongs
    /// to `DisplayPreviewRenderer`, which genuinely cannot encode a NaN.
    @Test("A NaN or an infinity is moved, not refused and not replaced")
    func nonFiniteComponentsAreMoved() throws {
        let quietNaN = Float(bitPattern: 0x7FC0_0001)
        let image = OrientationTestData.image(
            width: 2,
            height: 1,
            values: [quietNaN, .infinity, -.infinity, 1, 2, 3]
        )
        let oriented = try ImageOrienter()
            .apply(to: image, orientation: .mirroredHorizontally)

        #expect(oriented.width == 2)
        // The NaN pixel moved from column 0 to column 1, bit pattern intact.
        let moved = try #require(oriented.pixel(row: 0, column: 1))
        #expect(moved.red.bitPattern == quietNaN.bitPattern)
        #expect(moved.green == .infinity)
        #expect(moved.blue == -.infinity)
        let plain = try #require(oriented.pixel(row: 0, column: 0))
        #expect(plain.red == 1 && plain.green == 2 && plain.blue == 3)
    }

    /// `.upright` allocates nothing: it hands the same immutable array back,
    /// which copy-on-write makes free and exactly as faithful as a copy.
    @Test("The upright path returns the very same values")
    func uprightReusesTheSourceBuffer() throws {
        let image = OrientationTestData.labelled(["ABC", "DEF"])
        let oriented = try ImageOrienter().apply(to: image, orientation: .upright)

        #expect(oriented.values == image.values)
        #expect(oriented.values.map(\.bitPattern) == image.values.map(\.bitPattern))
        #expect(oriented.width == image.width)
        #expect(oriented.height == image.height)
        // The stage still ran, and provenance says so.
        #expect(oriented.processing.orientationApplied)
        #expect(oriented.processing.orientation == .upright)
    }

    // MARK: - Nothing else changes

    @Test("Orientation changes no colour fact")
    func nothingButGeometryChanges() throws {
        let image = OrientationTestData.labelled(Self.source)

        for orientation in RAWImageOrientation.allCases {
            let processing = try ImageOrienter()
                .apply(to: image, orientation: orientation).processing

            #expect(processing.sceneLinear, "\(orientation)")
            #expect(processing.pixelValuesPreserved, "\(orientation)")
            #expect(!processing.interpolated, "\(orientation)")
            #expect(!processing.arbitraryRotationApplied, "\(orientation)")
            #expect(!processing.cropped, "\(orientation)")
            #expect(!processing.scaled, "\(orientation)")
            #expect(!processing.clamped, "\(orientation)")
            #expect(!processing.gammaApplied, "\(orientation)")
            #expect(!processing.toneMappingApplied, "\(orientation)")
            #expect(!processing.displayEncodingApplied, "\(orientation)")
            #expect(processing.workingColorSpace == .extendedLinearSRGB, "\(orientation)")
        }
    }

    /// Four exchange width and height and four do not, and the pixel count is
    /// invariant for all eight.
    @Test("Exactly the transposing orientations exchange the dimensions")
    func dimensionsSwapForExactlyFourOrientations() throws {
        let image = OrientationTestData.labelled(["ABCDE", "FGHIJ", "KLMNO"])

        for orientation in RAWImageOrientation.allCases {
            let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
            if orientation.swapsDimensions {
                #expect(oriented.width == 3, "\(orientation)")
                #expect(oriented.height == 5, "\(orientation)")
            } else {
                #expect(oriented.width == 5, "\(orientation)")
                #expect(oriented.height == 3, "\(orientation)")
            }
            #expect(oriented.processing.dimensionsSwapped == orientation.swapsDimensions)
            #expect(oriented.pixelCount == 15, "\(orientation)")
            #expect(oriented.values.count == image.values.count, "\(orientation)")
        }
    }
}
