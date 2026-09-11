import Testing
import Foundation
@testable import InfraredConverter

/// What the orientation stage refuses, and how.
///
/// `IRChannelMixedRGBImage` is publicly constructible on purpose — it is a
/// data representation, and a test or an alternate producer may legitimately
/// build one — so every case here is a real boundary rather than an internal
/// assertion. Nothing in this stage traps, for any value the public
/// initialisers accept.
@Suite("ImageOrienter refusals")
struct ImageOrienterErrorTests {

    // MARK: - Geometry

    @Test("A buffer shorter than the geometry is refused, for every orientation")
    func aShortBufferIsRefused() throws {
        // 3×2 needs 18 values; this has 15.
        let short = OrientationTestData.image(
            width: 3, height: 2, values: Array(repeating: 0.5, count: 15)
        )

        for orientation in RAWImageOrientation.allCases {
            #expect(throws: OrientationError.self) {
                try ImageOrienter().apply(to: short, orientation: orientation)
            }
        }
    }

    @Test("A buffer longer than the geometry is refused too")
    func aLongBufferIsRefused() throws {
        let long = OrientationTestData.image(
            width: 2, height: 2, values: Array(repeating: 0.25, count: 15)
        )
        let error = try #require(throws: OrientationError.self) {
            try ImageOrienter().apply(to: long, orientation: .rotated90Clockwise)
        }
        guard case .invalidGeometry(let reason) = error else {
            Issue.record("expected invalidGeometry, got \(error)")
            return
        }
        #expect(reason.contains("2x2"))
        #expect(reason.contains("12"))
        #expect(reason.contains("15"))
    }

    @Test(
        "A non-positive dimension is refused",
        arguments: [(0, 4), (4, 0), (0, 0), (-1, 4), (4, -1)]
    )
    func nonPositiveDimensionsAreRefused(width: Int, height: Int) throws {
        let empty = OrientationTestData.image(width: width, height: height, values: [])
        #expect(throws: OrientationError.self) {
            try ImageOrienter().apply(to: empty, orientation: .transposed)
        }
    }

    /// A geometry whose element count is not a representable `Int` is reported
    /// rather than trapped on in an allocation.
    @Test("Overflowing geometry is reported, not trapped on")
    func overflowingGeometryIsReported() throws {
        let absurd = OrientationTestData.image(
            width: Int.max, height: 4, values: [1, 2, 3]
        )
        #expect(absurd.expectedValueCount == nil)
        #expect(!absurd.isGeometryConsistent)

        for orientation in RAWImageOrientation.allCases {
            #expect(throws: OrientationError.self) {
                try ImageOrienter().apply(to: absurd, orientation: orientation)
            }
        }

        // The three-channel product is checked separately from the pixel
        // product: a width×height that fits can still overflow when tripled.
        let tripleOverflow = OrientationTestData.image(
            width: Int.max / 2, height: 1, values: [1, 2, 3]
        )
        #expect(tripleOverflow.expectedValueCount == nil)
        #expect(throws: OrientationError.self) {
            try ImageOrienter().apply(to: tripleOverflow, orientation: .upright)
        }
    }

    /// The oriented representation's own accessors never trap either, for any
    /// geometry the public initialiser accepts.
    @Test("The oriented image's accessors report rather than trap")
    func orientedAccessorsNeverTrap() {
        let absurd = OrientedSceneLinearRGBImage(
            width: Int.max,
            height: 4,
            values: [1, 2, 3],
            processing: ImageOrientationProcessing(
                orientation: .upright,
                channelMixProcessing: OrientationTestData.channelMixProcessing()
            )
        )
        #expect(absurd.valuesPerRow == nil)
        #expect(absurd.expectedValueCount == nil)
        #expect(!absurd.isGeometryConsistent)
        #expect(absurd.storageIndex(row: 1, column: 0) == nil)
        #expect(absurd.pixel(row: 1, column: 0) == nil)
        #expect(absurd.value(row: 1, column: 0, channel: .red) == nil)
        // Row 0, column 0 is genuinely at element 0, and the buffer holds that
        // one pixel: the guards report what is unrepresentable rather than
        // refusing everything.
        #expect(absurd.storageIndex(row: 0, column: 0) == 0)

        let wellFormed = OrientedSceneLinearRGBImage(
            width: 2,
            height: 1,
            values: [0, 1, 2, 3, 4, 5],
            processing: ImageOrientationProcessing(
                orientation: .rotated90Clockwise,
                channelMixProcessing: OrientationTestData.channelMixProcessing()
            )
        )
        #expect(wellFormed.isGeometryConsistent)
        #expect(wellFormed.storageIndex(row: 0, column: 2) == nil)
        #expect(wellFormed.storageIndex(row: 1, column: 0) == nil)
        #expect(wellFormed.storageIndex(row: -1, column: 0) == nil)
        #expect(wellFormed.storageIndex(row: 0, column: -1) == nil)
        #expect(wellFormed.pixelCount == 2)
        #expect(wellFormed.valuesPerRow == 6)
    }

    // MARK: - The unmodelled-orientation policy

    /// The application layer refuses rather than guessing. This is the policy
    /// half of `RAWImageOrientation.init?(decoderFlip:)` returning `nil`.
    @Test("The workspace refuses an orientation code it cannot model")
    func theWorkspaceRefusesAnUnmodelledOrientation() {
        var metadata = RAWTestData.metadata()

        for flip in [-1, 8, 45, 180, 4_096] {
            metadata.geometry.flip = flip
            #expect(WorkspacePreviewPipeline.orientation(for: metadata) == nil, "flip \(flip)")
        }

        // And a modelled one is read, not refused.
        for orientation in RAWImageOrientation.allCases {
            metadata.geometry.flip = orientation.decoderFlip
            #expect(WorkspacePreviewPipeline.orientation(for: metadata) == orientation)
        }
    }

    /// The message names the value, so the file can be investigated rather
    /// than guessed at — and says explicitly that it was not treated as
    /// upright.
    @Test("The unmodelled-orientation failure reports the value it could not read")
    func theUnmodelledOrientationFailureIsLegible() throws {
        let error = OrientationError.unsupportedDecoderOrientation(flip: 77)
        let description = try #require(error.errorDescription)
        let reason = try #require(error.failureReason)

        #expect(!description.isEmpty)
        #expect(reason.contains("77"))
        #expect(reason.contains("upright"))
    }

    @Test("Every failure carries a description and a reason")
    func everyFailureIsLocalized() throws {
        let failures: [OrientationError] = [
            .invalidGeometry(reason: "geometry and buffer disagree"),
            .unrepresentableOrientedGeometry(reason: "extent is not representable"),
            .unsupportedDecoderOrientation(flip: 9),
        ]

        for failure in failures {
            #expect(failure.errorDescription?.isEmpty == false, "\(failure)")
            #expect(failure.failureReason?.isEmpty == false, "\(failure)")
        }

        // Distinct cases stay distinct: a caller can branch on them.
        #expect(OrientationError.invalidGeometry(reason: "a")
            != OrientationError.invalidGeometry(reason: "b"))
        #expect(OrientationError.unsupportedDecoderOrientation(flip: 8)
            != OrientationError.unsupportedDecoderOrientation(flip: 9))
    }

    /// `unrepresentableOrientedGeometry` guards a case the current arithmetic
    /// cannot reach: orientation only exchanges the two factors, so a
    /// consistent input already proves the output's element count is the one
    /// the input's buffer has. The guard stays because the alternative to a
    /// check is a trap inside an allocation, and this records that the case is
    /// deliberate rather than dead by accident.
    @Test("A consistent input always yields a representable oriented geometry")
    func consistentInputNeverProducesAnUnrepresentableOutput() throws {
        for (width, height) in [(1, 1), (1, 7), (7, 1), (3, 2), (16, 9), (97, 41)] {
            let image = OrientationTestData.image(
                width: width,
                height: height,
                values: Array(repeating: 0.5, count: width * height * 3)
            )
            for orientation in RAWImageOrientation.allCases {
                let oriented = try ImageOrienter().apply(to: image, orientation: orientation)
                #expect(oriented.expectedValueCount == image.values.count)
                #expect(oriented.isGeometryConsistent)
            }
        }
    }
}
