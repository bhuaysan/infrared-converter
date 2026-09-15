import Testing
import Foundation
@testable import InfraredConverter

/// The preset library: the one owner of creative-preset definitions, and the
/// four things that can happen to them — create, list, rename, delete.
///
/// Every test builds its own store over a **temporary directory**. Nothing
/// here reads or writes the real Application Support folder.
///
/// Applying a preset is deliberately not tested here: the library's job ends
/// at handing back an `IRCreativePreset`, and what a document does with its
/// `channelMix` is `DocumentState`'s concern, owned by another suite.
@Suite("IRCreativePresetLibrary")
@MainActor
struct IRCreativePresetLibraryTests {

    /// A temporary preset directory and a library over it.
    struct Sandbox {
        let directory: URL
        let store: FileIRCreativePresetStore

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ircreativepreset-library-\(UUID().uuidString)")
            // Deliberately not created here: a library that has never been
            // written to is the ordinary first-run state.
            store = FileIRCreativePresetStore(directory: directory)
        }

        @MainActor
        func makeLibrary() -> IRCreativePresetLibrary {
            IRCreativePresetLibrary(store: store)
        }

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
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        try body(sandbox)
    }

    // MARK: - First run

    @Test("An absent preset directory is an empty library, not a failure")
    func absentDirectoryIsNotAFailure() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            #expect(library.isEmpty)
            #expect(library.loadFailures.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: sandbox.directory.path))
        }
    }

    // MARK: - Creating

    @Test("A created preset is in the library immediately, and on disk under its own identity")
    func createdPresetIsInTheLibraryImmediately() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let before = library.version

            let preset = try library.create(
                IRCreativePresetDraft(name: "720 Sky"), channelMix: .redBlueSwap
            )

            #expect(library.preset(for: preset.id) == preset)
            #expect(library.presets == [preset])
            #expect(library.version > before)
            #expect(sandbox.fileNames == ["\(preset.id.rawValue).irpreset.json"])
        }
    }

    // MARK: - Apply-shape: the library returns the preset, nothing more

    /// What a workspace actually consumes: the resolved preset, whose
    /// `channelMix` it would hand to `DocumentState.setChannelMix`. This
    /// suite stops at proving the library returns the right value — applying
    /// it is another suite's concern.
    @Test("The library hands back exactly the stored preset, ready to apply")
    func theLibraryHandsBackTheStoredPreset() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let matrix = try RAWColorMatrix3x3(
                m00: 0, m01: 1, m02: 0, m10: 1, m11: 0, m12: 0, m20: 0, m21: 0, m22: 1
            )
            let created = try library.create(
                IRCreativePresetDraft(name: "Custom"), channelMix: .explicit(matrix)
            )

            let resolved = try #require(library.preset(for: created.id))
            #expect(resolved.channelMix == .explicit(matrix))
            #expect(resolved == created)
        }
    }

    // MARK: - Renaming

    @Test("Renaming a preset changes its name and preserves its identity")
    func renamingPreservesIdentity() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let original = try library.create(
                IRCreativePresetDraft(name: "Before"), channelMix: .redBlueSwap
            )

            var draft = IRCreativePresetDraft(original)
            draft.name = "After"
            let renamed = try library.update(
                draft, id: original.id, channelMix: original.channelMix
            )

            #expect(renamed.id == original.id)
            #expect(renamed.name == "After")
            #expect(renamed.channelMix == original.channelMix)
            let resolved = try #require(library.preset(for: original.id))
            #expect(resolved.name == "After")
            #expect(sandbox.fileNames == ["\(original.id.rawValue).irpreset.json"])
        }
    }

    @Test("An edited definition survives a reload")
    func anEditedDefinitionSurvivesAReload() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let original = try library.create(
                IRCreativePresetDraft(name: "First"), channelMix: .identity
            )
            var draft = IRCreativePresetDraft(original)
            draft.name = "Second"
            _ = try library.update(draft, id: original.id, channelMix: original.channelMix)

            let reopened = sandbox.makeLibrary()
            let resolved = try #require(reopened.preset(for: original.id))
            #expect(resolved.name == "Second")
            #expect(reopened.loadFailures.isEmpty)
        }
    }

    // MARK: - Deleting

    @Test("A deleted preset stops resolving, and its file is gone")
    func deletingRemovesThePreset() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let preset = try library.create(
                IRCreativePresetDraft(name: "Gone soon"), channelMix: .redBlueSwap
            )

            try library.delete(preset.id)

            #expect(library.preset(for: preset.id) == nil)
            #expect(sandbox.fileNames.isEmpty)
        }
    }

    /// No index to fall out of step: deleting one preset must leave every
    /// other definition — and every other photograph's already-resolved
    /// mix — exactly as it was.
    @Test("Deleting one preset leaves the rest of the library alone")
    func deletingOneLeavesTheRest() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let first = try library.create(
                IRCreativePresetDraft(name: "First"), channelMix: .identity
            )
            let second = try library.create(
                IRCreativePresetDraft(name: "Second"), channelMix: .redBlueSwap
            )

            try library.delete(first.id)

            #expect(library.presets.map(\.id) == [second.id])
            #expect(library.preset(for: second.id) == second)
        }
    }

    // MARK: - Duplicate identities are refused, never resolved by order

    /// The file store makes a duplicate identity on disk unreachable through
    /// itself — a file's name *is* its identity, and a payload that disagrees
    /// is refused before it ever reaches composition. `compose(_:)` is where
    /// ambiguity from any composed source would actually surface, so it is
    /// exercised directly.
    @Test("Two presets claiming one identity are both refused, regardless of input order")
    func duplicateIdentitiesAreRefusedRegardlessOfOrder() throws {
        let id = try IRCreativePresetID("user.duplicate")
        let first = IRCreativePreset(id: id, name: "First", channelMix: .identity)
        let second = IRCreativePreset(id: id, name: "Second", channelMix: .redBlueSwap)

        let forward = IRCreativePresetLibrary.compose([first, second])
        #expect(forward.presets.isEmpty)
        #expect(forward.failures.count == 1)
        guard case .duplicateIdentifier(let forwardID, _) = try #require(forward.failures.first)
        else {
            Issue.record("Expected .duplicateIdentifier, got \(forward.failures)")
            return
        }
        #expect(forwardID == id)

        let reversed = IRCreativePresetLibrary.compose([second, first])
        #expect(reversed.presets.isEmpty)
        #expect(reversed.failures.count == 1)
        guard case .duplicateIdentifier(let reversedID, _) = try #require(reversed.failures.first)
        else {
            Issue.record("Expected .duplicateIdentifier, got \(reversed.failures)")
            return
        }
        #expect(reversedID == id)
    }

    // MARK: - Display order

    /// Names are not unique — two presets may share one — so identity is the
    /// tiebreak that makes the order total, and it must not depend on
    /// insertion order or on the file system's enumeration order.
    @Test("Display order is by name case-insensitively, then by identity as the tiebreak")
    func displayOrderIsByNameThenIdentity() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            _ = try library.create(IRCreativePresetDraft(name: "Zebra"), channelMix: .identity)
            _ = try library.create(IRCreativePresetDraft(name: "alpha"), channelMix: .identity)
            _ = try library.create(IRCreativePresetDraft(name: "Mango"), channelMix: .identity)

            #expect(library.presets.map(\.name) == ["alpha", "Mango", "Zebra"])
        }
    }

    @Test("Two presets sharing one name are ordered by identity, the deterministic tiebreak")
    func equalNamesAreOrderedByIdentity() throws {
        let idA = try IRCreativePresetID("user.aaa")
        let idB = try IRCreativePresetID("user.bbb")
        // Constructed in an order chosen to disagree with the tiebreak, so a
        // stable-sort-by-insertion-order implementation would fail this.
        let presetB = IRCreativePreset(id: idB, name: "Same Name", channelMix: .identity)
        let presetA = IRCreativePreset(id: idA, name: "Same Name", channelMix: .redBlueSwap)

        let composed = IRCreativePresetLibrary.compose([presetB, presetA])
        #expect(composed.failures.isEmpty)
        #expect(composed.presets.map(\.id) == [idA, idB])
    }

    // MARK: - No library at all

    @Test("A library with no storage is empty, reports libraryUnavailable, and refuses save and delete")
    func aLibraryWithNoStorageIsEmptyAndRefuses() throws {
        let library = IRCreativePresetLibrary(
            store: nil,
            unavailable: .libraryUnavailable(underlying: IRCreativePresetLibrary.Unavailable())
        )

        #expect(library.isEmpty)
        #expect(library.loadFailures.count == 1)
        guard case .libraryUnavailable = try #require(library.loadFailures.first) else {
            Issue.record("Expected .libraryUnavailable, got \(library.loadFailures)")
            return
        }

        #expect(throws: (any Error).self) {
            _ = try library.create(IRCreativePresetDraft(name: "X"), channelMix: .identity)
        }
        #expect(throws: IRCreativePresetPersistenceError.self) {
            try library.delete(try IRCreativePresetID("user.anything"))
        }
    }

    // MARK: - Prefill independence

    /// `IRCreativePresetDraft.useFilter(from:)` copies a capture profile's
    /// filter once, at the moment the save sheet opened. A capture profile is
    /// immutable, so "changing it" can only mean replacing the stored
    /// definition under the same identity with a new value — and even that
    /// must not reach back into a preset already saved.
    @Test("Prefilling a draft's filter from a capture profile copies it once, never binds it")
    func prefillCopiesTheFilterOnceRatherThanBindingIt() throws {
        try Self.withSandbox { sandbox in
            let library = sandbox.makeLibrary()
            let profileID = try IRCaptureProfileID("user.some-camera")
            let originalProfile = IRCaptureProfile(
                id: profileID,
                name: "My Camera — 720 nm",
                filter: try IRFilterDescriptor.longPass(nominalNanometers: 720),
                processingBasis: .uncalibratedSensorRGB
            )

            var draft = IRCreativePresetDraft(name: "Suggested for my camera")
            draft.useFilter(from: originalProfile)
            let saved = try library.create(draft, channelMix: .redBlueSwap)

            #expect(saved.filter == .longPass(nominalCutoffNanometers: 720))

            // "Editing" the profile: an entirely new value, under the same
            // identity, with a different filter.
            let replacementProfile = IRCaptureProfile(
                id: profileID,
                name: "My Camera — 720 nm",
                filter: try IRFilterDescriptor.longPass(nominalNanometers: 590),
                processingBasis: .uncalibratedSensorRGB
            )
            #expect(replacementProfile.filter == .longPass(nominalCutoffNanometers: 590))

            // The already-saved preset, reloaded from disk, is untouched.
            let reopened = sandbox.makeLibrary()
            let stored = try #require(reopened.preset(for: saved.id))
            #expect(stored.filter == .longPass(nominalCutoffNanometers: 720))

            // And the draft itself never held a reference to the profile: a
            // second `useFilter(from:)` call on a fresh draft using the
            // replacement produces a different, independent value.
            var secondDraft = IRCreativePresetDraft(name: "Another")
            secondDraft.useFilter(from: replacementProfile)
            let second = try library.create(secondDraft, channelMix: .redBlueSwap)
            #expect(second.filter == .longPass(nominalCutoffNanometers: 590))
            #expect(saved.filter == .longPass(nominalCutoffNanometers: 720))
        }
    }
}
