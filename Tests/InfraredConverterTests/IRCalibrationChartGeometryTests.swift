import Testing
import Foundation
@testable import InfraredConverter

/// Turning four marked corners into twenty-four sampling regions: the grid, the
/// centred sampling, the CFA alignment, and the refusals.
@Suite("IRCalibrationChartGeometry")
struct IRCalibrationChartGeometryTests {

    static func rectangular(
        originX: Double = 0.1, originY: Double = 0.1,
        width: Double = 0.8, height: Double = 0.6,
        fraction: Double = IRCalibrationChartGeometry.defaultPatchSampleFraction
    ) throws -> IRCalibrationChartGeometry {
        try .rectangular(
            target: .colorCheckerClassic24,
            originX: originX, originY: originY, width: width, height: height,
            patchSampleFraction: fraction
        )
    }

    @Test("A rectangular outline produces one region per patch, in target order")
    func regionsPerPatch() throws {
        let regions = try Self.rectangular()
            .patchRegions(activeAreaWidth: 4000, activeAreaHeight: 3000)

        #expect(regions.count == 24)
        #expect(regions.map(\.patch) == IRCalibrationTarget.colorCheckerClassic24.patchIDs)
    }

    @Test("Regions do not overlap, and each lies inside the outlined chart")
    func regionsAreDisjointAndInside() throws {
        let geometry = try Self.rectangular()
        let regions = try geometry.patchRegions(activeAreaWidth: 4000, activeAreaHeight: 3000)

        for (index, first) in regions.enumerated() {
            // Inside the chart outline.
            #expect(first.region.originColumn >= Int(0.1 * 4000))
            #expect(first.region.originRow >= Int(0.1 * 3000))
            #expect(first.region.originColumn + first.region.width <= Int(0.9 * 4000))
            #expect(first.region.originRow + first.region.height <= Int(0.7 * 3000))

            for second in regions[(index + 1)...] {
                let separated =
                    first.region.originColumn + first.region.width <= second.region.originColumn
                    || second.region.originColumn + second.region.width <= first.region.originColumn
                    || first.region.originRow + first.region.height <= second.region.originRow
                    || second.region.originRow + second.region.height <= first.region.originRow
                #expect(separated, "\(first.patch) overlaps \(second.patch)")
            }
        }
    }

    /// Equal counts of every colour plane depend on whole 2x2 cells, which is
    /// what even origins and even extents buy.
    @Test("Every region has an even origin and an even extent, so it covers whole CFA cells")
    func regionsAreCFAAligned() throws {
        for fraction in [0.2, 0.35, 0.5, 0.9] {
            let regions = try Self.rectangular(fraction: fraction)
                .patchRegions(activeAreaWidth: 4000, activeAreaHeight: 3000)
            for (patch, region) in regions {
                #expect(region.originRow % 2 == 0, "\(patch) origin row \(region.originRow)")
                #expect(region.originColumn % 2 == 0, "\(patch) origin column \(region.originColumn)")
                #expect(region.width % 2 == 0, "\(patch) width \(region.width)")
                #expect(region.height % 2 == 0, "\(patch) height \(region.height)")
            }
        }
    }

    @Test("Only the centred fraction of each patch is sampled")
    func centredSampling() throws {
        let wide = try Self.rectangular(fraction: 0.9)
            .patchRegions(activeAreaWidth: 4000, activeAreaHeight: 3000)
        let narrow = try Self.rectangular(fraction: 0.3)
            .patchRegions(activeAreaWidth: 4000, activeAreaHeight: 3000)

        for (a, b) in zip(wide, narrow) {
            #expect(a.region.width > b.region.width)
            #expect(a.region.height > b.region.height)

            // Both centred on the same point, within one CFA cell.
            let wideCenter = Double(a.region.originColumn) + Double(a.region.width) / 2
            let narrowCenter = Double(b.region.originColumn) + Double(b.region.width) / 2
            #expect(abs(wideCenter - narrowCenter) <= 2)
        }
    }

    @Test("Patch 01 is top left and patch 24 is bottom right")
    func rowMajorOrder() throws {
        let regions = try Self.rectangular()
            .patchRegions(activeAreaWidth: 4000, activeAreaHeight: 3000)
        let byPatch = Dictionary(uniqueKeysWithValues: regions.map { ($0.patch, $0.region) })

        let first = try #require(byPatch[CalibrationTestData.patch(1)])
        let last = try #require(byPatch[CalibrationTestData.patch(24)])
        let seventh = try #require(byPatch[CalibrationTestData.patch(7)])

        #expect(first.originColumn < last.originColumn)
        #expect(first.originRow < last.originRow)
        // Patch 07 starts the second row: same column as 01, further down.
        #expect(seventh.originColumn == first.originColumn)
        #expect(seventh.originRow > first.originRow)
    }

    @Test("The bilinear map is exact for an affine outline")
    func affineExactness() throws {
        // A sheared outline: the mapping is affine, so a patch centre must land
        // exactly where the shear puts it.
        let geometry = try IRCalibrationChartGeometry(
            target: .colorCheckerClassic24,
            topLeft: try IRCalibrationChartPoint(x: 0.10, y: 0.10),
            topRight: try IRCalibrationChartPoint(x: 0.80, y: 0.10),
            bottomRight: try IRCalibrationChartPoint(x: 0.90, y: 0.70),
            bottomLeft: try IRCalibrationChartPoint(x: 0.20, y: 0.70)
        )
        let middle = geometry.point(u: 0.5, v: 0.5)
        #expect(abs(middle.x - 0.50) < 1e-12)
        #expect(abs(middle.y - 0.40) < 1e-12)

        // Corners map to corners.
        let topLeft = geometry.point(u: 0, v: 0)
        #expect(abs(topLeft.x - 0.10) < 1e-12)
        #expect(abs(topLeft.y - 0.10) < 1e-12)
    }

    // MARK: - Refusals

    @Test(
        "A corner outside the active area is refused",
        arguments: [(-0.01, 0.1), (0.1, 1.01), (1.5, 0.5)]
    )
    func cornerOutsideActiveArea(point: (Double, Double)) {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationChartPoint(x: point.0, y: point.1)
        }
    }

    @Test("A non-finite corner is refused")
    func nonFiniteCorner() {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationChartPoint(x: .nan, y: 0.5)
        }
    }

    @Test("A degenerate outline — zero area — is refused")
    func degenerateOutline() {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationChartGeometry(
                target: .colorCheckerClassic24,
                topLeft: try IRCalibrationChartPoint(x: 0.2, y: 0.2),
                topRight: try IRCalibrationChartPoint(x: 0.2, y: 0.2),
                bottomRight: try IRCalibrationChartPoint(x: 0.2, y: 0.2),
                bottomLeft: try IRCalibrationChartPoint(x: 0.2, y: 0.2)
            )
        }
    }

    @Test("Corners given in the wrong winding order are refused, not silently inverted")
    func wrongWinding() {
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationChartGeometry(
                target: .colorCheckerClassic24,
                topLeft: try IRCalibrationChartPoint(x: 0.1, y: 0.1),
                topRight: try IRCalibrationChartPoint(x: 0.1, y: 0.7),
                bottomRight: try IRCalibrationChartPoint(x: 0.9, y: 0.7),
                bottomLeft: try IRCalibrationChartPoint(x: 0.9, y: 0.1)
            )
        }
    }

    @Test(
        "An unusable sample fraction is refused",
        arguments: [0.0, -0.5, 1.5, Double.nan]
    )
    func invalidSampleFraction(fraction: Double) {
        #expect(throws: IRCalibrationError.self) {
            try Self.rectangular(fraction: fraction)
        }
    }

    @Test("A chart too small in the frame is refused, rather than sampled approximately")
    func chartTooSmall() throws {
        let tiny = try Self.rectangular(
            originX: 0.4, originY: 0.4, width: 0.02, height: 0.02
        )
        #expect(throws: IRCalibrationError.self) {
            try tiny.patchRegions(activeAreaWidth: 400, activeAreaHeight: 300)
        }
    }

    @Test("An active area too small for any patch region is refused")
    func activeAreaTooSmall() throws {
        let geometry = try Self.rectangular()
        #expect(throws: IRCalibrationError.self) {
            try geometry.patchRegions(activeAreaWidth: 1, activeAreaHeight: 1)
        }
    }

    /// The inscribed rectangle shrinks with rotation and eventually vanishes,
    /// which is reported rather than approximated.
    @Test("A steeply rotated outline is refused once no axis-aligned region fits inside a patch")
    func steeplyRotated() throws {
        let rotated = try IRCalibrationChartGeometry(
            target: .colorCheckerClassic24,
            topLeft: try IRCalibrationChartPoint(x: 0.05, y: 0.40),
            topRight: try IRCalibrationChartPoint(x: 0.50, y: 0.05),
            bottomRight: try IRCalibrationChartPoint(x: 0.95, y: 0.60),
            bottomLeft: try IRCalibrationChartPoint(x: 0.50, y: 0.95),
            patchSampleFraction: 0.9
        )
        #expect(throws: IRCalibrationError.self) {
            try rotated.patchRegions(activeAreaWidth: 400, activeAreaHeight: 300)
        }
    }

    @Test("A geometry whose target disagrees with the session's target is refused")
    func targetAgreement() throws {
        let geometry = try Self.rectangular()
        #expect(geometry.target == .colorCheckerClassic24)
        #expect(throws: Never.self) {
            _ = try IRCalibrationMeasurementPipeline.Session(
                target: .colorCheckerClassic24,
                geometry: geometry,
                illuminant: .d65,
                sensorConversion: .unknown,
                filter: try IRCalibrationFilterSnapshot(),
                bodyScope: .modelLevel,
                whiteBalancePolicy: .none,
                provenance: CalibrationTestData.provenance()
            )
        }
    }
}
