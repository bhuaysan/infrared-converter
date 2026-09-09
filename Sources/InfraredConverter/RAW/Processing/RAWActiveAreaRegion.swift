import Foundation

/// An axis-aligned integer rectangle in **active-image coordinates**.
///
/// ## Coordinate convention
///
/// Exactly the convention `LinearRAWMosaic` uses: `(0, 0)` is the top-left of
/// the active image area, rows increase downwards, columns increase to the
/// right, and no margin is added or subtracted anywhere. A region therefore
/// addresses the same samples as `LinearRAWMosaic.value(row:column:)` and the
/// same CFA phase as `SensorColorLayout.colorPlaneIndex(row:column:)`.
///
/// ## Why not `CGRect`
///
/// `CGRect` is floating-point and belongs to CoreGraphics. Sample selection is
/// integer sample counting: a rectangle of 63.5 samples has no meaning here,
/// and rounding one into existence at the processing boundary is exactly the
/// kind of silent reinterpretation this pipeline avoids. Keeping the type
/// application-owned and integer also keeps AppKit/CoreGraphics out of the
/// processing layer, so a future UI picker must convert *into* sample
/// coordinates deliberately rather than by accident.
///
/// ## Validation is explicit and never crops
///
/// `validate(inWidth:height:)` refuses a region that does not fit; it does
/// **not** clip one that hangs over an edge. A silently cropped region would
/// change which samples a measurement covers without saying so, and a caller
/// that wants clamping can compute it itself.
public struct RAWActiveAreaRegion: Equatable, Sendable {
    /// Row of the region's top edge, in active-image coordinates.
    public var originRow: Int
    /// Column of the region's left edge, in active-image coordinates.
    public var originColumn: Int
    /// Width in samples. Must be strictly positive.
    public var width: Int
    /// Height in samples. Must be strictly positive.
    public var height: Int

    public init(originRow: Int, originColumn: Int, width: Int, height: Int) {
        self.originRow = originRow
        self.originColumn = originColumn
        self.width = width
        self.height = height
    }

    /// One past the region's last row, or `nil` when the addition overflows.
    public var rowLimit: Int? {
        let (limit, overflow) = originRow.addingReportingOverflow(height)
        return overflow ? nil : limit
    }

    /// One past the region's last column, or `nil` when the addition
    /// overflows.
    public var columnLimit: Int? {
        let (limit, overflow) = originColumn.addingReportingOverflow(width)
        return overflow ? nil : limit
    }

    /// `width * height`, or `nil` when that multiplication overflows.
    public var sampleCount: Int? {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : count
    }

    /// Rejects a region that is not a usable selection inside a mosaic of the
    /// given dimensions.
    ///
    /// Refused, each with its own reason text:
    ///
    /// - a negative origin row or column,
    /// - a width or height that is zero or negative,
    /// - a far edge that overflows `Int`,
    /// - a far edge past the mosaic's right or bottom edge.
    ///
    /// Nothing is cropped, clamped or rounded on the way through.
    ///
    /// - Throws: `RAWProcessingError.invalidActiveAreaRegion`.
    public func validate(inWidth mosaicWidth: Int, height mosaicHeight: Int) throws {
        func fail(_ reason: String) -> RAWProcessingError {
            .invalidActiveAreaRegion(reason: reason)
        }

        guard originRow >= 0, originColumn >= 0 else {
            throw fail("""
                Region origin (row \(originRow), column \(originColumn)) is negative; \
                active-image coordinates start at (0, 0).
                """)
        }
        guard width > 0, height > 0 else {
            throw fail("""
                Region size \(width)x\(height) must be strictly positive in both \
                dimensions; an empty selection measures nothing.
                """)
        }
        guard let rowLimit, let columnLimit else {
            throw fail("""
                Region far edge overflows Int: origin (row \(originRow), \
                column \(originColumn)) plus size \(width)x\(height).
                """)
        }
        guard mosaicWidth > 0, mosaicHeight > 0 else {
            throw fail("""
                Mosaic dimensions \(mosaicWidth)x\(mosaicHeight) cannot contain any region.
                """)
        }
        guard columnLimit <= mosaicWidth, rowLimit <= mosaicHeight else {
            throw fail("""
                Region rows \(originRow)..<\(rowLimit), columns \
                \(originColumn)..<\(columnLimit) extends outside the \
                \(mosaicWidth)x\(mosaicHeight) active area. Regions are never \
                silently cropped.
                """)
        }
    }

    /// Rejects a region that does not fit inside `mosaic`'s active area.
    public func validate(in mosaic: LinearRAWMosaic) throws {
        try validate(inWidth: mosaic.width, height: mosaic.height)
    }
}
