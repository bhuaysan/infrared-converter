import Testing
import Foundation
@testable import InfraredConverter

/// The sidecar store on its own: naming, round-tripping, refusals, atomicity,
/// and the one rule the whole project rests on — the RAW file is never
/// touched.
///
/// Every test works inside its own temporary directory and no test reads or
/// writes anything a user owns.
@Suite("JSON sidecar adjustment store")
struct JSONSidecarImageAdjustmentStoreTests {

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

        var sidecar: URL { JSONSidecarImageAdjustmentStore.sidecarURL(for: raw) }

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

    static let store = JSONSidecarImageAdjustmentStore()

    /// The refusal a load produced, or `nil` when it did not refuse.
    ///
    /// A helper rather than a `catch` in each test, so every refusal is
    /// examined as the typed value it is instead of as `any Error`.
    static func loadRefusal(_ raw: URL) -> ImageAdjustmentPersistenceError? {
        do {
            _ = try store.load(for: raw)
            return nil
        } catch {
            return error
        }
    }

    /// The refusal a save produced, or `nil` when it did not refuse.
    static func saveRefusal(
        _ adjustments: ImageAdjustments, _ raw: URL
    ) -> ImageAdjustmentPersistenceError? {
        do {
            try store.save(adjustments, for: raw)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The name rule

    @Test("The sidecar is the RAW file's whole name plus the suffix, beside it")
    func theNameRuleIsTheWholeFileName() {
        let raw = URL(fileURLWithPath: "/Pictures/IR/OLYMPUS.ORF")
        let sidecar = JSONSidecarImageAdjustmentStore.sidecarURL(for: raw)

        #expect(sidecar.lastPathComponent == "OLYMPUS.ORF.iradjustments.json")
        #expect(sidecar.deletingLastPathComponent() == raw.deletingLastPathComponent())
        // It can never name a RAW file, whatever the RAW file is called.
        #expect(sidecar != raw)
        #expect(sidecar.pathExtension == "json")
    }

    @Test("Two RAW files with one base name keep separate sidecars")
    func theExtensionIsPartOfTheName() {
        let orf = JSONSidecarImageAdjustmentStore.sidecarURL(
            for: URL(fileURLWithPath: "/p/SCENE.ORF")
        )
        let arw = JSONSidecarImageAdjustmentStore.sidecarURL(
            for: URL(fileURLWithPath: "/p/SCENE.ARW")
        )
        #expect(orf != arw)
    }

    @Test("The rule is deterministic")
    func theRuleIsDeterministic() {
        let raw = URL(fileURLWithPath: "/p/A B+C.ORF")
        #expect(
            JSONSidecarImageAdjustmentStore.sidecarURL(for: raw)
                == JSONSidecarImageAdjustmentStore.sidecarURL(for: raw)
        )
        #expect(Self.store.sidecarURL(for: raw)
            == JSONSidecarImageAdjustmentStore.sidecarURL(for: raw))
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

    @Test("Saving then loading returns the same adjustments")
    func saveLoadRoundTrips() throws {
        try Self.withSandbox { sandbox in
            let adjustments = ImageAdjustments(orientation: .quarterTurnRight)
            try Self.store.save(adjustments, for: sandbox.raw)

            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded == adjustments)
            #expect(loaded.orientation == .quarterTurnRight)
            #expect(loaded.schemaVersion == ImageAdjustments.currentSchemaVersion)
        }
    }

    @Test("All eight orientation states round-trip")
    func allEightStatesRoundTrip() throws {
        let all: [UserOrientationAdjustment] = [
            .identity, .quarterTurnRight, .halfTurn, .quarterTurnLeft,
            .horizontalFlip, .verticalFlip, .diagonalFlip, .antiDiagonalFlip
        ]
        try Self.withSandbox { sandbox in
            for state in all {
                let adjustments = ImageAdjustments(orientation: state)
                try Self.store.save(adjustments, for: sandbox.raw)
                let loaded = try #require(try Self.store.load(for: sandbox.raw))
                #expect(loaded == adjustments)
                #expect(loaded.orientation == state)
                // And the token on disk is the wire format, not a description.
                try #expect(sandbox.sidecarText().contains("\"\(state.persistedToken)\""))
            }
        }
    }

    @Test("A hand-written sidecar loads as the adjustments it names")
    func aHandWrittenSidecarLoads() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeSidecar(
                """
                { "schemaVersion": 1, "orientation": "rotate90Clockwise" }
                """
            )
            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded.orientation == .quarterTurnRight)
        }
    }

    // MARK: - Identity is written, not implied

    @Test("Identity is saved as an ordinary sidecar, and the file stays")
    func identityIsWrittenLikeAnyOtherState() throws {
        try Self.withSandbox { sandbox in
            try Self.store.save(ImageAdjustments(orientation: .quarterTurnRight), for: sandbox.raw)
            try Self.store.save(.none, for: sandbox.raw)

            // The policy: a reset is a decision, so it is recorded. The store
            // never deletes a file the user can see.
            #expect(FileManager.default.fileExists(atPath: sandbox.sidecar.path))
            let loaded = try #require(try Self.store.load(for: sandbox.raw))
            #expect(loaded == ImageAdjustments.none)
            #expect(loaded.orientation.isIdentity)
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
            // The adjustment model's own error survived the file boundary.
            #expect(
                refusal.adjustment
                    == .unsupportedSchemaVersion(
                        found: 99, supported: ImageAdjustments.currentSchemaVersion
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
            #expect(
                refusal.adjustment
                    == .missingAdjustment(field: "orientation", schemaVersion: 1)
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
            // Not an adjustment-model refusal: the bytes never got that far.
            #expect(refusal.adjustment == nil)
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
        #expect(sidecar == JSONSidecarImageAdjustmentStore.sidecarURL(for: raw))
        #expect(refusal.errorDescription?.isEmpty == false)
        #expect(refusal.failureReason?.isEmpty == false)
    }

    // MARK: - Replacement

    @Test("Saving over an existing sidecar replaces it completely")
    func savingReplacesTheWholeRecord() throws {
        try Self.withSandbox { sandbox in
            try Self.store.save(ImageAdjustments(orientation: .halfTurn), for: sandbox.raw)
            let first = try sandbox.sidecarText()
            #expect(first.contains("rotate180"))

            try Self.store.save(ImageAdjustments(orientation: .verticalFlip), for: sandbox.raw)
            let second = try sandbox.sidecarText()

            // No remnant of the previous record: an atomic replacement, not an
            // overwrite in place that could leave a longer file's tail behind.
            #expect(!second.contains("rotate180"))
            #expect(second.contains("flipVertical"))
            try #expect(Self.store.load(for: sandbox.raw)?.orientation == .verticalFlip)
        }
    }

    @Test("A repeated save of the same state is byte-stable")
    func repeatedSavesAreByteStable() throws {
        try Self.withSandbox { sandbox in
            let adjustments = ImageAdjustments(orientation: .diagonalFlip)
            try Self.store.save(adjustments, for: sandbox.raw)
            let first = try Data(contentsOf: sandbox.sidecar)
            try Self.store.save(adjustments, for: sandbox.raw)
            try #expect(Data(contentsOf: sandbox.sidecar) == first)
        }
    }

    @Test("The sidecar is readable JSON a person can recognise")
    func theSidecarIsReadable() throws {
        try Self.withSandbox { sandbox in
            try Self.store.save(ImageAdjustments(orientation: .quarterTurnLeft), for: sandbox.raw)
            let text = try sandbox.sidecarText()

            // Semantic, not byte-for-byte: the format is the two fields and
            // their values, not a particular arrangement of whitespace.
            #expect(text.contains("\"orientation\""))
            #expect(text.contains("\"rotate270Clockwise\""))
            #expect(text.contains("\"schemaVersion\""))
            #expect(text.contains("1"))
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
            try Self.store.save(ImageAdjustments(orientation: .antiDiagonalFlip), for: sandbox.raw)
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

            try Self.store.save(ImageAdjustments(orientation: .quarterTurnRight), for: sandbox.raw)

            try #expect(Self.store.load(for: other) == nil)
            try Self.store.save(ImageAdjustments(orientation: .verticalFlip), for: other)
            try #expect(Self.store.load(for: sandbox.raw)?.orientation == .quarterTurnRight)
            try #expect(Self.store.load(for: other)?.orientation == .verticalFlip)
        }
    }
}
