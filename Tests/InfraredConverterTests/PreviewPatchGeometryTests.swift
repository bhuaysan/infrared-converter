import Testing
import Foundation
@testable import InfraredConverter

/// The road from a click to a sensor coordinate, and back again for the
/// overlay.
///
/// Everything here is arithmetic on `Double`s against known points. No view is
/// created, nothing is rendered, and no framework decides anything — which is
/// the property that makes a picker's correctness testable at all.
@Suite("Preview patch geometry")
struct PreviewPatchGeometryTests {

    private static let tolerance = 1e-12

    private static func expectClose(
        _ value: Double, _ expected: Double, _ label: String = ""
    ) {
        #expect(
            abs(value - expected) < tolerance,
            "\(label) expected \(expected), got \(value)"
        )
    }

    // MARK: - Aspect fit

    /// A wide area holding a 4:3 picture letterboxes on the **left and
    /// right**, and the picture is centred in what is left.
    @Test("A picture narrower than its area is centred with side bars")
    func sideBars() throws {
        let fitted = try #require(
            PreviewPatchGeometry.fittedImage(
                pixelWidth: 400, pixelHeight: 300, inWidth: 1200, height: 600
            )
        )
        // The height is the binding constraint: 600 / 300 = 2, so 800 x 600.
        Self.expectClose(fitted.width, 800, "width")
        Self.expectClose(fitted.height, 600, "height")
        Self.expectClose(fitted.originX, 200, "originX")
        Self.expectClose(fitted.originY, 0, "originY")
    }

    @Test("A picture shorter than its area is centred with bars above and below")
    func letterbox() throws {
        let fitted = try #require(
            PreviewPatchGeometry.fittedImage(
                pixelWidth: 400, pixelHeight: 300, inWidth: 800, height: 900
            )
        )
        // The width binds: 800 / 400 = 2, so 800 x 600, centred vertically.
        Self.expectClose(fitted.width, 800, "width")
        Self.expectClose(fitted.height, 600, "height")
        Self.expectClose(fitted.originX, 0, "originX")
        Self.expectClose(fitted.originY, 150, "originY")
    }

    @Test("A picture of the area's own proportions fills it exactly")
    func exactFit() throws {
        let fitted = try #require(
            PreviewPatchGeometry.fittedImage(
                pixelWidth: 1024, pixelHeight: 768, inWidth: 512, height: 384
            )
        )
        #expect(fitted == FittedRect(originX: 0, originY: 0, width: 512, height: 384))
    }

    @Test(
        "An impossible layout has no answer, rather than a plausible one",
        arguments: [
            (0, 300, 800.0, 600.0), (400, 0, 800.0, 600.0),
            (400, 300, 0.0, 600.0), (400, 300, 800.0, 0.0),
            (400, 300, Double.nan, 600.0),
        ]
    )
    func impossibleLayouts(
        pixelWidth: Int, pixelHeight: Int, areaWidth: Double, areaHeight: Double
    ) {
        #expect(
            PreviewPatchGeometry.fittedImage(
                pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                inWidth: areaWidth, height: areaHeight
            ) == nil
        )
    }

    // MARK: - Clicks outside the picture

    /// Refused, not clamped. An aspect-fit layout letterboxes generously, and
    /// snapping a margin click to an edge would move the patch somewhere the
    /// user did not point.
    @Test("A click in the letterbox is refused")
    func clicksInTheMarginAreRefused() throws {
        let fitted = try #require(
            PreviewPatchGeometry.fittedImage(
                pixelWidth: 400, pixelHeight: 300, inWidth: 1200, height: 600
            )
        )
        // The picture occupies x in 200...1000.
        for x in [0.0, 50.0, 199.0, 1001.0, 1199.0] {
            #expect(
                PreviewPatchGeometry.sourcePoint(
                    viewX: x, viewY: 300, image: fitted, orientation: .upright
                ) == nil
            )
        }
        // And inside it is not refused.
        #expect(
            PreviewPatchGeometry.sourcePoint(
                viewX: 600, viewY: 300, image: fitted, orientation: .upright
            ) != nil
        )
    }

    @Test("The edges of the picture count as inside")
    func theEdgesCountAsInside() throws {
        let fitted = FittedRect(originX: 200, originY: 0, width: 800, height: 600)
        for (x, y) in [(200.0, 0.0), (1000.0, 600.0), (200.0, 600.0), (1000.0, 0.0)] {
            #expect(
                PreviewPatchGeometry.sourcePoint(
                    viewX: x, viewY: y, image: fitted, orientation: .upright
                ) != nil
            )
        }
    }

    @Test("A non-finite click is refused")
    func aNonFiniteClickIsRefused() {
        let fitted = FittedRect(originX: 0, originY: 0, width: 100, height: 100)
        #expect(fitted.unitPoint(viewX: .nan, viewY: 50) == nil)
        #expect(fitted.unitPoint(viewX: 50, viewY: .infinity) == nil)
    }

    // MARK: - The orientation mapping, against the pixel-level table

    /// The continuous mapping has to agree with
    /// `RAWImageOrientation.sourceCoordinate(row:column:sourceWidth:sourceHeight:)`,
    /// which is what the orienter actually runs. They are written separately
    /// — one in whole samples for a gather loop, one in fractions for a click
    /// — and this is the test that stops them drifting apart.
    ///
    /// The check is on **pixel centres**: a destination pixel `(r, c)` has its
    /// centre at unit `((c + 0.5) / W', (r + 0.5) / H')`, and the source pixel
    /// it draws from has its centre at the corresponding unit point in source
    /// space. Mapping the first must land inside the second.
    @Test(
        "The unit mapping agrees with the pixel mapping, for all eight orientations",
        arguments: RAWImageOrientation.allCases
    )
    func theUnitMappingAgreesWithThePixelMapping(orientation: RAWImageOrientation) {
        let sourceWidth = 7, sourceHeight = 5
        let output = orientation.outputDimensions(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight
        )

        for row in 0..<output.height {
            for column in 0..<output.width {
                let expected = orientation.sourceCoordinate(
                    row: row, column: column,
                    sourceWidth: sourceWidth, sourceHeight: sourceHeight
                )

                let mapped = PreviewPatchGeometry.sourcePoint(
                    displayedX: (Double(column) + 0.5) / Double(output.width),
                    displayedY: (Double(row) + 0.5) / Double(output.height),
                    orientation: orientation
                )
                // The unit point back into source sample indices.
                let mappedColumn = Int(mapped.x * Double(sourceWidth))
                let mappedRow = Int(mapped.y * Double(sourceHeight))

                #expect(
                    mappedColumn == expected.column && mappedRow == expected.row,
                    """
                    \(orientation): displayed (\(row), \(column)) mapped to source \
                    (\(mappedRow), \(mappedColumn)), the orienter reads \
                    (\(expected.row), \(expected.column))
                    """
                )
            }
        }
    }

    @Test(
        "The forward and inverse unit mappings undo each other",
        arguments: RAWImageOrientation.allCases
    )
    func theMappingsAreInverses(orientation: RAWImageOrientation) {
        let points: [(Double, Double)] = [
            (0, 0), (1, 0), (0, 1), (1, 1), (0.5, 0.5),
            (0.125, 0.875), (0.31, 0.62), (0.999, 0.001),
        ]
        for (x, y) in points {
            let displayed = PreviewPatchGeometry.displayedPoint(
                sourceX: x, sourceY: y, orientation: orientation
            )
            let back = PreviewPatchGeometry.sourcePoint(
                displayedX: displayed.x, displayedY: displayed.y, orientation: orientation
            )
            Self.expectClose(back.x, x, "\(orientation) x")
            Self.expectClose(back.y, y, "\(orientation) y")

            // And the other way round, which is not the same statement for a
            // mapping that is not its own inverse.
            let source = PreviewPatchGeometry.sourcePoint(
                displayedX: x, displayedY: y, orientation: orientation
            )
            let forward = PreviewPatchGeometry.displayedPoint(
                sourceX: source.x, sourceY: source.y, orientation: orientation
            )
            Self.expectClose(forward.x, x, "\(orientation) inverse x")
            Self.expectClose(forward.y, y, "\(orientation) inverse y")
        }
    }

    /// The four reflections are their own inverses; the two quarter turns are
    /// not. That is the pair a copy-and-paste error produces a merely-rotated
    /// picture from, so it is pinned rather than inferred.
    @Test("Only the reflections and the half turn are self-inverse")
    func selfInverseCases() {
        let selfInverse: [RAWImageOrientation] = [
            .upright, .mirroredHorizontally, .mirroredVertically,
            .rotated180, .transposed, .transverse,
        ]
        for orientation in RAWImageOrientation.allCases {
            let a = PreviewPatchGeometry.sourcePoint(
                displayedX: 0.2, displayedY: 0.7, orientation: orientation
            )
            let b = PreviewPatchGeometry.displayedPoint(
                sourceX: 0.2, sourceY: 0.7, orientation: orientation
            )
            let agrees = abs(a.x - b.x) < Self.tolerance && abs(a.y - b.y) < Self.tolerance
            #expect(agrees == selfInverse.contains(orientation), "\(orientation)")
        }
    }

    // MARK: - A click through a whole layout

    /// The property the picker depends on, stated end to end: a click at the
    /// centre of the picture is the centre of the sensor, whatever the
    /// orientation and whatever the letterboxing.
    @Test(
        "A click at the picture's centre is the sensor's centre",
        arguments: RAWImageOrientation.allCases
    )
    func aCentreClickIsTheSensorCentre(orientation: RAWImageOrientation) throws {
        let sourceWidth = 4056, sourceHeight = 3040
        let displayed = orientation.outputDimensions(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight
        )
        let fitted = try #require(
            PreviewPatchGeometry.fittedImage(
                pixelWidth: displayed.width, pixelHeight: displayed.height,
                inWidth: 1000, height: 900
            )
        )
        let point = try #require(
            PreviewPatchGeometry.sourcePoint(
                viewX: fitted.originX + fitted.width / 2,
                viewY: fitted.originY + fitted.height / 2,
                image: fitted,
                orientation: orientation
            )
        )
        Self.expectClose(point.x, 0.5, "\(orientation) x")
        Self.expectClose(point.y, 0.5, "\(orientation) y")
    }

    /// An upright picture, letterboxed, clicked a quarter of the way in.
    /// Worked out by hand so the test does not merely restate the code.
    @Test("A known click in a letterboxed upright picture lands where it should")
    func aKnownClickUpright() throws {
        // 400 x 300 picture in a 1200 x 600 area → 800 x 600 at x = 200.
        let fitted = try #require(
            PreviewPatchGeometry.fittedImage(
                pixelWidth: 400, pixelHeight: 300, inWidth: 1200, height: 600
            )
        )
        // A quarter across the picture, three quarters down.
        let point = try #require(
            PreviewPatchGeometry.sourcePoint(
                viewX: 200 + 200, viewY: 450, image: fitted, orientation: .upright
            )
        )
        Self.expectClose(point.x, 0.25, "x")
        Self.expectClose(point.y, 0.75, "y")
    }

    /// The same click, with the photograph displayed a quarter turn
    /// clockwise. A click a quarter across the *displayed* picture is
    /// three-quarters of the way **down** the sensor, and a click
    /// three-quarters down the displayed picture is three-quarters across it.
    @Test("A known click in a quarter-turned picture lands where it should")
    func aKnownClickRotated() throws {
        let fitted = FittedRect(originX: 0, originY: 0, width: 400, height: 800)
        let point = try #require(
            PreviewPatchGeometry.sourcePoint(
                viewX: 100, viewY: 600, image: fitted, orientation: .rotated90Clockwise
            )
        )
        // displayed (x, y) = (0.25, 0.75) → source (y, 1 − x) = (0.75, 0.75)
        Self.expectClose(point.x, 0.75, "x")
        Self.expectClose(point.y, 0.75, "y")
    }

    // MARK: - The overlay

    @Test("An upright overlay is the region, scaled into the picture")
    func anUprightOverlay() throws {
        let fitted = FittedRect(originX: 100, originY: 50, width: 800, height: 600)
        let region = try NormalizedActiveAreaRegion(
            originX: 0.25, originY: 0.5, width: 0.125, height: 0.25
        )
        let rect = PreviewPatchGeometry.displayedRect(
            for: region, image: fitted, orientation: .upright
        )
        Self.expectClose(rect.originX, 100 + 200, "originX")
        Self.expectClose(rect.originY, 50 + 300, "originY")
        Self.expectClose(rect.width, 100, "width")
        Self.expectClose(rect.height, 150, "height")
    }

    /// Whatever the orientation, the overlay stays inside the picture and
    /// keeps its area — orientation permutes pixels and scales nothing.
    @Test(
        "An overlay stays inside the picture under every orientation",
        arguments: RAWImageOrientation.allCases
    )
    func anOverlayStaysInside(orientation: RAWImageOrientation) throws {
        let fitted = FittedRect(originX: 10, originY: 20, width: 640, height: 480)
        let region = try NormalizedActiveAreaRegion(
            originX: 0.1, originY: 0.7, width: 0.2, height: 0.25
        )
        let rect = PreviewPatchGeometry.displayedRect(
            for: region, image: fitted, orientation: orientation
        )
        #expect(rect.originX >= fitted.originX - Self.tolerance)
        #expect(rect.originY >= fitted.originY - Self.tolerance)
        #expect(rect.maxX <= fitted.maxX + Self.tolerance)
        #expect(rect.maxY <= fitted.maxY + Self.tolerance)
        #expect(rect.width > 0)
        #expect(rect.height > 0)
    }

    /// The overlay is derived from the region and the layout every time, so
    /// scaling the layout scales the overlay exactly. That is what keeps it
    /// aligned across a window resize without anything handling the resize.
    @Test("Scaling the layout scales the overlay by the same factor")
    func theOverlayFollowsTheLayout() throws {
        let region = try NormalizedActiveAreaRegion(
            originX: 0.3, originY: 0.4, width: 0.1, height: 0.2
        )
        let small = FittedRect(originX: 0, originY: 0, width: 400, height: 300)
        let large = FittedRect(originX: 0, originY: 0, width: 800, height: 600)

        let a = PreviewPatchGeometry.displayedRect(
            for: region, image: small, orientation: .transverse
        )
        let b = PreviewPatchGeometry.displayedRect(
            for: region, image: large, orientation: .transverse
        )
        Self.expectClose(b.originX, a.originX * 2, "originX")
        Self.expectClose(b.originY, a.originY * 2, "originY")
        Self.expectClose(b.width, a.width * 2, "width")
        Self.expectClose(b.height, a.height * 2, "height")
    }

    /// The round trip that matters for the picker as a whole: pick a point,
    /// build a region from it, draw that region, and the marker is centred on
    /// the click.
    @Test(
        "A picked patch's overlay is centred on the click that made it",
        arguments: RAWImageOrientation.allCases
    )
    func theOverlayIsCentredOnTheClick(orientation: RAWImageOrientation) throws {
        let sourceWidth = 4056, sourceHeight = 3040
        let displayed = orientation.outputDimensions(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight
        )
        let fitted = try #require(
            PreviewPatchGeometry.fittedImage(
                pixelWidth: displayed.width, pixelHeight: displayed.height,
                inWidth: 1000, height: 900
            )
        )
        let clickX = fitted.originX + fitted.width * 0.4
        let clickY = fitted.originY + fitted.height * 0.65

        let point = try #require(
            PreviewPatchGeometry.sourcePoint(
                viewX: clickX, viewY: clickY, image: fitted, orientation: orientation
            )
        )
        let adjustment = UserWhiteBalanceAdjustment.neutralPatch(
            try UserWhiteBalanceAdjustment.pickedRegion(
                atX: point.x, y: point.y,
                activeAreaWidth: sourceWidth, activeAreaHeight: sourceHeight
            )
        )
        let rect = PreviewPatchGeometry.displayedRect(
            for: try adjustment.normalizedRegion(
                activeAreaWidth: sourceWidth, activeAreaHeight: sourceHeight
            ),
            image: fitted,
            orientation: orientation
        )

        // Within a view point: the patch is resolved to whole samples, and a
        // sample is well under a point at this scale.
        #expect(abs((rect.originX + rect.width / 2) - clickX) < 1)
        #expect(abs((rect.originY + rect.height / 2) - clickY) < 1)
    }
}
