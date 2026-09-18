import Testing
import Foundation
@testable import InfraredConverter

/// Sidecar schema version 7, stated as a contract rather than demonstrated by
/// a round trip.
///
/// A round-trip test proves that this build agrees with itself. What has to be
/// proved instead is what a **record written by an earlier build** means, and
/// that the answer was chosen rather than defaulted: versions 1 to 6 migrate
/// to neutral contrast, because a neutral amount gives an exponent of exactly
/// `1` and the identity is exactly what those builds applied — they had no
/// contrast stage at all.
///
/// The last test in this file renders both sides and compares the buffers,
/// rather than taking that on trust.
@Suite("Contrast sidecar migration")
struct ContrastSidecarMigrationTests {

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
        (
            6,
            #"""
            {"schemaVersion":6,"captureProfileID":"builtin.uncalibrated",
             "adjustments":{"orientation":"rotate180",
             "channelMix":{"kind":"redBlueSwap"},"exposureEV":0.95,
             "whiteBalance":{"kind":"neutralPatch","region":{"originX":0.25,
             "originY":0.5,"width":0.125,"height":0.125}},
             "levels":{"blackPoint":0.05,"whitePoint":1.2}}}
            """#
        ),
    ]

    // MARK: - Versions 1 to 6 migrate to neutral contrast

    @Test(
        "Every historical version migrates to neutral contrast",
        arguments: ContrastSidecarMigrationTests.historical
    )
    func historicalVersionsMigrateToNeutral(record: (version: Int, json: String)) throws {
        let state = try Self.decode(record.json)

        #expect(state.adjustments.contrast == .neutral)
        #expect(state.adjustments.contrast.amount == 0)
        #expect(state.adjustments.contrast.isIdentity)
        // Neutral is what the absent field *meant*, not a fallback for a field
        // that went missing.
        #expect(GlobalContrastCurve(state.adjustments.contrast).isIdentity)
        #expect(GlobalContrastCurve(state.adjustments.contrast).exponent == 1)
    }

    /// The other half of a migration: what a version does carry has to survive
    /// it untouched. A migration that quietly reset another field would pass
    /// the test above.
    @Test(
        "The adjustments each version does carry survive the migration exactly",
        arguments: ContrastSidecarMigrationTests.historical
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
        if record.version >= 6 {
            #expect(state.adjustments.levels.blackPoint == 0.05)
            #expect(state.adjustments.levels.whitePoint == 1.2)
        } else {
            #expect(state.adjustments.levels == .neutral)
        }
    }

    @Test(
        "A migrated record is written back at version 7, with its neutral contrast",
        arguments: ContrastSidecarMigrationTests.historical
    )
    func aMigratedRecordIsWrittenAtVersionSeven(
        record: (version: Int, json: String)
    ) throws {
        let written = try Self.encoded(try Self.decode(record.json))
        #expect(written.contains(#""schemaVersion":7"#))
        #expect(written.contains(#""contrast":0"#))
        // Reading rewrote nothing: the migration happened in memory, and this
        // is the first time the newer shape exists at all.
        #expect(!record.json.contains("contrast"))

        // And re-reading what was written is the same record. The migration
        // runs once.
        #expect(try Self.decode(written) == (try Self.decode(record.json)))
    }

    // MARK: - What version 7 reads

    @Test(
        "A version 7 record loads the exact saved amount",
        arguments: [-1.0, -0.5, -0.001, 0.0, 0.001, 0.35, 0.355, 1.0]
    )
    func versionSevenLoadsTheSavedAmount(amount: Double) throws {
        let json = """
            {"schemaVersion":7,"captureProfileID":"builtin.uncalibrated",
             "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
             "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
             "levels":{"blackPoint":0,"whitePoint":1},"contrast":\(amount)}}
            """
        let state = try Self.decode(json)
        #expect(state.adjustments.contrast.amount == amount)
        // Not rounded to the slider's hundredths.
        #expect(GlobalContrastCurve(state.adjustments.contrast).exponent == exp2(amount))
    }

    // MARK: - What version 7 refuses

    @Test("A version 7 record with no contrast is refused rather than defaulted")
    func versionSevenWithoutContrastIsRefused() {
        #expect(
            throws: PhotographProcessingStateError.missingField(
                field: "contrast", schemaVersion: 7
            )
        ) {
            try Self.decode(
                """
                {"schemaVersion":7,"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
                 "levels":{"blackPoint":0,"whitePoint":1}}}
                """
            )
        }
    }

    @Test("An explicit null contrast is refused, exactly as absence is")
    func aNullContrastIsRefused() {
        #expect(
            throws: PhotographProcessingStateError.missingField(
                field: "contrast", schemaVersion: 7
            )
        ) {
            try Self.decode(Self.versionSeven(contrast: "null"))
        }
    }

    @Test(
        "A non-numeric contrast is refused",
        arguments: [#""0.5""#, "true", "[0.5]", "{\"amount\":0.5}"]
    )
    func aNonNumericContrastIsRefused(literal: String) {
        #expect(throws: (any Error).self) {
            try Self.decode(Self.versionSeven(contrast: literal))
        }
    }

    @Test(
        "A contrast outside the supported range is refused rather than clamped",
        arguments: [-1.5, -1.000_001, 1.000_001, 1.5, 50.0]
    )
    func anOutOfRangeContrastIsRefused(amount: Double) {
        #expect(throws: ImageAdjustmentError.self) {
            try Self.decode(Self.versionSeven(contrast: "\(amount)"))
        }
    }

    /// One authority per field. A pre-version-7 record carrying `contrast`
    /// says two different things about one photograph — the field, and the
    /// version that says there is no such field — and there is no reading of
    /// it that is not a guess.
    @Test(
        "A record before version 7 carrying a contrast field is refused",
        arguments: [1, 2, 3, 4]
    )
    func anEarlyRecordWithContrastIsRefused(version: Int) {
        // Each record carries exactly the fields its own version has, plus
        // `contrast` — so the refusal that fires is the one about `contrast`
        // and not about some other field the version never had.
        let mix = version >= 2 ? #""channelMix":{"kind":"identity"},"# : ""
        let exposure = version >= 3 ? #""exposureEV":0,"# : ""
        let balance = version >= 4 ? #""whiteBalance":{"kind":"defaultNeutralPatch"},"# : ""
        #expect {
            try Self.decode(
                """
                {"schemaVersion":\(version),"orientation":"none",
                 \(mix)\(exposure)\(balance)"contrast":0.5}
                """
            )
        } throws: { error in
            guard case .unexpectedField(let field, _) =
                    error as? PhotographProcessingStateError else { return false }
            return field == "contrast"
        }
    }

    @Test(
        "A nested version 5 or 6 record carrying a contrast field is refused",
        arguments: [5, 6]
    )
    func aNestedEarlyRecordWithContrastIsRefused(version: Int) {
        #expect {
            try Self.decode(
                """
                {"schemaVersion":\(version),"captureProfileID":"builtin.uncalibrated",
                 "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
                 "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
                 \(version == 6 ? #""levels":{"blackPoint":0,"whitePoint":1},"# : "")
                 "contrast":0.5}}
                """
            )
        } throws: { error in
            guard case .unexpectedField(let field, _) =
                    error as? PhotographProcessingStateError else { return false }
            return field == "contrast"
        }
    }

    // MARK: - Versions this build does not read

    @Test(
        "A version above 7 is refused outright, never read around",
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
                 "levels":{"blackPoint":0,"whitePoint":1},"contrast":0}}
                """
            )
        }
    }

    // MARK: - The migration is pixel-neutral

    /// The claim the migration rests on, checked rather than asserted: a
    /// version 6 photograph renders after this milestone exactly as it did
    /// before it.
    @Test("A migrated version 6 record renders the pre-milestone image exactly")
    func theMigrationIsPixelNeutral() throws {
        let url = URL(fileURLWithPath: "/tmp/contrast-migration.orf")
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url, width: 32, height: 24))
        )
        let migrated = try Self.decode(Self.historical[5].json)
        #expect(migrated.adjustments.contrast == .neutral)
        #expect(migrated.adjustments.levels.blackPoint == 0.05)

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
        // identical chain, stopping at the levels, which is what a build with
        // no contrast stage produced.
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
        let levelled = try LinearLevelsApplier().apply(
            to: exposed, levels: LinearLevels(migrated.adjustments.levels)
        )
        let preMilestone = try DisplayPreviewRenderer().render(
            try GlobalContrastApplier().apply(to: levelled, curve: .neutral),
            settings: WorkspacePreviewPipeline.displaySettings
        )

        #expect(
            WorkspaceStubs.pixelBytes(afterMigration.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: preMilestone)
                )
        )

        // And the contrast stage genuinely handed the levelled buffer straight
        // through — bit for bit, not merely to within a rounded byte.
        let curved = try GlobalContrastApplier().apply(to: levelled, curve: .neutral)
        #expect(curved.values == levelled.values)
        for index in 0..<levelled.values.count
        where curved.values[index].bitPattern != levelled.values[index].bitPattern {
            Issue.record("element \(index) changed bit pattern at neutral contrast")
        }
    }

    // MARK: - Helpers

    private static func versionSeven(contrast literal: String) -> String {
        """
        {"schemaVersion":7,"captureProfileID":"builtin.uncalibrated",
         "adjustments":{"orientation":"none","channelMix":{"kind":"identity"},
         "exposureEV":0,"whiteBalance":{"kind":"defaultNeutralPatch"},
         "levels":{"blackPoint":0,"whitePoint":1},"contrast":\(literal)}}
        """
    }
}
