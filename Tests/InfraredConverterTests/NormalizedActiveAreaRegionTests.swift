import Testing
import Foundation
@testable import InfraredConverter

/// The persisted shape of a neutral patch: what it accepts, what it refuses,
/// and what it never does quietly.
@Suite("NormalizedActiveAreaRegion")
struct NormalizedActiveAreaRegionTests {

    @Test("A rectangle inside the unit square is kept exactly")
    func aValidRegionIsKept() throws {
        let region = try NormalizedActiveAreaRegion(
            originX: 0.25, originY: 0.125, width: 0.5, height: 0.0625
        )
        #expect(region.originX == 0.25)
        #expect(region.originY == 0.125)
        #expect(region.width == 0.5)
        #expect(region.height == 0.0625)
        #expect(region.centerX == 0.5)
        #expect(region.centerY == 0.125 + 0.03125)
    }

    @Test("The whole active area is a legal region")
    func theFullAreaIsLegal() throws {
        let full = NormalizedActiveAreaRegion.full
        #expect(full.originX == 0)
        #expect(full.originY == 0)
        #expect(full.width == 1)
        #expect(full.height == 1)
        // And it is reachable through the validating initialiser too, so the
        // constant is not a way around the contract.
        let built = try NormalizedActiveAreaRegion(
            originX: 0, originY: 0, width: 1, height: 1
        )
        #expect(built == full)
    }

    // MARK: - Refusals

    /// Each of the four coordinates is checked, and the refusal names which.
    @Test(
        "A non-finite coordinate is refused, and named",
        arguments: ["originX", "originY", "width", "height"]
    )
    func nonFiniteCoordinatesAreRefused(field: String) {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ImageAdjustmentError.self) {
                try NormalizedActiveAreaRegion(
                    originX: field == "originX" ? value : 0.1,
                    originY: field == "originY" ? value : 0.1,
                    width: field == "width" ? value : 0.1,
                    height: field == "height" ? value : 0.1
                )
            }
        }
    }

    @Test(
        "A zero or negative extent is refused",
        arguments: [(0.0, 0.1), (0.1, 0.0), (-0.2, 0.1), (0.1, -0.2), (0.0, 0.0)]
    )
    func emptyRegionsAreRefused(width: Double, height: Double) {
        #expect(
            throws: ImageAdjustmentError.emptyNeutralPatch(width: width, height: height)
        ) {
            try NormalizedActiveAreaRegion(
                originX: 0.1, originY: 0.1, width: width, height: height
            )
        }
    }

    /// Refused, not clamped. A clamped patch measures different samples from
    /// the ones the record names.
    @Test(
        "A region outside the active area is refused, never clamped",
        arguments: [
            (-0.01, 0.1, 0.1, 0.1),
            (0.1, -0.01, 0.1, 0.1),
            (0.95, 0.1, 0.1, 0.1),
            (0.1, 0.95, 0.1, 0.1),
            (0.0, 0.0, 1.5, 0.1),
            (0.0, 0.0, 0.1, 2.0),
        ]
    )
    func regionsOutsideTheAreaAreRefused(
        originX: Double, originY: Double, width: Double, height: Double
    ) {
        #expect(
            throws: ImageAdjustmentError.neutralPatchOutsideActiveArea(
                originX: originX, originY: originY, width: width, height: height
            )
        ) {
            try NormalizedActiveAreaRegion(
                originX: originX, originY: originY, width: width, height: height
            )
        }
    }

    // MARK: - Centring

    @Test("A centred region keeps its size and is centred on the point")
    func centringIsExactInTheMiddle() throws {
        let region = try NormalizedActiveAreaRegion.centered(
            atX: 0.5, y: 0.5, width: 0.25, height: 0.125
        )
        #expect(region.width == 0.25)
        #expect(region.height == 0.125)
        #expect(abs(region.centerX - 0.5) < 1e-12)
        #expect(abs(region.centerY - 0.5) < 1e-12)
    }

    /// The rule an edge click depends on: the region is **shifted**, not
    /// trimmed, so a patch near the border measures as much of the photograph
    /// as one in the middle.
    @Test(
        "A region centred near an edge is shifted inward with its size intact",
        arguments: [
            (0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0), (0.01, 0.99),
        ]
    )
    func centringNearAnEdgeShiftsRatherThanTrims(x: Double, y: Double) throws {
        let region = try NormalizedActiveAreaRegion.centered(
            atX: x, y: y, width: 0.2, height: 0.3
        )
        #expect(region.width == 0.2)
        #expect(region.height == 0.3)
        #expect(region.originX >= 0)
        #expect(region.originY >= 0)
        #expect(region.originX + region.width <= 1 + 1e-12)
        #expect(region.originY + region.height <= 1 + 1e-12)
    }

    @Test("A centred region larger than the area is refused, not shrunk")
    func centringARegionTooLargeIsRefused() {
        #expect(throws: ImageAdjustmentError.self) {
            try NormalizedActiveAreaRegion.centered(
                atX: 0.5, y: 0.5, width: 1.5, height: 0.2
            )
        }
    }

    @Test("A non-finite centre is refused")
    func aNonFiniteCentreIsRefused() {
        #expect(throws: ImageAdjustmentError.self) {
            try NormalizedActiveAreaRegion.centered(
                atX: .nan, y: 0.5, width: 0.2, height: 0.2
            )
        }
        #expect(throws: ImageAdjustmentError.self) {
            try NormalizedActiveAreaRegion.centered(
                atX: 0.5, y: .infinity, width: 0.2, height: 0.2
            )
        }
    }

    // MARK: - Persistence

    @Test("The encoded shape is the documented one")
    func theEncodedShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let region = try NormalizedActiveAreaRegion(
            originX: 0.25, originY: 0.5, width: 0.125, height: 0.0625
        )
        #expect(
            String(decoding: try encoder.encode(region), as: UTF8.self)
                == #"{"height":0.0625,"originX":0.25,"originY":0.5,"width":0.125}"#
        )
    }

    @Test("A region round-trips exactly")
    func aRegionRoundTrips() throws {
        let regions = [
            try NormalizedActiveAreaRegion(
                originX: 0, originY: 0, width: 1, height: 1
            ),
            try NormalizedActiveAreaRegion(
                originX: 0.25, originY: 0.5, width: 0.125, height: 0.0625
            ),
            try NormalizedActiveAreaRegion(
                originX: 0.9, originY: 0.9, width: 0.1, height: 0.1
            ),
        ]
        for region in regions {
            let data = try JSONEncoder().encode(region)
            #expect(try JSONDecoder().decode(NormalizedActiveAreaRegion.self, from: data) == region)
        }
    }

    @Test(
        "Every coordinate is required, and its absence is refused rather than defaulted",
        arguments: ["originX", "originY", "width", "height"]
    )
    func everyCoordinateIsRequired(field: String) throws {
        var object: [String: Double] = [
            "originX": 0.1, "originY": 0.1, "width": 0.2, "height": 0.2,
        ]
        object[field] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ImageAdjustmentError.missingNeutralPatchField(field: field)) {
            try JSONDecoder().decode(NormalizedActiveAreaRegion.self, from: data)
        }
    }

    /// The refusals apply to what comes off a disk, not only to what code
    /// constructs.
    @Test("A malformed persisted region is refused at the decoder")
    func malformedPersistedRegionsAreRefused() {
        let cases = [
            #"{"originX":-0.5,"originY":0,"width":0.1,"height":0.1}"#,
            #"{"originX":0,"originY":0,"width":0,"height":0.1}"#,
            #"{"originX":0.5,"originY":0.5,"width":0.9,"height":0.1}"#,
        ]
        for json in cases {
            #expect(throws: ImageAdjustmentError.self) {
                try JSONDecoder().decode(
                    NormalizedActiveAreaRegion.self, from: Data(json.utf8)
                )
            }
        }
    }
}
