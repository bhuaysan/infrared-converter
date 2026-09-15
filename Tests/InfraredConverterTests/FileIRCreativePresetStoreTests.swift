import Testing
import Foundation
@testable import InfraredConverter

/// The file-backed creative-preset store on its own: naming, round-tripping,
/// lazy directory creation, replacement, deletion, and the refusals —
/// corrupt files, malformed filenames, the reserved builtin namespace, and a
/// filename/payload mismatch.
///
/// Every test works inside its own temporary directory, constructed fresh for
/// each test. **No test ever touches the real Application Support
/// directory** — every store under test is built with
/// `FileIRCreativePresetStore(directory:)` pointed at that temporary
/// directory.
@Suite("FileIRCreativePresetStore")
struct FileIRCreativePresetStoreTests {

    /// A temporary directory a store can be pointed at.
    ///
    /// Deliberately does **not** create the directory in `init`: part of what
    /// this suite proves is that reading an absent library creates nothing,
    /// so the directory must still be absent when a test begins.
    struct Sandbox {
        let directory: URL
        let store: FileIRCreativePresetStore

        init() {
            // Resolved up front, for the same reason the capture-profile
            // store sandbox resolves it: `contentsOfDirectory(at:)` hands
            // back paths with `/tmp`'s symlink into `/private` resolved, and
            // an unresolved directory here would make every URL this suite
            // builds by hand disagree with one the store discovers by
            // enumeration for a reason that has nothing to do with the
            // store's own behaviour.
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ircreativepreset-store-tests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            store = FileIRCreativePresetStore(directory: directory)
        }

        var directoryExists: Bool {
            FileManager.default.fileExists(atPath: directory.path)
        }

        func fileExists(for id: IRCreativePresetID) -> Bool {
            FileManager.default.fileExists(
                atPath: FileIRCreativePresetStore.presetURL(for: id, in: directory).path
            )
        }

        func createDirectory() throws {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func withSandbox(_ body: (Sandbox) throws -> Void) throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        try body(sandbox)
    }

    /// A preset a test can save, with sensible defaults and a fresh identity
    /// per call so tests do not collide with one another.
    static func makePreset(
        id: IRCreativePresetID = .generatedUserID(),
        name: String = "Test Preset",
        channelMix: UserChannelMixAdjustment = .identity,
        filter: IRFilterDescriptor = .unknown
    ) -> IRCreativePreset {
        IRCreativePreset(id: id, name: name, channelMix: channelMix, filter: filter)
    }

    /// The refusal a save produced, or `nil` when it did not refuse.
    static func saveRefusal(
        _ preset: IRCreativePreset, _ store: FileIRCreativePresetStore
    ) -> IRCreativePresetPersistenceError? {
        do {
            try store.save(preset)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The name rule

    @Test("presetURL(for:in:) is <id>.irpreset.json in the given directory, deterministically")
    func namingRule() throws {
        let directory = URL(fileURLWithPath: "/tmp/some-presets", isDirectory: true)
        let id = try IRCreativePresetID("user.550e8400-e29b-41d4-a716-446655440000")

        let url = FileIRCreativePresetStore.presetURL(for: id, in: directory)
        #expect(
            url.lastPathComponent == "user.550e8400-e29b-41d4-a716-446655440000.irpreset.json"
        )
        #expect(url == FileIRCreativePresetStore.presetURL(for: id, in: directory))
    }

    @Test("presetID(forFileNamed:) is the inverse of the naming rule for our own names")
    func namingRuleIsInvertible() throws {
        let id = try IRCreativePresetID("user.550e8400-e29b-41d4-a716-446655440000")
        let name = FileIRCreativePresetStore.presetURL(
            for: id, in: URL(fileURLWithPath: "/tmp")
        ).lastPathComponent
        #expect(FileIRCreativePresetStore.presetID(forFileNamed: name) == id)
    }

    @Test(
        "A name that is not one of ours, or whose token is not a valid identifier, is nil",
        arguments: [
            ".DS_Store",
            "notes.txt",
            "user.abc.irpreset.json.bak",
            "not-a-valid-identifier.irpreset.json",
        ]
    )
    func foreignOrInvalidNamesAreNil(name: String) {
        #expect(FileIRCreativePresetStore.presetID(forFileNamed: name) == nil)
    }

    // MARK: - Classification: foreign, ours, or ours and malformed

    @Test(
        "A name without our suffix is foreign, whatever else is wrong with it",
        arguments: [".DS_Store", "notes.txt", "README.md", "irpreset.json", "user.abc.irpreset.JSON"]
    )
    func foreignNames(name: String) {
        #expect(FileIRCreativePresetStore.classify(fileNamed: name) == .foreign)
    }

    @Test("A name with our suffix and a valid token classifies as that preset")
    func ourNames() throws {
        let id = try IRCreativePresetID("user.550e8400-e29b-41d4-a716-446655440000")
        let name = FileIRCreativePresetStore.presetURL(
            for: id, in: URL(fileURLWithPath: "/tmp")
        ).lastPathComponent

        guard case .preset(let found) = FileIRCreativePresetStore.classify(fileNamed: name) else {
            Issue.record("Expected .preset, got \(FileIRCreativePresetStore.classify(fileNamed: name))")
            return
        }
        #expect(found == id)
    }

    @Test(
        "A name with our suffix and an invalid token is malformed, not foreign",
        arguments: [
            ("BAD PRESET!.irpreset.json", "BAD PRESET!"),
            (".irpreset.json", ""),
            ("not-a-valid-identifier.irpreset.json", "not-a-valid-identifier"),
            ("User.ABC.irpreset.json", "User.ABC"),
        ]
    )
    func malformedNames(name: String, expectedToken: String) {
        guard case .malformed(let token, let reason) =
            FileIRCreativePresetStore.classify(fileNamed: name)
        else {
            Issue.record("Expected .malformed for \(name)")
            return
        }
        #expect(token == expectedToken)
        #expect(!reason.isEmpty)
    }

    // MARK: - Path safety

    @Test("The production location is a pure path, nothing created or read")
    func applicationSupportDirectoryIsWhereClaimed() throws {
        let directory = try FileIRCreativePresetStore.applicationSupportDirectory()
        #expect(directory.path.hasSuffix("Infrared Converter/Presets"))
    }

    // MARK: - Save then load

    @Test("A saved preset is returned by loadAll(), with no failures")
    func saveThenLoad() throws {
        try Self.withSandbox { sandbox in
            let preset = Self.makePreset(
                id: try IRCreativePresetID("user.720-sky"),
                name: "720 nm Sky",
                channelMix: .redBlueSwap,
                filter: try IRFilterDescriptor.longPass(nominalNanometers: 720)
            )
            try sandbox.store.save(preset)

            let load = sandbox.store.loadAll()
            #expect(load.failures.isEmpty)
            #expect(load.presets == [preset])
        }
    }

    /// The mix round-trips through the file store exactly as it does through
    /// the bare record — this is that same claim proved end to end, disk
    /// included.
    @Test("An asymmetric explicit matrix round-trips through the file store bit-identically")
    func anAsymmetricMatrixRoundTripsThroughTheStore() throws {
        try Self.withSandbox { sandbox in
            let matrix = try RAWColorMatrix3x3(
                m00: 0.5, m01: -1.25, m02: 2.0,
                m10: 0.0, m11: 3.75, m12: -0.5,
                m20: 1.0, m21: 0.25, m22: -2.5
            )
            let preset = Self.makePreset(name: "Asymmetric", channelMix: .explicit(matrix))
            try sandbox.store.save(preset)

            let loaded = try #require(sandbox.store.loadAll().presets.first)
            #expect(loaded.channelMix.matrix.m00 == 0.5)
            #expect(loaded.channelMix.matrix.m01 == -1.25)
            #expect(loaded.channelMix.matrix.m02 == 2.0)
            #expect(loaded.channelMix.matrix.m10 == 0.0)
            #expect(loaded.channelMix.matrix.m11 == 3.75)
            #expect(loaded.channelMix.matrix.m12 == -0.5)
            #expect(loaded.channelMix.matrix.m20 == 1.0)
            #expect(loaded.channelMix.matrix.m21 == 0.25)
            #expect(loaded.channelMix.matrix.m22 == -2.5)
            #expect(loaded == preset)
        }
    }

    @Test(
        "Each common nominal cutoff round-trips through the file store",
        arguments: IRFilterDescriptor.commonNominalCutoffsNanometers
    )
    func nominalCutoffsRoundTripThroughTheStore(nanometers: Double) throws {
        try Self.withSandbox { sandbox in
            let filter = try IRFilterDescriptor.longPass(nominalNanometers: nanometers)
            let preset = Self.makePreset(channelMix: .redBlueSwap, filter: filter)
            try sandbox.store.save(preset)

            let loaded = try #require(sandbox.store.loadAll().presets.first)
            #expect(loaded.filter == filter)
            #expect(loaded.filterLabel?.contains("nominal") == true)
        }
    }

    // MARK: - Lazy directory creation

    @Test("An absent directory loads as empty and successful, and stays absent")
    func lazyDirectoryCreation() throws {
        try Self.withSandbox { sandbox in
            #expect(!sandbox.directoryExists)

            let load = sandbox.store.loadAll()
            #expect(load.presets.isEmpty)
            #expect(load.failures.isEmpty)
            #expect(!sandbox.directoryExists)

            try sandbox.store.save(Self.makePreset())
            #expect(sandbox.directoryExists)
        }
    }

    // MARK: - Save is a replace

    @Test("Saving twice under the same id leaves one file, and loadAll() returns the second definition")
    func saveIsAReplace() throws {
        try Self.withSandbox { sandbox in
            let id = IRCreativePresetID.generatedUserID()
            try sandbox.store.save(Self.makePreset(id: id, name: "First"))
            try sandbox.store.save(Self.makePreset(id: id, name: "Second"))

            let contents = try FileManager.default.contentsOfDirectory(
                at: sandbox.directory, includingPropertiesForKeys: nil
            )
            #expect(contents.count == 1)

            let load = sandbox.store.loadAll()
            #expect(load.failures.isEmpty)
            #expect(load.presets.map(\.name) == ["Second"])
        }
    }

    // MARK: - Delete

    @Test("Deleting removes the file, and deleting an id that is not stored is not an error")
    func deleteRemoves() throws {
        try Self.withSandbox { sandbox in
            let id = IRCreativePresetID.generatedUserID()
            try sandbox.store.save(Self.makePreset(id: id))
            #expect(sandbox.fileExists(for: id))

            try sandbox.store.delete(id)
            #expect(!sandbox.fileExists(for: id))
            #expect(sandbox.store.loadAll().presets.isEmpty)

            #expect(throws: Never.self) { try sandbox.store.delete(id) }
            #expect(throws: Never.self) { try sandbox.store.delete(.generatedUserID()) }
        }
    }

    // MARK: - Foreign files are ignored in silence

    @Test("Foreign files beside a preset are ignored in silence")
    func foreignFilesAreIgnored() throws {
        try Self.withSandbox { sandbox in
            let preset = Self.makePreset(name: "Kept")
            try sandbox.store.save(preset)

            try Data().write(to: sandbox.directory.appendingPathComponent(".DS_Store"))
            try Data("a note to myself".utf8)
                .write(to: sandbox.directory.appendingPathComponent("notes.txt"))

            let load = sandbox.store.loadAll()
            #expect(load.failures.isEmpty)
            #expect(load.presets == [preset])
        }
    }

    // MARK: - Malformed filenames are reported, not silently skipped

    @Test("A malformed preset filename is reported, and costs only that file")
    func malformedFilenameIsReported() throws {
        try Self.withSandbox { sandbox in
            let kept = Self.makePreset(name: "Kept")
            try sandbox.store.save(kept)

            let badName = "BAD PRESET!.irpreset.json"
            let badURL = sandbox.directory.appendingPathComponent(badName)
            try Data(#"{"schemaVersion":1}"#.utf8).write(to: badURL)

            let load = sandbox.store.loadAll()

            #expect(load.presets == [kept])
            #expect(load.failures.count == 1)

            guard case .invalidPresetFilename(let url, let token, let reason) =
                try #require(load.failures.first)
            else {
                Issue.record("Expected .invalidPresetFilename, got \(load.failures)")
                return
            }
            #expect(url.lastPathComponent == badName)
            #expect(token == "BAD PRESET!")
            #expect(!reason.isEmpty)
            #expect(FileManager.default.fileExists(atPath: badURL.path))
        }
    }

    /// The requirement stated most concretely: two good presets and one bad
    /// file must yield both good presets **and** exactly one reported
    /// failure — never a library that silently drops to one preset, and
    /// never one that throws its whole load away over one bad file.
    @Test("One malformed preset file does not prevent valid presets from loading")
    func oneMalformedFileDoesNotBlockValidPresets() throws {
        try Self.withSandbox { sandbox in
            let first = Self.makePreset(id: try IRCreativePresetID("user.p1"), name: "P1")
            let second = Self.makePreset(id: try IRCreativePresetID("user.p2"), name: "P2")
            try sandbox.store.save(first)
            try sandbox.store.save(second)

            let garbageURL = sandbox.directory.appendingPathComponent("user.p3.irpreset.json")
            try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x10, 0x20]).write(to: garbageURL)

            let load = sandbox.store.loadAll()
            #expect(Set(load.presets.map(\.id)) == Set([first.id, second.id]))
            #expect(load.failures.count == 1)
            guard case .cannotDecode(let url, _) = try #require(load.failures.first) else {
                Issue.record("Expected .cannotDecode, got \(load.failures)")
                return
            }
            #expect(url.lastPathComponent == garbageURL.lastPathComponent)
        }
    }

    // MARK: - Filename/payload mismatch

    @Test("A file whose name and payload disagree is refused, not reconciled")
    func filenamePayloadMismatchIsRefused() throws {
        try Self.withSandbox { sandbox in
            try sandbox.createDirectory()
            let namedID = try IRCreativePresetID("user.aaa")
            let payloadID = try IRCreativePresetID("user.bbb")
            let url = FileIRCreativePresetStore.presetURL(for: namedID, in: sandbox.directory)

            let record = IRCreativePresetRecord(
                Self.makePreset(id: payloadID, name: "Stored under the wrong name")
            )
            try JSONEncoder().encode(record).write(to: url)

            let load = sandbox.store.loadAll()
            #expect(load.presets.isEmpty)

            guard case .filenameIdentityMismatch(let failedURL, let expected, let found) =
                try #require(load.failures.first)
            else {
                Issue.record("Expected .filenameIdentityMismatch, got \(load.failures)")
                return
            }
            #expect(failedURL.lastPathComponent == url.lastPathComponent)
            #expect(expected == namedID)
            #expect(found == payloadID)
        }
    }

    // MARK: - The reserved builtin namespace

    @Test("Saving a preset in the builtin namespace is refused, and nothing is written")
    func reservedNamespaceOnSave() throws {
        try Self.withSandbox { sandbox in
            let id = try IRCreativePresetID("builtin.impostor")
            let preset = Self.makePreset(id: id, name: "Not really built in")
            let refusal = try #require(Self.saveRefusal(preset, sandbox.store))
            guard case .reservedIdentifier(let refusedID, _) = refusal else {
                Issue.record("Expected .reservedIdentifier, got \(refusal)")
                return
            }
            #expect(refusedID == id)
            #expect(!sandbox.directoryExists)
        }
    }

    @Test("A hand-written file named for a builtin identity is refused, and not loaded")
    func reservedNamespaceOnLoad() throws {
        try Self.withSandbox { sandbox in
            try sandbox.createDirectory()
            let id = try IRCreativePresetID("builtin.impostor")
            let url = FileIRCreativePresetStore.presetURL(for: id, in: sandbox.directory)
            let record = IRCreativePresetRecord(Self.makePreset(id: id))
            try JSONEncoder().encode(record).write(to: url)

            let load = sandbox.store.loadAll()
            #expect(load.presets.isEmpty)
            guard case .reservedIdentifier(let refusedID, _) = try #require(load.failures.first)
            else {
                Issue.record("Expected .reservedIdentifier, got \(load.failures)")
                return
            }
            #expect(refusedID == id)
        }
    }

    @Test("Deleting a builtin identity is refused")
    func reservedNamespaceOnDelete() throws {
        try Self.withSandbox { sandbox in
            let id = try IRCreativePresetID("builtin.impostor")
            #expect(throws: IRCreativePresetPersistenceError.self) {
                try sandbox.store.delete(id)
            }
        }
    }

    // MARK: - Determinism and readability

    @Test("The written file is pretty-printed, sorted, and valid UTF-8 JSON a person can read")
    func writtenFileIsReadable() throws {
        try Self.withSandbox { sandbox in
            let preset = Self.makePreset(
                id: try IRCreativePresetID("user.readable"), name: "Readable"
            )
            try sandbox.store.save(preset)

            let url = FileIRCreativePresetStore.presetURL(for: preset.id, in: sandbox.directory)
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)

            #expect(text.contains("\"schemaVersion\""))
            #expect(text.contains("\"user.readable\""))
            #expect(text.contains("\n"))

            // Sorted keys: "channelMix" precedes "id" precedes "name".
            let channelMixRange = try #require(text.range(of: "\"channelMix\""))
            let idRange = try #require(text.range(of: "\"id\""))
            let nameRange = try #require(text.range(of: "\"name\""))
            #expect(channelMixRange.lowerBound < idRange.lowerBound)
            #expect(idRange.lowerBound < nameRange.lowerBound)

            let decoded = try JSONDecoder().decode(IRCreativePresetRecord.self, from: data)
            #expect(decoded.preset == preset)
        }
    }

    // MARK: - Deterministic ordering

    @Test("loadAll() ordering is deterministic across repeated loads")
    func loadOrderIsDeterministic() throws {
        try Self.withSandbox { sandbox in
            let ids = try ["user.charlie", "user.alpha", "user.bravo"]
                .map(IRCreativePresetID.init)
            for id in ids {
                try sandbox.store.save(Self.makePreset(id: id, name: id.rawValue))
            }

            let first = sandbox.store.loadAll().presets.map(\.id.rawValue)
            let second = sandbox.store.loadAll().presets.map(\.id.rawValue)
            #expect(first == second)
            #expect(first == ids.map(\.rawValue).sorted())
        }
    }
}
