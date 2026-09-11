import Foundation

/// Everything the user has decided about one image, as data.
///
/// ```text
/// ImageDocument (does not exist yet)
///  ├── source        the RAW file — never modified
///  ├── metadata      immutable facts the decoder read
///  └── adjustments   ← this type: the editing decisions
/// ```
///
/// ## Why a record rather than a property
///
/// Orientation is the only adjustment today, and it could have been a single
/// property on `DocumentState`. It is a record instead because every
/// adjustment that follows — exposure, the white-balance choice, the channel
/// mix, tone settings, crop — belongs beside it rather than as another
/// unrelated field, and because the set has to be serialisable **as a set**:
/// a recipe is "all of these together", not one of them at a time.
///
/// This is the first step toward the versioned `InfraredRecipe` the project
/// will need. It is deliberately not that format: a recipe also references
/// camera, capture-configuration and filter profiles by stable identity, and
/// none of those exist yet. Defining the whole format now would mean
/// versioning guesses. See
/// `docs/decisions/0010-user-owned-orientation-adjustment.md`.
///
/// ## Where it lives, and how long
///
/// In memory, on `DocumentState`, for as long as a file is open. **Nothing
/// writes it to disk.** The type is `Codable` and round-trips, and that is a
/// separate fact from being persisted: the serialisable model, the current
/// in-memory ownership, and a future sidecar or document format are three
/// different things and only the first two exist.
public struct ImageAdjustments: Equatable, Sendable {

    /// The schema version this build writes and is the highest it reads.
    ///
    /// Versioned from the first persisted format onward, before anything is
    /// written to disk — which is the only time it is free to do.
    public static let currentSchemaVersion = 1

    /// The schema version this record was written with.
    public let schemaVersion: Int

    /// The user's orientation correction, on top of whatever the file
    /// recorded. `.identity` means they asked for none.
    public var orientation: UserOrientationAdjustment

    public init(
        orientation: UserOrientationAdjustment = .identity,
        schemaVersion: Int = ImageAdjustments.currentSchemaVersion
    ) {
        self.orientation = orientation
        self.schemaVersion = schemaVersion
    }

    /// A freshly opened file's adjustments: the user has decided nothing.
    ///
    /// Not "the image is upright" — the file's own orientation still applies.
    public static let none = ImageAdjustments()

    /// Whether the user has made any editing decision at all.
    public var isIdentity: Bool { orientation.isIdentity }
}

// MARK: - Persistence

extension ImageAdjustments: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case orientation
    }

    /// Reads a persisted record, refusing anything it cannot fully understand.
    ///
    /// The policy, stated once because the alternative is so tempting: a
    /// record that cannot be read is an **error**, never an empty set of
    /// adjustments. Falling back to `.none` would silently discard a user's
    /// edits and present the result as a deliberate choice.
    ///
    /// - A version above `currentSchemaVersion` is refused: it may carry
    ///   adjustments whose omission would change the image.
    /// - A version below `1` is refused: no version of this project wrote it.
    /// - A missing field its version requires is refused rather than
    ///   defaulted.
    /// - An orientation token this version does not model is refused by
    ///   `UserOrientationAdjustment`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        guard let version else {
            throw ImageAdjustmentError.missingAdjustment(
                field: "schemaVersion", schemaVersion: 0
            )
        }
        guard version >= 1, version <= Self.currentSchemaVersion else {
            throw ImageAdjustmentError.unsupportedSchemaVersion(
                found: version, supported: Self.currentSchemaVersion
            )
        }

        guard let orientation = try container.decodeIfPresent(
            UserOrientationAdjustment.self, forKey: .orientation
        ) else {
            throw ImageAdjustmentError.missingAdjustment(
                field: "orientation", schemaVersion: version
            )
        }

        self.init(orientation: orientation, schemaVersion: version)
    }

    /// Writes the record at the **current** schema version, whatever version
    /// it was read at.
    ///
    /// A record read at version 1 and written back is a version-1 record;
    /// there is nothing else it could be while only one version exists. When
    /// a second version arrives, this is where a migration becomes visible.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(orientation, forKey: .orientation)
    }
}
