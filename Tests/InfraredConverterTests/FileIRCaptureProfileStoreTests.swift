import Testing
import Foundation
@testable import InfraredConverter

/// The file-backed capture-profile store on its own: naming, path safety,
/// round-tripping, lazy directory creation, replacement, deletion, and the
/// refusals — corrupt files, duplicate identities, the reserved builtin
/// namespace, and a processing basis with no wire format.
///
/// Every test works inside its own temporary directory, constructed fresh for
/// each test. **No test ever touches the real Application Support
/// directory** — every store under test is built with
/// `FileIRCaptureProfileStore(directory:)` pointed at that temporary
/// directory. The one exception is `applicationSupportDirectoryIsWhereClaimed`,
/// which asserts the shape of the production path as a pure string, without
/// creating, reading or writing anything.
@Suite("FileIRCaptureProfileStore")
struct FileIRCaptureProfileStoreTests {

    /// A temporary directory a store can be pointed at.
    ///
    /// Deliberately does **not** create the directory in `init`, unlike this
    /// project's other store sandboxes: this suite exists in part to prove
    /// that reading an absent library creates nothing, so the directory must
    /// still be absent when a test begins.
    struct Sandbox {
        let directory: URL
        let store: FileIRCaptureProfileStore

        init() {
            // Resolved up front: `/tmp` and `NSTemporaryDirectory()` are
            // symlinks into `/private` on macOS, and `FileManager` hands back
            // the resolved form from `contentsOfDirectory(at:)`. Building the
            // directory unresolved would make every URL this suite
            // constructs by hand disagree with one the store discovers by
            // enumeration, for a reason that has nothing to do with the
            // store's own behaviour.
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ircaptureprofile-store-tests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            store = FileIRCaptureProfileStore(directory: directory)
        }

        var directoryExists: Bool {
            FileManager.default.fileExists(atPath: directory.path)
        }

        func fileExists(for id: IRCaptureProfileID) -> Bool {
            FileManager.default.fileExists(
                atPath: FileIRCaptureProfileStore.profileURL(for: id, in: directory).path
            )
        }

        /// Creates the directory by hand, for a test that writes a file
        /// directly rather than through `save`.
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

    /// A profile a test can save, with sensible defaults and a fresh
    /// identity per call so tests do not collide with one another.
    static func makeProfile(
        id: IRCaptureProfileID = .generatedUserID(),
        name: String = "Test Profile",
        cameraMatch: IRCameraMatch = .any,
        sensorConversion: IRSensorConversion = .unknown,
        filter: IRFilterDescriptor = .unknown,
        processingBasis: IRCaptureProcessingBasis = .uncalibratedSensorRGB
    ) -> IRCaptureProfile {
        IRCaptureProfile(
            id: id,
            name: name,
            cameraMatch: cameraMatch,
            sensorConversion: sensorConversion,
            filter: filter,
            processingBasis: processingBasis
        )
    }

    /// The refusal a save produced, or `nil` when it did not refuse.
    static func saveRefusal(
        _ profile: IRCaptureProfile, _ store: FileIRCaptureProfileStore
    ) -> IRCaptureProfilePersistenceError? {
        do {
            try store.save(profile)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The name rule

    @Test("profileURL(for:in:) is <id>.irprofile.json in the given directory, deterministically")
    func namingRule() throws {
        let directory = URL(fileURLWithPath: "/tmp/some-profiles", isDirectory: true)
        let id = try IRCaptureProfileID("user.550e8400-e29b-41d4-a716-446655440000")

        let url = FileIRCaptureProfileStore.profileURL(for: id, in: directory)
        #expect(
            url.lastPathComponent
                == "user.550e8400-e29b-41d4-a716-446655440000.irprofile.json"
        )
        #expect(url == FileIRCaptureProfileStore.profileURL(for: id, in: directory))
    }

    @Test("profileID(forFileNamed:) is the inverse of the naming rule for our own names")
    func namingRuleIsInvertible() throws {
        let id = try IRCaptureProfileID("user.550e8400-e29b-41d4-a716-446655440000")
        let name = FileIRCaptureProfileStore.profileURL(
            for: id, in: URL(fileURLWithPath: "/tmp")
        ).lastPathComponent
        #expect(FileIRCaptureProfileStore.profileID(forFileNamed: name) == id)
    }

    @Test(
        "A name that is not one of ours, or whose token is not a valid identifier, is nil",
        arguments: [
            ".DS_Store",
            "notes.txt",
            "user.abc.irprofile.json.bak",
            "not-a-valid-identifier.irprofile.json",
        ]
    )
    func foreignOrInvalidNamesAreNil(name: String) {
        #expect(FileIRCaptureProfileStore.profileID(forFileNamed: name) == nil)
    }

    // MARK: - Path safety

    @Test("A profile's file stays inside the store's directory, whatever its identity")
    func pathSafety() throws {
        let directory = URL(fileURLWithPath: "/tmp/ircaptureprofile-path-safety", isDirectory: true)
        let ids = (0..<20).map { _ in IRCaptureProfileID.generatedUserID() }
            + [
                try IRCaptureProfileID("user.a-b"),
                try IRCaptureProfileID("user.a.deeply.namespaced.one"),
                .builtinUncalibrated,
            ]

        for id in ids {
            let url = FileIRCaptureProfileStore.profileURL(for: id, in: directory)
            #expect(!url.lastPathComponent.contains("/"))
            #expect(url.deletingLastPathComponent() == directory)
            #expect(!url.pathComponents.contains(".."))
        }
    }

    @Test("The production location is a pure path, nothing created or read")
    func applicationSupportDirectoryIsWhereClaimed() throws {
        let directory = try FileIRCaptureProfileStore.applicationSupportDirectory()
        #expect(directory.path.hasSuffix("Infrared Converter/Profiles"))
    }

    // MARK: - Save then load

    @Test("A saved profile is returned by loadAll(), with no failures")
    func saveThenLoad() throws {
        try Self.withSandbox { sandbox in
            let profile = Self.makeProfile(
                id: try IRCaptureProfileID("user.epl3-720nm"),
                name: "E-PL3 — 720 nm",
                cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
                sensorConversion: .fullSpectrum(vendor: "Some Converter"),
                filter: try IRFilterDescriptor.longPass(nominalNanometers: 720)
            )
            try sandbox.store.save(profile)

            let load = sandbox.store.loadAll()
            #expect(load.failures.isEmpty)
            #expect(load.profiles == [profile])
        }
    }

    // MARK: - Lazy directory creation

    @Test("An absent directory loads as empty and successful, and stays absent")
    func lazyDirectoryCreation() throws {
        try Self.withSandbox { sandbox in
            #expect(!sandbox.directoryExists)

            let load = sandbox.store.loadAll()
            #expect(load.profiles.isEmpty)
            #expect(load.failures.isEmpty)
            #expect(!sandbox.directoryExists)

            try sandbox.store.save(Self.makeProfile())
            #expect(sandbox.directoryExists)
        }
    }

    // MARK: - Save is a replace

    @Test("Saving twice under the same id leaves one file, and loadAll() returns the second definition")
    func saveIsAReplace() throws {
        try Self.withSandbox { sandbox in
            let id = IRCaptureProfileID.generatedUserID()
            try sandbox.store.save(Self.makeProfile(id: id, name: "First"))
            try sandbox.store.save(Self.makeProfile(id: id, name: "Second"))

            let contents = try FileManager.default.contentsOfDirectory(
                at: sandbox.directory, includingPropertiesForKeys: nil
            )
            #expect(contents.count == 1)

            let load = sandbox.store.loadAll()
            #expect(load.failures.isEmpty)
            #expect(load.profiles.map(\.name) == ["Second"])
        }
    }

    // MARK: - Delete

    @Test("Deleting removes the file, and deleting an id that is not stored is not an error")
    func deleteRemoves() throws {
        try Self.withSandbox { sandbox in
            let id = IRCaptureProfileID.generatedUserID()
            try sandbox.store.save(Self.makeProfile(id: id))
            #expect(sandbox.fileExists(for: id))

            try sandbox.store.delete(id)
            #expect(!sandbox.fileExists(for: id))
            #expect(sandbox.store.loadAll().profiles.isEmpty)

            // The end state already holds: not an error.
            #expect(throws: Never.self) { try sandbox.store.delete(id) }
            #expect(throws: Never.self) { try sandbox.store.delete(.generatedUserID()) }
        }
    }

    // MARK: - Foreign files are ignored in silence

    @Test("Foreign files beside a profile are ignored in silence")
    func foreignFilesAreIgnored() throws {
        try Self.withSandbox { sandbox in
            let profile = Self.makeProfile(name: "Kept")
            try sandbox.store.save(profile)

            try Data().write(to: sandbox.directory.appendingPathComponent(".DS_Store"))
            try Data("a note to myself".utf8)
                .write(to: sandbox.directory.appendingPathComponent("notes.txt"))
            try Data("# not a profile".utf8)
                .write(to: sandbox.directory.appendingPathComponent("README.md"))

            let load = sandbox.store.loadAll()
            #expect(load.failures.isEmpty)
            #expect(load.profiles == [profile])
        }
    }

    // MARK: - Corrupt-file isolation

    @Test("A corrupt file is isolated: the rest of the library still loads, and the failure names it")
    func corruptFileIsolation() throws {
        try Self.withSandbox { sandbox in
            let p1 = Self.makeProfile(id: try IRCaptureProfileID("user.p1"), name: "P1")
            let p3 = Self.makeProfile(id: try IRCaptureProfileID("user.p3"), name: "P3")
            try sandbox.store.save(p1)
            try sandbox.store.save(p3)

            let corruptURL = FileIRCaptureProfileStore.profileURL(
                for: try IRCaptureProfileID("user.p2"), in: sandbox.directory
            )
            try Data("{ not json".utf8).write(to: corruptURL)

            let load = sandbox.store.loadAll()
            #expect(Set(load.profiles.map(\.id)) == Set([p1.id, p3.id]))
            #expect(load.failures.count == 1)

            guard case .cannotDecode(let url, _) = try #require(load.failures.first) else {
                Issue.record("Expected .cannotDecode, got \(String(describing: load.failures.first))")
                return
            }
            // Compared by name rather than by whole URL: `contentsOfDirectory`
            // returns paths with the temporary directory's symlink resolved
            // (`/private/var/...` where the sandbox built `/var/...`), and the
            // claim under test is *which file refused*, not how the path was
            // spelled.
            #expect(url.lastPathComponent == corruptURL.lastPathComponent)
            #expect(url.resolvingSymlinksInPath() == corruptURL.resolvingSymlinksInPath())
        }
    }

    // MARK: - A schema version from the future

    @Test("A profile at an unsupported schema version is a typed refusal that survives the file boundary")
    func unsupportedSchemaVersionSurvives() throws {
        try Self.withSandbox { sandbox in
            try sandbox.createDirectory()
            let url = FileIRCaptureProfileStore.profileURL(
                for: try IRCaptureProfileID("user.future"), in: sandbox.directory
            )
            try Data(
                """
                {
                  "schemaVersion": 99,
                  "id": "user.future",
                  "name": "From the future",
                  "cameraMatch": { "kind": "any" },
                  "sensorConversion": { "kind": "unknown" },
                  "filter": { "kind": "unknown" },
                  "processingBasis": { "kind": "uncalibratedSensorRGB" }
                }
                """.utf8
            ).write(to: url)

            let load = sandbox.store.loadAll()
            #expect(load.profiles.isEmpty)
            let failure = try #require(load.failures.first)
            #expect(
                failure.record
                    == .unsupportedSchemaVersion(
                        found: 99, supported: IRCaptureProfile.currentSchemaVersion
                    )
            )
        }
    }

    // MARK: - Filename/payload mismatch

    @Test("A file whose name and payload disagree is refused, not reconciled")
    func filenamePayloadMismatchIsRefused() throws {
        try Self.withSandbox { sandbox in
            try sandbox.createDirectory()
            let namedID = try IRCaptureProfileID("user.aaa")
            let payloadID = try IRCaptureProfileID("user.bbb")
            let url = FileIRCaptureProfileStore.profileURL(for: namedID, in: sandbox.directory)

            let record = try IRCaptureProfileRecord(
                Self.makeProfile(id: payloadID, name: "Stored under the wrong name")
            )
            try JSONEncoder().encode(record).write(to: url)

            let load = sandbox.store.loadAll()
            #expect(load.profiles.isEmpty)

            guard case .filenameIdentityMismatch(let failedURL, let expected, let found)
                = try #require(load.failures.first)
            else {
                Issue.record("Expected .filenameIdentityMismatch, got \(String(describing: load.failures.first))")
                return
            }
            // By name, for the same reason as above: the enumerated path has
            // the temporary directory's symlink resolved.
            #expect(failedURL.lastPathComponent == url.lastPathComponent)
            #expect(failedURL.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
            #expect(expected == namedID)
            #expect(found == payloadID)
        }
    }

    // MARK: - Duplicate identity

    /// A stub store, conforming only to the protocol, that reports two
    /// profiles sharing one identity.
    ///
    /// `save` derives a file's name from the profile's own identity
    /// (`profileURL(for:in:)`), so two files can never claim one id on disk —
    /// the filename/payload-mismatch refusal above is the closest that gets,
    /// and it refuses rather than producing a duplicate. That makes the
    /// duplicate-identity case unreachable through `FileIRCaptureProfileStore`
    /// itself. The refusal still has to exist, so it is proved directly
    /// against `IRCaptureProfileStore`'s protocol surface instead: a stub
    /// whose `loadAll()` simply hands back two profiles with the same id, fed
    /// as `userProfiles` to `IRCaptureProfileRegistry`, which must refuse
    /// rather than silently keep one and drop the other.
    private struct DuplicateStubStore: IRCaptureProfileStore {
        let profiles: [IRCaptureProfile]
        func loadAll() -> IRCaptureProfileLibraryLoad {
            IRCaptureProfileLibraryLoad(profiles: profiles)
        }
        func save(_ profile: IRCaptureProfile) throws(IRCaptureProfilePersistenceError) {}
        func delete(_ id: IRCaptureProfileID) throws(IRCaptureProfilePersistenceError) {}
    }

    @Test("Two profiles claiming one identity are refused by the registry, never resolved")
    func duplicateIdentityIsRefusedThroughTheRegistry() throws {
        let id = try IRCaptureProfileID("user.duplicate")
        let stub = DuplicateStubStore(profiles: [
            Self.makeProfile(id: id, name: "First"),
            Self.makeProfile(id: id, name: "Second"),
        ])

        #expect(throws: IRCaptureProfileError.duplicateProfileID(id: id)) {
            _ = try IRCaptureProfileRegistry(userProfiles: stub.loadAll().profiles)
        }
    }

    // MARK: - The reserved builtin namespace

    @Test("Saving a profile in the builtin namespace is refused, and nothing is written")
    func reservedNamespaceOnSave() throws {
        try Self.withSandbox { sandbox in
            let profile = Self.makeProfile(id: .builtinUncalibrated, name: "Not really built in")
            let refusal = try #require(Self.saveRefusal(profile, sandbox.store))
            guard case .reservedIdentifier(let id, _) = refusal else {
                Issue.record("Expected .reservedIdentifier, got \(refusal)")
                return
            }
            #expect(id == .builtinUncalibrated)
            #expect(!sandbox.directoryExists)
        }
    }

    @Test("A hand-written file named for a builtin identity is refused, and not loaded")
    func reservedNamespaceOnLoad() throws {
        try Self.withSandbox { sandbox in
            try sandbox.createDirectory()
            let url = FileIRCaptureProfileStore.profileURL(
                for: .builtinUncalibrated, in: sandbox.directory
            )
            let record = try IRCaptureProfileRecord(.builtinUncalibrated)
            try JSONEncoder().encode(record).write(to: url)

            let load = sandbox.store.loadAll()
            #expect(load.profiles.isEmpty)
            guard case .reservedIdentifier(let id, _) = try #require(load.failures.first) else {
                Issue.record("Expected .reservedIdentifier, got \(String(describing: load.failures.first))")
                return
            }
            #expect(id == .builtinUncalibrated)
        }
    }

    @Test("Deleting a builtin identity is refused")
    func reservedNamespaceOnDelete() throws {
        try Self.withSandbox { sandbox in
            #expect(throws: IRCaptureProfilePersistenceError.self) {
                try sandbox.store.delete(.builtinUncalibrated)
            }
        }
    }

    // MARK: - A processing basis with no wire format

    @Test("Saving a profile with an unsupported processing basis is refused, and leaves no file")
    func unsupportedProcessingBasisOnSave() throws {
        try Self.withSandbox { sandbox in
            let matrix = try RAWColorMatrix3x3(
                m00: 1, m01: 0, m02: 0,
                m10: 0, m11: 1, m12: 0,
                m20: 0, m21: 0, m22: 1
            )
            let id = IRCaptureProfileID.generatedUserID()
            let profile = Self.makeProfile(id: id, processingBasis: .explicitMatrix(matrix))

            let refusal = try #require(Self.saveRefusal(profile, sandbox.store))
            guard case .unsupportedProcessingBasis(let failedID, _) = refusal else {
                Issue.record("Expected .unsupportedProcessingBasis, got \(refusal)")
                return
            }
            #expect(failedID == id)

            // Refused before anything was created, not merely before this one
            // profile's file: the directory itself never came into being.
            #expect(!sandbox.directoryExists)
            #expect(!sandbox.fileExists(for: id))
        }
    }

    // MARK: - Determinism and readability

    @Test("The written file is pretty-printed, sorted, and valid UTF-8 JSON a person can read")
    func writtenFileIsReadable() throws {
        try Self.withSandbox { sandbox in
            let profile = Self.makeProfile(
                id: try IRCaptureProfileID("user.readable"), name: "Readable"
            )
            try sandbox.store.save(profile)

            let url = FileIRCaptureProfileStore.profileURL(for: profile.id, in: sandbox.directory)
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)

            #expect(text.contains("\"schemaVersion\""))
            #expect(text.contains("\"user.readable\""))
            // Pretty-printed: more than one line.
            #expect(text.contains("\n"))

            // Sorted keys: "cameraMatch" precedes "id" precedes "name".
            let cameraRange = try #require(text.range(of: "\"cameraMatch\""))
            let idRange = try #require(text.range(of: "\"id\""))
            let nameRange = try #require(text.range(of: "\"name\""))
            #expect(cameraRange.lowerBound < idRange.lowerBound)
            #expect(idRange.lowerBound < nameRange.lowerBound)

            // Valid JSON, and it round-trips to the profile it was saved from.
            let decoded = try JSONDecoder().decode(IRCaptureProfileRecord.self, from: data)
            #expect(decoded.profile == profile)
        }
    }

    // MARK: - Deterministic ordering

    @Test("loadAll() ordering is deterministic across repeated loads")
    func loadOrderIsDeterministic() throws {
        try Self.withSandbox { sandbox in
            let ids = try ["user.charlie", "user.alpha", "user.bravo"]
                .map(IRCaptureProfileID.init)
            for id in ids {
                try sandbox.store.save(Self.makeProfile(id: id, name: id.rawValue))
            }

            let first = sandbox.store.loadAll().profiles.map(\.id.rawValue)
            let second = sandbox.store.loadAll().profiles.map(\.id.rawValue)
            #expect(first == second)
            // Sorted by filename, which for these identities is also
            // alphabetical.
            #expect(first == ids.map(\.rawValue).sorted())
        }
    }
}
