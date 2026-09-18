import Foundation

// MARK: - The schema

/// ## The forward-compatibility rule
///
/// Extensibility is why the sidecar holds a record rather than a value, so a
/// reader is allowed to ignore a field it does not know about — but only a
/// field whose absence cannot change the photograph.
///
/// ```text
/// non-semantic field      may be added within a schema version, and ignored
///                         e.g. a note, an author, a timestamp
///
/// image-affecting field   requires a schema-version bump
///                         e.g. exposure, a channel mix, a capture profile
/// ```
///
/// The distinction is not stylistic. An older client that silently ignored a
/// newer `exposureEV` would open the file, render a different photograph from
/// the one the user saved, and report no problem at all — and would then write
/// the record back without the field, destroying the edit. So:
///
/// **Any new persisted setting whose omission would change the rendered image
/// requires a new schema version, and an older client must refuse that version
/// rather than read around it.**
///
/// The rule has now been applied six times rather than merely written down.
/// `channelMix` raised the version from 1 to 2, `exposureEV` from 2 to 3,
/// `whiteBalance` from 3 to 4, `captureProfileID` from 4 to 5, `levels` from 5
/// to 6 and `contrast` from 6 to 7 — none was slipped into an older version as
/// an optional field.
///
/// `levels` is the clearest case the rule has had. A build that ignored it
/// would render a photograph with the black point the user pulled up sitting
/// back at `0`, would say nothing, and would then write the record back
/// without the field — destroying the edit. So version 5 does not learn about
/// levels, and a version 6 record is refused by any build that does not have
/// them.
///
/// `captureProfileID` earns a version for the general reason even though every
/// profile this build ships happens to share one processing basis: the field's
/// whole purpose is to select which camera-to-working transform runs, so a
/// build that ignored it would eventually render somebody's photograph through
/// the wrong one and say nothing.
extension PhotographProcessingState {

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
    /// ## It lives here rather than on `ImageAdjustments`
    ///
    /// It used to live there, when adjustments were the only thing a sidecar
    /// held. They are not any more: the payload is the photograph's complete
    /// application-owned processing state, of which the adjustments are one
    /// half. A schema version belongs to the record it describes, and leaving
    /// it on the adjustments would have meant a version number that claimed to
    /// describe a file it only half covered. `ImageAdjustments` went back to
    /// being editing data with no persistence metadata on it at all. See
    /// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 7.
    enum PersistedSchemaVersion: Int, CaseIterable, Sendable {
        /// `orientation` alone, at the top level.
        case orientationOnly = 1
        /// `orientation` and `channelMix`, at the top level.
        case channelMix = 2
        /// `orientation`, `channelMix` and `exposureEV`, at the top level.
        case exposure = 3
        /// `orientation`, `channelMix`, `exposureEV` and `whiteBalance`, at
        /// the top level.
        case whiteBalance = 4
        /// `captureProfileID`, and the four adjustments nested under
        /// `adjustments`.
        case captureProfile = 5
        /// `captureProfileID`, and the five adjustments nested under
        /// `adjustments` — `levels` being the new one.
        case levels = 6
        /// `captureProfileID`, and the six adjustments nested under
        /// `adjustments` — `contrast` being the new one.
        case contrast = 7

        /// The version this build writes. Named explicitly, so adding a case
        /// does not by itself change what is written; a test asserts that it
        /// is the highest case.
        static let current = PersistedSchemaVersion.contrast

        /// The first version any build of this project wrote.
        static let first = PersistedSchemaVersion.orientationOnly

        /// Whether this version keeps the adjustments at the top level of the
        /// record, beside `schemaVersion`, rather than nested.
        ///
        /// True for every historical version and false from 5 onward. Written
        /// as a switch so a new case has to answer the question.
        var storesAdjustmentsAtTopLevel: Bool {
            switch self {
            case .orientationOnly, .channelMix, .exposure, .whiteBalance: return true
            case .captureProfile, .levels, .contrast: return false
            }
        }
    }

    /// The schema version this build writes, and the highest it reads.
    public static let currentSchemaVersion = PersistedSchemaVersion.current.rawValue
}

// MARK: - The wire format

/// ## Version 7 adds `contrast`
///
/// ```text
/// v6                                     v7
/// {                                      {
///   "schemaVersion": 6,                    "schemaVersion": 7,
///   "captureProfileID": "…",               "captureProfileID": "…",
///   "adjustments": {                       "adjustments": {
///     …,                                     …,
///     "levels": {                            "levels": {
///       "blackPoint": 0.05,                    "blackPoint": 0.05,
///       "whitePoint": 1.2                      "whitePoint": 1.2
///     }                                      },
///   }                                        "contrast": 0.35
/// }                                        }
///                                        }
/// ```
///
/// A bare number rather than an object, for the reason `exposureEV` is one:
/// the decision *is* one number. The exponent `k = 2^amount` is deliberately
/// not written beside it — it is derived, and a record carrying both could
/// disagree with itself.
///
/// The field is required at version 7 and refused before it. A build that
/// ignored it would render a photograph with the contrast a person applied
/// sitting back at neutral, would say nothing, and would then write the record
/// back without the field, destroying the edit.
///
/// ## Version 6 adds `levels`, inside the nesting version 5 introduced
///
/// ```text
/// v5                                     v6
/// {                                      {
///   "schemaVersion": 5,                    "schemaVersion": 6,
///   "captureProfileID": "…",               "captureProfileID": "…",
///   "adjustments": {                       "adjustments": {
///     "orientation": "…",                    "orientation": "…",
///     "channelMix": { … },                   "channelMix": { … },
///     "exposureEV": 0,                       "exposureEV": 0,
///     "whiteBalance": { … }                  "whiteBalance": { … },
///   }                                        "levels": {
/// }                                            "blackPoint": 0.05,
///                                              "whitePoint": 1.2
///                                            }
///                                          }
///                                        }
/// ```
///
/// One key rather than two, because the pair is one decision and the invariant
/// `blackPoint < whitePoint` belongs to neither number alone. Both its fields
/// are required; `UserLevelsAdjustment` refuses a record that is missing one,
/// carries a non-finite bound, or orders the two the wrong way round — and
/// refuses rather than reordering, because swapping them inverts the
/// photograph.
///
/// ## Version 5 nests, and versions 1 to 4 did not
///
/// ```text
/// v4                                   v5
/// {                                    {
///   "schemaVersion": 4,                  "schemaVersion": 5,
///   "orientation": "…",                  "captureProfileID": "builtin.uncalibrated",
///   "channelMix": { … },                 "adjustments": {
///   "exposureEV": 0,                       "orientation": "…",
///   "whiteBalance": { … }                  "channelMix": { … },
/// }                                        "exposureEV": 0,
///                                          "whiteBalance": { … }
///                                        }
///                                      }
/// ```
///
/// The nesting is the wire format catching up with the model. Once the record
/// holds two different kinds of thing — a reference to a reusable capture
/// configuration, and this photograph's own edits — a flat object says they are
/// the same kind, and every future field would have to be read to find out
/// which half it belongs to. A reader can now see the boundary this milestone
/// exists to draw.
///
/// The alternative was to stay flat and add `captureProfileID` beside the four
/// adjustments. It would have made this migration shorter and every later one
/// worse, and it would have left `ImageAdjustments` unable to own its own
/// encoding while the record owned the version.
///
/// **There is exactly one authority for each field.** A version 5 record that
/// also carries `orientation` at the top level is refused, and a version 1 to 4
/// record that carries `adjustments` or `captureProfileID` is refused. Neither
/// is read "leniently": a record with two places to look for one value has no
/// reading that is not a guess.
///
/// The filename did not change. `<RAW name>.iradjustments.json` is what every
/// sidecar already written is called, and changing the payload's shape is no
/// reason to orphan them. See `docs/decisions/0013-adjustment-sidecar.md`.
extension PhotographProcessingState: Codable {

    /// The record's own keys.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case captureProfileID
        case adjustments
    }

    /// The adjustment fields' keys.
    ///
    /// Used against two different containers — the nested `adjustments` object
    /// in version 5, and the top level in versions 1 to 4 — which is exactly
    /// why they are a separate key type rather than more cases above.
    private enum AdjustmentKeys: String, CodingKey, CaseIterable {
        case orientation
        case channelMix
        case exposureEV
        case whiteBalance
        case levels
        case contrast
    }

    /// Reads a persisted record, refusing anything it cannot fully understand
    /// and migrating anything it can.
    ///
    /// The policy, stated once because the alternative is so tempting: a record
    /// that cannot be read is an **error**, never an empty state. Falling back
    /// to `.none` would silently discard a user's edits and present the result
    /// as a deliberate choice.
    ///
    /// - A version above `currentSchemaVersion` is refused: it may carry
    ///   settings whose omission would change the image.
    /// - A version below `1` is refused: no version of this project wrote it.
    /// - A missing field its version requires is refused rather than defaulted.
    /// - A field its version does not have is refused rather than read.
    /// - An orientation token, channel-mix kind or white-balance kind this
    ///   build does not model is refused by the adjustment type that owns it.
    /// - A capture profile identifier that is not well formed is refused by
    ///   `IRCaptureProfileID`. Whether that profile **exists** is a different
    ///   question, asked later, by the registry — a record naming a profile
    ///   this machine does not have is perfectly well formed.
    ///
    /// ## The migrations
    ///
    /// ```text
    /// v1   orientation      → mix .identity, 0 EV, default patch, builtin.uncalibrated
    /// v2   + channelMix     → 0 EV, default patch, builtin.uncalibrated
    /// v3   + exposureEV     → default patch, builtin.uncalibrated
    /// v4   + whiteBalance   → builtin.uncalibrated, neutral levels
    /// v5   + captureProfileID, adjustments nested   → neutral levels, contrast 0
    /// v6   + levels          → contrast 0
    /// v7   + contrast        → read as written
    /// ```
    ///
    /// Version 6 migrates to **neutral** contrast — amount `0`, whose curve
    /// exponent is exactly `1` — and that is a migration rather than a default
    /// for the reason every other one is: it is what the absent field meant.
    /// Every build that wrote version 6 had no contrast stage at all, so a
    /// version 6 photograph renders after this milestone exactly as it did
    /// before it, and a test compares the buffers rather than taking that on
    /// trust.
    ///
    /// Version 5 migrates to **neutral** levels — black `0`, white `1` — and
    /// that is a migration rather than a default for the same reason the
    /// others are: neutral levels are mathematically the identity, and the
    /// identity is exactly what every build that wrote version 5 applied,
    /// because it had no levels stage at all. A version 5 photograph therefore
    /// renders after this milestone exactly as it did before it, and a test
    /// compares the buffers rather than taking that on trust.
    ///
    /// Every historical version migrates to `builtin.uncalibrated`, and that is
    /// a **migration** rather than a default: it is not a guess about a missing
    /// field, it is what the absent field meant. Every build of this
    /// application that wrote versions 1 to 4 rendered through
    /// `RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor`, and
    /// `builtin.uncalibrated` is the profile whose processing basis is exactly
    /// that. The migration is therefore pixel-neutral, and a test renders both
    /// states and compares the buffers rather than taking that on trust.
    ///
    /// The same reasoning as the earlier migrations, applied to the new field:
    /// the tempting wrong answers — "no profile", or a plausible-looking
    /// infrared profile — would respectively leave the record unable to render
    /// and change every previously saved photograph without saying so.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try Self.schemaVersion(in: container)
        let version = schema.rawValue

        // The same decoder, read through the adjustment keys. For a historical
        // version that is where the adjustments are; for version 5 it is where
        // they must NOT be.
        let flat = try decoder.container(keyedBy: AdjustmentKeys.self)

        // The switch is over `PersistedSchemaVersion`, with no `default`, so
        // adding a version is a compile error here rather than a silent
        // fall-through into an older version's decoding.
        switch schema {
        case .orientationOnly, .channelMix, .exposure, .whiteBalance:
            try Self.refuse(.captureProfileID, in: container, schemaVersion: version)
            try Self.refuse(.adjustments, in: container, schemaVersion: version)
            self.init(
                // The migration. Not a fallback for a field that went missing:
                // an absent profile in versions 1 to 4 *is* the built-in
                // uncalibrated one, because that is the only processing those
                // versions ever did.
                captureProfile: .builtinUncalibrated,
                adjustments: try Self.adjustments(in: flat, schemaVersion: schema)
            )

        case .captureProfile, .levels, .contrast:
            // One authority per field. A version 5, 6 or 7 record that also carries
            // adjustments at the top level says two things about one
            // photograph, and there is no reading of it that is not a guess.
            for key in AdjustmentKeys.allCases {
                try Self.refuse(key, in: flat, schemaVersion: version)
            }
            guard let profile = try container.decodeIfPresent(
                IRCaptureProfileID.self, forKey: .captureProfileID
            ) else {
                throw PhotographProcessingStateError.missingField(
                    field: CodingKeys.captureProfileID.stringValue, schemaVersion: version
                )
            }
            guard container.contains(.adjustments) else {
                throw PhotographProcessingStateError.missingField(
                    field: CodingKeys.adjustments.stringValue, schemaVersion: version
                )
            }
            let nested = try container.nestedContainer(
                keyedBy: AdjustmentKeys.self, forKey: .adjustments
            )
            self.init(
                captureProfile: profile,
                adjustments: try Self.adjustments(in: nested, schemaVersion: schema)
            )
        }
    }

    /// Writes the record at the **current** schema version.
    ///
    /// Nothing else is possible: no in-memory record carries any other version,
    /// which is what makes every publicly constructible value round-trip. A
    /// migrated version 1 to 6 record is therefore written back as version 7
    /// the next time it is saved — with the built-in uncalibrated profile it
    /// was migrated to, which is the state it was already in. Reading rewrites
    /// nothing: an older record is upgraded on disk only when the user's next
    /// decision renders and is saved.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(captureProfile, forKey: .captureProfileID)

        var nested = container.nestedContainer(
            keyedBy: AdjustmentKeys.self, forKey: .adjustments
        )
        try nested.encode(adjustments.orientation, forKey: .orientation)
        try nested.encode(adjustments.channelMix, forKey: .channelMix)
        try nested.encode(adjustments.exposure, forKey: .exposureEV)
        try nested.encode(adjustments.whiteBalance, forKey: .whiteBalance)
        try nested.encode(adjustments.levels, forKey: .levels)
        try nested.encode(adjustments.contrast, forKey: .contrast)
    }

    // MARK: - Reading the version

    private static func schemaVersion(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> PersistedSchemaVersion {
        guard let raw = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) else {
            throw PhotographProcessingStateError.missingField(
                field: CodingKeys.schemaVersion.stringValue, schemaVersion: 0
            )
        }
        // Range first, then the closed set. The two refusals are the same error
        // because they are the same fact — this build does not read that
        // version — but the order matters for what a reader learns: a version
        // above the current one is a newer record, not a malformed one.
        guard raw >= PersistedSchemaVersion.first.rawValue,
              raw <= PersistedSchemaVersion.current.rawValue,
              let schema = PersistedSchemaVersion(rawValue: raw)
        else {
            throw PhotographProcessingStateError.unsupportedSchemaVersion(
                found: raw, supported: currentSchemaVersion
            )
        }
        return schema
    }

    // MARK: - Reading the adjustments a version defines

    /// Reads the adjustment fields a schema version has, from whichever
    /// container holds them, and supplies the historical meaning of the ones it
    /// does not.
    ///
    /// Versions 1 to 6 predate a field each. Such a record describes a
    /// photograph that was rendered with no remapping, at `0 EV`, and
    /// white-balanced from the application's centred neutral patch — which is
    /// what the workspace always did. Those are the states the record was
    /// actually saved in.
    ///
    /// The white-balance migration is the one worth stating out loud, because
    /// the tempting wrong answer is close by. An older record migrates to
    /// `.defaultNeutralPatch` — the *same deterministic centred patch* — and
    /// **not** to identity gains. Identity gains would open every previously
    /// saved photograph with a different white balance from the one it was
    /// saved with, and nothing would say so.
    private static func adjustments(
        in container: KeyedDecodingContainer<AdjustmentKeys>,
        schemaVersion schema: PersistedSchemaVersion
    ) throws -> ImageAdjustments {
        let version = schema.rawValue

        let orientation = try require(
            UserOrientationAdjustment.self, .orientation,
            in: container, schemaVersion: version
        )

        switch schema {
        case .orientationOnly:
            try refuse(.channelMix, in: container, schemaVersion: version)
            try refuse(.exposureEV, in: container, schemaVersion: version)
            try refuse(.whiteBalance, in: container, schemaVersion: version)
            try refuse(.levels, in: container, schemaVersion: version)
            try refuse(.contrast, in: container, schemaVersion: version)
            return ImageAdjustments(
                orientation: orientation,
                channelMix: .identity,
                exposure: .neutral,
                whiteBalance: .defaultNeutralPatch,
                levels: .neutral,
                contrast: .neutral
            )

        case .channelMix:
            try refuse(.exposureEV, in: container, schemaVersion: version)
            try refuse(.whiteBalance, in: container, schemaVersion: version)
            try refuse(.levels, in: container, schemaVersion: version)
            try refuse(.contrast, in: container, schemaVersion: version)
            return ImageAdjustments(
                orientation: orientation,
                channelMix: try require(
                    UserChannelMixAdjustment.self, .channelMix,
                    in: container, schemaVersion: version
                ),
                exposure: .neutral,
                whiteBalance: .defaultNeutralPatch,
                levels: .neutral,
                contrast: .neutral
            )

        case .exposure:
            try refuse(.whiteBalance, in: container, schemaVersion: version)
            try refuse(.levels, in: container, schemaVersion: version)
            try refuse(.contrast, in: container, schemaVersion: version)
            return ImageAdjustments(
                orientation: orientation,
                channelMix: try require(
                    UserChannelMixAdjustment.self, .channelMix,
                    in: container, schemaVersion: version
                ),
                exposure: try require(
                    UserExposureAdjustment.self, .exposureEV,
                    in: container, schemaVersion: version
                ),
                whiteBalance: .defaultNeutralPatch,
                levels: .neutral,
                contrast: .neutral
            )

        case .whiteBalance, .captureProfile:
            // Versions 4 and 5 carry the same four adjustments; only where they
            // sit in the record differs, and the container settled that before
            // this was called. Neither has levels — and neither build had a
            // levels stage, so neutral is what they applied.
            try refuse(.levels, in: container, schemaVersion: version)
            try refuse(.contrast, in: container, schemaVersion: version)
            return ImageAdjustments(
                orientation: orientation,
                channelMix: try require(
                    UserChannelMixAdjustment.self, .channelMix,
                    in: container, schemaVersion: version
                ),
                exposure: try require(
                    UserExposureAdjustment.self, .exposureEV,
                    in: container, schemaVersion: version
                ),
                whiteBalance: try require(
                    UserWhiteBalanceAdjustment.self, .whiteBalance,
                    in: container, schemaVersion: version
                ),
                levels: .neutral,
                contrast: .neutral
            )

        case .levels:
            // Version 6 carries levels but predates the contrast curve, and
            // the build that wrote it applied none. Neutral is what it did.
            try refuse(.contrast, in: container, schemaVersion: version)
            return ImageAdjustments(
                orientation: orientation,
                channelMix: try require(
                    UserChannelMixAdjustment.self, .channelMix,
                    in: container, schemaVersion: version
                ),
                exposure: try require(
                    UserExposureAdjustment.self, .exposureEV,
                    in: container, schemaVersion: version
                ),
                whiteBalance: try require(
                    UserWhiteBalanceAdjustment.self, .whiteBalance,
                    in: container, schemaVersion: version
                ),
                levels: try require(
                    UserLevelsAdjustment.self, .levels,
                    in: container, schemaVersion: version
                ),
                contrast: .neutral
            )

        case .contrast:
            return ImageAdjustments(
                orientation: orientation,
                channelMix: try require(
                    UserChannelMixAdjustment.self, .channelMix,
                    in: container, schemaVersion: version
                ),
                exposure: try require(
                    UserExposureAdjustment.self, .exposureEV,
                    in: container, schemaVersion: version
                ),
                whiteBalance: try require(
                    UserWhiteBalanceAdjustment.self, .whiteBalance,
                    in: container, schemaVersion: version
                ),
                levels: try require(
                    UserLevelsAdjustment.self, .levels,
                    in: container, schemaVersion: version
                ),
                contrast: try require(
                    UserContrastAdjustment.self, .contrast,
                    in: container, schemaVersion: version
                )
            )
        }
    }

    /// Reads a field its version requires, refusing its absence.
    ///
    /// `decodeIfPresent` is used only to turn absence — or an explicit `null` —
    /// into the typed `missingField` refusal rather than a `DecodingError`. It
    /// never yields a default.
    private static func require<Value: Decodable, Key: CodingKey>(
        _ type: Value.Type,
        _ key: Key,
        in container: KeyedDecodingContainer<Key>,
        schemaVersion: Int
    ) throws -> Value {
        guard let value = try container.decodeIfPresent(type, forKey: key) else {
            throw PhotographProcessingStateError.missingField(
                field: key.stringValue, schemaVersion: schemaVersion
            )
        }
        return value
    }

    /// Refuses a field its version does not have.
    private static func refuse<Key: CodingKey>(
        _ key: Key,
        in container: KeyedDecodingContainer<Key>,
        schemaVersion: Int
    ) throws {
        guard !container.contains(key) else {
            throw PhotographProcessingStateError.unexpectedField(
                field: key.stringValue, schemaVersion: schemaVersion
            )
        }
    }
}
