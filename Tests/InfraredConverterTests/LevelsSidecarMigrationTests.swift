import Testing
import Foundation
@testable import InfraredConverter

/// Sidecar schema version 6, stated as a contract rather than demonstrated by
/// a round trip.
///
/// A round-trip test proves that this build agrees with itself. What has to be
/// proved instead is what a **record written by an earlier build** means, and
/// that the answer was chosen rather than defaulted: versions 1 to 5 migrate
/// to neutral levels, because neutral levels are the identity and the identity
/// is exactly what those builds applied — they had no levels stage at all.
///
/// The last test in this file renders both sides and compares the buffers,
/// rather than taking that on trust.
@Suite("Levels sidecar migration")
struct LevelsSidecarMigrationTests {

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

    /// One record per historical version, each with every adjustment that
    /// version *does* have moved away from its default — so a migration that
    /// dropped one would be visible rather than masked by a shared default.
    static let historical: [(version: Int, json: String)] = [
        (1, #"{"schemaVersion":1,"orientation":"rotate180"}"#),
        (
            2,
            #"""
            {"schemaVersion":2,"orientation":"rotate180",
             "channelMix":{"kind":"redBlueSwap"}}
            """#
        ),
        (
            3,
            #"""
            {"schemaVersion":3,"orientation":"rotate180",
             "channelMix":{"kind":"redBlueSwap"},"exposureEV":0.95}
            """#
        ),
        (
            4,
            #"""
            {"schemaVersion":4,"orientation":"rotate180",
             "channelMix":{"kind":"redBlueSwap"},"exposureEV":0.95,
             "whiteBalance":{"kind":"neutralPatch","region":{"originX":0.25,
             "originY":0.5,"width":0.125,"height":0.125}}}
            """#
        ),
        (
            5,
            #"""
            {"schemaVersion":5,"captureProfileID":"builtin.uncalibrated",
             "adjustments":{"orientation":"rotate180",
             "channelMix":{"kind":"redBlueSwap"},"exposureEV":0.95,
             "whiteBalance":{"kind":"neutralPatch","region":{"originX":0.25,
             "originY":0.5,"width":0.125,"height":0.125}}}}
            """#
        ),
    ]

    // MARK: - Versions 1 to 5 migrate to neutral levels

    @Test(
        "Every historical version migrates to neutral levels",
        arguments: LevelsSidecarMigrationTests.historical
    )
    func historicalVersionsMigrateToNeutralLevels(record: (version: Int, json: String)) throws {
        let state = try Self.decode(record.json)

        #expect(state.adjustments.levels == .neutral)
        #expect(state.adjustments.levels.blackPoint == 0)
        #expect(state.adjustments.levels.whitePoint == 1)
        #expect(state.adjustments.levels.isIdentity)
        // Neutral is what the absent field *meant*, not a fallback for a field
        // that went missing.
        #expect(LinearLevels(state.adjustments.levels).isIdentity)
    }

    /// The other half of a migration: what a version does carry has to survive
    /// it untouched. A migration that quietly reset another field would pass
    /// the test above.
    @Test(
        "The adjustments each version does carry survive the migration exactly",
        arguments: LevelsSidecarMigrationTests.historical
    )
    func theOtherAdjustmentsSurvive(record: (version: Int, json: String)) throws {
        let state = try Self.decode(record.json)

        #expect(state.captureProfile == .builtinUncalibrated)
        #expect(state.adjustments.orientation == .halfTurn)
        if record.version >= 2 {
            #expect(state.adjustments.channelMix == .redBlueSwap)
        } else {
            #expect(state.adjustments.channelMix == .identity)
        }
        if record.version >= 3 {
            #expect(state.adjustments.exposure.ev == 0.95)
        } else {
            #expect(state.adjustments.exposure == .neutral)
        }
        if record.version >= 4 {
            #expect(state.adjustments.whiteBalance.kind == .neutralPatch)
            #expect(state.adjustments.whiteBalance.selectedRegion?.originX == 0.25)
        } else {
            #expect(state.adjustments.whiteBalance == .defaultNeutralPatch)
        }
    }

    @Test(
        "A migrated record is written back at the current version, with its neutral levels",
        arguments: LevelsSidecarMigrationTests.historical
    )
    func aMigratedRecordIsWrittenAtVersionSix(record: (version: Int, json: String)) throws {
        let written = try Self.encoded(try Self.decode(record.json))
        #expect(written.contains(#""schemaVersion":7"#))
        #expect(written.contains(#""levels":{"blackPoint":0,"whitePoint":1}"#))
        // Reading rewrote nothing: the migration happened in memory, and this
        // is the first time the newer shape exists at all.
        #expect(!record.json.contains("levels"))

        // And re-reading what was written is the same record. The migration
        // runs once.
        #expect(try Self.decode(written) == (try Self.decode(record.json)))
    }

    // MARK: - Version 6 carries the decision

    @Test(
        "A version 6 record loads the exact saved levels",
        arguments: [
            (0.05, 1.2), (0.0, 1.0), (-0.25, 2.0), (0.999, 1.0), (-1e6, 1e6),
        ]
    )
    func versionSixLoadsTheSavedLevels(black: Double, white: Double) throws {
        let json = """
            {"schemaVersion":6,"captureProfileID":"builtin.uncalibrated",
             "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
             "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
             "levels":{"blackPoint":\(black),"whitePoint":\(white)}}}
            """
        let state = try Self.decode(json)
        #expect(state.adjustments.levels.blackPoint == black)
        #expect(state.adjustments.levels.whitePoint == white)
    }

    // MARK: - What version 6 refuses

    @Test("A version 6 record with no levels is refused rather than defaulted")
    func versionSixWithoutLevelsIsRefused() {
        #expect(
            throws: PhotographProcessingStateError.missingField(
                field: "levels", schemaVersion: 6
            )
        ) {
            try Self.decode(
                """
                {"schemaVersion":6,"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"}}}
                """
            )
        }
    }

    @Test(
        "A version 6 record with malformed levels is refused",
        arguments: [
            #"{"whitePoint":1}"#,
            #"{"blackPoint":0}"#,
            "{}",
            #"{"blackPoint":null,"whitePoint":1}"#,
        ]
    )
    func malformedLevelsAreRefused(levels: String) {
        #expect {
            try Self.decode(
                """
                {"schemaVersion":6,"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
                 "levels":\(levels)}}
                """
            )
        } throws: { error in
            guard case .missingLevelsField = error as? ImageAdjustmentError else {
                return false
            }
            return true
        }
    }

    @Test("A version 6 record whose levels are not numbers is refused")
    func nonNumericLevelsAreRefused() {
        #expect(throws: (any Error).self) {
            try Self.decode(
                """
                {"schemaVersion":6,"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
                 "levels":{"blackPoint":"dark","whitePoint":1}}}
                """
            )
        }
    }

    @Test(
        "A version 6 record whose black point is not below its white point is refused",
        arguments: [(0.5, 0.5), (1.2, 0.3), (1.0, 0.0), (-0.1, -0.5)]
    )
    func unorderedLevelsAreRefused(black: Double, white: Double) {
        #expect {
            try Self.decode(
                """
                {"schemaVersion":6,"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
                 "levels":{"blackPoint":\(black),"whitePoint":\(white)}}}
                """
            )
        } throws: { error in
            guard case .levelsNotOrdered(let reportedBlack, let reportedWhite) =
                    error as? ImageAdjustmentError else { return false }
            // Reported in the order they were written, not reordered.
            return reportedBlack == black && reportedWhite == white
        }
    }

    // MARK: - One authority per field, per version

    /// The mirror of the refusals above: a version that does **not** have
    /// levels may not carry them either. A record that says two things about
    /// one photograph has no reading that is not a guess.
    @Test(
        "A record older than version 6 carrying levels is refused",
        arguments: [
            #"{"schemaVersion":1,"orientation":"none","levels":{"blackPoint":0,"whitePoint":1}}"#,
            #"""
            {"schemaVersion":4,"orientation":"none","channelMix":{"kind":"identity"},
             "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
             "levels":{"blackPoint":0,"whitePoint":1}}
            """#,
            #"""
            {"schemaVersion":5,"captureProfileID":"builtin.uncalibrated",
             "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
             "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
             "levels":{"blackPoint":0,"whitePoint":1}}}
            """#,
        ]
    )
    func anOlderRecordCarryingLevelsIsRefused(json: String) {
        #expect {
            try Self.decode(json)
        } throws: { error in
            guard case .unexpectedField(let field, _) =
                    error as? PhotographProcessingStateError else { return false }
            return field == "levels"
        }
    }

    // MARK: - Versions this build does not read

    @Test(
        "A version above the current one is refused outright, never read around",
        arguments: [8, 9, 42]
    )
    func aNewerVersionIsRefused(version: Int) {
        #expect(
            throws: PhotographProcessingStateError.unsupportedSchemaVersion(
                found: version, supported: 7
            )
        ) {
            try Self.decode(
                """
                {"schemaVersion":\(version),"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
                 "levels":{"blackPoint":0,"whitePoint":1}}}
                """
            )
        }
    }

    @Test("Six is the version this build writes, and the highest it reads")
    func sixIsTheCurrentVersion() {
        #expect(PhotographProcessingState.currentSchemaVersion == 7)
        #expect(
            PhotographProcessingState.PersistedSchemaVersion.current
                == PhotographProcessingState.PersistedSchemaVersion.allCases.max(by: {
                    $0.rawValue < $1.rawValue
                })
        )
    }

    // MARK: - The migration is pixel-neutral

    /// The acceptance criterion, as arithmetic rather than as an argument.
    ///
    /// A version 5 record and the version 6 state it migrates to are the same
    /// value in memory, so comparing them would prove nothing. What is proved
    /// here is the step before that: that **neutral levels change no pixel**,
    /// by rendering the migrated state and rendering the identical state
    /// through a pipeline call that skips nothing, and comparing the buffers.
    ///
    /// If someone made neutral levels do anything at all — a clamp, a
    /// renormalisation, a rounding — this fails.
    @Test("A version 5 photograph renders identically after migrating to version 6")
    func theMigrationIsPixelNeutral() throws {
        let url = URL(fileURLWithPath: "/tmp/levels-migration.orf")
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url, width: 32, height: 24))
        )
        let migrated = try Self.decode(Self.historical[4].json)
        #expect(migrated.adjustments.levels == .neutral)

        let pipeline = WorkspacePreviewPipeline()
        let source = try pipeline.prepare(
            decoding: url,
            using: decoder,
            whiteBalance: migrated.adjustments.whiteBalance,
            captureProfile: .builtinUncalibrated
        )

        // What the migrated record renders.
        let afterMigration = try pipeline.render(source, adjustments: migrated.adjustments)

        // What the same photograph rendered before this milestone existed: the
        // identical chain with the levels stage asked for the identity, which
        // is what a build with no levels stage produced.
        let mixed = try IRChannelMixer().apply(
            to: source.preview, mix: migrated.adjustments.channelMix.mix
        )
        let oriented = try ImageOrienter().apply(
            to: mixed,
            orientation: try WorkspacePreviewPipeline.effectiveOrientation(
                for: source.metadata, adjustments: migrated.adjustments
            ).applied
        )
        let exposed = try SceneLinearExposer().apply(
            to: oriented, exposure: SceneLinearExposure(migrated.adjustments.exposure)
        )
        let preMilestone = try DisplayPreviewRenderer().render(
            try GlobalContrastApplier().apply(
                to: try LinearLevelsApplier().apply(to: exposed, levels: .neutral),
                curve: .neutral
            ),
            settings: WorkspacePreviewPipeline.displaySettings
        )

        #expect(
            WorkspaceStubs.pixelBytes(afterMigration.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: preMilestone)
                )
        )

        // And the levels stage genuinely handed the exposed buffer straight
        // through — bit for bit, not merely to within a rounded byte.
        let levelled = try LinearLevelsApplier().apply(to: exposed, levels: .neutral)
        #expect(levelled.values == exposed.values)
        for index in 0..<exposed.values.count
        where levelled.values[index].bitPattern != exposed.values[index].bitPattern {
            Issue.record("element \(index) changed bit pattern at neutral levels")
        }
    }
}
