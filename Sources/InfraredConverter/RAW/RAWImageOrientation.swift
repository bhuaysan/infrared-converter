import Foundation

/// How a file says its sensor geometry should be arranged for viewing: one of
/// the eight discrete orientations, owned by this application rather than by
/// the decoder.
///
/// ## Why this type exists
///
/// `RAWMetadata.Geometry.flip` is LibRaw's own integer. It is a dcraw-derived
/// **bitfield**, not an EXIF orientation code, and the two disagree for six of
/// the eight values — `flip 2` is EXIF 4 and `flip 3` is EXIF 3, which is
/// exactly the kind of near-miss that survives review. Letting that integer
/// travel through the pipeline would mean every stage that touched geometry
/// had to know a third-party library's private encoding. So the integer is
/// mapped once, here, into a named case, and nothing downstream ever sees it
/// again.
///
/// ## All eight, and reflections are not rotations
///
/// Four quarter-turns would be a lossy model. Four of the eight orientations
/// are **reflections** — they reverse handedness, and no rotation can produce
/// them. Collapsing `.transposed` onto `.rotated90Clockwise` mirrors the
/// photograph, which is both wrong and hard to notice on a symmetrical
/// subject. `isMirrored` is the fact that separates the two families, and it
/// is on the type rather than inferred by callers.
///
/// ```text
///                        EXIF   LibRaw flip   swaps dimensions   mirrored
/// upright                 1          0              no             no
/// mirroredHorizontally    2          1              no             yes
/// rotated180              3          3              no             no
/// mirroredVertically      4          2              no             yes
/// transposed              5          4              yes            yes
/// rotated90Clockwise      6          6              yes            no
/// transverse              7          7              yes            yes
/// rotated270Clockwise     8          5              yes            no
/// ```
///
/// ## Names are the display operation, not the stored layout
///
/// EXIF names its orientations after where the stored image's first row and
/// column *end up* ("right, top"). This type names the operation a viewer must
/// **perform** — `.rotated90Clockwise` means "turn the stored pixels a quarter
/// turn clockwise to view them". That is the direction the code actually
/// works in, and naming it the other way round is the single most common
/// orientation bug there is.
///
/// ## This is discrete geometry only
///
/// Eight permutations of whole pixels. Arbitrary-angle rotation, straightening,
/// crop and perspective correction are editing features and are **not** this
/// type; nothing here interpolates, resamples or invents a pixel. See
/// `docs/decisions/0009-application-owned-orientation.md`.
public enum RAWImageOrientation: Equatable, Sendable, CaseIterable {
    /// Stored as viewed. EXIF 1, LibRaw flip 0.
    case upright
    /// Mirror about the vertical axis: left and right exchange. EXIF 2,
    /// LibRaw flip 1.
    case mirroredHorizontally
    /// A half turn. EXIF 3, LibRaw flip 3.
    case rotated180
    /// Mirror about the horizontal axis: top and bottom exchange. EXIF 4,
    /// LibRaw flip 2.
    case mirroredVertically
    /// Reflect across the main diagonal — row and column exchange. EXIF 5,
    /// LibRaw flip 4. A reflection, **not** a rotation.
    case transposed
    /// A quarter turn clockwise. EXIF 6, LibRaw flip 6.
    case rotated90Clockwise
    /// Reflect across the anti-diagonal. EXIF 7, LibRaw flip 7. A reflection,
    /// **not** a rotation — and not the same operation as `.transposed`.
    case transverse
    /// A quarter turn counter-clockwise, named for the clockwise angle so one
    /// sense of rotation is used throughout. EXIF 8, LibRaw flip 5.
    case rotated270Clockwise

    /// The orientation a decoder's LibRaw-style `flip` bitfield names, or
    /// `nil` when the value is not one this application models.
    ///
    /// ## The mapping is LibRaw's own, read from its source
    ///
    /// LibRaw's `flip` is three independent bits, applied in this order to a
    /// **destination** coordinate to find its source (`LibRaw::flip_index`,
    /// `src/write/file_write.cpp`):
    ///
    /// ```text
    /// bit 2 (4)   swap row and column
    /// bit 1 (2)   row = sourceHeight - 1 - row
    /// bit 0 (1)   column = sourceWidth - 1 - column
    /// ```
    ///
    /// and its EXIF tag 274 reader is the string index
    /// `"50132467"[exif & 7]` (`src/metadata/tiff.cpp`), which is where the
    /// EXIF column of this type's table comes from. Both were read from the
    /// vendored 0.22.2 sources in this repository, not assumed.
    ///
    /// ## Why it is failable
    ///
    /// `flip` reaches the application as an `Int`, and LibRaw does not
    /// guarantee `0...7`: several format parsers assign it from a file field
    /// directly (`flip = get4()` in `src/metadata/ciff.cpp`, `flip = get2()`
    /// in `src/metadata/nikon.cpp`), and `identify()` normalises only exact
    /// 90/180/270-degree values into the bitfield. A file carrying anything
    /// else leaves a number here that means nothing to us.
    ///
    /// Returning `nil` is the whole policy: an unmodelled value is **not**
    /// silently read as upright, because "the file asked for something we do
    /// not understand" and "the file asked for nothing" are different facts
    /// and only one of them is safe to act on. Whoever asks decides what to
    /// do about it; this type refuses to guess.
    public init?(decoderFlip: Int) {
        switch decoderFlip {
        case 0: self = .upright
        case 1: self = .mirroredHorizontally
        case 2: self = .mirroredVertically
        case 3: self = .rotated180
        case 4: self = .transposed
        case 5: self = .rotated270Clockwise
        case 6: self = .rotated90Clockwise
        case 7: self = .transverse
        default: return nil
        }
    }

    /// The LibRaw-style `flip` bitfield this orientation corresponds to.
    ///
    /// Round-trips with `init?(decoderFlip:)` in both directions for all eight
    /// cases. Exposed for diagnostics and for tests that pin the mapping, not
    /// because any processing stage should reach for it.
    public var decoderFlip: Int {
        switch self {
        case .upright: return 0
        case .mirroredHorizontally: return 1
        case .mirroredVertically: return 2
        case .rotated180: return 3
        case .transposed: return 4
        case .rotated270Clockwise: return 5
        case .rotated90Clockwise: return 6
        case .transverse: return 7
        }
    }

    /// The orientation an EXIF/TIFF tag 274 value names, or `nil` outside
    /// `1...8`.
    ///
    /// Provided so the mapping can be stated and tested in the vocabulary the
    /// standard uses, and so a future decoder that reports EXIF codes directly
    /// needs no second translation table. `0` is rejected along with everything
    /// else out of range: it is "unspecified", which is not "upright".
    public init?(exifOrientation: Int) {
        switch exifOrientation {
        case 1: self = .upright
        case 2: self = .mirroredHorizontally
        case 3: self = .rotated180
        case 4: self = .mirroredVertically
        case 5: self = .transposed
        case 6: self = .rotated90Clockwise
        case 7: self = .transverse
        case 8: self = .rotated270Clockwise
        default: return nil
        }
    }

    /// The EXIF/TIFF tag 274 value this orientation corresponds to, `1...8`.
    public var exifOrientation: Int {
        switch self {
        case .upright: return 1
        case .mirroredHorizontally: return 2
        case .rotated180: return 3
        case .mirroredVertically: return 4
        case .transposed: return 5
        case .rotated90Clockwise: return 6
        case .transverse: return 7
        case .rotated270Clockwise: return 8
        }
    }

    /// Whether viewing exchanges width and height.
    ///
    /// True for exactly the four quarter-turn-family orientations, which are
    /// also exactly the four whose coordinate mapping transposes.
    public var swapsDimensions: Bool {
        switch self {
        case .upright, .mirroredHorizontally, .rotated180, .mirroredVertically:
            return false
        case .transposed, .rotated90Clockwise, .transverse, .rotated270Clockwise:
            return true
        }
    }

    /// Whether the orientation reverses handedness: a reflection, which no
    /// rotation can reproduce.
    ///
    /// The distinction this type exists to keep. A mirrored rendering of a
    /// photograph is wrong in a way that is invisible on a symmetrical subject
    /// and glaring on text, so the fact is named rather than left to be
    /// inferred from a case list.
    public var isMirrored: Bool {
        switch self {
        case .mirroredHorizontally, .mirroredVertically, .transposed, .transverse:
            return true
        case .upright, .rotated180, .rotated90Clockwise, .rotated270Clockwise:
            return false
        }
    }

    /// True only for `.upright`, where viewing requires no rearrangement at
    /// all.
    ///
    /// Not the same question as `swapsDimensions == false`: `.rotated180` and
    /// both mirrors keep the dimensions and still move every pixel.
    public var isIdentity: Bool { self == .upright }

    /// The dimensions a source of `width × height` has after orientation.
    ///
    /// The only thing that changes is whether the two are exchanged; neither
    /// is ever scaled, padded or cropped, so the pixel count is invariant.
    public func outputDimensions(
        sourceWidth: Int, sourceHeight: Int
    ) -> (width: Int, height: Int) {
        swapsDimensions
            ? (width: sourceHeight, height: sourceWidth)
            : (width: sourceWidth, height: sourceHeight)
    }

    /// The **source** coordinate a destination coordinate draws its pixel
    /// from.
    ///
    /// Written in this direction — destination asks, source answers — because
    /// that is the direction a gather loop runs: every destination pixel is
    /// written exactly once, from exactly one source, so no output can be
    /// missed or written twice by construction. The reverse direction (a
    /// scatter) would make both properties something to prove rather than
    /// something the loop shape guarantees.
    ///
    /// ```text
    ///   w = sourceWidth      h = sourceHeight
    ///   destination (r, c), 0 ≤ r < outputHeight, 0 ≤ c < outputWidth
    ///
    ///   upright                source(r,           c          )
    ///   mirroredHorizontally   source(r,           w − 1 − c  )
    ///   rotated180             source(h − 1 − r,   w − 1 − c  )
    ///   mirroredVertically     source(h − 1 − r,   c          )
    ///   transposed             source(c,           r          )
    ///   rotated90Clockwise     source(h − 1 − c,   r          )
    ///   transverse             source(h − 1 − c,   w − 1 − r  )
    ///   rotated270Clockwise    source(c,           w − 1 − r  )
    /// ```
    ///
    /// The four transposing cases take their destination row from a source
    /// *column* and vice versa, which is why they are the four that swap
    /// dimensions — and why the `w − 1` and `h − 1` terms attach to the
    /// opposite axis from the one a reader expects. That crossover is the
    /// single easiest thing to get wrong here, so the table above is written
    /// out rather than derived from a matrix.
    ///
    /// Pure arithmetic on the arguments: no bounds check, no clamping, no
    /// trapping. A destination coordinate inside the oriented geometry always
    /// yields a source coordinate inside the source geometry — `ImageOrienter`
    /// validates the geometry once, before any of this runs.
    public func sourceCoordinate(
        row: Int, column: Int, sourceWidth: Int, sourceHeight: Int
    ) -> (row: Int, column: Int) {
        let lastRow = sourceHeight - 1
        let lastColumn = sourceWidth - 1
        switch self {
        case .upright:
            return (row: row, column: column)
        case .mirroredHorizontally:
            return (row: row, column: lastColumn - column)
        case .rotated180:
            return (row: lastRow - row, column: lastColumn - column)
        case .mirroredVertically:
            return (row: lastRow - row, column: column)
        case .transposed:
            return (row: column, column: row)
        case .rotated90Clockwise:
            return (row: lastRow - column, column: row)
        case .transverse:
            return (row: lastRow - column, column: lastColumn - row)
        case .rotated270Clockwise:
            return (row: column, column: lastColumn - row)
        }
    }

    /// A short label for diagnostics, provenance reports and the inspector.
    public var diagnosticDescription: String {
        switch self {
        case .upright: return "upright (no rearrangement)"
        case .mirroredHorizontally: return "mirrored horizontally"
        case .rotated180: return "rotated 180°"
        case .mirroredVertically: return "mirrored vertically"
        case .transposed: return "transposed (reflected across the main diagonal)"
        case .rotated90Clockwise: return "rotated 90° clockwise"
        case .transverse: return "transverse (reflected across the anti-diagonal)"
        case .rotated270Clockwise: return "rotated 270° clockwise"
        }
    }
}

extension RAWMetadata.Geometry {
    /// The application-owned orientation this file asks for, or `nil` when the
    /// decoder reported a `flip` value this application does not model.
    ///
    /// ## `nil` means "unmodelled", and callers must not read it as upright
    ///
    /// See `RAWImageOrientation.init?(decoderFlip:)` for why an out-of-range
    /// value is reachable at all. A caller that needs an orientation and gets
    /// `nil` has to decide what to do — refuse, or proceed while recording
    /// that it proceeded without one. Substituting `.upright` would turn an
    /// unread file field into a silent claim about the photograph.
    ///
    /// ## What this cannot tell you
    ///
    /// Whether the file **recorded** an orientation at all. Two LibRaw
    /// behaviours combine to hide that: `src/metadata/tiff.cpp` maps EXIF `1`
    /// to `0` and then copies a value into `tiff_flip` only when it is
    /// non-zero, and `identify()` finishes by substituting `0` when nothing
    /// supplied one (`src/metadata/identify.cpp`). So "the file said upright"
    /// and "nothing in the file said anything" arrive here as the same number
    /// and are genuinely indistinguishable at this boundary. Answering the
    /// question needs the file's own bytes.
    ///
    /// That is not a defect in this property; it is a fact about the decoder,
    /// and it has a visible consequence: a photograph taken with the camera
    /// turned, by a body that recorded upright — or recorded nothing — is
    /// upright as far as every layer above this is concerned. Displaying it as
    /// captured is the correct response to the metadata. Correcting it is a
    /// user adjustment, kept separate from this value; see
    /// `UserOrientationAdjustment`.
    public var orientation: RAWImageOrientation? {
        RAWImageOrientation(decoderFlip: flip)
    }

    /// Whether `flip` is a value this application models.
    ///
    /// `orientation != nil`, named so a caller can ask the question without
    /// implying it wants the value.
    public var orientationIsRepresentable: Bool { orientation != nil }
}
