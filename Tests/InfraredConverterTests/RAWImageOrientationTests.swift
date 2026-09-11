import Testing
import Foundation
@testable import InfraredConverter

/// The decoder → application orientation mapping, and the geometry each case
/// describes.
///
/// ## No LibRaw here
///
/// Not one test in this file opens a file or touches the decoder. The mapping
/// is a table, and a table is tested as a table: every input stated, every
/// output stated, both directions pinned. Making these tests depend on a RAW
/// fixture would mean the eight-way mapping was only ever exercised for
/// whichever single orientation that one file happens to record — which, for
/// this project's fixture, is `.upright`.
///
/// The pixel-remapping tests are separate, in `ImageOrienterTests`, and the
/// fixture-backed end-to-end check is separate again.
@Suite("RAWImageOrientation")
struct RAWImageOrientationTests {

    /// The whole mapping, written out once: case, EXIF code, LibRaw flip,
    /// whether it exchanges dimensions, whether it is a reflection.
    ///
    /// Read from the vendored LibRaw 0.22.2 sources — `LibRaw::flip_index` in
    /// `src/write/file_write.cpp` for the bitfield, and the `"50132467"`
    /// string index in `src/metadata/tiff.cpp` for EXIF tag 274 — not from
    /// the implementation under test.
    static let mapping: [(
        orientation: RAWImageOrientation,
        exif: Int,
        flip: Int,
        swaps: Bool,
        mirrored: Bool
    )] = [
        (.upright, 1, 0, false, false),
        (.mirroredHorizontally, 2, 1, false, true),
        (.rotated180, 3, 3, false, false),
        (.mirroredVertically, 4, 2, false, true),
        (.transposed, 5, 4, true, true),
        (.rotated90Clockwise, 6, 6, true, false),
        (.transverse, 7, 7, true, true),
        (.rotated270Clockwise, 8, 5, true, false),
    ]

    // MARK: - The decoder mapping

    @Test("Every LibRaw flip value maps to its documented orientation")
    func flipValuesMapToOrientations() {
        for entry in Self.mapping {
            #expect(
                RAWImageOrientation(decoderFlip: entry.flip) == entry.orientation,
                "flip \(entry.flip)"
            )
            #expect(entry.orientation.decoderFlip == entry.flip, "\(entry.orientation)")
        }
    }

    /// The near-misses that make a hand-written mapping worth pinning: three
    /// of the eight flip values differ from the EXIF code they represent, and
    /// two of them differ by swapping with each other.
    @Test("The three values where flip and EXIF disagree are the documented ones")
    func flipAndExifDisagreeExactlyWhereDocumented() {
        // flip 2 is EXIF 4, not EXIF 2.
        #expect(RAWImageOrientation(decoderFlip: 2) == .mirroredVertically)
        #expect(RAWImageOrientation(exifOrientation: 2) == .mirroredHorizontally)
        // flip 3 is EXIF 3 — the one that happens to coincide.
        #expect(RAWImageOrientation(decoderFlip: 3) == .rotated180)
        #expect(RAWImageOrientation(exifOrientation: 3) == .rotated180)
        // flip 5 is EXIF 8, and flip 6 is EXIF 6.
        #expect(RAWImageOrientation(decoderFlip: 5) == .rotated270Clockwise)
        #expect(RAWImageOrientation(exifOrientation: 5) == .transposed)
        #expect(RAWImageOrientation(decoderFlip: 6) == .rotated90Clockwise)
        #expect(RAWImageOrientation(exifOrientation: 6) == .rotated90Clockwise)

        // Only three of the eight cases have flip == exif.
        let coinciding = Self.mapping.filter { $0.flip == $0.exif }
        #expect(coinciding.count == 3)
        #expect(coinciding.map(\.exif).sorted() == [3, 6, 7])
    }

    @Test("Every EXIF orientation maps to its documented case")
    func exifValuesMapToOrientations() {
        for entry in Self.mapping {
            #expect(
                RAWImageOrientation(exifOrientation: entry.exif) == entry.orientation,
                "EXIF \(entry.exif)"
            )
            #expect(entry.orientation.exifOrientation == entry.exif, "\(entry.orientation)")
        }
    }

    @Test("The eight cases are exactly the eight the table describes")
    func everyCaseIsMapped() {
        #expect(RAWImageOrientation.allCases.count == 8)
        #expect(Self.mapping.count == 8)
        #expect(Set(Self.mapping.map(\.orientation)) == Set(RAWImageOrientation.allCases))
        // No two cases share a flip or an EXIF code.
        #expect(Set(RAWImageOrientation.allCases.map(\.decoderFlip)) == Set(0...7))
        #expect(Set(RAWImageOrientation.allCases.map(\.exifOrientation)) == Set(1...8))
    }

    // MARK: - The unmodelled-value policy

    /// The explicit alternative to a silent substitution. LibRaw does not
    /// guarantee `0...7`: several format parsers assign `flip` straight from a
    /// file field, and `identify()` normalises only exact 90/180/270-degree
    /// values into the bitfield.
    @Test(
        "An unmodelled flip value maps to nil, never to upright",
        arguments: [-1, 8, 9, 45, 90, 180, 270, 360, 1_000, Int.min, Int.max]
    )
    func unmodelledFlipValuesAreRefused(flip: Int) {
        #expect(RAWImageOrientation(decoderFlip: flip) == nil)
    }

    /// `90`, `180` and `270` deserve their own note: they are degree values
    /// LibRaw's `identify()` converts into the bitfield before the application
    /// sees them. If one ever arrives unconverted it must not be read as a
    /// rotation by accident — `180` is not `flip 180`, and none of them is a
    /// modelled bitfield value.
    @Test("Degree-valued flips are not silently reinterpreted as rotations")
    func degreeValuesAreNotRotations() {
        for degrees in [90, 180, 270] {
            #expect(RAWImageOrientation(decoderFlip: degrees) == nil, "\(degrees)")
        }
    }

    @Test(
        "An out-of-range EXIF orientation maps to nil, including 0",
        arguments: [0, -1, 9, 10, 274, Int.min, Int.max]
    )
    func unmodelledExifValuesAreRefused(exif: Int) {
        // `0` is "unspecified" in EXIF, which is not "upright".
        #expect(RAWImageOrientation(exifOrientation: exif) == nil)
    }

    // MARK: - Metadata

    @Test("Geometry exposes the mapped orientation for every modelled flip")
    func geometryExposesTheOrientation() {
        for entry in Self.mapping {
            let geometry = Self.geometry(flip: entry.flip)
            #expect(geometry.orientation == entry.orientation, "flip \(entry.flip)")
            #expect(geometry.orientationIsRepresentable)
        }
    }

    @Test("Geometry reports nil rather than upright for an unmodelled flip")
    func geometryRefusesUnmodelledFlips() {
        for flip in [-3, 8, 99] {
            let geometry = Self.geometry(flip: flip)
            #expect(geometry.orientation == nil, "flip \(flip)")
            #expect(!geometry.orientationIsRepresentable)
            // The distinction the policy exists for.
            #expect(geometry.orientation != .upright)
        }
    }

    // MARK: - Properties of the cases

    @Test("Exactly four orientations exchange width and height")
    func dimensionSwappingIsTheTransposingFour() {
        for entry in Self.mapping {
            #expect(entry.orientation.swapsDimensions == entry.swaps, "\(entry.orientation)")
            let output = entry.orientation.outputDimensions(
                sourceWidth: 7, sourceHeight: 3
            )
            #expect(output.width == (entry.swaps ? 3 : 7), "\(entry.orientation)")
            #expect(output.height == (entry.swaps ? 7 : 3), "\(entry.orientation)")
        }
        #expect(RAWImageOrientation.allCases.filter(\.swapsDimensions).count == 4)
    }

    /// The distinction that four quarter-turns would have lost. A reflection
    /// reverses handedness and no rotation reproduces it.
    @Test("Exactly four orientations are reflections, and they are named")
    func reflectionsAreDistinguishedFromRotations() {
        for entry in Self.mapping {
            #expect(entry.orientation.isMirrored == entry.mirrored, "\(entry.orientation)")
        }
        #expect(
            Set(RAWImageOrientation.allCases.filter(\.isMirrored))
                == [.mirroredHorizontally, .mirroredVertically, .transposed, .transverse]
        )
        // Transpose and a quarter turn both swap dimensions and are *not* the
        // same operation — the confusion this property exists to prevent.
        #expect(RAWImageOrientation.transposed.swapsDimensions)
        #expect(RAWImageOrientation.rotated90Clockwise.swapsDimensions)
        #expect(RAWImageOrientation.transposed.isMirrored)
        #expect(!RAWImageOrientation.rotated90Clockwise.isMirrored)
    }

    @Test("Only upright is the identity")
    func onlyUprightIsIdentity() {
        for orientation in RAWImageOrientation.allCases {
            #expect(orientation.isIdentity == (orientation == .upright))
        }
        // Not the same question as "keeps its dimensions": three others do.
        let keepsDimensions = RAWImageOrientation.allCases.filter { !$0.swapsDimensions }
        #expect(keepsDimensions.count == 4)
        #expect(keepsDimensions.filter(\.isIdentity).count == 1)
    }

    @Test("Output dimensions never change the pixel count")
    func outputDimensionsPreserveThePixelCount() {
        for orientation in RAWImageOrientation.allCases {
            for (width, height) in [(1, 1), (1, 9), (9, 1), (4056, 3040), (3, 2)] {
                let output = orientation.outputDimensions(
                    sourceWidth: width, sourceHeight: height
                )
                #expect(output.width * output.height == width * height)
            }
        }
    }

    @Test("Every case has a distinct, readable diagnostic description")
    func diagnosticDescriptionsAreDistinct() {
        let descriptions = RAWImageOrientation.allCases.map(\.diagnosticDescription)
        #expect(Set(descriptions).count == 8)
        #expect(descriptions.allSatisfy { !$0.isEmpty })
        // The two reflections say so, rather than reading as rotations.
        #expect(RAWImageOrientation.transposed.diagnosticDescription.contains("reflected"))
        #expect(RAWImageOrientation.transverse.diagnosticDescription.contains("reflected"))
    }

    // MARK: - Helpers

    /// Metadata geometry carrying one `flip`, with everything else fixed.
    static func geometry(flip: Int) -> RAWMetadata.Geometry {
        RAWMetadata.Geometry(
            rawWidth: 4080,
            rawHeight: 3040,
            visibleWidth: 4056,
            visibleHeight: 3040,
            topMargin: 0,
            leftMargin: 0,
            outputWidth: 4056,
            outputHeight: 3040,
            flip: flip,
            pixelAspect: 1
        )
    }
}
