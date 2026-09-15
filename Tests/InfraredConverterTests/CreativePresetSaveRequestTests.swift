import Testing
import Foundation
@testable import InfraredConverter

/// The save-as-preset **snapshot contract**: the mix a preset records is the
/// one the photograph had when the person asked to save it, not the one it has
/// when they finish typing a name.
///
/// ## The defect this suite exists to prevent
///
/// The first implementation read `DocumentState.channelMixAdjustment` twice —
/// once to show the sheet and again inside the save closure:
///
/// ```swift
/// channelMix: documentState.channelMixAdjustment          // shown
/// save: { try presetLibrary.create($0,
///             channelMix: documentState.channelMixAdjustment) }   // stored
/// ```
///
/// Between those two reads a person types a name, and in those seconds the
/// photograph's mix can change — another preset applied from the same menu, a
/// matrix committed in the editor. The sheet then showed one matrix and stored
/// another, silently, and the preset a person believed they had saved was not
/// the one on disk. That is the worst shape a persistence bug can take: it
/// looks like it worked.
///
/// ## What is actually tested, and why it is not the sheet
///
/// Not the modal. macOS presentation is not an oracle — a test that drove a
/// real sheet would be proving AppKit's behaviour, and the contract would still
/// be unproven the next time somebody rewrote the closure.
///
/// The seam is `CreativePresetSaveRequest`, which is the value the interface
/// actually passes around: it is constructed once from the document when the
/// button is tapped, and both the sheet's display and the save go through it.
/// These tests construct it exactly as `ChannelMixControl` does, move the
/// document on underneath it, and commit through `commit(_:to:)` — the same
/// method the sheet's Save button calls. Nothing is re-implemented here.
///
/// See `docs/decisions/0024-reusable-creative-presets.md`.
@Suite("Creative preset save snapshot")
@MainActor
struct CreativePresetSaveRequestTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/preset-save-snapshot.orf")

    /// Two deliberately different, deliberately asymmetric mixes. Neither is
    /// the identity or the red/blue swap, so neither could be produced by a
    /// stray built-in and mistaken for the other.
    static let mixA = try! UserChannelMixAdjustment.explicit(
        persistedMatrix: [0.25, 0.5, -0.75, 1.5, 0, 0.125, -1, 2, 0.375]
    )
    static let mixB = try! UserChannelMixAdjustment.explicit(
        persistedMatrix: [3, -0.5, 0.25, 0, 1.25, -2, 0.625, 0, 1]
    )

    /// A temporary preset library. The real Application Support folder is
    /// never touched.
    struct Sandbox {
        let directory: URL

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("preset-save-snapshot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }

        @MainActor
        func makeLibrary() -> IRCreativePresetLibrary {
            IRCreativePresetLibrary(store: FileIRCreativePresetStore(directory: directory))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    static func withSandbox(_ body: (Sandbox) throws -> Void) throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try body(sandbox)
    }

    static func waitUntilSettled(_ state: DocumentState) async throws {
        for _ in 0..<600 {
            if case .decoding = state.status {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                return
            }
        }
        Issue.record("The open never settled")
    }

    /// An open, adjustable document sitting on `mixA`.
    static func documentOnMixA(
        store: StubPhotographProcessingStore = StubPhotographProcessingStore()
    ) async throws -> DocumentState {
        let state = WorkspaceStubs.documentState(url: url, store: store)
        state.open(url)
        try await waitUntilSettled(state)

        state.setChannelMix(mixA)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                state, adjustments: ImageAdjustments(channelMix: mixA)
            )
        )
        #expect(state.channelMixAdjustment == mixA)
        return state
    }

    // MARK: - The contract

    /// The whole defect, as one scenario.
    ///
    /// The request is seeded with A, the document then moves to B and renders
    /// it, and the commit still stores A. The stored preset is read back from
    /// the library — not from the value that was passed in — so this proves
    /// what reached persistence rather than what was handed to a function.
    @Test("A preset saves the mix the sheet was opened with, not the one the document moved to")
    func theSnapshotIsWhatIsPersisted() async throws {
        try await Self.withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let state = try await Self.documentOnMixA()

            // The button is tapped: one read of the document, here.
            let request = CreativePresetSaveRequest(snapshotOf: state)
            #expect(request.channelMix == Self.mixA)

            // The person is typing a name. Meanwhile the photograph moves on —
            // another preset applied, a matrix committed, anything at all.
            state.setChannelMix(Self.mixB)
            _ = try #require(
                await WorkspaceStubs.waitForPreview(
                    state, adjustments: ImageAdjustments(channelMix: Self.mixB)
                )
            )
            #expect(state.channelMixAdjustment == Self.mixB)

            // The snapshot did not move with it.
            #expect(request.channelMix == Self.mixA)

            // Save is pressed.
            let saved = try request.commit(
                IRCreativePresetDraft(name: "Snapshot"), to: library
            )

            // What was returned, what is in the library, and what is on disk
            // all carry A.
            #expect(saved.channelMix == Self.mixA)
            #expect(saved.channelMix != Self.mixB)

            let installed = try #require(library.preset(for: saved.id))
            #expect(installed.channelMix == Self.mixA)
            #expect(installed.channelMix != Self.mixB)

            let reloaded = sandbox.makeLibrary()
            let fromDisk = try #require(reloaded.preset(for: saved.id))
            #expect(fromDisk.channelMix == Self.mixA)
            #expect(fromDisk.channelMix != Self.mixB)

            // And coefficient by coefficient, so a comparison that happened to
            // succeed for the wrong reason cannot hide.
            #expect(fromDisk.channelMix.matrix == Self.mixA.matrix)
            #expect(fromDisk.channelMix.matrix != Self.mixB.matrix)
        }
    }

    /// The same contract stated from the other end: the value the sheet
    /// **displays** is the value it stores.
    ///
    /// The sheet renders `request.channelMix`, so proving that field is stable
    /// across a document change proves the display cannot drift away from what
    /// Save will write — which is the half of the defect a person would
    /// actually have seen.
    @Test("The mix the sheet displays is the mix it commits, across a document change")
    func whatIsShownIsWhatIsStored() async throws {
        try await Self.withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let state = try await Self.documentOnMixA()

            let request = CreativePresetSaveRequest(snapshotOf: state)
            let displayed = request.channelMix

            state.setChannelMix(Self.mixB)
            _ = try #require(
                await WorkspaceStubs.waitForPreview(
                    state, adjustments: ImageAdjustments(channelMix: Self.mixB)
                )
            )

            let saved = try request.commit(
                IRCreativePresetDraft(name: "Shown equals stored"), to: library
            )
            #expect(saved.channelMix == displayed)
        }
    }

    /// Saving a preset is a library operation and touches no photograph.
    ///
    /// Stated here rather than assumed, because the request now holds a mix
    /// that is *not* the document's: a commit that wrote its snapshot back into
    /// the photograph would silently undo the person's most recent edit.
    @Test("Committing a stale snapshot does not write it back to the photograph")
    func committingDoesNotTouchTheDocument() async throws {
        try await Self.withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let store = StubPhotographProcessingStore()
            let state = try await Self.documentOnMixA(store: store)

            let request = CreativePresetSaveRequest(snapshotOf: state)

            state.setChannelMix(Self.mixB)
            _ = try #require(
                await WorkspaceStubs.waitForPreview(
                    state, adjustments: ImageAdjustments(channelMix: Self.mixB)
                )
            )
            try await Self.waitUntil("the document's own mix is saved") {
                store.saved(for: Self.url) == ImageAdjustments(channelMix: Self.mixB)
            }

            _ = try request.commit(
                IRCreativePresetDraft(name: "No side effect"), to: library
            )
            try await Task.sleep(nanoseconds: 30_000_000)

            // The photograph is still on B — its own most recent decision.
            #expect(state.channelMixAdjustment == Self.mixB)
            #expect(store.saved(for: Self.url) == ImageAdjustments(channelMix: Self.mixB))
        }
    }

    /// The same contract, one layer up: through the sheet the interface
    /// actually builds.
    ///
    /// `ChannelMixControl` constructs `CreativePresetSaveView(request:library:)`
    /// and nothing else, so this exercises the real wiring rather than a
    /// reimplementation of it. The view is asked what it displays, the document
    /// is moved, and the view's own save action is invoked — which is what the
    /// Save button calls. No modal is presented: presentation is AppKit's
    /// behaviour, and it is not the contract under test.
    @Test("The sheet the interface builds displays and stores the same snapshot")
    func theSheetItselfCarriesTheSnapshot() async throws {
        try await Self.withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let state = try await Self.documentOnMixA()

            let request = CreativePresetSaveRequest(snapshotOf: state)
            let sheet = CreativePresetSaveView(request: request, library: library)

            // What a person sees.
            #expect(sheet.channelMix == Self.mixA)

            state.setChannelMix(Self.mixB)
            _ = try #require(
                await WorkspaceStubs.waitForPreview(
                    state, adjustments: ImageAdjustments(channelMix: Self.mixB)
                )
            )

            // Still what a person sees, and now what the Save button does.
            #expect(sheet.channelMix == Self.mixA)
            let saved = try sheet.save(IRCreativePresetDraft(name: "Through the sheet"))

            #expect(saved.channelMix == Self.mixA)
            #expect(saved.channelMix != Self.mixB)
            let installed = try #require(library.preset(for: saved.id))
            #expect(installed.channelMix == Self.mixA)
        }
    }

    // MARK: - What the snapshot captures besides the mix

    /// The filter prefill is taken in the same single read, and is equally a
    /// copy: the capture profile it came from may be edited or deleted
    /// afterwards, and neither the request nor anything saved from it changes.
    @Test("The filter note is prefilled from the capture profile, once, as a copy")
    func theFilterPrefillIsASnapshotToo() async throws {
        try await Self.withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()

            let profile = IRCaptureProfile(
                id: try IRCaptureProfileID("user.snapshot-profile"),
                name: "Converted E-PL3 — R72",
                filter: try IRFilterDescriptor.longPass(nominalNanometers: 720),
                processingBasis: .uncalibratedSensorRGB
            )
            let registry = try IRCaptureProfileRegistry(
                builtins: IRCaptureProfileRegistry.builtinProfiles, userProfiles: [profile]
            )

            let state = WorkspaceStubs.documentState(url: Self.url, registry: registry)
            state.open(Self.url)
            try await Self.waitUntilSettled(state)
            state.setCaptureProfile(profile)
            _ = try #require(
                await WorkspaceStubs.waitForPreview(
                    state, adjustments: ImageAdjustments()
                )
            )

            let request = CreativePresetSaveRequest(snapshotOf: state)
            #expect(request.draft.filter.kind == .longPass)
            #expect(request.draft.filter.nominalCutoffNanometers == "720")
            // The sheet says where it came from, so the copy is visible.
            #expect(request.prefilledFrom?.contains(profile.name) == true)

            // The person types a name into the prefilled draft and saves —
            // the filter field is left exactly as it was prefilled.
            var edited = request.draft
            edited.name = "Prefilled From Profile"
            let saved = try request.commit(edited, to: library)
            #expect(saved.filter == .longPass(nominalCutoffNanometers: 720))

            // The photograph is moved to a profile describing a different
            // filter. Nothing about the saved preset follows it.
            state.setCaptureProfile(.builtinUncalibrated)
            let installed = try #require(library.preset(for: saved.id))
            #expect(installed.filter == .longPass(nominalCutoffNanometers: 720))
        }
    }

    /// A document with nothing open snapshots the identity mix and no prefill,
    /// rather than trapping or inventing a filter.
    @Test("A snapshot of a document with nothing open is the identity mix, unprefilled")
    func aSnapshotOfNothingIsHonest() throws {
        let state = DocumentState()
        let request = CreativePresetSaveRequest(snapshotOf: state)
        #expect(request.channelMix == .identity)
        #expect(request.prefilledFrom == nil)
        #expect(request.draft.filter.kind == .unknown)
    }

    /// Two taps are two requests, so cancelling one and asking again presents a
    /// fresh sheet rather than reviving the previous one.
    @Test("Each request has its own identity, so asking again is a new sheet")
    func eachRequestIsItsOwn() async throws {
        let state = try await Self.documentOnMixA()
        let first = CreativePresetSaveRequest(snapshotOf: state)
        let second = CreativePresetSaveRequest(snapshotOf: state)
        #expect(first.id != second.id)
        #expect(first.channelMix == second.channelMix)
    }

    // MARK: - Helpers

    @MainActor
    static func withSandboxAsync(_ body: (Sandbox) async throws -> Void) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try await body(sandbox)
    }

    static func waitUntil(
        _ description: String, _ condition: () -> Bool
    ) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Never became true: \(description)")
    }
}
