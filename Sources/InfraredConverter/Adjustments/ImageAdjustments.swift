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
/// There are four adjustments today — the orientation correction, the creative
/// channel mix, the exposure compensation and the infrared white balance — and
/// this is why the model was a record from the first one. Every adjustment that
/// follows, tone settings and crop among them, belongs beside them rather than
/// as another unrelated field, and the set has to be serialisable **as a set**:
/// a recipe is "all of these together", not one of them at a time.
///
/// The white balance is the first adjustment that is not applied to the
/// retained reduced preview — it is upstream of demosaicing, so changing it
/// re-prepares that preview from the retained normalised mosaic. That changes
/// what the workspace *schedules*, and deliberately nothing about this model:
/// it is a field like the other three, one request is still one complete
/// state, and the export still takes the whole record and nothing else. See
/// `docs/decisions/0019-interactive-white-balance.md`.
///
/// It is also what makes one render request mean one complete state. The
/// workspace never asks for "the new orientation", "the new mix", "the new
/// exposure" or "the new patch"; it asks for the whole record, so a burst of
/// changes to any of them — a slider drag included — collapses to one newest
/// state and nothing in between is ever rendered or written. See
/// `docs/decisions/0016-interactive-channel-mixer.md`,
/// `docs/decisions/0017-interactive-exposure.md` and
/// `docs/decisions/0019-interactive-white-balance.md`.
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
    /// 4    orientation, channelMix, exposureEV, whiteBalance
    /// ```
    ///
    /// Versions 2, 3 and 4 exist because a channel mix, an exposure and a white
    /// balance each change the rendered image, and the rule below says an
    /// image-affecting field needs its own version. Version 1, 2 and 3 records
    /// still read, as the migration in `init(from:)` describes.
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

    /// The infrared white balance the user chose, as **intent**:
    /// `.defaultNeutralPatch`, or a neutral rectangle they picked.
    ///
    /// Resolved into an active-area region and then into gains by the RAW
    /// front half, every time, for the preview and for the export alike. The
    /// gains are never stored here and never persisted. See
    /// `docs/decisions/0019-interactive-white-balance.md`.
    ///
    /// It is the one adjustment that is **upstream of demosaicing**: changing
    /// it cannot be applied to the retained reduced preview and re-prepares
    /// that preview from the retained normalised mosaic instead. That is a
    /// scheduling fact, not a modelling one — it is a field of this record like
    /// the other three, and one request still means one complete state.
    ///
    /// Its default is not the identity. `.defaultNeutralPatch` measures real
    /// samples and produces real multipliers; see `isDefault`.
    public var whiteBalance: UserWhiteBalanceAdjustment

    /// Builds a record of the user's decisions at this build's schema version.
    ///
    /// There is deliberately no version parameter. See `schemaVersion`.
    public init(
        orientation: UserOrientationAdjustment = .identity,
        channelMix: UserChannelMixAdjustment = .identity,
        exposure: UserExposureAdjustment = .neutral,
        whiteBalance: UserWhiteBalanceAdjustment = .defaultNeutralPatch
    ) {
        self.orientation = orientation
        self.channelMix = channelMix
        self.exposure = exposure
        self.whiteBalance = whiteBalance
    }

    /// A freshly opened file's adjustments: the user has decided nothing.
    ///
    /// Not "the image is upright" — the file's own orientation still applies —
    /// and not "this is a visible-light photograph": the channel mix is
    /// identity because nothing here can know that a file is an infrared
    /// capture, not because anything decided it is not one.
    public static let none = ImageAdjustments()

    /// Whether every adjustment in this record is the value a freshly opened
    /// file with no sidecar gets.
    ///
    /// ```text
    /// orientation    no correction on top of what the file records
    /// channelMix     no creative remapping
    /// exposure       exactly 0 EV
    /// whiteBalance   the application's default centred neutral patch
    /// ```
    ///
    /// ## It replaced `isIdentity`, and the difference matters
    ///
    /// This property used to be called `isIdentity` and meant **no net effect
    /// on the image**. That reading survived three adjustments and died on the
    /// fourth: the default white balance estimates real multipliers from real
    /// samples, so `ImageAdjustments.none` visibly changes the photograph, and
    /// a property claiming otherwise would have been false for every record in
    /// the application.
    ///
    /// The honest split is between two different questions, and only one of
    /// them can be answered from a record:
    ///
    /// ```text
    /// isDefault        "has the user departed from the defaults?"
    ///                  a fact about this record. Answerable here.
    ///
    /// has no effect    "would rendering with these adjustments change the
    ///                  pixels?" Not answerable here at all: the white balance
    ///                  is intent, and whether its gains come out as 1,1,1,1
    ///                  depends on the photograph. Pretending otherwise would
    ///                  be exactly the kind of plausible-looking claim this
    ///                  project refuses to make.
    /// ```
    ///
    /// So this is a question about **decisions**, not about pixels.
    ///
    /// Two things it does *not* mean, each of which `isIdentity` was read as:
    ///
    /// ```text
    /// "the user decided nothing"      the defaults are states a person can
    ///                                 deliberately reach and save — Reset
    ///                                 Orientation, Identity, Reset Exposure,
    ///                                 Reset White Balance
    /// "nothing is on disk"            a default record is written like any
    ///                                 other; see ADR 0013, Decision 6
    /// ```
    /// It compares each field against **its default value**, not against its
    /// net effect. An `.explicit` matrix that happens to be the identity
    /// leaves the channels alone and is still not `.identity`: it carries
    /// different provenance and persists differently, so a record holding one
    /// is not a record of the defaults. That is the same distinction
    /// `UserChannelMixAdjustment.isIdentity` deliberately does not make.
    ///
    /// Equivalent to `self == .none`, and written out so that adding a field
    /// without deciding what its default is fails to compile here.
    public var isDefault: Bool {
        orientation == .identity
            && channelMix == .identity
            && exposure == .neutral
            && whiteBalance == .defaultNeutralPatch
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
/// The rule has now been applied three times rather than merely written down.
/// `channelMix` changes the rendered image, so adding it raised the version
/// from 1 to 2, `exposureEV` raised it from 2 to 3, and `whiteBalance` raised
/// it from 3 to 4 — none was slipped into an older version as an optional
/// field — and a build that reads only an older version refuses a newer record
/// outright rather than opening it without the field. In the other direction,
/// versions 1, 2 and 3 are still read, because what each absent field meant is
/// known exactly: no remapping, `0 EV`, and the default centred neutral patch
/// every build of this project estimated from.
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
        /// `orientation`, `channelMix`, `exposureEV` and `whiteBalance`.
        case whiteBalance = 4

        /// The version this build writes. Named explicitly, so adding a case
        /// does not by itself change what is written; a test asserts that it
        /// is the highest case.
        static let current = PersistedSchemaVersion.whiteBalance

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
        case whiteBalance
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
    /// v1    orientation          → mix .identity, 0 EV, default neutral patch
    /// v2    + channelMix         → 0 EV, default neutral patch
    /// v3    + exposureEV         → default neutral patch
    /// v4    + whiteBalance       → read as written
    /// ```
    ///
    /// Version 1 predates the creative mix, versions 1 and 2 predate the
    /// exposure control, and versions 1 to 3 predate the white-balance picker.
    /// Such a record describes a photograph that was rendered with no
    /// remapping, at `0 EV`, and white-balanced from the application's centred
    /// neutral patch — which is what the workspace always did. Those are the
    /// states the record was actually saved in. That makes this a
    /// **migration** rather than a default: it is not a guess about a missing
    /// field, it is what the absent field meant.
    ///
    /// The white-balance migration is the one worth stating out loud, because
    /// the tempting wrong answer is close by. An older record migrates to
    /// `.defaultNeutralPatch` — the *same deterministic centred patch* — and
    /// **not** to identity gains. Identity gains would open every previously
    /// saved photograph with a different white balance from the one it was
    /// saved with, and nothing would say so.
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
            try Self.refuse(.whiteBalance, in: container, schemaVersion: version)
            // The migration. Not a default for a field that went missing: an
            // absent mix in version 1 *is* the identity, an absent exposure
            // *is* 0 EV, and an absent white balance *is* the default centred
            // patch, because version 1 rendered exactly that.
            self.init(
                orientation: orientation,
                channelMix: .identity,
                exposure: .neutral,
                whiteBalance: .defaultNeutralPatch
            )

        case .channelMix:
            try Self.refuse(.exposureEV, in: container, schemaVersion: version)
            try Self.refuse(.whiteBalance, in: container, schemaVersion: version)
            let channelMix = try Self.require(
                UserChannelMixAdjustment.self, .channelMix,
                in: container, schemaVersion: version
            )
            // The migration: version 2 predates the exposure control and the
            // white-balance picker; it rendered at 0 EV from the default
            // centred patch.
            self.init(
                orientation: orientation,
                channelMix: channelMix,
                exposure: .neutral,
                whiteBalance: .defaultNeutralPatch
            )

        case .exposure:
            try Self.refuse(.whiteBalance, in: container, schemaVersion: version)
            let channelMix = try Self.require(
                UserChannelMixAdjustment.self, .channelMix,
                in: container, schemaVersion: version
            )
            let exposure = try Self.require(
                UserExposureAdjustment.self, .exposureEV,
                in: container, schemaVersion: version
            )
            // The migration: version 3 predates the white-balance picker and
            // rendered from the default centred patch.
            self.init(
                orientation: orientation,
                channelMix: channelMix,
                exposure: exposure,
                whiteBalance: .defaultNeutralPatch
            )

        case .whiteBalance:
            let channelMix = try Self.require(
                UserChannelMixAdjustment.self, .channelMix,
                in: container, schemaVersion: version
            )
            let exposure = try Self.require(
                UserExposureAdjustment.self, .exposureEV,
                in: container, schemaVersion: version
            )
            let whiteBalance = try Self.require(
                UserWhiteBalanceAdjustment.self, .whiteBalance,
                in: container, schemaVersion: version
            )
            self.init(
                orientation: orientation,
                channelMix: channelMix,
                exposure: exposure,
                whiteBalance: whiteBalance
            )
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
    /// round-trip. A migrated version 1, 2 or 3 record is therefore written
    /// back as version 4 the next time it is saved — with the identity mix, the
    /// `0 EV` and the default neutral patch it was migrated to, which is the
    /// state it was already in. Reading rewrites nothing: an older record is
    /// upgraded on disk only when the user's next decision renders and is
    /// saved.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(orientation, forKey: .orientation)
        try container.encode(channelMix, forKey: .channelMix)
        try container.encode(exposure, forKey: .exposureEV)
        try container.encode(whiteBalance, forKey: .whiteBalance)
    }
}
