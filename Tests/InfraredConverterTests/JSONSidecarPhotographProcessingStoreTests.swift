import Testing
import Foundation
@testable import InfraredConverter

/// The sidecar store on its own: naming, round-tripping, refusals, atomicity,
/// and the one rule the whole project rests on — the RAW file is never
/// touched.
///
/// The payload widened from `ImageAdjustments` alone to
/// `PhotographProcessingState` — a capture-profile reference plus the
/// adjustments — when the sidecar stopped being an adjustments-only file. Every
/// save and load here goes through that record now, never through
/// `ImageAdjustments` on its own, because that is what the store's protocol
/// actually holds.
///
/// Every test works inside its own temporary directory and no test reads or
/// writes anything a user owns.
@Suite("JSON sidecar photograph-processing store")
struct JSONSidecarPhotographProcessingStoreTests {

    /// A temporary directory with a stand-in "RAW" file in it.
    ///
    /// The bytes are not a real RAW file, deliberately: this suite tests the
    /// store, which must never open the RAW file at all. A file it cannot
    /// parse is the strongest possible statement of that.
    struct Sandbox {
        let directory: URL
        let raw: URL
        static let rawBytes = Data("ORF\u{0}not-a-real-raw-file\u{1}\u{2}\u{3}".utf8)

        init(rawName: String = "OLYMPUS.ORF") throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("iradjustments-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            raw = directory.appendingPathComponent(rawName)
            try Self.rawBytes.write(to: raw)
        }

        var sidecar: URL { JSONSidecarPhotographProcessingStore.sidecarURL(for: raw) }

        func writeSidecar(_ text: String) throws {
            try Data(text.utf8).write(to: sidecar)
        }

        func sidecarText() throws -> String {
            String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)
        }

        var rawIsUnchanged: Bool {
            (try? Data(contentsOf: raw)) == Self.rawBytes
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func withSandbox(
        rawName: String = "OLYMPUS.ORF",
        _ body: (Sandbox) throws -> Void
    ) throws {
        let sandbox = try Sandbox(rawName: rawName)
        defer { sandbox.cleanUp() }
        try body(sandbox)
    }

    static let store = JSONSidecarPhotographProcessingStore()

    /// The refusal a load produced, or `nil` when it did not refuse.
    ///
    /// A helper rather than a `catch` in each test, so every refusal is
    /// examined as the typed value it is instead of as `any Error`.
    static func loadRefusal(_ raw: URL) -> PhotographProcessingPersistenceError? {
        do {
            _ = try store.load(for: raw)
            return nil
        } catch {
            return error
        }
    }

    /// The refusal a save produced, or `nil` when it did not refuse.
    ///
    /// Takes a `PhotographProcessingState` — the store's actual unit — rather
    /// than `ImageAdjustments` alone, so `try store.save(state, for: raw)`
    /// below type-checks against the widened protocol instead of a stale
    /// narrower one.
    static func saveRefusal(
        _ state: PhotographProcessingState, _ raw: URL
    ) -> PhotographProcessingPersistenceError? {
        do {
            try store.save(state, for: raw)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The name rule

    @Test("The sidecar is the RAW file's whole name plus the suffix, beside it")
    func theNameRuleIsTheWholeFileName() {
        let raw = URL(fileURLWithPath: "/Pictures/IR/OLYMPUS.ORF")
        let sidecar = JSONSidecarPhotographProcessingStore.sidecarURL(for: raw)

        #expect(sidecar.lastPathComponent == "OLYMPUS.ORF.iradjustments.json")
        #expect(sidecar.deletingLastPathComponent() == raw.deletingLastPathComponent())
        // It can never name a RAW file, whatever the RAW file is called.
        #expect(sidecar != raw)
        #expect(sidecar.pathExtension == "json")
    }

    @Test("Two RAW files with one base name keep separate sidecars")
    func theExtensionIsPartOfTheName() {
        let orf = JSONSidecarPhotographProcessingStore.sidecarURL(
            for: URL(fileURLWithPath: "/p/SCENE.ORF")
        )
        let arw = JSONSidecarPhotographProcessingStore.sidecarURL(
            for: URL(fileURLWithPath: "/p/SCENE.ARW")
        )
        #expect(orf != arw)
    }

    @Test("The rule is deterministic")
    func theRuleIsDeterministic() {
        let raw = URL(fileURLWithPath: "/p/A B+C.ORF")
        #expect(
            JSONSidecarPhotographProcessingStore.sidecarURL(for: raw)
                == JSONSidecarPhotographProcessingStore.sidecarURL(for: raw)
        )
        #expect(Self.store.sidecarURL(for: raw)
            == JSONSidecarPhotographProcessingStore.sidecarURL(for: raw))
    }

    // MARK: - Absence

    @Test("No sidecar is nil, and is not an error")
    func aMissingSidecarIsNil() throws {
        try Self.withSandbox { sandbox in
            try #expect(Self.store.load(for: sandbox.raw) == nil)
            #expect(!FileManager.default.fileExists(atPath: sandbox.sidecar.path))
        }
    }

    @Test("A RAW file in a directory that does not exist is nil, not an error")
    func aMissingDirectoryIsNil() throws {
        let raw = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/nothing.orf")
        try #expect(Self.store.load(for: raw) == nil)
    }

    // MARK: - Round trips

    @Test("Saving then loading returns the same state")
    func saveLoadRoundTrips() throws {
        try Self.withSandbox { sandbox in
            let state = PhotographProcessingState(
                adjustments: ImageAdjustments(orientation: .quarterTurnRight)
            )
            try Self.store.save(state, for: sandbox.raw)

            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded == state)
            #expect(loaded.adjustments.orientation == .quarterTurnRight)
            #expect(loaded.captureProfile == .builtinUncalibrated)
            // The record was written at the current schema version — there is
            // no other version any in-memory value can hold.
            try #expect(
                sandbox.sidecarText()
                    .contains("\"schemaVersion\" : \(PhotographProcessingState.currentSchemaVersion)")
            )
        }
    }

    @Test("All eight orientation states round-trip")
    func allEightStatesRoundTrip() throws {
        let all: [UserOrientationAdjustment] = [
            .identity, .quarterTurnRight, .halfTurn, .quarterTurnLeft,
            .horizontalFlip, .verticalFlip, .diagonalFlip, .antiDiagonalFlip
        ]
        try Self.withSandbox { sandbox in
            for orientation in all {
                let state = PhotographProcessingState(
                    adjustments: ImageAdjustments(orientation: orientation)
                )
                try Self.store.save(state, for: sandbox.raw)
                let loaded = try #require(try Self.store.load(for: sandbox.raw))
                #expect(loaded == state)
                #expect(loaded.adjustments.orientation == orientation)
                // And the token on disk is the wire format, not a description.
                try #expect(sandbox.sidecarText().contains("\"\(orientation.persistedToken)\""))
            }
        }
    }

    @Test("A hand-written sidecar loads as the state it names")
    func aHandWrittenSidecarLoads() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(
                """
                {
                  "schemaVersion": 2,
                  "orientation": "rotate90Clockwise",
                  "channelMix": { "kind": "redBlueSwap" }
                }
                """
            )
            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded.adjustments.orientation == .quarterTurnRight)
            #expect(loaded.adjustments.channelMix == .redBlueSwap)
            // A historical, flat record migrates to the built-in uncalibrated
            // profile: it is the only processing basis any of those versions
            // ever rendered through.
            #expect(loaded.captureProfile == .builtinUncalibrated)
        }
    }

    // MARK: - The channel mix, through a real file

    @Test("Every channel-mix state survives a save and a load")
    func everyChannelMixRoundTripsThroughTheFile() throws {
        try Self.withSandbox { sandbox in
            let explicit = try UserChannelMixAdjustment.explicit(
                persistedMatrix: [0.5, 0, -0.25, 0, 1, 0, 2, 0, 0.125]
            )
            for mix in [UserChannelMixAdjustment.identity, .redBlueSwap, explicit] {
                let state = PhotographProcessingState(
                    adjustments: ImageAdjustments(orientation: .quarterTurnLeft, channelMix: mix)
                )
                try Self.store.save(state, for: sandbox.raw)
                let loaded = try #require(try Self.store.load(for: sandbox.raw))
                #expect(loaded == state)
                #expect(loaded.adjustments.channelMix == mix)
                // The kind token on disk is the wire format.
                try #expect(
                    sandbox.sidecarText().contains("\"\(mix.kind.rawValue)\"")
                )
            }
            #expect(sandbox.rawIsUnchanged)
        }
    }

    // MARK: - The version 1 migration, through a real file

    /// A sidecar written by the build before the channel mix, exposure, white
    /// balance or capture profile existed. It is read, not refused: what its
    /// absent fields meant is known exactly.
    @Test("A version 1 sidecar loads with the identity mix, 0 EV, the default patch and the built-in profile")
    func aVersionOneSidecarMigrates() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(
                """
                { "schemaVersion": 1, "orientation": "flipHorizontal" }
                """
            )

            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded.adjustments.orientation == .horizontalFlip)
            #expect(loaded.adjustments.channelMix == .identity)
            #expect(loaded.captureProfile == .builtinUncalibrated)

            // Nothing was rewritten by reading it. A migration happens in
            // memory; the file changes only when the workspace saves a state
            // that has rendered.
            try #expect(sandbox.sidecarText().contains("\"schemaVersion\": 1"))
            #expect(!(try sandbox.sidecarText().contains("channelMix")))

            // And the next save writes the current schema version, 5, nested
            // under "adjustments", with the state it migrated to.
            try Self.store.save(loaded, for: sandbox.raw)
            let text = try sandbox.sidecarText()
            #expect(text.contains("\"schemaVersion\" : 5"))
            #expect(text.contains("\"captureProfileID\" : \"builtin.uncalibrated\""))
            #expect(text.contains("\"adjustments\""))
            #expect(text.contains("\"identity\""))
            #expect(text.contains("\"exposureEV\" : 0"))
            #expect(text.contains("\"defaultNeutralPatch\""))
            try #expect(Self.store.load(for: sandbox.raw) == loaded)
            #expect(sandbox.rawIsUnchanged)
        }
    }

    // MARK: - Schema versions 3 and 4, through a real file

    @Test("A version 2 sidecar loads at 0 EV and the default patch, and saves as version 5")
    func aVersionTwoSidecarMigrates() throws {
        try Self.withSandbox { sandbox in
            let original = """
                { "schemaVersion": 2, "orientation": "rotate180", "channelMix": { "kind": "redBlueSwap" } }
                """
            try sandbox.writeSidecar(original)

            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded.adjustments.orientation == .halfTurn)
            #expect(loaded.adjustments.channelMix == .redBlueSwap)
            #expect(loaded.adjustments.exposure == .neutral)
            #expect(loaded.adjustments.whiteBalance == .defaultNeutralPatch)
            #expect(loaded.captureProfile == .builtinUncalibrated)
            // Reading migrates in memory and writes nothing.
            try #expect(sandbox.sidecarText() == original)

            try Self.store.save(loaded, for: sandbox.raw)
            let text = try sandbox.sidecarText()
            #expect(text.contains("\"schemaVersion\" : 5"))
            #expect(text.contains("\"captureProfileID\" : \"builtin.uncalibrated\""))
            #expect(text.contains("\"exposureEV\" : 0"))
            #expect(text.contains("\"redBlueSwap\""))
            #expect(text.contains("\"defaultNeutralPatch\""))
            try #expect(Self.store.load(for: sandbox.raw) == loaded)
            #expect(sandbox.rawIsUnchanged)
        }
    }

    @Test("A hand-written version 3 sidecar loads all three adjustments")
    func aHandWrittenVersionThreeSidecarLoads() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(
                """
                {
                  "schemaVersion": 3,
                  "orientation": "none",
                  "channelMix": { "kind": "redBlueSwap" },
                  "exposureEV": 1.25
                }
                """
            )
            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded.adjustments.orientation == .identity)
            #expect(loaded.adjustments.channelMix == .redBlueSwap)
            #expect(loaded.adjustments.exposure.ev == 1.25)
        }
    }

    /// Two different authorities refuse across these three bodies, and the
    /// point of the test is that both survive the file boundary as the typed
    /// value they actually are:
    ///
    /// ```text
    /// exposureAdjustmentOutOfRange   the VALUE refusing — a well-formed but
    ///                                 out-of-range exposure — still lives on
    ///                                 `ImageAdjustmentError`, reached through
    ///                                 `.adjustment`
    /// unexpectedField / missingField  the RECORD refusing — a field its
    ///                                 schema version does not have, or lacks
    ///                                 one it requires — now live on
    ///                                 `PhotographProcessingStateError`,
    ///                                 reached through `.record`
    /// ```
    @Test("An invalid exposure in a sidecar is refused with its typed reason, and nothing is repaired")
    func anInvalidExposureSidecarIsRefused() throws {
        try Self.withSandbox { sandbox in
            let body = """
                { "schemaVersion": 3, "orientation": "none", "channelMix": { "kind": "identity" }, \
                "exposureEV": 12.5 }
                """
            try sandbox.writeSidecar(body)
            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            #expect(
                refusal.adjustment
                    == .exposureAdjustmentOutOfRange(
                        ev: 12.5, supported: UserExposureAdjustment.supportedRange
                    )
            )
            #expect(refusal.failureReason?.isEmpty == false)
            try #expect(sandbox.sidecarText() == body)
            #expect(sandbox.rawIsUnchanged)
        }
        try Self.withSandbox { sandbox in
            let body = """
                { "schemaVersion": 2, "orientation": "none", "channelMix": { "kind": "identity" }, \
                "exposureEV": 1 }
                """
            try sandbox.writeSidecar(body)
            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            #expect(refusal.record == .unexpectedField(field: "exposureEV", schemaVersion: 2))
            #expect(refusal.failureReason?.isEmpty == false)
            try #expect(sandbox.sidecarText() == body)
            #expect(sandbox.rawIsUnchanged)
        }
        try Self.withSandbox { sandbox in
            let body = """
                { "schemaVersion": 3, "orientation": "none", "channelMix": { "kind": "identity" } }
                """
            try sandbox.writeSidecar(body)
            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            #expect(refusal.record == .missingField(field: "exposureEV", schemaVersion: 3))
            #expect(refusal.failureReason?.isEmpty == false)
            try #expect(sandbox.sidecarText() == body)
            #expect(sandbox.rawIsUnchanged)
        }
    }

    @Test("A version 1 sidecar carrying a channel mix is refused")
    func aVersionOneSidecarWithAMixIsRefused() throws {
        try Self.withSandbox { sandbox in
            let text = """
                {
                  "schemaVersion": 1,
                  "orientation": "none",
                  "channelMix": { "kind": "redBlueSwap" }
                }
                """
            try sandbox.writeSidecar(text)

            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            // A field a version does not have is a RECORD refusal now, not an
            // adjustment refusal.
            #expect(
                refusal.record
                    == .unexpectedField(field: "channelMix", schemaVersion: 1)
            )
            // Nothing repaired, nothing deleted.
            try #expect(sandbox.sidecarText() == text)
            #expect(sandbox.rawIsUnchanged)
        }
    }

    @Test("An unreadable channel mix is refused, with its typed reason intact")
    func anUnreadableMixIsRefused() throws {
        let bodies = [
            #"{ "schemaVersion": 2, "orientation": "none", "channelMix": { "kind": "aerochrome" } }"#,
            #"{ "schemaVersion": 2, "orientation": "none", "channelMix": { "kind": "matrix" } }"#,
            #"{ "schemaVersion": 2, "orientation": "none", "channelMix": { "kind": "matrix", "matrix": [1,2,3] } }"#,
        ]
        for body in bodies {
            try Self.withSandbox { sandbox in
                try sandbox.writeSidecar(body)
                let refusal = try #require(Self.loadRefusal(sandbox.raw))
                // The record refused, and the typed value survived the file
                // boundary rather than becoming a sentence.
                #expect(refusal.adjustment != nil)
                #expect(refusal.errorDescription?.isEmpty == false)
                #expect(refusal.failureReason?.isEmpty == false)
                try #expect(sandbox.sidecarText() == body)
                #expect(sandbox.rawIsUnchanged)
            }
        }
    }

    /// The built-in-plus-matrix contradiction, through a real file: refused
    /// with its typed reason intact, and neither the sidecar nor the RAW file
    /// is changed by the refusal.
    @Test("A sidecar whose built-in mix carries a matrix is refused, not read around")
    func aBuiltInMixWithAMatrixIsRefused() throws {
        for kind in ["identity", "redBlueSwap"] {
            try Self.withSandbox { sandbox in
                let body = """
                    {
                      "schemaVersion": 2,
                      "orientation": "none",
                      "channelMix": { "kind": "\(kind)", "matrix": [9,9,9,9,9,9,9,9,9] }
                    }
                    """
                try sandbox.writeSidecar(body)

                let refusal = try #require(Self.loadRefusal(sandbox.raw))
                #expect(
                    refusal.adjustment
                        == .unexpectedChannelMixField(field: "matrix", kind: kind)
                )
                try #expect(sandbox.sidecarText() == body)
                #expect(sandbox.rawIsUnchanged)
            }
        }
    }

    // MARK: - Identity is written, not implied

    @Test("Identity is saved as an ordinary sidecar, and the file stays")
    func identityIsWrittenLikeAnyOtherState() throws {
        try Self.withSandbox { sandbox in
            try Self.store.save(
                PhotographProcessingState(
                    adjustments: ImageAdjustments(orientation: .quarterTurnRight)
                ),
                for: sandbox.raw
            )
            try Self.store.save(.none, for: sandbox.raw)

            // The policy: a reset is a decision, so it is recorded. The store
            // never deletes a file the user can see.
            #expect(FileManager.default.fileExists(atPath: sandbox.sidecar.path))
            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded == PhotographProcessingState.none)
            #expect(loaded.adjustments.orientation.isIdentity)
            try #expect(sandbox.sidecarText().contains("\"none\""))
        }
    }

    // MARK: - Refusals

    @Test("A newer schema version is refused, with its typed reason intact")
    func anUnsupportedSchemaVersionIsRefused() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(
                """
                { "schemaVersion": 99, "orientation": "rotate90Clockwise", "exposureEV": 1.5 }
                """
            )

            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            guard case .cannotDecode(let sidecar, _) = refusal else {
                Issue.record("Expected .cannotDecode, got \(refusal)")
                return
            }
            #expect(sidecar == sandbox.sidecar)
            // The record's own error survived the file boundary. A schema
            // version is a fact about the RECORD, not about one adjustment.
            #expect(
                refusal.record
                    == .unsupportedSchemaVersion(
                        found: 99, supported: PhotographProcessingState.currentSchemaVersion
                    )
            )
            // Refused, not repaired: the bytes are exactly as they were.
            try #expect(sandbox.sidecarText().contains("99"))
        }
    }

    @Test("An unknown orientation token is refused, and reported verbatim")
    func anUnknownOrientationTokenIsRefused() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(
                """
                { "schemaVersion": 1, "orientation": "rotate45Clockwise" }
                """
            )

            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            #expect(
                refusal.adjustment
                    == .unknownOrientationAdjustment(token: "rotate45Clockwise")
            )
        }
    }

    @Test("A missing required field is refused rather than defaulted")
    func aMissingFieldIsRefused() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(#"{ "schemaVersion": 1 }"#)

            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            // Which fields a schema version requires is a fact about the
            // record's shape, not about the value of one adjustment.
            #expect(
                refusal.record
                    == .missingField(field: "orientation", schemaVersion: 1)
            )
        }
    }

    @Test("Corrupt JSON is refused, and is not mistaken for a missing sidecar")
    func corruptJSONIsRefused() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar("{ this is not json at all")

            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            guard case .cannotDecode(_, let underlying) = refusal else {
                Issue.record("Expected .cannotDecode, got \(refusal)")
                return
            }
            #expect(underlying is DecodingError)
            // Not an adjustment or record-shape refusal: the bytes never got
            // that far.
            #expect(refusal.adjustment == nil)
            #expect(refusal.record == nil)
        }
    }

    @Test("An empty sidecar is refused, not read as no adjustments")
    func anEmptySidecarIsRefused() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar("")
            #expect(Self.loadRefusal(sandbox.raw) != nil)
        }
    }

    @Test("A directory where the sidecar should be is a read failure")
    func aDirectoryInTheSidecarsPlaceIsAReadFailure() throws {
        try Self.withSandbox { sandbox in
            try FileManager.default.createDirectory(
                at: sandbox.sidecar, withIntermediateDirectories: true
            )
            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            guard case .cannotRead = refusal else {
                Issue.record("Expected .cannotRead, got \(refusal)")
                return
            }
        }
    }

    @Test("An unwritable location is a write failure, reported not trapped")
    func anUnwritableLocationIsAWriteFailure() throws {
        let raw = URL(fileURLWithPath: "/\(UUID().uuidString)/nowhere/IMG.ORF")
        let refusal = try #require(Self.saveRefusal(.none, raw))
        guard case .cannotWrite(let sidecar, _) = refusal else {
            Issue.record("Expected .cannotWrite, got \(refusal)")
            return
        }
        #expect(sidecar == JSONSidecarPhotographProcessingStore.sidecarURL(for: raw))
        #expect(refusal.errorDescription?.isEmpty == false)
        #expect(refusal.failureReason?.isEmpty == false)
    }

    // MARK: - Replacement

    @Test("Saving over an existing sidecar replaces it completely")
    func savingReplacesTheWholeRecord() throws {
        try Self.withSandbox { sandbox in
            try Self.store.save(
                PhotographProcessingState(adjustments: ImageAdjustments(orientation: .halfTurn)),
                for: sandbox.raw
            )
            let first = try sandbox.sidecarText()
            #expect(first.contains("rotate180"))

            try Self.store.save(
                PhotographProcessingState(adjustments: ImageAdjustments(orientation: .verticalFlip)),
                for: sandbox.raw
            )
            let second = try sandbox.sidecarText()

            // No remnant of the previous record: an atomic replacement, not an
            // overwrite in place that could leave a longer file's tail behind.
            #expect(!second.contains("rotate180"))
            #expect(second.contains("flipVertical"))
            try #expect(Self.store.load(for: sandbox.raw)?.adjustments.orientation == .verticalFlip)
        }
    }

    @Test("A repeated save of the same state is byte-stable")
    func repeatedSavesAreByteStable() throws {
        try Self.withSandbox { sandbox in
            let state = PhotographProcessingState(
                adjustments: ImageAdjustments(
                    orientation: .diagonalFlip,
                    channelMix: try UserChannelMixAdjustment.explicit(
                        persistedMatrix: [1, 0.5, 0, 0, 1, 0, 0, 0, 0.25]
                    )
                )
            )
            try Self.store.save(state, for: sandbox.raw)
            let first = try Data(contentsOf: sandbox.sidecar)
            try Self.store.save(state, for: sandbox.raw)
            try #expect(Data(contentsOf: sandbox.sidecar) == first)
        }
    }

    @Test("The sidecar is readable JSON a person can recognise")
    func theSidecarIsReadable() throws {
        try Self.withSandbox { sandbox in
            try Self.store.save(
                PhotographProcessingState(
                    adjustments: ImageAdjustments(
                        orientation: .quarterTurnLeft, channelMix: .redBlueSwap
                    )
                ),
                for: sandbox.raw
            )
            let text = try sandbox.sidecarText()

            // Semantic, not byte-for-byte: the format is the fields and their
            // values, not a particular arrangement of whitespace.
            #expect(text.contains("\"orientation\""))
            #expect(text.contains("\"rotate270Clockwise\""))
            #expect(text.contains("\"schemaVersion\""))
            #expect(text.contains("\(PhotographProcessingState.currentSchemaVersion)"))
            // Version 5 nests the adjustments and names the capture profile
            // beside them, rather than putting everything at the top level.
            #expect(text.contains("\"captureProfileID\""))
            #expect(text.contains("\"builtin.uncalibrated\""))
            #expect(text.contains("\"adjustments\""))
            #expect(text.contains("\"channelMix\""))
            #expect(text.contains("\"kind\""))
            #expect(text.contains("\"redBlueSwap\""))
            #expect(text.contains("\n"))
        }
    }

    // MARK: - The RAW file

    @Test("Every operation leaves the RAW file byte-identical")
    func theRAWFileIsNeverTouched() throws {
        try Self.withSandbox { sandbox in
            let before = try Data(contentsOf: sandbox.raw)
            let attributesBefore = try FileManager.default
                .attributesOfItem(atPath: sandbox.raw.path)

            _ = try Self.store.load(for: sandbox.raw)
            try Self.store.save(
                PhotographProcessingState(adjustments: ImageAdjustments(orientation: .antiDiagonalFlip)),
                for: sandbox.raw
            )
            _ = try Self.store.load(for: sandbox.raw)
            try Self.store.save(.none, for: sandbox.raw)

            try #expect(Data(contentsOf: sandbox.raw) == before)
            #expect(sandbox.rawIsUnchanged)
            let attributesAfter = try FileManager.default
                .attributesOfItem(atPath: sandbox.raw.path)
            #expect(
                attributesBefore[.modificationDate] as? Date
                    == attributesAfter[.modificationDate] as? Date
            )
            #expect(attributesBefore[.size] as? Int == attributesAfter[.size] as? Int)
        }
    }

    @Test("A refused load leaves the RAW file and the sidecar alone")
    func arefusedLoadChangesNothing() throws {
        try Self.withSandbox { sandbox in
            let text = #"{ "schemaVersion": 7, "orientation": "rotate90Clockwise" }"#
            try sandbox.writeSidecar(text)

            #expect(Self.loadRefusal(sandbox.raw) != nil)
            try #expect(sandbox.sidecarText() == text)
            #expect(sandbox.rawIsUnchanged)
        }
    }

    @Test("Adjustments belong to their own RAW file")
    func adjustmentsBelongToTheirFile() throws {
        try Self.withSandbox { sandbox in
            let other = sandbox.directory.appendingPathComponent("B.ORF")
            try Sandbox.rawBytes.write(to: other)

            try Self.store.save(
                PhotographProcessingState(adjustments: ImageAdjustments(orientation: .quarterTurnRight)),
                for: sandbox.raw
            )

            try #expect(Self.store.load(for: other) == nil)
            try Self.store.save(
                PhotographProcessingState(adjustments: ImageAdjustments(orientation: .verticalFlip)),
                for: other
            )
            try #expect(Self.store.load(for: sandbox.raw)?.adjustments.orientation == .quarterTurnRight)
            try #expect(Self.store.load(for: other)?.adjustments.orientation == .verticalFlip)
        }
    }

    // MARK: - The capture profile, the widened half of the record

    /// A non-default profile reference and non-default adjustments, saved and
    /// read back together — proving the record really is one thing rather
    /// than two independently-persisted halves.
    @Test("A non-default capture profile round-trips alongside non-default adjustments")
    func aNonDefaultCaptureProfileRoundTrips() throws {
        try Self.withSandbox { sandbox in
            let profile = try IRCaptureProfileID("user.epl3-720nm")
            let patch = try NormalizedActiveAreaRegion(
                originX: 0.2, originY: 0.3, width: 0.1, height: 0.15
            )
            let adjustments = ImageAdjustments(
                orientation: .quarterTurnRight,
                channelMix: .redBlueSwap,
                exposure: try UserExposureAdjustment(ev: 0.5),
                whiteBalance: .neutralPatch(patch)
            )
            let state = PhotographProcessingState(captureProfile: profile, adjustments: adjustments)
            try Self.store.save(state, for: sandbox.raw)

            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded == state)
            #expect(loaded.captureProfile == profile)
            #expect(loaded.adjustments == adjustments)
            try #expect(sandbox.sidecarText().contains("\"user.epl3-720nm\""))
            #expect(sandbox.rawIsUnchanged)
        }
    }

    /// A version 4 sidecar is still flat — no `captureProfileID`, no nested
    /// `adjustments` — and it is read as a migration, not rewritten by the
    /// read. Only a subsequent *save* may change what is on disk.
    @Test("A historical version 4 sidecar migrates to the built-in profile, and loading does not rewrite it")
    func aVersionFourSidecarMigratesWithoutRewriting() throws {
        try Self.withSandbox { sandbox in
            let original = """
                {
                  "schemaVersion": 4,
                  "orientation": "rotate90Clockwise",
                  "channelMix": { "kind": "redBlueSwap" },
                  "exposureEV": 0.75,
                  "whiteBalance": { "kind": "defaultNeutralPatch" }
                }
                """
            try sandbox.writeSidecar(original)
            let attributesBefore = try FileManager.default
                .attributesOfItem(atPath: sandbox.sidecar.path)

            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded.captureProfile == .builtinUncalibrated)
            #expect(
                loaded.adjustments
                    == ImageAdjustments(
                        orientation: .quarterTurnRight,
                        channelMix: .redBlueSwap,
                        exposure: try UserExposureAdjustment(ev: 0.75),
                        whiteBalance: .defaultNeutralPatch
                    )
            )

            // The read produced a migrated value in memory; the file itself
            // is untouched, bytes and modification date alike.
            try #expect(sandbox.sidecarText() == original)
            let attributesAfter = try FileManager.default
                .attributesOfItem(atPath: sandbox.sidecar.path)
            #expect(
                attributesBefore[.modificationDate] as? Date
                    == attributesAfter[.modificationDate] as? Date
            )
            #expect(attributesBefore[.size] as? Int == attributesAfter[.size] as? Int)
        }
    }

    /// The other half of the same story: once that migrated value is actually
    /// saved, the file catches up to the current, nested wire format.
    @Test("Saving a migrated version 4 state writes the version 5 nested shape")
    func savingAMigratedVersionFourStateWritesVersionFive() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(
                """
                {
                  "schemaVersion": 4,
                  "orientation": "rotate180",
                  "channelMix": { "kind": "identity" },
                  "exposureEV": 0,
                  "whiteBalance": { "kind": "defaultNeutralPatch" }
                }
                """
            )
            let loaded = try #require(try Self.store.load(for: sandbox.raw))

            try Self.store.save(loaded, for: sandbox.raw)
            let text = try sandbox.sidecarText()
            #expect(text.contains("\"schemaVersion\" : 5"))
            #expect(text.contains("\"captureProfileID\" : \"builtin.uncalibrated\""))
            #expect(text.contains("\"adjustments\""))
            // The adjustment fields are no longer at the top level: reading
            // them back through the record, not a bare substring search, is
            // what actually proves the nesting, so confirm the round trip too.
            try #expect(Self.store.load(for: sandbox.raw) == loaded)
            #expect(sandbox.rawIsUnchanged)
        }
    }

    /// A well-formed reference to a profile nothing has installed is a STORE
    /// success. Whether the profile actually exists is the document layer's
    /// question, asked later by the registry — not this type's.
    @Test("A hand-written sidecar naming an uninstalled profile loads successfully")
    func anUninstalledProfileLoadsSuccessfully() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(
                """
                {
                  "schemaVersion": 5,
                  "captureProfileID": "user.does-not-exist",
                  "adjustments": {
                    "orientation": "none",
                    "channelMix": { "kind": "identity" },
                    "exposureEV": 0,
                    "whiteBalance": { "kind": "defaultNeutralPatch" }
                  }
                }
                """
            )
            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded.captureProfile.rawValue == "user.does-not-exist")
        }
    }

    /// A profile identifier that is not well-formed at all is a different
    /// failure from an unknown-but-well-formed one: it is the bytes refusing,
    /// caught at `IRCaptureProfileID`'s own boundary, and it must survive as
    /// that typed value through `cannotDecode`.
    @Test("A malformed capture profile identifier fails with its typed reason intact")
    func aMalformedProfileIDIsRefused() throws {
        try Self.withSandbox { sandbox in
            let body = """
                {
                  "schemaVersion": 5,
                  "captureProfileID": "Builtin.Uncalibrated",
                  "adjustments": {
                    "orientation": "none",
                    "channelMix": { "kind": "identity" },
                    "exposureEV": 0,
                    "whiteBalance": { "kind": "defaultNeutralPatch" }
                  }
                }
                """
            try sandbox.writeSidecar(body)

            let refusal = try #require(Self.loadRefusal(sandbox.raw))
            guard case .cannotDecode = refusal else {
                Issue.record("Expected .cannotDecode, got \(refusal)")
                return
            }
            guard case .invalidProfileID(let token, _) = try #require(refusal.captureProfile) else {
                Issue.record("Expected .invalidProfileID, got \(String(describing: refusal.captureProfile))")
                return
            }
            #expect(token == "Builtin.Uncalibrated")
            // Nothing else claims this refusal: it is the profile system's
            // alone, not the record's shape or one adjustment's value.
            #expect(refusal.record == nil)
            #expect(refusal.adjustment == nil)
            try #expect(sandbox.sidecarText() == body)
            #expect(sandbox.rawIsUnchanged)
        }
    }
}
