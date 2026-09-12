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
/// There are three adjustments today — the orientation correction, the
/// creative channel mix and the exposure compensation — and this is why the
/// model was a record from the first one. Every adjustment that follows, the
/// white-balance choice and tone settings and crop, belongs beside them rather
/// than as another unrelated field, and the set has to be serialisable **as a
/// set**: a recipe is "all of these together", not one of them at a time.
///
/// It is also what makes one render request mean one complete state. The
/// workspace never asks for "the new orientation", "the new mix" or "the new
/// exposure"; it asks for the whole record, so a burst of changes to any of
/// them — a slider drag included — collapses to one newest state and nothing
/// in between is ever rendered or written. See
/// `docs/decisions/0016-interactive-channel-mixer.md` and
/// `docs/decisions/0017-interactive-exposure.md`.
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
    ///
    /// ```text
    /// 1    orientation
    /// 2    orientation, channelMix
    /// 3    orientation, channelMix, exposureEV
    /// ```
    ///
    /// Versions 2 and 3 exist because a channel mix and an exposure each change
    /// the rendered image, and the rule below says an image-affecting field
    /// needs its own version. Version 1 and 2 records still read, as the
    /// migration in `init(from:)` describes.
    ///
    /// Derived from `PersistedSchemaVersion.current` rather than written as a
    /// literal, so the list of versions this build reads and the version it
    /// writes cannot disagree.
    public static let currentSchemaVersion = PersistedSchemaVersion.current.rawValue

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

    /// The creative infrared channel mix the user chose. `.identity` means
    /// they asked for no remapping.
    ///
    /// A **creative** decision, and never a calibration: it says how RGB is
    /// remixed inside a working colour space that has already been
    /// established, and it is recorded as intent rather than as anything
    /// measured. See `docs/decisions/0007-infrared-channel-mixing.md`.
    ///
    /// It is deliberately not defaulted anywhere in the processing API. The
    /// default here is the **application layer's** choice for a file with no
    /// saved decision, stated in one place, and it is `.identity` because
    /// nothing in this project knows whether a given RAW file is an infrared
    /// capture.
    public var channelMix: UserChannelMixAdjustment

    /// The exposure compensation the user chose. `.neutral` is `0 EV`.
    ///
    /// Applied in the linear domain as `× 2^EV` by the display renderer, after
    /// the mix and the orientation and before the display range policy. It is
    /// not tone mapping, not highlight recovery and not automatic: nothing
    /// derives it from the image. See
    /// `docs/decisions/0017-interactive-exposure.md`.
    public var exposure: UserExposureAdjustment

    /// Builds a record of the user's decisions at this build's schema version.
    ///
    /// There is deliberately no version parameter. See `schemaVersion`.
    public init(
        orientation: UserOrientationAdjustment = .identity,
        channelMix: UserChannelMixAdjustment = .identity,
        exposure: UserExposureAdjustment = .neutral
    ) {
        self.orientation = orientation
        self.channelMix = channelMix
        self.exposure = exposure
    }

    /// A freshly opened file's adjustments: the user has decided nothing.
    ///
    /// Not "the image is upright" — the file's own orientation still applies —
    /// and not "this is a visible-light photograph": the channel mix is
    /// identity because nothing here can know that a file is an infrared
    /// capture, not because anything decided it is not one.
    public static let none = ImageAdjustments()

    /// Whether this record has **no net effect on the image**.
    ///
    /// Every adjustment it holds is the identity: no orientation correction on
    /// top of what the file records, no creative channel remapping, and
    /// exactly `0 EV`. It is one question about the whole record, because a
    /// record that leaves the geometry and the channels alone and lifts the
    /// exposure by a tenth of a stop does affect the image.
    ///
    /// Three things it does **not** mean, each of which it has been read as:
    ///
    /// ```text
    /// "the user decided nothing"      identity is a decision a person can
    ///                                 reach and save — Reset, or Identity on
    ///                                 the mix control
    /// "nothing is on disk"            identity is written like any other
    ///                                 state; see ADR 0013, Decision 6
    /// "no provenance was recorded"    an .explicit matrix that happens to be
    ///                                 the identity has no net effect and is
    ///                                 still not `.identity`
    /// ```
    ///
    /// It compares net effects, and nothing else.
    public var isIdentity: Bool {
        orientation.isIdentity && channelMix.isIdentity && exposure.isIdentity
    }
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
/// version rather than read around it.**
///
/// The rule has now been applied twice rather than merely written down.
/// `channelMix` changes the rendered image, so adding it raised the version
/// from 1 to 2, and `exposureEV` raised it from 2 to 3 — neither was slipped
/// into an older version as an optional field — and a build that reads only an
/// older version refuses a newer record outright rather than opening it
/// without the field. In the other direction, versions 1 and 2 are still read,
/// because what each absent field meant is known exactly: no remapping, and
/// `0 EV`.
extension ImageAdjustments {
    /// Every schema version this build reads, as a closed set.
    ///
    /// The migration in `init(from:)` switches over this type, **exhaustively
    /// and with no `default`**. That is the point of it. The version on the
    /// wire used to be dispatched as a bare `Int`:
    ///
    /// ```text
    /// switch version {
    /// case 1:   … migrate
    /// default:  … decode as version 2
    /// }
    /// ```
    ///
    /// which compiles unchanged the day a version 3 is added and quietly sends
    /// every version 3 record through version 2's decoding. A new case here is
    /// a compile error in the migration until someone decides what that
    /// version's record contains.
    ///
    /// Internal rather than private so a test can pin the set: the raw values
    /// are contiguous from 1 and `current` is the highest of them.
    enum PersistedSchemaVersion: Int, CaseIterable, Sendable {
        /// `orientation` alone.
        case orientationOnly = 1
        /// `orientation` and `channelMix`.
        case channelMix = 2
        /// `orientation`, `channelMix` and `exposureEV`.
        case exposure = 3

        /// The version this build writes. Named explicitly, so adding a case
        /// does not by itself change what is written; a test asserts that it
        /// is the highest case.
        static let current = PersistedSchemaVersion.exposure

        /// The first version any build of this project wrote.
        static let first = PersistedSchemaVersion.orientationOnly
    }
}

extension ImageAdjustments: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case orientation
        case channelMix
        case exposureEV
    }

    /// Reads a persisted record, refusing anything it cannot fully understand
    /// and migrating anything it can.
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
    /// - A field its version does not have is refused rather than read.
    /// - An orientation token or channel-mix kind this version does not model
    ///   is refused by the adjustment type that owns it.
    ///
    /// ## The migrations
    ///
    /// ```text
    /// v1    orientation                        → channelMix = .identity, exposure = 0 EV
    /// v2    orientation, channelMix            → exposure = 0 EV
    /// v3    orientation, channelMix, exposureEV → read as written
    /// ```
    ///
    /// Version 1 predates the creative mix and versions 1 and 2 predate the
    /// exposure control, so such a record describes a photograph that was
    /// rendered with no remapping and at `0 EV` — which the workspace always
    /// passed. Those are the states the record was actually saved in. That
    /// makes this a **migration** rather than a default: it is not a guess
    /// about a missing field, it is what the absent field meant.
    ///
    /// A record that carries a field its version does not have is a different
    /// thing entirely and is refused. Reading it would break the rule below in
    /// the one direction that destroys data, and writing it back at the
    /// current version would then make the loss permanent. Every field a
    /// version has is required, `decodeIfPresent` notwithstanding: absence is
    /// refused, never defaulted.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        guard let rawVersion else {
            throw ImageAdjustmentError.missingAdjustment(
                field: "schemaVersion", schemaVersion: 0
            )
        }
        // Range first, then the closed set. The two refusals are the same
        // error because they are the same fact — this build does not read
        // that version — but the order matters for what a reader learns: a
        // version above the current one is a newer record, not a malformed
        // one.
        guard rawVersion >= PersistedSchemaVersion.first.rawValue,
              rawVersion <= PersistedSchemaVersion.current.rawValue,
              let schema = PersistedSchemaVersion(rawValue: rawVersion)
        else {
            throw ImageAdjustmentError.unsupportedSchemaVersion(
                found: rawVersion, supported: Self.currentSchemaVersion
            )
        }
        let version = schema.rawValue

        guard let orientation = try container.decodeIfPresent(
            UserOrientationAdjustment.self, forKey: .orientation
        ) else {
            throw ImageAdjustmentError.missingAdjustment(
                field: "orientation", schemaVersion: version
            )
        }

        // Every version from the first onward has `orientation`; version 2
        // adds `channelMix` and version 3 adds `exposureEV`. The switch is over
        // `PersistedSchemaVersion`, with no `default`, so adding a version is a
        // compile error here rather than a silent fall-through into an older
        // version's decoding.
        switch schema {
        case .orientationOnly:
            try Self.refuse(.channelMix, in: container, schemaVersion: version)
            try Self.refuse(.exposureEV, in: container, schemaVersion: version)
            // The migration. Not a default for a field that went missing: an
            // absent mix in version 1 *is* the identity, and an absent exposure
            // *is* 0 EV, because version 1 rendered exactly that.
            self.init(orientation: orientation, channelMix: .identity, exposure: .neutral)

        case .channelMix:
            try Self.refuse(.exposureEV, in: container, schemaVersion: version)
            let channelMix = try Self.require(
                UserChannelMixAdjustment.self, .channelMix,
                in: container, schemaVersion: version
            )
            // The migration: version 2 predates the exposure control and
            // rendered at 0 EV.
            self.init(orientation: orientation, channelMix: channelMix, exposure: .neutral)

        case .exposure:
            let channelMix = try Self.require(
                UserChannelMixAdjustment.self, .channelMix,
                in: container, schemaVersion: version
            )
            let exposure = try Self.require(
                UserExposureAdjustment.self, .exposureEV,
                in: container, schemaVersion: version
            )
            self.init(orientation: orientation, channelMix: channelMix, exposure: exposure)
        }
    }

    /// Reads a field its version requires, refusing its absence.
    ///
    /// `decodeIfPresent` is used only to turn absence — or an explicit `null` —
    /// into the typed `missingAdjustment` refusal rather than a
    /// `DecodingError`. It never yields a default.
    private static func require<Value: Decodable>(
        _ type: Value.Type,
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        schemaVersion: Int
    ) throws -> Value {
        guard let value = try container.decodeIfPresent(type, forKey: key) else {
            throw ImageAdjustmentError.missingAdjustment(
                field: key.stringValue, schemaVersion: schemaVersion
            )
        }
        return value
    }

    /// Refuses a field its version does not have.
    private static func refuse(
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        schemaVersion: Int
    ) throws {
        guard !container.contains(key) else {
            throw ImageAdjustmentError.unexpectedAdjustment(
                field: key.stringValue, schemaVersion: schemaVersion
            )
        }
    }

    /// Writes the record at the **current** schema version.
    ///
    /// Nothing else is possible: no in-memory record carries any other
    /// version, which is what makes every publicly constructible value
    /// round-trip. A migrated version 1 or 2 record is therefore written back
    /// as version 3 the next time it is saved — with the identity mix and the
    /// `0 EV` it was migrated to, which is the state it was already in.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(orientation, forKey: .orientation)
        try container.encode(channelMix, forKey: .channelMix)
        try container.encode(exposure, forKey: .exposureEV)
    }
}
