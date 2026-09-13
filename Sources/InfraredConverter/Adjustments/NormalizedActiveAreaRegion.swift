import Foundation

/// A rectangle inside the RAW active image area, expressed as fractions of
/// that area rather than as pixels.
///
/// ```text
/// (0, 0)                         (1, 0)
///    ┌──────────────────────────────┐
///    │        active image area     │
///    │     ┌───────────┐            │
///    │     │  region   │            │
///    │     └───────────┘            │
///    └──────────────────────────────┘
/// (0, 1)                         (1, 1)
/// ```
///
/// ## Why fractions, and not pixels
///
/// This is a **persisted editing decision**, and the four things it has to
/// survive are the four things pixel coordinates do not:
///
/// ```text
/// the preview reduction   the workspace edits a 2048-pixel rendition of a
///                         4056-pixel photograph; a region recorded in preview
///                         pixels would mean something different at another
///                         preview size
/// orientation             the displayed image may be a quarter turn away from
///                         the sensor's own layout, and the user's correction
///                         can change that at any time
/// the display             a click lands in view points inside an aspect-fitted
///                         rectangle, which is neither of the above
/// the export              which runs at the sensor's own resolution, from the
///                         file, with no preview anywhere
/// ```
///
/// All four are resolutions of the *same* rectangle of the *same* photograph.
/// Recording the fraction of the active area, in the sensor's own
/// (pre-orientation) axes, is the one description every stage can convert
/// into its own coordinates — and the conversion has exactly one home,
/// `UserWhiteBalanceAdjustment.resolvedRegion(activeAreaWidth:height:)`.
///
/// Integer active-area pixels would work too, and would be exact rather than
/// rounded. They were not chosen because they silently assume that every
/// decode of one file reports the same active area: a LibRaw upgrade that
/// changes a crop by two rows would move every saved patch by two rows and
/// nothing would say so. A fraction describes the same part of the picture
/// either way.
///
/// ## The axes
///
/// `x` runs left to right and `y` runs top to bottom, matching
/// `RAWActiveAreaRegion`'s row/column convention and
/// `LinearRAWMosaic`'s sample order. They are **sensor** axes: the orientation
/// stage has not run, and nothing here knows which way up the photograph is
/// displayed.
///
/// ## Validation refuses; it never clamps
///
/// A persisted region that is not inside the unit square is an error, for the
/// same reason an unreadable orientation token is: a clamped region measures
/// different samples from the ones the record describes, and nothing on screen
/// would say so. See `docs/decisions/0019-interactive-white-balance.md`.
public struct NormalizedActiveAreaRegion: Equatable, Sendable {

    /// Left edge, as a fraction of the active area's width. `0...1`.
    public let originX: Double
    /// Top edge, as a fraction of the active area's height. `0...1`.
    public let originY: Double
    /// Width, as a fraction of the active area's width. Strictly positive.
    public let width: Double
    /// Height, as a fraction of the active area's height. Strictly positive.
    public let height: Double

    /// Builds a region, refusing anything that is not a rectangle inside the
    /// unit square.
    ///
    /// - Throws: `ImageAdjustmentError.nonFiniteNeutralPatchCoordinate` for a
    ///   NaN or an infinity, `.emptyNeutralPatch` for a non-positive extent,
    ///   and `.neutralPatchOutsideActiveArea` for a rectangle that starts
    ///   before the area or ends past it.
    public init(originX: Double, originY: Double, width: Double, height: Double) throws {
        for (name, value) in [
            ("originX", originX), ("originY", originY),
            ("width", width), ("height", height),
        ] where !value.isFinite {
            throw ImageAdjustmentError.nonFiniteNeutralPatchCoordinate(
                field: name, value: value
            )
        }
        guard width > 0, height > 0 else {
            throw ImageAdjustmentError.emptyNeutralPatch(width: width, height: height)
        }
        guard originX >= 0, originY >= 0,
              originX + width <= 1, originY + height <= 1
        else {
            throw ImageAdjustmentError.neutralPatchOutsideActiveArea(
                originX: originX, originY: originY, width: width, height: height
            )
        }
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    /// The whole active area.
    ///
    /// Not a default for anything: it exists so that the widest legal region
    /// has a name, and so tests have a boundary case that is inside the unit
    /// square by exactly zero margin.
    public static let full = NormalizedActiveAreaRegion(validatedUnitSquare: ())

    private init(validatedUnitSquare: ()) {
        self.originX = 0
        self.originY = 0
        self.width = 1
        self.height = 1
    }

    /// A region of the given size centred on a point, **shifted** — never
    /// shrunk — to stay inside the active area.
    ///
    /// The shift is what a picker needs: clicking near an edge should measure
    /// the same amount of the photograph as clicking in the middle, not a
    /// sliver of it. A region larger than the area cannot be shifted into it
    /// and is refused by `init` rather than trimmed.
    ///
    /// - Parameters:
    ///   - x: horizontal centre, as a fraction of the active area's width.
    ///   - y: vertical centre, as a fraction of its height.
    ///   - width: the region's width, as a fraction of the area's width.
    ///   - height: the region's height, as a fraction of its height.
    /// - Throws: `ImageAdjustmentError`, as `init` does.
    public static func centered(
        atX x: Double, y: Double, width: Double, height: Double
    ) throws -> NormalizedActiveAreaRegion {
        for (name, value) in [("centerX", x), ("centerY", y)] where !value.isFinite {
            throw ImageAdjustmentError.nonFiniteNeutralPatchCoordinate(
                field: name, value: value
            )
        }
        guard width > 0, height > 0 else {
            throw ImageAdjustmentError.emptyNeutralPatch(width: width, height: height)
        }
        // `min(max(...))` rather than a clamp on the centre, so that the
        // extent is preserved exactly and only the origin moves.
        let originX = width <= 1 ? min(max(0, x - width / 2), 1 - width) : x - width / 2
        let originY = height <= 1 ? min(max(0, y - height / 2), 1 - height) : y - height / 2
        return try NormalizedActiveAreaRegion(
            originX: originX, originY: originY, width: width, height: height
        )
    }

    /// The horizontal centre, as a fraction of the active area's width.
    public var centerX: Double { originX + width / 2 }
    /// The vertical centre, as a fraction of its height.
    public var centerY: Double { originY + height / 2 }

    /// One line for a control, an inspector or a log.
    public var diagnosticDescription: String {
        String(
            format: "%.4f, %.4f, %.4f × %.4f of the active area",
            originX, originY, width, height
        )
    }
}

// MARK: - Persistence

/// ## The wire format
///
/// A keyed object of four JSON numbers, each a fraction of the active image
/// area:
///
/// ```json
/// {
///   "originX" : 0.4766,
///   "originY" : 0.4688,
///   "width"   : 0.0468,
///   "height"  : 0.0625
/// }
/// ```
///
/// No unit field, and no pixel dimensions beside it. The unit is the active
/// area itself and it is in the type's name; a `"unit" : "fraction"` field
/// would be a second place for the same fact to be wrong, and recorded pixel
/// dimensions would invite a reader to trust them over the file's own decode.
///
/// Every field is required. An absent one is refused rather than defaulted,
/// because there is no value a missing origin or extent could mean: the four
/// numbers together are the rectangle.
extension NormalizedActiveAreaRegion: Codable {
    private enum CodingKeys: String, CodingKey {
        case originX
        case originY
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func require(_ key: CodingKeys) throws -> Double {
            guard let value = try container.decodeIfPresent(Double.self, forKey: key) else {
                throw ImageAdjustmentError.missingNeutralPatchField(field: key.stringValue)
            }
            return value
        }

        try self.init(
            originX: require(.originX),
            originY: require(.originY),
            width: require(.width),
            height: require(.height)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originX, forKey: .originX)
        try container.encode(originY, forKey: .originY)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}
