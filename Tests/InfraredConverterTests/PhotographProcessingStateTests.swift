import Testing
import Foundation
@testable import InfraredConverter

/// The photograph's complete application-owned state, and the sidecar wire
/// format that carries it.
///
/// This suite owns what `ImageAdjustments` used to: the schema version, the
/// migrations, and the policy applied to a record this build cannot read.
@Suite("PhotographProcessingState")
struct PhotographProcessingStateTests {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func decode(_ json: String) throws -> PhotographProcessingState {
        try JSONDecoder().decode(PhotographProcessingState.self, from: Data(json.utf8))
    }

    private static func encoded(_ state: PhotographProcessingState) throws -> String {
        String(decoding: try encoder.encode(state), as: UTF8.self)
    }

    // MARK: - The two halves

    @Test("A fresh state is the built-in uncalibrated profile and no decisions")
    func aFreshStateIsTheDefault() {
        let state = PhotographProcessingState.none
        #expect(state.captureProfile == .builtinUncalibrated)
        #expect(state.adjustments == .none)
        #expect(state.isDefault)
        #expect(PhotographProcessingState.currentSchemaVersion == 5)
    }

    /// The document-level default is both halves, and either one can answer no.
    @Test("Either half away from its default stops the state being default")
    func isDefaultCoversBothHalves() throws {
        let otherProfile = try IRCaptureProfileID("user.something-else")
        #expect(
            !PhotographProcessingState(captureProfile: otherProfile).isDefault
        )
        #expect(
            !PhotographProcessingState(
                adjustments: ImageAdjustments(orientation: .halfTurn)
            ).isDefault
        )
        // And the adjustments half is unchanged by the profile half: it knows
        // nothing about profiles and is not asked to.
        #expect(PhotographProcessingState(captureProfile: otherProfile).adjustments.isDefault)
    }

    // MARK: - The version 5 wire format

    @Test("The encoded shape is the documented one")
    func theEncodedShapeIsStable() throws {
        #expect(
            try Self.encoded(
                PhotographProcessingState(
                    adjustments: ImageAdjustments(orientation: .quarterTurnRight)
                )
            )
                == #"{"adjustments":{"channelMix":{"kind":"identity"},"exposureEV":0,"orientation":"rotate90Clockwise","whiteBalance":{"kind":"defaultNeutralPatch"}},"captureProfileID":"builtin.uncalibrated","schemaVersion":5}"#
        )

        // The profile is a bare string: matching is exact and its parts are a
        // convention for humans, not something a reader interprets.
        #expect(
            try Self.encoded(
                PhotographProcessingState(
                    captureProfile: try IRCaptureProfileID("user.epl3-720nm"),
                    adjustments: ImageAdjustments(
                        channelMix: .redBlueSwap,
                        exposure: try UserExposureAdjustment(ev: 1.25)
                    )
                )
            )
                == #"{"adjustments":{"channelMix":{"kind":"redBlueSwap"},"exposureEV":1.25,"orientation":"none","whiteBalance":{"kind":"defaultNeutralPatch"}},"captureProfileID":"user.epl3-720nm","schemaVersion":5}"#
        )

        // A built-in mix's nine numbers are derived from its token and are
        // deliberately not written.
        #expect(
            !(try Self.encoded(
                PhotographProcessingState(
                    adjustments: ImageAdjustments(channelMix: .redBlueSwap)
                )
            )).contains("matrix")
        )

        let explicit = try Self.encoded(
            PhotographProcessingState(
                adjustments: ImageAdjustments(
                    channelMix: try UserChannelMixAdjustment.explicit(
                        persistedMatrix: [0, 0, 1, 0, 1, 0, 1, 0, 0]
                    )
                )
            )
        )
        #expect(explicit.contains(#""matrix":[0,0,1,0,1,0,1,0,0]"#))
    }

    @Test("A version 5 record round-trips exactly")
    func aVersionFiveRecordRoundTrips() throws {
        let states: [PhotographProcessingState] = [
            .none,
            PhotographProcessingState(
                captureProfile: try IRCaptureProfileID("user.a-profile"),
                adjustments: ImageAdjustments(
                    orientation: .antiDiagonalFlip,
                    channelMix: try UserChannelMixAdjustment.explicit(
                        persistedMatrix: [0.25, -1, 2, 0, 0.5, 0, 3, 0, -0.75]
                    ),
                    exposure: try UserExposureAdjustment(ev: -0.05),
                    whiteBalance: .neutralPatch(
                        try NormalizedActiveAreaRegion(
                            originX: 0.25, originY: 0.5, width: 0.125, height: 0.0625
                        )
                    )
                )
            ),
        ]
        for state in states {
            let bytes = try Self.encoder.encode(state)
            let decoded = try JSONDecoder().decode(
                PhotographProcessingState.self, from: bytes
            )
            #expect(decoded == state)
            // Deterministic: the same state encodes to the same bytes every
            // time, not merely to an equivalent object.
            #expect(try Self.encoder.encode(decoded) == bytes)
            #expect(try Self.encoder.encode(state) == bytes)
        }
    }

    @Test("Every orientation and every channel mix round-trips inside the record")
    func everyAdjustmentValueRoundTrips() throws {
        let mixes: [UserChannelMixAdjustment] = [
            .identity,
            .redBlueSwap,
            try UserChannelMixAdjustment.explicit(
                persistedMatrix: [0.1, 0.2, 0.3, -0.4, 1.5, 0.6, 0.7, 0.8, -0.9]
            ),
        ]
        for orientation in UserOrientationAdjustment.allCases {
            for mix in mixes {
                let state = PhotographProcessingState(
                    adjustments: ImageAdjustments(orientation: orientation, channelMix: mix)
                )
                let decoded = try JSONDecoder().decode(
                    PhotographProcessingState.self, from: try Self.encoder.encode(state)
                )
                #expect(decoded == state)
                #expect(decoded.adjustments.orientation.transform == orientation.transform)
                #expect(decoded.adjustments.channelMix.matrix == mix.matrix)
            }
        }
    }

    @Test(
        "A version 3 exposure survives to bit-pattern precision",
        arguments: [-10.0, -2.5, -0.05, 0, 0.1, 0.73000001, 1.25, 4.5, 10]
    )
    func anExposureIsNotRoundedOnTheWayThrough(ev: Double) throws {
        let state = PhotographProcessingState(
            adjustments: ImageAdjustments(exposure: try UserExposureAdjustment(ev: ev))
        )
        let decoded = try JSONDecoder().decode(
            PhotographProcessingState.self, from: try Self.encoder.encode(state)
        )
        #expect(decoded == state)
        #expect(decoded.adjustments.exposure.ev.bitPattern == ev.bitPattern)
    }

    // MARK: - The set of readable versions is closed

    /// The migration switches over `PersistedSchemaVersion` with no `default`,
    /// which is what makes adding a version a compile error there. That
    /// guarantee holds only while the enum and the numbers agree, so the
    /// agreement is pinned here: the cases are exactly `1...current`, with no
    /// gap, and `current` is the highest of them.
    @Test("The readable schema versions are exactly 1 through the current one")
    func theReadableVersionsAreClosedAndContiguous() {
        let raw = PhotographProcessingState.PersistedSchemaVersion.allCases.map(\.rawValue)
        #expect(raw == Array(1...PhotographProcessingState.currentSchemaVersion))
        #expect(
            PhotographProcessingState.PersistedSchemaVersion.current
                == PhotographProcessingState.PersistedSchemaVersion.allCases.last
        )
        #expect(PhotographProcessingState.PersistedSchemaVersion.first.rawValue == 1)
    }

    /// Which versions keep the adjustments at the top level, and which nest
    /// them. Pinned because the migration reads a different container for each.
    @Test("Versions 1 to 4 are flat and version 5 nests")
    func theLayoutBoundaryIsWhereItIsDocumented() {
        for version in PhotographProcessingState.PersistedSchemaVersion.allCases {
            #expect(version.storesAdjustmentsAtTopLevel == (version.rawValue <= 4))
        }
    }

    // MARK: - The migrations

    @Test(
        "A version 1 record reads as itself, migrated to the built-in profile",
        arguments: UserOrientationAdjustment.allCases
    )
    func aVersionOneRecordMigrates(orientation: UserOrientationAdjustment) throws {
        let decoded = try Self.decode(
            #"{"schemaVersion":1,"orientation":"\#(orientation.persistedToken)"}"#
        )
        #expect(decoded.adjustments.orientation == orientation)
        // Migrations, not defaults for missing fields: version 1 rendered no
        // creative remapping, at 0 EV, from the default centred patch, through
        // the identity false-colour axis assignment — which is exactly what
        // `builtin.uncalibrated` names.
        #expect(decoded.adjustments.channelMix == .identity)
        #expect(decoded.adjustments.exposure == .neutral)
        #expect(decoded.adjustments.whiteBalance == .defaultNeutralPatch)
        #expect(decoded.captureProfile == .builtinUncalibrated)
        #expect(
            decoded
                == PhotographProcessingState(
                    adjustments: ImageAdjustments(orientation: orientation)
                )
        )
    }

    @Test(
        "A version 2 record keeps its mix and migrates the rest",
        arguments: ["identity", "redBlueSwap"]
    )
    func aVersionTwoRecordMigrates(kind: String) throws {
        let decoded = try Self.decode(
            #"{"schemaVersion":2,"orientation":"rotate270Clockwise","channelMix":{"kind":"\#(kind)"}}"#
        )
        #expect(decoded.adjustments.orientation == .quarterTurnLeft)
        #expect(decoded.adjustments.channelMix.kind.rawValue == kind)
        #expect(decoded.adjustments.exposure == .neutral)
        #expect(decoded.adjustments.whiteBalance == .defaultNeutralPatch)
        #expect(decoded.captureProfile == .builtinUncalibrated)
    }

    @Test("A version 3 record keeps its exposure and migrates the rest")
    func aVersionThreeRecordMigrates() throws {
        let decoded = try Self.decode(
            #"""
            {"schemaVersion":3,"orientation":"transposeMainDiagonal",
             "channelMix":{"kind":"redBlueSwap"},"exposureEV":-0.5}
            """#
        )
        #expect(decoded.adjustments.orientation == .diagonalFlip)
        #expect(decoded.adjustments.channelMix == .redBlueSwap)
        #expect(decoded.adjustments.exposure.ev == -0.5)
        // The one migration worth stating out loud: the *same deterministic
        // centred patch*, not identity gains. Identity gains would open every
        // previously saved photograph with a different white balance.
        #expect(decoded.adjustments.whiteBalance == .defaultNeutralPatch)
        #expect(decoded.captureProfile == .builtinUncalibrated)
    }

    @Test("A version 4 record keeps all four adjustments and migrates the profile")
    func aVersionFourRecordMigrates() throws {
        let decoded = try Self.decode(
            #"""
            {"schemaVersion":4,"orientation":"rotate180",
             "channelMix":{"kind":"redBlueSwap"},"exposureEV":-0.5,
             "whiteBalance":{"kind":"neutralPatch","region":{"originX":0.25,
             "originY":0.5,"width":0.125,"height":0.0625}}}
            """#
        )
        #expect(
            decoded
                == PhotographProcessingState(
                    captureProfile: .builtinUncalibrated,
                    adjustments: ImageAdjustments(
                        orientation: .halfTurn,
                        channelMix: .redBlueSwap,
                        exposure: try UserExposureAdjustment(ev: -0.5),
                        whiteBalance: .neutralPatch(
                            try NormalizedActiveAreaRegion(
                                originX: 0.25, originY: 0.5, width: 0.125, height: 0.0625
                            )
                        )
                    )
                )
        )
    }

    /// A migrated record is written back at version 5, in the nested shape,
    /// with the profile it was migrated to — and re-reading that is the same
    /// record. The migration runs once.
    @Test(
        "Every historical version is written back as a version 5 record",
        arguments: [
            #"{"schemaVersion":1,"orientation":"rotate180"}"#,
            #"{"schemaVersion":2,"orientation":"rotate180","channelMix":{"kind":"identity"}}"#,
            #"""
            {"schemaVersion":3,"orientation":"rotate180",
             "channelMix":{"kind":"identity"},"exposureEV":0}
            """#,
            #"""
            {"schemaVersion":4,"orientation":"rotate180",
             "channelMix":{"kind":"identity"},"exposureEV":0,
             "whiteBalance":{"kind":"defaultNeutralPatch"}}
            """#,
        ]
    )
    func aMigratedRecordIsWrittenAtTheCurrentVersion(json: String) throws {
        let decoded = try Self.decode(json)
        #expect(
            try Self.encoded(decoded)
                == #"{"adjustments":{"channelMix":{"kind":"identity"},"exposureEV":0,"orientation":"rotate180","whiteBalance":{"kind":"defaultNeutralPatch"}},"captureProfileID":"builtin.uncalibrated","schemaVersion":5}"#
        )
        let reread = try JSONDecoder().decode(
            PhotographProcessingState.self, from: try Self.encoder.encode(decoded)
        )
        #expect(reread == decoded)
    }

    // MARK: - One authority per field

    /// The wire format's own version of "no duplicate authorities". A version 5
    /// record that also carries adjustments at the top level says two things
    /// about one photograph, and there is no reading of it that is not a guess.
    @Test(
        "A version 5 record carrying top-level adjustments is refused",
        arguments: ["orientation", "channelMix", "exposureEV", "whiteBalance"]
    )
    func aVersionFiveRecordWithFlatAdjustmentsIsRefused(field: String) {
        let stray: String
        switch field {
        case "orientation": stray = #""orientation":"none""#
        case "channelMix": stray = #""channelMix":{"kind":"identity"}"#
        case "exposureEV": stray = #""exposureEV":0"#
        default: stray = #""whiteBalance":{"kind":"defaultNeutralPatch"}"#
        }
        let json = #"""
            {"schemaVersion":5,"captureProfileID":"builtin.uncalibrated",\#(stray),
             "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
             "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"}}}
            """#
        #expect(
            throws: PhotographProcessingStateError.unexpectedField(
                field: field, schemaVersion: 5
            )
        ) {
            try Self.decode(json)
        }
    }

    /// And the other direction: a historical record carrying version 5's
    /// fields is not a historical record.
    @Test(
        "A historical record carrying version 5 fields is refused",
        arguments: [1, 2, 3, 4]
    )
    func aHistoricalRecordWithVersionFiveFieldsIsRefused(version: Int) {
        #expect(
            throws: PhotographProcessingStateError.unexpectedField(
                field: "captureProfileID", schemaVersion: version
            )
        ) {
            try Self.decode(
                #"""
                {"schemaVersion":\#(version),"orientation":"none",
                 "captureProfileID":"builtin.uncalibrated"}
                """#
            )
        }
    }

    /// Field strictness per version. An image-affecting field is never quietly
    /// defaulted because it is absent, and never quietly ignored because its
    /// version predates it.
    @Test(
        "Each version's fields are exactly its own",
        arguments: [
            (#"{"schemaVersion":1,"orientation":"none","channelMix":{"kind":"identity"}}"#,
             PhotographProcessingStateError.unexpectedField(field: "channelMix", schemaVersion: 1)),
            (#"{"schemaVersion":1,"orientation":"none","exposureEV":0}"#,
             PhotographProcessingStateError.unexpectedField(field: "exposureEV", schemaVersion: 1)),
            (#"{"schemaVersion":2,"orientation":"none","channelMix":{"kind":"identity"},"exposureEV":0.5}"#,
             PhotographProcessingStateError.unexpectedField(field: "exposureEV", schemaVersion: 2)),
            (#"{"schemaVersion":3,"orientation":"none","channelMix":{"kind":"identity"}}"#,
             PhotographProcessingStateError.missingField(field: "exposureEV", schemaVersion: 3)),
            (#"{"schemaVersion":3,"orientation":"none","channelMix":{"kind":"identity"},"exposureEV":null}"#,
             PhotographProcessingStateError.missingField(field: "exposureEV", schemaVersion: 3)),
            (#"{"schemaVersion":3,"orientation":"none","exposureEV":0.5}"#,
             PhotographProcessingStateError.missingField(field: "channelMix", schemaVersion: 3)),
            (#"{"schemaVersion":3,"channelMix":{"kind":"identity"},"exposureEV":0.5}"#,
             PhotographProcessingStateError.missingField(field: "orientation", schemaVersion: 3)),
            (#"{"schemaVersion":4,"orientation":"none","channelMix":{"kind":"identity"},"exposureEV":0}"#,
             PhotographProcessingStateError.missingField(field: "whiteBalance", schemaVersion: 4)),
        ]
    )
    func eachVersionsFieldsAreExactlyItsOwn(
        json: String, refusal: PhotographProcessingStateError
    ) {
        #expect(throws: refusal) { try Self.decode(json) }
    }

    // MARK: - Version 5's own required fields

    @Test("A version 5 record with no capture profile is refused")
    func aVersionFiveRecordWithoutAProfileIsRefused() {
        #expect(
            throws: PhotographProcessingStateError.missingField(
                field: "captureProfileID", schemaVersion: 5
            )
        ) {
            try Self.decode(
                #"""
                {"schemaVersion":5,"adjustments":{"orientation":"none",
                 "channelMix":{"kind":"identity"},"exposureEV":0,
                 "whiteBalance":{"kind":"defaultNeutralPatch"}}}
                """#
            )
        }
    }

    @Test("A version 5 record with no adjustments object is refused")
    func aVersionFiveRecordWithoutAdjustmentsIsRefused() {
        #expect(
            throws: PhotographProcessingStateError.missingField(
                field: "adjustments", schemaVersion: 5
            )
        ) {
            try Self.decode(
                #"{"schemaVersion":5,"captureProfileID":"builtin.uncalibrated"}"#
            )
        }
    }

    @Test("A version 5 record missing an adjustment inside the object is refused")
    func aVersionFiveRecordWithAnIncompleteObjectIsRefused() {
        #expect(
            throws: PhotographProcessingStateError.missingField(
                field: "whiteBalance", schemaVersion: 5
            )
        ) {
            try Self.decode(
                #"""
                {"schemaVersion":5,"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0}}
                """#
            )
        }
    }

    /// A reference to a profile this machine does not have is **well formed**.
    /// Whether it resolves is a different question, asked later, by the
    /// registry — and answered by refusing the open rather than by silently
    /// substituting another profile.
    @Test("An unknown but well-formed profile reference decodes")
    func anUnknownProfileReferenceDecodes() throws {
        let decoded = try Self.decode(
            #"""
            {"schemaVersion":5,"captureProfileID":"user.does-not-exist",
             "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
             "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"}}}
            """#
        )
        #expect(decoded.captureProfile.rawValue == "user.does-not-exist")
        #expect(!IRCaptureProfileRegistry.builtin.contains(decoded.captureProfile))
    }

    @Test(
        "A malformed profile reference is refused by the identifier itself",
        arguments: ["", "uncalibrated", "Builtin.Uncalibrated", "builtin.", ".uncalibrated",
                    "builtin.unca librated", "builtin.unca/librated"]
    )
    func aMalformedProfileReferenceIsRefused(token: String) {
        #expect(throws: IRCaptureProfileError.self) {
            try Self.decode(
                #"""
                {"schemaVersion":5,"captureProfileID":"\#(token)",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"}}}
                """#
            )
        }
    }

    // MARK: - Refusals about the version itself

    @Test(
        "A newer schema version is refused rather than partly applied",
        arguments: [6, 7, 99]
    )
    func aNewerSchemaVersionIsRefused(version: Int) {
        #expect(
            throws: PhotographProcessingStateError.unsupportedSchemaVersion(
                found: version, supported: 5
            )
        ) {
            try Self.decode(
                #"""
                {"schemaVersion":\#(version),"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"}},
                 "toneCurve":[0,1]}
                """#
            )
        }
    }

    @Test("A schema version below one is refused", arguments: [0, -1, -7])
    func anImpossibleSchemaVersionIsRefused(version: Int) {
        #expect(
            throws: PhotographProcessingStateError.unsupportedSchemaVersion(
                found: version, supported: 5
            )
        ) {
            try Self.decode(#"{"schemaVersion":\#(version),"orientation":"none"}"#)
        }
    }

    @Test("A missing schema version is refused")
    func aMissingSchemaVersionIsRefused() {
        #expect(
            throws: PhotographProcessingStateError.missingField(
                field: "schemaVersion", schemaVersion: 0
            )
        ) {
            try Self.decode(#"{"orientation":"none"}"#)
        }
    }

    /// Extensibility is the reason this is a record, so a field this version
    /// does not know about is read past — **when ignoring it cannot change the
    /// photograph**. A note can be; an adjustment cannot, which is why the
    /// previous test's `toneCurve` arrives with a version bump.
    @Test("An unknown non-semantic field at a readable version is ignored")
    func unknownNonSemanticFieldsAreIgnored() throws {
        let decoded = try Self.decode(
            #"""
            {"schemaVersion":5,"captureProfileID":"builtin.uncalibrated",
             "note":"scanned by hand",
             "adjustments":{"orientation":"flipVertical","channelMix":{"kind":"identity"},
             "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"}}}
            """#
        )
        #expect(decoded.adjustments.orientation == .verticalFlip)
        #expect(decoded.captureProfile == .builtinUncalibrated)
    }

    // MARK: - Refusals about adjustment values

    /// The policy that matters most: a corrupt record never decodes into "the
    /// user asked for nothing". That would discard their edit and present the
    /// result as a deliberate choice.
    @Test("An unreadable orientation token is refused, never read as identity")
    func anUnreadableTokenNeverBecomesIdentity() {
        let json = #"{"schemaVersion":2,"orientation":"rotateSideways","channelMix":{"kind":"identity"}}"#
        #expect(
            throws: ImageAdjustmentError.unknownOrientationAdjustment(token: "rotateSideways")
        ) {
            try Self.decode(json)
        }
        #expect((try? Self.decode(json)) == nil)
    }

    @Test("An unreadable channel-mix kind is refused, never read as identity")
    func anUnknownMixKindIsRefused() {
        #expect(throws: ImageAdjustmentError.unknownChannelMixKind(token: "aerochrome")) {
            try Self.decode(
                #"{"schemaVersion":2,"orientation":"none","channelMix":{"kind":"aerochrome"}}"#
            )
        }
    }

    @Test("A channel mix with no kind is refused")
    func aMixWithNoKindIsRefused() {
        #expect(throws: ImageAdjustmentError.missingChannelMixField(field: "kind")) {
            try Self.decode(#"{"schemaVersion":2,"orientation":"none","channelMix":{}}"#)
        }
    }

    @Test("An explicit mix with no matrix is refused")
    func anExplicitMixWithNoMatrixIsRefused() {
        #expect(throws: ImageAdjustmentError.missingChannelMixField(field: "matrix")) {
            try Self.decode(
                #"{"schemaVersion":2,"orientation":"none","channelMix":{"kind":"matrix"}}"#
            )
        }
    }

    @Test(
        "A matrix that is not nine coefficients is refused",
        arguments: [[Double](), [1], Array(repeating: 1.0, count: 8),
                    Array(repeating: 1.0, count: 10)]
    )
    func aMalformedMatrixIsRefused(coefficients: [Double]) {
        let list = coefficients.map { String($0) }.joined(separator: ",")
        #expect(
            throws: ImageAdjustmentError.malformedChannelMixMatrix(
                coefficientCount: coefficients.count, expected: 9
            )
        ) {
            try Self.decode(
                #"""
                {"schemaVersion":2,"orientation":"none",
                 "channelMix":{"kind":"matrix","matrix":[\#(list)]}}
                """#
            )
        }
    }

    @Test(
        "An exposure outside the supported range is refused, not clamped",
        arguments: [10.000001, -10.5, 11, -100, 1e300]
    )
    func anOutOfRangeExposureIsRefused(ev: Double) {
        #expect(
            throws: ImageAdjustmentError.exposureAdjustmentOutOfRange(
                ev: ev, supported: UserExposureAdjustment.supportedRange
            )
        ) {
            try Self.decode(
                #"""
                {"schemaVersion":3,"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":\#(ev)}
                """#
            )
        }
    }

    @Test("An exposure that is not a number is refused as undecodable")
    func aNonNumericExposureIsRefused() {
        #expect(throws: DecodingError.self) {
            try Self.decode(
                #"""
                {"schemaVersion":3,"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":"+1 EV"}
                """#
            )
        }
    }

    @Test("The record's refusals carry readable reasons")
    func theRefusalsAreInformative() {
        let version = PhotographProcessingStateError.unsupportedSchemaVersion(
            found: 9, supported: 5
        )
        #expect(version.errorDescription?.isEmpty == false)
        #expect(version.failureReason?.contains("9") == true)

        let older = PhotographProcessingStateError.unsupportedSchemaVersion(
            found: 0, supported: 5
        )
        #expect(older.failureReason?.contains("no version") == true)

        let missing = PhotographProcessingStateError.missingField(
            field: "captureProfileID", schemaVersion: 5
        )
        #expect(missing.errorDescription?.isEmpty == false)
        #expect(missing.failureReason?.contains("captureProfileID") == true)

        let unexpected = PhotographProcessingStateError.unexpectedField(
            field: "channelMix", schemaVersion: 1
        )
        #expect(unexpected.errorDescription?.isEmpty == false)
        #expect(unexpected.failureReason?.contains("channelMix") == true)
    }
}
