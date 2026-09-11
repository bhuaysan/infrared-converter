import Foundation

/// A correction the **user** asked for, on top of whatever the file recorded.
///
/// ```text
/// recorded / decoder orientation      an immutable fact about the input
///                +
/// user orientation adjustment         ← this type: an editing decision
///                =
/// effective orientation               what the pixels are actually permuted by
/// ```
///
/// ## Why this is not `RAWImageOrientation`
///
/// It holds one, and it is deliberately a different type all the same. The two
/// answer different questions, and a signature that accepts either would let
/// them be confused exactly once, quietly, in the direction that matters:
/// writing a user's rotation back into metadata would make an editing decision
/// look like something the camera said. `RAWMetadata.Geometry.orientation`
/// never changes when a user rotates the image — nothing here can change it.
///
/// The **algebra** is shared, because there is only one algebra: both are
/// elements of the same eight-element group, and duplicating
/// `RAWImageOrientation`'s composition would give two implementations to keep
/// in agreement. So the group element is wrapped, not re-derived.
///
/// ## It is a state, not a history
///
/// Every operation returns the **canonical single orientation** that the whole
/// sequence of presses adds up to, because the eight are closed under
/// composition. Four rotate-rights persist as `.identity`, not as four
/// commands:
///
/// ```swift
/// UserOrientationAdjustment.identity
///     .rotatedRight().rotatedRight().rotatedRight().rotatedRight()
///     == .identity                                        // true
/// ```
///
/// There is no command log, no undo stack and no accumulation of pixel
/// transforms — the image is always permuted exactly once, from the
/// unoriented source, by the single effective orientation.
///
/// ## Reset means identity, not upright
///
/// `.identity` means "the user asked for no correction". It does **not** mean
/// the displayed image is upright: a file that records a rotation still gets
/// that rotation. See `EffectiveImageOrientation`.
public struct UserOrientationAdjustment: Equatable, Sendable {

    /// The symmetry this adjustment applies, expressed in the same
    /// eight-element algebra the file's own orientation uses — and still a
    /// different fact from it.
    public let transform: RAWImageOrientation

    public init(transform: RAWImageOrientation) {
        self.transform = transform
    }

    // MARK: - The eight canonical states

    /// No user correction. The image is arranged exactly as its metadata asks.
    public static let identity = UserOrientationAdjustment(transform: .upright)
    /// A quarter turn clockwise on top of the recorded orientation.
    public static let quarterTurnRight = UserOrientationAdjustment(
        transform: .rotated90Clockwise
    )
    /// A quarter turn counter-clockwise on top of the recorded orientation.
    public static let quarterTurnLeft = UserOrientationAdjustment(
        transform: .rotated270Clockwise
    )
    /// A half turn.
    public static let halfTurn = UserOrientationAdjustment(transform: .rotated180)
    /// Left and right exchanged.
    public static let horizontalFlip = UserOrientationAdjustment(
        transform: .mirroredHorizontally
    )
    /// Top and bottom exchanged.
    public static let verticalFlip = UserOrientationAdjustment(
        transform: .mirroredVertically
    )
    /// Reflected across the main diagonal. Not reachable from a single UI
    /// control, and reachable by combining two — a flip and a quarter turn.
    public static let diagonalFlip = UserOrientationAdjustment(transform: .transposed)
    /// Reflected across the anti-diagonal. Also a combination, and **not** the
    /// same operation as `diagonalFlip`.
    public static let antiDiagonalFlip = UserOrientationAdjustment(transform: .transverse)

    /// All eight canonical states, for exhaustive tests and round-trips.
    public static let allCases: [UserOrientationAdjustment] =
        RAWImageOrientation.allCases.map(UserOrientationAdjustment.init(transform:))

    // MARK: - What the user pressed

    /// This adjustment followed by a quarter turn clockwise, canonicalised.
    public func rotatedRight() -> UserOrientationAdjustment {
        applying(.rotated90Clockwise)
    }

    /// This adjustment followed by a quarter turn counter-clockwise,
    /// canonicalised.
    public func rotatedLeft() -> UserOrientationAdjustment {
        applying(.rotated270Clockwise)
    }

    /// This adjustment followed by a half turn, canonicalised.
    public func rotatedHalfTurn() -> UserOrientationAdjustment {
        applying(.rotated180)
    }

    /// This adjustment followed by a horizontal flip, canonicalised.
    ///
    /// Note that this flips the image **as the user currently sees it**, which
    /// is why it composes onto the existing adjustment rather than replacing
    /// it.
    public func flippedHorizontally() -> UserOrientationAdjustment {
        applying(.mirroredHorizontally)
    }

    /// This adjustment followed by a vertical flip, canonicalised.
    public func flippedVertically() -> UserOrientationAdjustment {
        applying(.mirroredVertically)
    }

    /// The one operation that does not compose: it discards the user's
    /// correction entirely and returns to what the file asks for.
    ///
    /// Reset is `.identity`. It is emphatically **not** "make the image
    /// upright": on a file whose metadata records a rotation, resetting
    /// restores that rotation.
    public static let reset = identity

    /// This adjustment followed by `next`, reduced to the single canonical
    /// state the pair adds up to.
    ///
    /// `RAWImageOrientation.composed(with:)`'s convention — receiver first,
    /// argument second — is what makes this read the way a user experiences
    /// it: the correction already in force, and then the button just pressed.
    public func applying(_ next: RAWImageOrientation) -> UserOrientationAdjustment {
        UserOrientationAdjustment(transform: transform.composed(with: next))
    }

    /// This adjustment followed by another, reduced to one canonical state.
    public func applying(_ next: UserOrientationAdjustment) -> UserOrientationAdjustment {
        applying(next.transform)
    }

    // MARK: - Facts about the adjustment

    /// Whether the user has asked for no correction at all.
    public var isIdentity: Bool { transform.isIdentity }
    /// Whether the correction exchanges the displayed width and height.
    public var swapsDimensions: Bool { transform.swapsDimensions }
    /// Whether the correction reverses handedness — a reflection, which no
    /// rotation can reproduce.
    public var isMirrored: Bool { transform.isMirrored }

    /// The adjustment that undoes this one.
    public var inverse: UserOrientationAdjustment {
        UserOrientationAdjustment(transform: transform.inverse)
    }

    /// A short label for diagnostics, provenance and the inspector, worded
    /// from the user's point of view rather than the file's.
    public var diagnosticDescription: String {
        switch transform {
        case .upright: return "none (the file's own orientation)"
        case .rotated90Clockwise: return "rotated 90° right"
        case .rotated270Clockwise: return "rotated 90° left"
        case .rotated180: return "rotated 180°"
        case .mirroredHorizontally: return "flipped horizontally"
        case .mirroredVertically: return "flipped vertically"
        case .transposed: return "flipped across the main diagonal"
        case .transverse: return "flipped across the anti-diagonal"
        }
    }
}

// MARK: - Persistence

extension UserOrientationAdjustment: Codable {

    /// The stable, semantic token this adjustment persists as.
    ///
    /// Deliberately **not** a case index, an `allCases` position, a LibRaw
    /// `flip` bitfield or an EXIF code:
    ///
    /// - an index breaks the moment a case is reordered or inserted, and
    ///   breaks *silently*, by reading as a different valid orientation;
    /// - `flip` is a third-party library's private encoding, and persisting
    ///   it would tie saved user edits to a decoder we may replace;
    /// - an EXIF code describes what a **file** recorded, which is the one
    ///   thing this type is defined not to be.
    ///
    /// These strings are a wire format. Changing one is a breaking change to
    /// every persisted adjustment and needs a schema version, not an edit.
    public var persistedToken: String {
        switch transform {
        case .upright: return "none"
        case .rotated90Clockwise: return "rotate90Clockwise"
        case .rotated180: return "rotate180"
        case .rotated270Clockwise: return "rotate270Clockwise"
        case .mirroredHorizontally: return "flipHorizontal"
        case .mirroredVertically: return "flipVertical"
        case .transposed: return "transposeMainDiagonal"
        case .transverse: return "transposeAntiDiagonal"
        }
    }

    /// The adjustment a persisted token names, or `nil` when this version does
    /// not model it.
    ///
    /// `nil` rather than `.identity`: see `ImageAdjustmentError`.
    public init?(persistedToken token: String) {
        switch token {
        case "none": self = .identity
        case "rotate90Clockwise": self = .quarterTurnRight
        case "rotate180": self = .halfTurn
        case "rotate270Clockwise": self = .quarterTurnLeft
        case "flipHorizontal": self = .horizontalFlip
        case "flipVertical": self = .verticalFlip
        case "transposeMainDiagonal": self = .diagonalFlip
        case "transposeAntiDiagonal": self = .antiDiagonalFlip
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let token = try decoder.singleValueContainer().decode(String.self)
        guard let adjustment = UserOrientationAdjustment(persistedToken: token) else {
            throw ImageAdjustmentError.unknownOrientationAdjustment(token: token)
        }
        self = adjustment
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistedToken)
    }
}
