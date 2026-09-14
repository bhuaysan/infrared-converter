import Testing
import Foundation
@testable import InfraredConverter

/// The file-backed calibration store: naming, path safety, round-tripping,
/// lazy directory creation, replacement, deletion, and the refusals.
///
/// Every test works inside its own temporary directory. **No test touches the
/// real Application Support directory** — the one exception is
/// `applicationSupportDirectoryIsWhereClaimed`, which asserts the shape of the
/// production path as a pure string without creating, reading or writing
/// anything.
@Suite("FileIRCalibrationStore")
struct FileIRCalibrationStoreTests {

    struct Sandbox {
        let directory: URL
        let store: FileIRCalibrationStore

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ircalibration-store-tests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            store = FileIRCalibrationStore(directory: directory)
        }

        var directoryExists: Bool {
            FileManager.default.fileExists(atPath: directory.path)
        }

        func createDirectory() throws {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    static func withSandbox(_ body: (Sandbox) throws -> Void) throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        try body(sandbox)
    }

    static func calibration(
        id: IRCalibrationID? = nil, name: String = "Test calibration"
    ) throws -> IRCalibration {
        try CalibrationTestData.calibration(name: name, id: id ?? .generated())
    }

    static func saveRefusal(
        _ calibration: IRCalibration, _ store: FileIRCalibrationStore
    ) -> IRCalibrationPersistenceError? {
        do {
            try store.save(calibration)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Location and naming

    @Test("The production location is a pure path, nothing created or read")
    func applicationSupportDirectoryIsWhereClaimed() throws {
        let url = try FileIRCalibrationStore.applicationSupportDirectory()
        #expect(url.lastPathComponent == "Calibrations")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Infrared Converter")
        #expect(
            url.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent == "Application Support"
        )
    }

    /// Two stores, two folders. A calibration is not a capture profile and
    /// they do not share a namespace, a schema or a location.
    @Test("Calibrations live beside profiles, not among them")
    func separateFromProfiles() throws {
        let calibrations = try FileIRCalibrationStore.applicationSupportDirectory()
        let profiles = try FileIRCaptureProfileStore.applicationSupportDirectory()
        #expect(calibrations != profiles)
        #expect(
            calibrations.deletingLastPathComponent() == profiles.deletingLastPathComponent()
        )
        #expect(FileIRCalibrationStore.fileSuffix != FileIRCaptureProfileStore.fileSuffix)
    }

    @Test("calibrationURL(for:in:) is <id>.ircalibration.json, deterministically")
    func namingRule() throws {
        let directory = URL(fileURLWithPath: "/tmp/some-calibrations", isDirectory: true)
        let id = try IRCalibrationID("calibration.550e8400-e29b-41d4-a716-446655440000")
        let url = FileIRCalibrationStore.calibrationURL(for: id, in: directory)

        #expect(
            url.lastPathComponent
                == "calibration.550e8400-e29b-41d4-a716-446655440000.ircalibration.json"
        )
        #expect(FileIRCalibrationStore.calibrationID(forFileNamed: url.lastPathComponent) == id)
    }

    @Test(
        "A name without our suffix is foreign",
        arguments: [".DS_Store", "notes.txt", "p.irprofile.json", "x.ircalibration.json.bak"]
    )
    func foreignNames(name: String) {
        #expect(FileIRCalibrationStore.classify(fileNamed: name) == .foreign)
    }

    @Test(
        "A name with our suffix and an invalid token is malformed, not foreign",
        arguments: [
            "BAD CALIBRATION!.ircalibration.json",
            ".ircalibration.json",
            "user.abc.ircalibration.json",
            "calibration.ircalibration.json",
        ]
    )
    func malformedNames(name: String) {
        guard case .malformed(_, let reason) =
            FileIRCalibrationStore.classify(fileNamed: name)
        else {
            Issue.record("Expected .malformed for \(name)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("A calibration's file stays inside the store's directory, whatever its identity")
    func pathSafety() throws {
        let directory = URL(fileURLWithPath: "/tmp/ircalibration-path-safety", isDirectory: true)
        for id in (0..<20).map({ _ in IRCalibrationID.generated() }) {
            let url = FileIRCalibrationStore.calibrationURL(for: id, in: directory)
            #expect(url.deletingLastPathComponent().path == directory.path)
            #expect(!url.lastPathComponent.contains("/"))
        }
    }

    // MARK: - Round trip

    @Test("A saved calibration is returned by loadAll(), with no failures")
    func saveAndLoad() throws {
        try Self.withSandbox { sandbox in
            let calibration = try Self.calibration()
            try sandbox.store.save(calibration)

            let load = sandbox.store.loadAll()
            #expect(load.failures.isEmpty)
            #expect(load.calibrations == [calibration])
            #expect(load.calibrations.first?.status == .measured)
            #expect(load.calibrations.first?.isValidatedInfraredCalibration == false)
        }
    }

    @Test("Several calibrations load in a deterministic order")
    func deterministicOrder() throws {
        try Self.withSandbox { sandbox in
            let ids = [
                try IRCalibrationID("calibration.aaa"),
                try IRCalibrationID("calibration.bbb"),
                try IRCalibrationID("calibration.ccc"),
            ]
            for id in ids.reversed() {
                try sandbox.store.save(try Self.calibration(id: id, name: "C \(id)"))
            }

            let first = sandbox.store.loadAll().calibrations.map(\.id)
            let second = sandbox.store.loadAll().calibrations.map(\.id)
            #expect(first == second)
            #expect(Set(first) == Set(ids))
        }
    }

    @Test("An absent directory loads as empty and successful, and stays absent")
    func absentDirectory() throws {
        try Self.withSandbox { sandbox in
            #expect(!sandbox.directoryExists)
            let load = sandbox.store.loadAll()
            #expect(load.calibrations.isEmpty)
            #expect(load.failures.isEmpty)
            #expect(!sandbox.directoryExists)
        }
    }

    @Test("The directory is created by the first save, not by a read")
    func lazyDirectoryCreation() throws {
        try Self.withSandbox { sandbox in
            _ = sandbox.store.loadAll()
            #expect(!sandbox.directoryExists)

            try sandbox.store.save(try Self.calibration())
            #expect(sandbox.directoryExists)
        }
    }

    @Test("The written file is pretty-printed, sorted, and valid UTF-8 JSON a person can read")
    func humanReadableFile() throws {
        try Self.withSandbox { sandbox in
            let calibration = try Self.calibration()
            try sandbox.store.save(calibration)

            let url = sandbox.store.calibrationURL(for: calibration.id)
            let data = try Data(contentsOf: url)
            let text = try #require(String(data: data, encoding: .utf8))

            #expect(text.contains("\n"))
            #expect(text.contains("\"schemaVersion\" : \(IRCalibration.currentSchemaVersion)"))
            #expect(try JSONSerialization.jsonObject(with: data) as? [String: Any] != nil)
        }
    }

    @Test("Saving twice under one identity leaves one file, holding the second definition")
    func replacement() throws {
        try Self.withSandbox { sandbox in
            let id = IRCalibrationID.generated()
            try sandbox.store.save(try Self.calibration(id: id, name: "First"))
            try sandbox.store.save(try Self.calibration(id: id, name: "Second"))

            let contents = try FileManager.default.contentsOfDirectory(
                at: sandbox.directory, includingPropertiesForKeys: nil
            )
            #expect(contents.count == 1)
            #expect(sandbox.store.loadAll().calibrations.map(\.name) == ["Second"])
        }
    }

    @Test("Deleting removes the file, and deleting an id that is not stored is not an error")
    func deletion() throws {
        try Self.withSandbox { sandbox in
            let calibration = try Self.calibration()
            try sandbox.store.save(calibration)
            try sandbox.store.delete(calibration.id)

            #expect(sandbox.store.loadAll().calibrations.isEmpty)
            #expect(throws: Never.self) { try sandbox.store.delete(.generated()) }
        }
    }

    // MARK: - Refusals

    @Test("Foreign files beside a calibration are ignored in silence")
    func foreignFilesIgnored() throws {
        try Self.withSandbox { sandbox in
            let calibration = try Self.calibration()
            try sandbox.store.save(calibration)

            try Data().write(to: sandbox.directory.appendingPathComponent(".DS_Store"))
            try Data("a note".utf8)
                .write(to: sandbox.directory.appendingPathComponent("notes.txt"))

            let load = sandbox.store.loadAll()
            #expect(load.failures.isEmpty)
            #expect(load.calibrations == [calibration])
        }
    }

    @Test("A malformed calibration filename is reported, and costs only that file")
    func malformedFilenameReported() throws {
        try Self.withSandbox { sandbox in
            let kept = try Self.calibration(name: "Kept")
            try sandbox.store.save(kept)

            let badName = "BAD CALIBRATION!.ircalibration.json"
            let badURL = sandbox.directory.appendingPathComponent(badName)
            try Data(#"{"schemaVersion":1}"#.utf8).write(to: badURL)

            let load = sandbox.store.loadAll()
            #expect(load.calibrations == [kept])
            #expect(load.failures.count == 1)

            guard case .invalidCalibrationFilename(let url, let token, _) =
                try #require(load.failures.first)
            else {
                Issue.record("Expected .invalidCalibrationFilename, got \(load.failures)")
                return
            }
            #expect(url.lastPathComponent == badName)
            #expect(token == "BAD CALIBRATION!")
            #expect(FileManager.default.fileExists(atPath: badURL.path))
        }
    }

    @Test("A corrupt file is isolated: the rest of the library still loads, and the failure names it")
    func corruptFileIsolation() throws {
        try Self.withSandbox { sandbox in
            let kept = try Self.calibration(
                id: try IRCalibrationID("calibration.aaa"), name: "Kept"
            )
            try sandbox.store.save(kept)

            let corruptID = try IRCalibrationID("calibration.bbb")
            try Data("not json at all".utf8).write(
                to: FileIRCalibrationStore.calibrationURL(
                    for: corruptID, in: sandbox.directory
                )
            )

            let load = sandbox.store.loadAll()
            #expect(load.calibrations == [kept])
            #expect(load.failures.count == 1)
            #expect(load.failures.first?.url?.lastPathComponent.contains("bbb") == true)
            #expect(load.hasFailures)
            #expect(load.failureSummary != nil)
        }
    }

    @Test("A file whose name and payload disagree is refused, not reconciled")
    func filenameIdentityMismatch() throws {
        try Self.withSandbox { sandbox in
            try sandbox.createDirectory()

            let payloadID = try IRCalibrationID("calibration.payload")
            let namedID = try IRCalibrationID("calibration.name")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                IRCalibrationRecord(try Self.calibration(id: payloadID))
            )
            try data.write(
                to: FileIRCalibrationStore.calibrationURL(for: namedID, in: sandbox.directory)
            )

            let load = sandbox.store.loadAll()
            #expect(load.calibrations.isEmpty)

            guard case .filenameIdentityMismatch(_, let expected, let found) =
                try #require(load.failures.first)
            else {
                Issue.record("Expected .filenameIdentityMismatch, got \(load.failures)")
                return
            }
            #expect(expected == namedID)
            #expect(found == payloadID)
        }
    }

    @Test("A calibration at an unsupported schema version is a typed refusal across the file boundary")
    func unsupportedSchemaVersion() throws {
        try Self.withSandbox { sandbox in
            try sandbox.createDirectory()

            let id = try IRCalibrationID("calibration.future")
            let encoder = JSONEncoder()
            let data = try encoder.encode(
                IRCalibrationRecord(try Self.calibration(id: id))
            )
            var object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            object["schemaVersion"] = IRCalibration.currentSchemaVersion + 1
            try JSONSerialization.data(withJSONObject: object).write(
                to: FileIRCalibrationStore.calibrationURL(for: id, in: sandbox.directory)
            )

            let load = sandbox.store.loadAll()
            #expect(load.calibrations.isEmpty)

            let failure = try #require(load.failures.first)
            let record = failure.underlying as? IRCalibrationRecordError
            guard case .unsupportedSchemaVersion(let found, let supported) =
                try #require(record)
            else {
                Issue.record("Expected .unsupportedSchemaVersion, got \(failure)")
                return
            }
            #expect(found == IRCalibration.currentSchemaVersion + 1)
            #expect(supported == IRCalibration.currentSchemaVersion)
        }
    }

    // MARK: - What the store does not do

    /// Nothing here is validated, and storing a calibration does not make it
    /// so: the status is derived from the artefact's own contents every time
    /// it is read back.
    @Test("A stored calibration is Measured on the way in and Measured on the way out")
    func storingDoesNotValidate() throws {
        try Self.withSandbox { sandbox in
            let calibration = try Self.calibration()
            #expect(calibration.status == .measured)
            try sandbox.store.save(calibration)

            let loaded = try #require(sandbox.store.loadAll().calibrations.first)
            #expect(loaded.status == .measured)
            #expect(!loaded.isValidatedInfraredCalibration)
        }
    }
}
