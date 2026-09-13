import Foundation

/// Where a displayed preview actually is inside the area it was given, and how
/// to get from a point on it back to the sensor.
///
/// ```text
/// a click, in view points
///     ↓  fittedImage      undo the aspect-fit letterboxing
/// a unit point on the displayed image          (0…1, as viewed)
///     ↓  sourcePoint      undo the effective orientation
/// a unit point on the active image area        (0…1, in sensor axes)
///     ↓  UserWhiteBalanceAdjustment.pickedRegion
/// a NormalizedActiveAreaRegion                 ← what gets persisted
/// ```
///
/// and the same road travelled the other way, so the overlay that shows the
/// patch is drawn from the persisted region rather than from whatever the
/// click happened to be.
///
/// ## Why it is a separate, plain type
///
/// Because it is the correctness-critical half of a picker, and it must be
/// testable without a window. Nothing here imports SwiftUI, AppKit or
/// CoreGraphics: it is arithmetic on `Double`s, the eight orientations it
/// consults are the application's own, and every mapping in it can be checked
/// against a table of known points.
///
/// ## What it does not depend on, and why that matters
///
/// ```text
/// depends on     the displayed rectangle, the displayed pixel dimensions,
///                and the effective orientation
///
/// does NOT       the channel mix, the exposure, the display encoding, the
/// depend on      preview resolution policy, the window's scale factor
/// ```
///
/// The mix and the exposure change what the pixels look like and move none of
/// them, so a picker that consulted either would be reading appearance as
/// geometry. The preview's resolution does not appear either: normalised
/// coordinates are the same fractions of the same photograph at 2048 pixels
/// and at 512, which is the entire reason the persisted patch is normalised.
///
/// ## Coordinate conventions
///
/// View coordinates have their origin at the top left of the area the image
/// was laid out in, `y` increasing downwards — AppKit's flipped convention and
/// SwiftUI's default, and the same sense as the row/column order of every
/// image buffer here. Unit coordinates are fractions of the image, in the same
/// sense.
enum PreviewPatchGeometry {

    /// Where an image of the given pixel dimensions sits inside an area of the
    /// given size, when it is scaled to fit and centred.
    ///
    /// This is `.aspectRatio(contentMode: .fit)`, computed rather than
    /// observed. A view cannot ask SwiftUI where it put the picture, so the
    /// only way to map a click onto a pixel is to reproduce the rule — and to
    /// pin it with tests, since a view whose click mapping is a quarter of a
    /// letterbox out looks almost right.
    ///
    /// - Returns: the image's rectangle in view coordinates, or `nil` when the
    ///   question has no answer: a non-positive dimension anywhere.
    static func fittedImage(
        pixelWidth: Int,
        pixelHeight: Int,
        inWidth areaWidth: Double,
        height areaHeight: Double
    ) -> FittedRect? {
        guard pixelWidth > 0, pixelHeight > 0,
              areaWidth > 0, areaHeight > 0,
              areaWidth.isFinite, areaHeight.isFinite
        else { return nil }

        let scale = min(
            areaWidth / Double(pixelWidth), areaHeight / Double(pixelHeight)
        )
        let width = Double(pixelWidth) * scale
        let height = Double(pixelHeight) * scale
        return FittedRect(
            originX: (areaWidth - width) / 2,
            originY: (areaHeight - height) / 2,
            width: width,
            height: height
        )
    }

    /// Where a point in **active-area** (sensor) unit coordinates appears in
    /// **displayed** unit coordinates, after an orientation.
    ///
    /// The forward direction: source asks, destination answers. It is the
    /// continuous counterpart of
    /// `RAWImageOrientation.sourceCoordinate(row:column:sourceWidth:sourceHeight:)`,
    /// which runs the other way because a gather loop does.
    ///
    /// ```text
    ///   upright                (u,      v     )
    ///   mirroredHorizontally   (1 − u,  v     )
    ///   rotated180             (1 − u,  1 − v )
    ///   mirroredVertically     (u,      1 − v )
    ///   transposed             (v,      u     )
    ///   rotated90Clockwise     (1 − v,  u     )
    ///   transverse             (1 − v,  1 − u )
    ///   rotated270Clockwise    (v,      1 − u )
    /// ```
    ///
    /// The four transposing cases exchange the axes, which is why their
    /// `1 −` terms attach to the axis a reader does not expect. That crossover
    /// is the single easiest thing here to get wrong, so both directions are
    /// written out and both are tested against the pixel-level table.
    static func displayedPoint(
        sourceX x: Double, sourceY y: Double, orientation: RAWImageOrientation
    ) -> (x: Double, y: Double) {
        switch orientation {
        case .upright: return (x, y)
        case .mirroredHorizontally: return (1 - x, y)
        case .rotated180: return (1 - x, 1 - y)
        case .mirroredVertically: return (x, 1 - y)
        case .transposed: return (y, x)
        case .rotated90Clockwise: return (1 - y, x)
        case .transverse: return (1 - y, 1 - x)
        case .rotated270Clockwise: return (y, 1 - x)
        }
    }

    /// Where a point in **displayed** unit coordinates came from in
    /// **active-area** (sensor) unit coordinates.
    ///
    /// The inverse of `displayedPoint(sourceX:sourceY:orientation:)`, written
    /// out rather than derived, and tested as a round trip in both directions
    /// for all eight orientations.
    ///
    /// The four reflections are their own inverses; the two quarter turns
    /// invert to each other, which is the one place a copy-and-paste error
    /// produces a picture that is merely rotated the wrong way rather than
    /// obviously broken.
    static func sourcePoint(
        displayedX x: Double, displayedY y: Double, orientation: RAWImageOrientation
    ) -> (x: Double, y: Double) {
        switch orientation {
        case .upright: return (x, y)
        case .mirroredHorizontally: return (1 - x, y)
        case .rotated180: return (1 - x, 1 - y)
        case .mirroredVertically: return (x, 1 - y)
        case .transposed: return (y, x)
        case .rotated90Clockwise: return (y, 1 - x)
        case .transverse: return (1 - y, 1 - x)
        case .rotated270Clockwise: return (1 - y, x)
        }
    }

    /// The active-area point a click landed on, or `nil` when the click was
    /// not on the image.
    ///
    /// **Clicks outside the picture are refused, not clamped.** An aspect-fit
    /// layout letterboxes, sometimes generously, and treating a click in the
    /// margin as a click on the nearest edge would silently move a user's
    /// neutral patch to somewhere they did not point at.
    ///
    /// - Parameters:
    ///   - viewX: horizontal position of the click, in view points, relative
    ///     to the top-left of the area the image was laid out in.
    ///   - viewY: vertical position, likewise, increasing downwards.
    ///   - image: where the image actually is inside that area.
    ///   - orientation: the orientation the pixels were permuted by — the
    ///     file's own composed with the user's correction.
    /// - Returns: the point in active-area unit coordinates, in **sensor**
    ///   axes.
    static func sourcePoint(
        viewX: Double,
        viewY: Double,
        image: FittedRect,
        orientation: RAWImageOrientation
    ) -> (x: Double, y: Double)? {
        guard let displayed = image.unitPoint(viewX: viewX, viewY: viewY) else { return nil }
        return sourcePoint(
            displayedX: displayed.x, displayedY: displayed.y, orientation: orientation
        )
    }

    /// Where a persisted neutral patch appears on the displayed image, in view
    /// coordinates.
    ///
    /// The overlay's whole geometry, and the reason it stays aligned when the
    /// window is resized, when the photograph is rotated, and when the preview
    /// resolution changes: it is derived from the canonical region and the
    /// current layout every time, and no view coordinate is ever stored.
    ///
    /// The region's two corners are mapped and then re-ordered, because four
    /// of the eight orientations exchange the axes and two more reverse one of
    /// them — so the mapped "origin" is not always the top-left corner of the
    /// result.
    static func displayedRect(
        for region: NormalizedActiveAreaRegion,
        image: FittedRect,
        orientation: RAWImageOrientation
    ) -> FittedRect {
        let a = displayedPoint(
            sourceX: region.originX, sourceY: region.originY, orientation: orientation
        )
        let b = displayedPoint(
            sourceX: region.originX + region.width,
            sourceY: region.originY + region.height,
            orientation: orientation
        )
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        return FittedRect(
            originX: image.originX + minX * image.width,
            originY: image.originY + minY * image.height,
            width: (maxX - minX) * image.width,
            height: (maxY - minY) * image.height
        )
    }
}

/// An axis-aligned rectangle in view points, with its origin at the top left.
///
/// Deliberately not `CGRect`: this type is used by the geometry above, which
/// is plain arithmetic that a test must be able to exercise without importing
/// a graphics framework. The one view that draws it converts at the edge.
struct FittedRect: Equatable, Sendable {
    let originX: Double
    let originY: Double
    let width: Double
    let height: Double

    init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    var maxX: Double { originX + width }
    var maxY: Double { originY + height }

    /// Whether a point in view coordinates is inside this rectangle. Edges
    /// count as inside.
    func contains(viewX: Double, viewY: Double) -> Bool {
        viewX >= originX && viewX <= maxX && viewY >= originY && viewY <= maxY
    }

    /// A point in view coordinates as a fraction of this rectangle, or `nil`
    /// when it is outside it.
    ///
    /// The result is clamped to `0...1` **after** the containment test, which
    /// is not a contradiction: the test decides whether the point counts at
    /// all, and the clamp only removes the floating-point overshoot a point
    /// exactly on an edge can produce.
    func unitPoint(viewX: Double, viewY: Double) -> (x: Double, y: Double)? {
        guard width > 0, height > 0, viewX.isFinite, viewY.isFinite else { return nil }
        guard contains(viewX: viewX, viewY: viewY) else { return nil }
        return (
            x: min(1, max(0, (viewX - originX) / width)),
            y: min(1, max(0, (viewY - originY) / height))
        )
    }
}
