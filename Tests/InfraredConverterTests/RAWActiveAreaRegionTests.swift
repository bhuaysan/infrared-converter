import Foundation
import Testing
@testable import InfraredConverter

/// The region type on its own: coordinates, arithmetic, and the validation
/// that refuses a selection instead of quietly cropping it.
@Suite("RAWActiveAreaRegion")
struct RAWActiveAreaRegionTests {

    static func region(
        _ originRow: Int, _ originColumn: Int, _ width: Int, _ height: Int
    ) -> RAWActiveAreaRegion {
        RAWActiveAreaRegion(
            originRow: originRow, originColumn: originColumn, width: width, height: height
        )
    }

    // MARK: - Valid regions

    @Test("A region inside the mosaic validates, including one filling it exactly")
    func validRegions() throws {
        try Self.region(0, 0, 1, 1).validate(inWidth: 8, height: 8)
        try Self.region(2, 3, 4, 5).validate(inWidth: 8, height: 8)
        try Self.region(0, 0, 8, 8).validate(inWidth: 8, height: 8)
        try Self.region(7, 7, 1, 1).validate(inWidth: 8, height: 8)
    }

    @Test("Limits and sample count are computed without trapping")
    func derivedValues() {
        let region = Self.region(10, 20, 4, 6)
        #expect(region.rowLimit == 16)
        #expect(region.columnLimit == 24)
        #expect(region.sampleCount == 24)

        // Overflow reports itself rather than trapping.
        #expect(Self.region(Int.max, 0, 1, 2).rowLimit == nil)
        #expect(Self.region(0, Int.max, 2, 1).columnLimit == nil)
        #expect(Self.region(0, 0, Int.max, 3).sampleCount == nil)
    }

    // MARK: - Rejected regions

    @Test("A zero or negative width is refused")
    func zeroWidth() {
        #expect(throws: RAWProcessingError.self) {
            try Self.region(0, 0, 0, 4).validate(inWidth: 8, height: 8)
        }
        #expect(throws: RAWProcessingError.self) {
            try Self.region(0, 0, -3, 4).validate(inWidth: 8, height: 8)
        }
    }

    @Test("A zero or negative height is refused")
    func zeroHeight() {
        #expect(throws: RAWProcessingError.self) {
            try Self.region(0, 0, 4, 0).validate(inWidth: 8, height: 8)
        }
        #expect(throws: RAWProcessingError.self) {
            try Self.region(0, 0, 4, -3).validate(inWidth: 8, height: 8)
        }
    }

    @Test("A negative origin is refused in either axis")
    func negativeOrigin() {
        #expect(throws: RAWProcessingError.self) {
            try Self.region(-1, 0, 2, 2).validate(inWidth: 8, height: 8)
        }
        #expect(throws: RAWProcessingError.self) {
            try Self.region(0, -1, 2, 2).validate(inWidth: 8, height: 8)
        }
    }

    @Test("A region past the right edge is refused, not cropped")
    func pastRightEdge() {
        // One column too far: the whole selection is refused, and no smaller
        // 7-wide region is substituted.
        #expect(throws: RAWProcessingError.self) {
            try Self.region(0, 1, 8, 4).validate(inWidth: 8, height: 8)
        }
        #expect(throws: RAWProcessingError.self) {
            try Self.region(0, 8, 1, 1).validate(inWidth: 8, height: 8)
        }
    }

    @Test("A region past the bottom edge is refused, not cropped")
    func pastBottomEdge() {
        #expect(throws: RAWProcessingError.self) {
            try Self.region(1, 0, 4, 8).validate(inWidth: 8, height: 8)
        }
        #expect(throws: RAWProcessingError.self) {
            try Self.region(8, 0, 1, 1).validate(inWidth: 8, height: 8)
        }
    }

    @Test("An origin plus dimension that overflows Int is refused")
    func overflowingFarEdge() {
        #expect(throws: RAWProcessingError.self) {
            try Self.region(Int.max, 0, 2, 2).validate(inWidth: 8, height: 8)
        }
        #expect(throws: RAWProcessingError.self) {
            try Self.region(0, Int.max, 2, 2).validate(inWidth: 8, height: 8)
        }
        #expect(throws: RAWProcessingError.self) {
            try Self.region(Int.max - 1, Int.max - 1, Int.max, Int.max)
                .validate(inWidth: 8, height: 8)
        }
    }

    @Test("Rejections are typed and say which rule was broken")
    func rejectionsAreTyped() {
        func reason(_ region: RAWActiveAreaRegion) -> String? {
            do {
                try region.validate(inWidth: 8, height: 8)
                return nil
            } catch let error as RAWProcessingError {
                guard case .invalidActiveAreaRegion(let reason) = error else { return nil }
                return reason
            } catch {
                return nil
            }
        }

        #expect(reason(Self.region(-1, 0, 2, 2))?.contains("negative") == true)
        #expect(reason(Self.region(0, 0, 0, 2))?.contains("strictly positive") == true)
        #expect(reason(Self.region(Int.max, 0, 2, 2))?.contains("overflows") == true)
        #expect(reason(Self.region(0, 0, 9, 2))?.contains("outside") == true)
    }

    @Test("Validation against a mosaic uses that mosaic's own dimensions")
    func validatesAgainstAMosaic() throws {
        let mosaic = LinearRAWMosaic(
            width: 4,
            height: 2,
            values: [Float](repeating: 0.5, count: 8),
            sensorColorLayout: RAWTestData.bayerLayout(),
            processing: RAWLinearProcessing(whiteLevelPolicy: .metadataMaximum, whiteLevel: 4095)
        )
        try RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 4, height: 2)
            .validate(in: mosaic)
        // Valid for a 4-wide mosaic in the other axis, still refused here.
        #expect(throws: RAWProcessingError.self) {
            try RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 2, height: 4)
                .validate(in: mosaic)
        }
    }

    @Test("The type is a value type with equality by coordinates")
    func equality() {
        #expect(Self.region(1, 2, 3, 4) == Self.region(1, 2, 3, 4))
        #expect(Self.region(1, 2, 3, 4) != Self.region(2, 1, 3, 4))
        #expect(Self.region(1, 2, 3, 4) != Self.region(1, 2, 4, 3))
    }
}
