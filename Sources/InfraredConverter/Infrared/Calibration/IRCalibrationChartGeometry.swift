import Foundation

/// A point in normalised active-area coordinates.
///
/// `(0, 0)` is the top-left of the active area and `(1, 1)` the bottom-right,
/// in the **unoriented** sensor's own frame — the same coordinate system a
/// photograph's neutral patch is stored in
/// (``NormalizedActiveAreaRegion``). Resolution-independent, so a chart
/// outline marked once stays correct whatever the active area's pixel
/// dimensions turn out to be.
public struct IRCalibrationChartPoint: Equatable, Sendable {

    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws(IRCalibrationError) {
        for (name, value) in [("x", x), ("y", y)] {
            guard value.isFinite else {
                throw .nonFiniteValue(field: "chartCorner.\(name)", value: value)
            }
            guard (0...1).contains(value) else {
                throw .invalidChartGeometry(
                    reason: """
                        A chart corner at \(name) = \(value) is outside the active area. \
                        Corners are normalised active-area coordinates in 0...1, and a chart \
                        partly off the sensor cannot be sampled.
                        """
                )
            }
        }
        self.x = x
        self.y = y
    }
}

/// Where a calibration target is in the frame, and therefore where each of its
/// patches is.
///
/// ```text
/// topLeft ─────────────── topRight
///    │  ▢ ▢ ▢ ▢ ▢ ▢          │
///    │  ▢ ▢ ▢ ▢ ▢ ▢          │
///    │  ▢ ▢ ▢ ▢ ▢ ▢          │
///    │  ▢ ▢ ▢ ▢ ▢ ▢          │
/// bottomLeft ─────────── bottomRight
/// ```
///
/// ## Manual registration, deliberately
///
/// Somebody marks the four corners of the patch array; the known grid does the
/// rest. There is **no automatic chart detection** here — no corner finder, no
/// pattern matcher, no computer vision of any kind. A detector that is right
/// 95% of the time is worse than useless for calibration: the 5% produces a
/// measurement set that looks perfectly ordinary and is sampled from the wrong
/// squares, and nothing downstream can tell.
///
/// ## Bilinear, and what that costs
///
/// The unit square is mapped onto the quadrilateral bilinearly:
///
/// ```text
/// P(u,v) = (1−u)(1−v)·TL + u(1−v)·TR + uv·BR + (1−u)v·BL
/// ```
///
/// Exact for any affine arrangement — a chart that is translated, scaled,
/// stretched or sheared in the frame. It is **not** a projective correction, so
/// a chart photographed at an angle steep enough for real perspective is
/// approximated rather than solved, and the error grows towards the middle of
/// the array.
///
/// That is a deliberate trade. A homography needs an 8x8 solve and a second
/// numerical path to get right, and the protocol's answer is far simpler and
/// better anyway: photograph the chart square-on, which a calibration session
/// can always arrange and which removes several other problems at the same
/// time. See `docs/calibration-protocol.md`.
///
/// ## Sampling the middle
///
/// Only the central fraction of each patch is sampled, so that the mapping's
/// approximation, the chart's printed borders, and any light falling off at a
/// patch edge all stay outside the measured region.
public struct IRCalibrationChartGeometry: Equatable, Sendable {

    public let target: IRCalibrationTarget
    public let topLeft: IRCalibrationChartPoint
    public let topRight: IRCalibrationChartPoint
    public let bottomRight: IRCalibrationChartPoint
    public let bottomLeft: IRCalibrationChartPoint

    /// The fraction of each patch cell's width and height that is sampled,
    /// centred.
    ///
    /// `0.5` by default — a quarter of each patch's area, taken from the
    /// middle. Generous enough that a patch is averaged over many thousands of
    /// samples on a twelve-megapixel sensor, and far enough from the edges that
    /// neither the printed gap between patches nor a few degrees of
    /// misregistration reaches the measurement.
    public let patchSampleFraction: Double

    public static let defaultPatchSampleFraction = 0.5

    /// The smallest patch region that can contain whole CFA cells.
    public static let minimumPatchExtent = 2

    public init(
        target: IRCalibrationTarget,
        topLeft: IRCalibrationChartPoint,
        topRight: IRCalibrationChartPoint,
        bottomRight: IRCalibrationChartPoint,
        bottomLeft: IRCalibrationChartPoint,
        patchSampleFraction: Double = IRCalibrationChartGeometry.defaultPatchSampleFraction
    ) throws(IRCalibrationError) {
        guard patchSampleFraction.isFinite else {
            throw .nonFiniteValue(
                field: "patchSampleFraction", value: patchSampleFraction
            )
        }
        guard patchSampleFraction > 0, patchSampleFraction <= 1 else {
            throw .invalidChartGeometry(
                reason: """
                    A patch sample fraction of \(patchSampleFraction) is not usable; it is the \
                    centred fraction of each patch that is measured, and must be greater than \
                    0 and at most 1.
                    """
            )
        }

        // A quadrilateral with zero area, or one whose corners were given in
        // the wrong order, produces patch regions that overlap or invert. The
        // signed area catches both: it is zero for the degenerate case and
        // negative when the corners wind the other way.
        let area = Self.signedArea(topLeft, topRight, bottomRight, bottomLeft)
        guard area > 0 else {
            throw .invalidChartGeometry(
                reason: """
                    The four corners enclose a signed area of \(area). They must be given \
                    clockwise from the top left as the image is stored — top left, top right, \
                    bottom right, bottom left — and must enclose a real area. A zero or \
                    negative one means two corners coincide, or they were given in the wrong \
                    order, and the patch grid derived from them would be inverted or empty.
                    """
            )
        }

        self.target = target
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
        self.patchSampleFraction = patchSampleFraction
    }

    /// A chart filling an axis-aligned rectangle of the frame.
    ///
    /// The common case, and the one a test constructs.
    public static func rectangular(
        target: IRCalibrationTarget,
        originX: Double,
        originY: Double,
        width: Double,
        height: Double,
        patchSampleFraction: Double = IRCalibrationChartGeometry.defaultPatchSampleFraction
    ) throws(IRCalibrationError) -> IRCalibrationChartGeometry {
        try IRCalibrationChartGeometry(
            target: target,
            topLeft: try IRCalibrationChartPoint(x: originX, y: originY),
            topRight: try IRCalibrationChartPoint(x: originX + width, y: originY),
            bottomRight: try IRCalibrationChartPoint(
                x: originX + width, y: originY + height
            ),
            bottomLeft: try IRCalibrationChartPoint(x: originX, y: originY + height),
            patchSampleFraction: patchSampleFraction
        )
    }

    /// The point of the chart at normalised grid coordinates `(u, v)`.
    public func point(u: Double, v: Double) -> (x: Double, y: Double) {
        let a = (1 - u) * (1 - v)
        let b = u * (1 - v)
        let c = u * v
        let d = (1 - u) * v
        return (
            x: a * topLeft.x + b * topRight.x + c * bottomRight.x + d * bottomLeft.x,
            y: a * topLeft.y + b * topRight.y + c * bottomRight.y + d * bottomLeft.y
        )
    }

    /// The sampling region of every patch, in active-area pixels.
    ///
    /// Regions are axis-aligned and snapped to even origins and even extents,
    /// so each contains whole 2x2 CFA cells and therefore equal numbers of
    /// every colour plane. A region that straddled half a cell would measure
    /// one green phase more often than the other, which is precisely the
    /// alignment artefact the green-channel policy exists to be independent of.
    ///
    /// For a rotated chart the axis-aligned rectangle is taken *inside* the
    /// mapped cell — the intersection of the mapped corners' extents — so the
    /// measured area never reaches into a neighbouring patch. It shrinks as the
    /// rotation grows, and at a large enough angle it vanishes, which is
    /// reported rather than silently sampled from somewhere approximate.
    public func patchRegions(
        activeAreaWidth: Int, activeAreaHeight: Int
    ) throws(IRCalibrationError) -> [(patch: IRCalibrationTargetPatchID, region: RAWActiveAreaRegion)] {
        guard activeAreaWidth >= Self.minimumPatchExtent,
              activeAreaHeight >= Self.minimumPatchExtent
        else {
            throw .invalidChartGeometry(
                reason: """
                    An active area of \(activeAreaWidth)x\(activeAreaHeight) cannot contain \
                    patch regions of at least \(Self.minimumPatchExtent)x\
                    \(Self.minimumPatchExtent).
                    """
            )
        }

        let rows = target.rows
        let columns = target.columns
        let halfU = patchSampleFraction / (2 * Double(columns))
        let halfV = patchSampleFraction / (2 * Double(rows))

        var result: [(patch: IRCalibrationTargetPatchID, region: RAWActiveAreaRegion)] = []
        result.reserveCapacity(target.patchCount)

        for (index, patch) in target.patchIDs.enumerated() {
            let row = index / columns
            let column = index % columns
            let centerU = (Double(column) + 0.5) / Double(columns)
            let centerV = (Double(row) + 0.5) / Double(rows)

            let corners = [
                point(u: centerU - halfU, v: centerV - halfV),
                point(u: centerU + halfU, v: centerV - halfV),
                point(u: centerU + halfU, v: centerV + halfV),
                point(u: centerU - halfU, v: centerV + halfV),
            ]

            // The inscribed axis-aligned rectangle: right of every left-hand
            // corner, left of every right-hand one, and likewise vertically.
            let left = max(corners[0].x, corners[3].x)
            let right = min(corners[1].x, corners[2].x)
            let top = max(corners[0].y, corners[1].y)
            let bottom = min(corners[2].y, corners[3].y)

            let region = try Self.region(
                left: left, top: top, right: right, bottom: bottom,
                activeAreaWidth: activeAreaWidth,
                activeAreaHeight: activeAreaHeight,
                patch: patch
            )
            result.append((patch: patch, region: region))
        }

        return result
    }

    private static func region(
        left: Double, top: Double, right: Double, bottom: Double,
        activeAreaWidth: Int, activeAreaHeight: Int,
        patch: IRCalibrationTargetPatchID
    ) throws(IRCalibrationError) -> RAWActiveAreaRegion {
        func refuse(_ reason: String) -> IRCalibrationError {
            .invalidChartGeometry(reason: reason)
        }

        for (name, value) in [("left", left), ("top", top), ("right", right), ("bottom", bottom)]
        where !value.isFinite {
            throw refuse("Patch \"\(patch)\" mapped to a non-finite \(name) edge (\(value)).")
        }

        // Even origins and even extents, so the region covers whole CFA cells.
        let originColumn = Int((left * Double(activeAreaWidth)).rounded(.down)) & ~1
        let originRow = Int((top * Double(activeAreaHeight)).rounded(.down)) & ~1
        let farColumn = Int((right * Double(activeAreaWidth)).rounded(.down))
        let farRow = Int((bottom * Double(activeAreaHeight)).rounded(.down))

        let width = max(0, min(farColumn, activeAreaWidth) - originColumn) & ~1
        let height = max(0, min(farRow, activeAreaHeight) - originRow) & ~1

        guard originColumn >= 0, originRow >= 0 else {
            throw refuse("Patch \"\(patch)\" mapped outside the active area.")
        }
        guard width >= minimumPatchExtent, height >= minimumPatchExtent else {
            throw refuse("""
                Patch "\(patch)" maps to a \(width)x\(height) region, and at least \
                \(minimumPatchExtent)x\(minimumPatchExtent) is needed to contain whole CFA \
                cells. The chart is too small in the frame, the sampled fraction of each \
                patch is too low, or the outline is rotated far enough that no axis-aligned \
                rectangle fits inside a patch.
                """)
        }
        guard originColumn + width <= activeAreaWidth,
              originRow + height <= activeAreaHeight
        else {
            throw refuse("""
                Patch "\(patch)" maps to rows \(originRow)..<\(originRow + height), columns \
                \(originColumn)..<\(originColumn + width), which extends outside the \
                \(activeAreaWidth)x\(activeAreaHeight) active area.
                """)
        }

        return RAWActiveAreaRegion(
            originRow: originRow,
            originColumn: originColumn,
            width: width,
            height: height
        )
    }

    /// Twice the signed area of the quadrilateral, by the shoelace formula.
    ///
    /// Positive when the corners wind clockwise in image coordinates, where `y`
    /// increases downwards.
    private static func signedArea(
        _ a: IRCalibrationChartPoint,
        _ b: IRCalibrationChartPoint,
        _ c: IRCalibrationChartPoint,
        _ d: IRCalibrationChartPoint
    ) -> Double {
        (a.x * b.y - b.x * a.y)
            + (b.x * c.y - c.x * b.y)
            + (c.x * d.y - d.x * c.y)
            + (d.x * a.y - a.x * d.y)
    }

    public var diagnosticDescription: String {
        String(
            format: """
                %@ outlined at (%.4f, %.4f) (%.4f, %.4f) (%.4f, %.4f) (%.4f, %.4f), \
                sampling the central %.0f%% of each patch, bilinear (not projective)
                """,
            target.displayName,
            topLeft.x, topLeft.y, topRight.x, topRight.y,
            bottomRight.x, bottomRight.y, bottomLeft.x, bottomLeft.y,
            patchSampleFraction * 100
        )
    }
}
