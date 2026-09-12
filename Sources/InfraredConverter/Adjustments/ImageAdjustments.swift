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
/// In memory, on `DocumentState`, for as long as a file is open — and in a
/// JSON sidecar beside the RAW file between sessions, through
/// `ImageAdjustmentStore`. This `Codable` conformance is that sidecar's wire
/// format, which is why its refusals matter: a record this build cannot fully
/// understand is an error rather than an empty set of adjustments, all the way
/// out to the workspace. See `docs/decisions/0013-adjustment-sidecar.md`.
///
/// It is still not a recipe. A sidecar is the state of one photograph; a
/// recipe is a reusable set of choices that also references camera, capture
/// and filter profiles by stable identity, and none of those exist yet.
public struct ImageAdjustments: Equatable, Sendable {

    /// The schema version this build writes and is the highest it reads.
    ///
    /// Versioned from the first persisted format onward, before anything is
    /// written to disk — which is the only time it is free to do.
    public static let currentSchemaVersion = 1

    /// The wire-format version this record belongs to.
    ///
    /// **Wire-format metadata, not editing state**, and therefore not stored
    /// and not settable. An in-memory record is always a record of this
    /// build's schema, so an `ImageAdjustments` whose version disagrees with
    /// what `encode(to:)` writes cannot be constructed — by anyone, not
    /// merely by convention.
    ///
    /// It was a stored property with a public parameter, and that was a
    /// modelling error: a caller could name any integer, and encoding ignored
    /// it and wrote the current one, so a publicly constructible value did not
    /// round-trip. Harmless while nothing is persisted; a corruption bug the
    /// day a sidecar is written. A historical version now exists only inside
    /// `init(from:)`, for exactly as long as it takes to decide whether it can
    /// be read.
    public var schemaVersion: Int { Self.currentSchemaVersion }

    /// The user's orientation correction, on top of whatever the file
    /// recorded. `.identity` means they asked for none.
    public var orientation: UserOrientationAdjustment

    /// Builds a record of the user's decisions at this build's schema version.
    ///
    /// There is deliberately no version parameter. See `schemaVersion`.
    public init(orientation: UserOrientationAdjustment = .identity) {
        self.orientation = orientation
    }

    /// A freshly opened file's adjustments: the user has decided nothing.
    ///
    /// Not "the image is upright" — the file's own orientation still applies.
    public static let none = ImageAdjustments()

    /// Whether the user has made any editing decision at all.
    public var isIdentity: Bool { orientation.isIdentity }
}

// MARK: - Persistence

/// ## The forward-compatibility rule
///
/// Extensibility is why this is a record rather than a property, so a reader
/// is allowed to ignore a field it does not know about — but only a field
/// whose absence cannot change the photograph.
///
/// ```text
/// non-semantic field      may be added within a schema version, and ignored
///                         e.g. a note, an author, a timestamp
///
/// image-affecting field   requires a schema-version bump
///                         e.g. exposure, a channel mix, a crop, a curve
/// ```
///
/// The distinction is not stylistic. An older client that silently ignored a
/// newer `exposureEV` would open the file, render a different photograph from
/// the one the user saved, and report no problem at all — and would then write
/// the record back without the field, destroying the edit. So:
///
/// **Any new persisted setting whose omission would change the rendered image
/// requires a new schema version, and an older client must refuse that
/// version rather than read around it.** `init(from:)` already does refuse it;
/// this is the rule that says when a future author must raise the number.
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

        // `version` is known to equal `currentSchemaVersion` here: anything
        // else was refused above. When a second version exists, this is where
        // a migration becomes visible, and the decoded version stops being
        // discardable.
        self.init(orientation: orientation)
    }

    /// Writes the record at the **current** schema version.
    ///
    /// Nothing else is possible: no in-memory record carries any other
    /// version, which is what makes every publicly constructible value
    /// round-trip. When a second version arrives, this is where a migration
    /// becomes visible.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(orientation, forKey: .orientation)
    }
}
