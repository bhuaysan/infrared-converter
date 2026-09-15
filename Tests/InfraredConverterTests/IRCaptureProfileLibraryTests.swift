import Testing
import Foundation
@testable import InfraredConverter

/// The profile library: the one owner of capture-profile definitions, and the
/// four things that can happen to them.
///
/// Every test builds its own store over a **temporary directory**. Nothing here
/// reads or writes the real Application Support folder, because a suite that
/// did would leave profiles on the machine it ran on and would pass or fail
/// depending on what somebody had created there earlier.
@Suite("IR capture profile library")
@MainActor
struct IRCaptureProfileLibraryTests {

    /// A temporary profile directory and a library over it.
    struct Sandbox {
        let directory: URL
        let store: FileIRCaptureProfileStore

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("irprofile-library-\(UUID().uuidString)")
            // Deliberately not created here. A library that has never been
            // written to is the ordinary first-run state, and several tests
            // below are about exactly that.
            store = FileIRCaptureProfileStore(directory: directory)
        }

        @MainActor
        func makeLibrary() -> IRCaptureProfileLibrary {
            IRCaptureProfileLibrary(store: store)
        }

        /// Writes a file into the profile directory by hand, creating it first.
        func writeFile(named name: String, contents: String) throws {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }

        var fileNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    static func withSandbox(_ body: (Sandbox) throws -> Void) throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try body(sandbox)
    }

    /// A draft for a plausible real configuration, the one the milestone is
    /// named after.
    static func epl3Draft(name: String = "My Olympus E-PL3 — R72") -> IRCaptureProfileDraft {
        IRCaptureProfileDraft(
            name: name,
            cameraScope: .specificCamera,
            cameraMake: "OLYMPUS IMAGING CORP.",
            cameraModel: "E-PL3",
            conversionKind: .fullSpectrum,
            conversionVendor: "Some Converter",
            filter: IRCaptureProfileDraft.FilterDraft(
                kind: .longPass, nominalCutoffNanometers: "720"
            )
        )
    }

    // MARK: - First run

    /// The normal first-run state, and it is not an error.
    ///
    /// A photographer who has never created a profile has an application that
    /// works, offers the built-in profile, and reports nothing wrong — and a
    /// file system this application has not touched.
    @Test("An absent profile directory is a built-in-only library, not a failure")
    func absentDirectoryIsNotAFailure() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()

            #expect(library.loadFailures.isEmpty)
            #expect(library.userProfiles.isEmpty)
            #expect(library.registry.allProfiles == [.builtinUncalibrated])
            // Reading a library creates nothing.
            #expect(!FileManager.default.fileExists(atPath: sandbox.directory.path))
        }
    }

    // MARK: - Creating

    /// The claim is "no restart": the registry a document consumes contains the
    /// new profile the moment `create` returns.
    @Test("A created profile is in the registry immediately")
    func createdProfileIsInTheRegistryImmediately() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let before = library.version

            let profile = try library.create(Self.epl3Draft())

            #expect(library.registry.contains(profile.id))
            let resolved = try library.registry.profile(for: profile.id)
            #expect(resolved == profile)
            #expect(library.userProfiles == [profile])
            #expect(library.version > before)

            // And it is on disk, under its own identity, not in some index.
            #expect(sandbox.fileNames == ["\(profile.id.rawValue).irprofile.json"])
        }
    }

    /// Identity is generated and is not the name. Two profiles a person calls
    /// the same thing are two profiles.
    @Test("Created profiles get distinct generated identities, never the name")
    func createdProfilesGetGeneratedIdentities() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()

            let first = try library.create(Self.epl3Draft(name: "720 nm"))
            let second = try library.create(Self.epl3Draft(name: "720 nm"))

            #expect(first.id != second.id)
            #expect(first.id.namespace == IRCaptureProfileID.userNamespace)
            // Generated, and therefore incapable of carrying the name: what
            // follows the namespace is a UUID.
            //
            // Asserting merely that the identifier does not *contain* "720"
            // was both weaker and unsound — a random UUID's hex spells those
            // three digits roughly one run in a hundred, which says nothing
            // at all about where the identity came from.
            for id in [first.id, second.id] {
                let generated = id.rawValue.dropFirst(
                    IRCaptureProfileID.userNamespace.count + 1
                )
                #expect(UUID(uuidString: String(generated)) != nil, "\(id.rawValue)")
            }
            #expect(library.userProfiles.count == 2)
        }
    }

    /// The honesty claim, restated where a user profile is actually made: a
    /// user-defined profile is not a calibrated one, however specifically it
    /// names a camera and a filter.
    @Test("A user-created profile is explicitly uncalibrated")
    func aUserCreatedProfileIsUncalibrated() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let profile = try library.create(Self.epl3Draft())

            #expect(profile.processingBasis == .uncalibratedSensorRGB)
            #expect(!profile.isValidatedInfraredCalibration)
            #expect(
                profile.cameraToWorkingTransform == .sensorRGBIdentityFalseColor
            )
        }
    }

    // MARK: - Renaming and editing

    /// The whole reason identity is not the display name: renaming must not
    /// cost a single photograph its profile.
    @Test("Renaming a profile changes its name and preserves its identity")
    func renamingPreservesIdentity() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let original = try library.create(Self.epl3Draft(name: "E-PL3 R72"))

            var draft = IRCaptureProfileDraft(original)
            draft.name = "My Olympus 720"
            let renamed = try library.update(draft, id: original.id)

            #expect(renamed.id == original.id)
            #expect(renamed.name == "My Olympus 720")
            let resolved = try library.registry.profile(for: original.id)
            #expect(resolved.name == "My Olympus 720")
            // Everything a photograph resolves through is unchanged.
            #expect(renamed.cameraMatch == original.cameraMatch)
            #expect(renamed.sensorConversion == original.sensorConversion)
            #expect(renamed.filter == original.filter)
            #expect(renamed.processingBasis == original.processingBasis)
            // One file, still under the original identity.
            #expect(sandbox.fileNames == ["\(original.id.rawValue).irprofile.json"])
        }
    }

    /// A descriptive edit: the filter gains a nominal wavelength it did not
    /// have. The identity and the processing basis are untouched, so no
    /// photograph's pixels can differ.
    @Test("Editing a profile's metadata keeps its identity and its processing")
    func editingMetadataKeepsIdentityAndProcessing() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            var initial = Self.epl3Draft()
            initial.filter = IRCaptureProfileDraft.FilterDraft(kind: .unknown)
            let original = try library.create(initial)
            #expect(original.filter == .unknown)

            var draft = IRCaptureProfileDraft(original)
            draft.filter = IRCaptureProfileDraft.FilterDraft(
                kind: .longPass, nominalCutoffNanometers: "720"
            )
            let edited = try library.update(draft, id: original.id)

            #expect(edited.id == original.id)
            #expect(edited.filter == .longPass(nominalCutoffNanometers: 720))
            #expect(edited.processingBasis == original.processingBasis)
            // Still not a calibration. A wavelength is a family label.
            #expect(!edited.isValidatedInfraredCalibration)
        }
    }

    /// Editing replaces a definition whole. Reloading from disk must agree with
    /// what is in memory, because the two are the same thing seen twice.
    @Test("An edited definition survives a reload")
    func anEditedDefinitionSurvivesAReload() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let original = try library.create(Self.epl3Draft(name: "First"))
            var draft = IRCaptureProfileDraft(original)
            draft.name = "Second"
            _ = try library.update(draft, id: original.id)

            let reopened = sandbox.makeLibrary()
            let resolved = try reopened.registry.profile(for: original.id)
            #expect(resolved.name == "Second")
            #expect(reopened.loadFailures.isEmpty)
        }
    }

    // MARK: - Deleting

    @Test("A deleted profile stops resolving, and its file is gone")
    func deletingRemovesTheProfile() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let profile = try library.create(Self.epl3Draft())

            try library.delete(profile.id)

            #expect(!library.registry.contains(profile.id))
            #expect(throws: IRCaptureProfileError.unknownProfile(id: profile.id)) {
                _ = try library.registry.profile(for: profile.id)
            }
            #expect(sandbox.fileNames.isEmpty)
            // The built-in profile is untouched by any of this.
            #expect(library.registry.contains(.builtinUncalibrated))
        }
    }

    /// Deleting one profile leaves the others exactly as they were. There is no
    /// index to fall out of step.
    @Test("Deleting one profile leaves the rest of the library alone")
    func deletingOneLeavesTheRest() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let first = try library.create(Self.epl3Draft(name: "First"))
            let second = try library.create(Self.epl3Draft(name: "Second"))

            try library.delete(first.id)

            #expect(library.userProfiles.map(\.id) == [second.id])
            let resolved = try library.registry.profile(for: second.id)
            #expect(resolved == second)
        }
    }

    // MARK: - The built-in profile is immutable

    /// `builtin.uncalibrated` is a value this build holds, not a file. It is
    /// what every historical sidecar migrates to and the one profile guaranteed
    /// to exist, so nothing may rename it, replace it or remove it.
    @Test("The built-in profile cannot be overwritten or deleted")
    func theBuiltInProfileIsImmutable() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()

            let impostor = IRCaptureProfile(
                id: .builtinUncalibrated,
                name: "Not the built-in one",
                processingBasis: .uncalibratedSensorRGB
            )
            #expect(throws: IRCaptureProfilePersistenceError.self) {
                try library.save(impostor)
            }
            #expect(throws: IRCaptureProfilePersistenceError.self) {
                try library.delete(.builtinUncalibrated)
            }

            #expect(library.isBuiltin(.builtinUncalibrated))
            let resolved = try library.registry.profile(for: .builtinUncalibrated)
            #expect(resolved == .builtinUncalibrated)
            #expect(sandbox.fileNames.isEmpty)
        }
    }

    /// A draft can never mint a reserved identity either, so the refusal holds
    /// at both ends of the creation path.
    @Test("A draft refuses a reserved identity")
    func aDraftRefusesAReservedIdentity() throws {
        #expect(throws: IRCaptureProfileDraftError.self) {
            _ = try Self.epl3Draft().makeProfile(id: .builtinUncalibrated)
        }
    }

    // MARK: - Load failures are reported, and isolate

    /// One corrupt file is one missing profile, not a missing library.
    @Test("A corrupt profile file is reported and does not hide the valid ones")
    func aCorruptFileIsIsolated() throws {
        try Self.withSandbox { sandbox in
            let seeding = sandbox.makeLibrary()
            let first = try seeding.create(Self.epl3Draft(name: "First"))
            let second = try seeding.create(Self.epl3Draft(name: "Second"))
            try sandbox.writeFile(
                named: "user.broken.irprofile.json", contents: "{ this is not json"
            )

            let library = sandbox.makeLibrary()

            let loadedIDs: [String] = library.userProfiles.map(\.id.rawValue).sorted()
            let expectedIDs: [String] = [first.id.rawValue, second.id.rawValue].sorted()
            #expect(loadedIDs == expectedIDs)
            #expect(library.registry.contains(.builtinUncalibrated))
            #expect(library.loadFailures.count == 1)
            let failure = try #require(library.loadFailures.first)
            guard case .cannotDecode = failure else {
                Issue.record("Expected .cannotDecode, got \(failure)")
                return
            }
        }
    }

    /// A file claiming a built-in identity is not admitted, whatever it
    /// contains, and it does not shadow the profile it is named after.
    @Test("A stored profile claiming a built-in identity is refused")
    func aStoredBuiltinIdentityIsRefused() throws {
        try Self.withSandbox { sandbox in
            try sandbox.writeFile(
                named: "builtin.uncalibrated.irprofile.json",
                contents: """
                    {
                      "schemaVersion": 1,
                      "id": "builtin.uncalibrated",
                      "name": "Impostor",
                      "cameraMatch": { "kind": "any" },
                      "sensorConversion": { "kind": "unknown" },
                      "filter": { "kind": "unknown" },
                      "processingBasis": { "kind": "uncalibratedSensorRGB" }
                    }
                    """
            )

            let library = sandbox.makeLibrary()

            #expect(library.userProfiles.isEmpty)
            let resolved = try library.registry.profile(for: .builtinUncalibrated)
            #expect(resolved == .builtinUncalibrated)
            #expect(library.loadFailures.count == 1)
            let failure = try #require(library.loadFailures.first)
            guard case .reservedIdentifier(let id, _) = failure else {
                Issue.record("Expected .reservedIdentifier, got \(failure)")
                return
            }
            #expect(id == .builtinUncalibrated)
        }
    }

    // MARK: - No library at all

    /// The location could not be determined. The built-in profile is a value,
    /// so the application still renders photographs; only user profiles are
    /// gone, and the library says so rather than looking empty.
    @Test("A library with no storage still offers the built-in profile")
    func aLibraryWithNoStorageStillWorks() throws {
        let library = IRCaptureProfileLibrary(
            store: nil,
            unavailable: .libraryUnavailable(underlying: IRCaptureProfileLibrary.Unavailable())
        )

        #expect(library.registry.allProfiles == [.builtinUncalibrated])
        #expect(library.loadFailures.count == 1)
        #expect(throws: IRCaptureProfilePersistenceError.self) {
            _ = try library.create(Self.epl3Draft())
        }
        #expect(throws: IRCaptureProfilePersistenceError.self) {
            try library.delete(try IRCaptureProfileID("user.anything"))
        }
    }

    // MARK: - Ordering

    /// The registry keeps two orders on purpose: one reproducible, one
    /// readable. A menu sorted by a field a person can rename is right for a
    /// menu and wrong for anything mechanical.
    @Test("Display order is built-in first, then user profiles by name")
    func displayOrderIsBuiltInFirstThenByName() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            _ = try library.create(Self.epl3Draft(name: "Zebra"))
            _ = try library.create(Self.epl3Draft(name: "Alpha"))

            #expect(library.profilesForDisplay.map(\.name)
                == ["Uncalibrated / Generic", "Alpha", "Zebra"])
            // And the deterministic listing is still sorted by identity, which
            // a rename cannot disturb.
            #expect(library.registry.allProfiles.map(\.id)
                == library.registry.allProfiles.map(\.id).sorted { $0.rawValue < $1.rawValue })
        }
    }

    // MARK: - Registry composition

    @Test("Composition refuses an identity claimed twice rather than picking one")
    func compositionRefusesDuplicates() throws {
        let duplicate = IRCaptureProfile(
            id: try IRCaptureProfileID("user.same"),
            name: "One",
            processingBasis: .uncalibratedSensorRGB
        )
        let other = IRCaptureProfile(
            id: try IRCaptureProfileID("user.same"),
            name: "Another",
            processingBasis: .uncalibratedSensorRGB
        )

        #expect(throws: IRCaptureProfileError.duplicateProfileID(id: duplicate.id)) {
            _ = try IRCaptureProfileRegistry(userProfiles: [duplicate, other])
        }
    }

    @Test("Composition always includes the built-in profiles")
    func compositionIncludesTheBuiltIns() throws {
        let user = IRCaptureProfile(
            id: try IRCaptureProfileID("user.one"),
            name: "One",
            processingBasis: .uncalibratedSensorRGB
        )
        let registry = try IRCaptureProfileRegistry(userProfiles: [user])

        #expect(registry.contains(.builtinUncalibrated))
        #expect(registry.contains(user.id))
        #expect(registry.count == 2)
        #expect(registry.userProfiles == [user])
    }
}
