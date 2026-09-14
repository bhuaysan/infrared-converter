import Testing
import Foundation
@testable import InfraredConverter

/// What a persisted profile library does to an open photograph — and, far more
/// often, what it deliberately does not.
///
/// The suite that pins the boundary this milestone exists to draw:
///
/// ```text
/// a profile          reusable capture context, shared by many photographs
/// an adjustment      one photograph's own decision, shared by none
/// ```
///
/// Every test drives a real `IRCaptureProfileLibrary` over a **temporary**
/// profile directory. Nothing here reads or writes the real Application Support
/// folder.
///
/// Serialised, for the reason the other workspace suites are: these drive real
/// renders through the coalescing slots.
@Suite("Workspace capture profile library", .serialized)
@MainActor
struct WorkspaceCaptureProfileLibraryTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/profile-library.orf")
    nonisolated static let other = URL(fileURLWithPath: "/tmp/profile-library-other.orf")

    /// A temporary profile directory and a library over it.
    struct Sandbox {
        let directory: URL

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("workspace-irprofiles-\(UUID().uuidString)")
        }

        @MainActor
        func makeLibrary() -> IRCaptureProfileLibrary {
            IRCaptureProfileLibrary(store: FileIRCaptureProfileStore(directory: directory))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func withSandbox(_ body: (Sandbox) throws -> Void) rethrows {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        try body(sandbox)
    }

    /// A draft describing the milestone's example configuration, applicable to
    /// any camera so that it is not the camera match under test here.
    static func draft(name: String) -> IRCaptureProfileDraft {
        IRCaptureProfileDraft(
            name: name,
            conversionKind: .fullSpectrum,
            conversionVendor: "Some Converter",
            filter: IRCaptureProfileDraft.FilterDraft(
                kind: .longPass, nominalCutoffNanometers: "720"
            )
        )
    }

    static func document(
        url: URL = WorkspaceCaptureProfileLibraryTests.url,
        registry: IRCaptureProfileRegistry,
        store: StubPhotographProcessingStore,
        log: WorkspaceEventLog
    ) -> DocumentState {
        DocumentState(
            decoder: RecordingMosaicDecoder(
                wrapped: WorkspaceStubDecoder(
                    result: .success(RAWTestData.decodedRAW(url: url)),
                    mosaic: .success(WorkspaceStubs.mosaic(url: url, width: 16, height: 12))
                ),
                log: log
            ),
            store: store,
            registry: registry,
            render: RecordingRender(log: log).render,
            prepareSource: RecordingPreparation(log: log).prepare
        )
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

    static func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Never became true: \(description)")
    }

    static func preview(_ state: DocumentState) throws -> WorkspacePreview {
        guard case .decoded(let loaded) = state.status,
              case .rendered(let preview) = loaded.owned
        else {
            Issue.record("Expected a rendered preview, got \(state.status)")
            throw CancellationError()
        }
        return preview
    }

    /// A neutral patch that is not the default, so "the user decided something
    /// about this photograph" is visible in the record.
    static var pickedPatch: UserWhiteBalanceAdjustment {
        get throws {
            .neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: 0.1, originY: 0.2, width: 0.2, height: 0.2
                )
            )
        }
    }

    // MARK: - The end-to-end reusable-profile workflow

    /// The milestone's headline claim, in one test: a person creates one
    /// reusable profile, assigns it to two photographs, and each photograph
    /// keeps its own white balance.
    @Test("One profile serves two photographs, and each keeps its own decisions")
    func oneProfileServesTwoPhotographs() async throws {
        try await withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let profile = try library.create(Self.draft(name: "E-PL3 720"))

            let logA = WorkspaceEventLog()
            let storeA = StubPhotographProcessingStore(log: logA)
            let documentA = Self.document(
                registry: library.registry, store: storeA, log: logA
            )
            documentA.open(Self.url)
            try await Self.waitUntilSettled(documentA)

            documentA.setCaptureProfile(profile)
            documentA.setWhiteBalance(try Self.pickedPatch)
            try await Self.waitUntil("A saves its state") {
                storeA.savedState(for: Self.url)?.adjustments.whiteBalance
                    == (try? Self.pickedPatch)
            }

            let logB = WorkspaceEventLog()
            let storeB = StubPhotographProcessingStore(log: logB)
            let documentB = Self.document(
                url: Self.other, registry: library.registry, store: storeB, log: logB
            )
            documentB.open(Self.other)
            try await Self.waitUntilSettled(documentB)
            documentB.setCaptureProfile(profile)
            try await Self.waitUntil("B saves its state") {
                storeB.savedState(for: Self.other)?.captureProfile == profile.id
            }

            // The same profile identity in both sidecars — a reference, not a
            // copy of the definition.
            #expect(storeA.savedState(for: Self.url)?.captureProfile == profile.id)
            #expect(storeB.savedState(for: Self.other)?.captureProfile == profile.id)

            // And two different white balances. This is the boundary: a patch
            // is a place in one picture, and sharing a profile does not share
            // one.
            #expect(storeA.savedState(for: Self.url)?.adjustments.whiteBalance
                == (try Self.pickedPatch))
            #expect(storeB.savedState(for: Self.other)?.adjustments.whiteBalance
                == .defaultNeutralPatch)
            #expect(documentA.whiteBalanceAdjustment != documentB.whiteBalanceAdjustment)

            // Neither is a calibration, however specific the profile's name is.
            #expect(!(try Self.preview(documentA)).isValidatedInfraredCalibration)
        }
    }

    // MARK: - Editing a profile does not touch a photograph's adjustments

    /// The regression that guards the most important domain boundary. Editing
    /// a shared profile must not reach into any photograph's own decisions.
    @Test("Editing a profile changes no photograph's white balance or other adjustments")
    func editingAProfileChangesNoAdjustments() async throws {
        try await withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let profile = try library.create(Self.draft(name: "Before"))

            let log = WorkspaceEventLog()
            let store = StubPhotographProcessingStore(log: log)
            let document = Self.document(registry: library.registry, store: store, log: log)
            document.open(Self.url)
            try await Self.waitUntilSettled(document)

            document.setCaptureProfile(profile)
            document.setWhiteBalance(try Self.pickedPatch)
            document.setChannelMix(.redBlueSwap)
            document.setExposure(try UserExposureAdjustment(ev: 0.75))
            document.rotateOrientationRight()
            try await Self.waitUntil("the state is saved") {
                document.adjustmentPersistence.isDurable
            }
            let saved = try #require(store.savedState(for: Self.url))
            let writesBefore = store.writes.count

            // The edit: a rename and a descriptive change, through the library.
            var draft = IRCaptureProfileDraft(profile)
            draft.name = "After"
            draft.conversionVendor = "Another Converter"
            let edited = try library.update(draft, id: profile.id)
            document.updateCaptureProfiles(library.registry)
            try await Self.waitUntil("the preview carries the edited definition") {
                (try? Self.preview(document))?.captureProfile == edited
            }

            // Bit for bit the same adjustments, before and after.
            #expect(document.whiteBalanceAdjustment == saved.adjustments.whiteBalance)
            #expect(document.channelMixAdjustment == saved.adjustments.channelMix)
            #expect(document.exposureAdjustment == saved.adjustments.exposure)
            #expect(document.orientationAdjustment == saved.adjustments.orientation)
            // The identity is unchanged, so the sidecar had nothing new to say
            // and was not rewritten.
            #expect(store.writes.count == writesBefore)
            #expect(store.savedState(for: Self.url) == saved)
            #expect(document.adjustmentPersistence.isDurable)
        }
    }

    /// A rename is descriptive, and the inspector must stop showing the old
    /// name — but the pixels cannot differ, because the processing basis did
    /// not change.
    @Test("A rename re-renders for provenance and does not re-prepare")
    func aRenameReRendersAndDoesNotRePrepare() async throws {
        try await withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let profile = try library.create(Self.draft(name: "Before"))

            let log = WorkspaceEventLog()
            let store = StubPhotographProcessingStore(log: log)
            let document = Self.document(registry: library.registry, store: store, log: log)
            document.open(Self.url)
            try await Self.waitUntilSettled(document)
            document.setCaptureProfile(profile)
            try await Self.waitUntil("the profile is in force") {
                document.captureProfile == profile
            }
            let preparationsBefore = log.preparationRequests.count
            let before = try Self.preview(document)

            var draft = IRCaptureProfileDraft(profile)
            draft.name = "After"
            _ = try library.update(draft, id: profile.id)
            document.updateCaptureProfiles(library.registry)
            try await Self.waitUntil("the new name is on the preview") {
                (try? Self.preview(document))?.captureProfile.name == "After"
            }

            let after = try Self.preview(document)
            #expect(after.captureProfile.id == profile.id)
            // No heavy pass: the camera-to-working transform did not change, so
            // re-preparing would be work whose result is already on screen.
            #expect(log.preparationRequests.count == preparationsBefore)
            #expect(log.decodeCount == 1)
            #expect(after.pixelWidth == before.pixelWidth)
            #expect(after.pixelHeight == before.pixelHeight)
        }
    }

    // MARK: - Deleting a profile that is open

    /// A profile deleted elsewhere does not reinterpret the photograph on
    /// screen. The document keeps the definition it resolved; the consequence
    /// appears the next time the file is opened, which is where a refusal with
    /// a remedy belongs.
    @Test("Deleting the profile in use leaves the open photograph as it was")
    func deletingTheProfileInUseLeavesTheDocumentAlone() async throws {
        try await withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let profile = try library.create(Self.draft(name: "Doomed"))

            let log = WorkspaceEventLog()
            let store = StubPhotographProcessingStore(log: log)
            let document = Self.document(registry: library.registry, store: store, log: log)
            document.open(Self.url)
            try await Self.waitUntilSettled(document)
            document.setCaptureProfile(profile)
            try await Self.waitUntil("the profile is saved") {
                store.savedState(for: Self.url)?.captureProfile == profile.id
            }

            try library.delete(profile.id)
            document.updateCaptureProfiles(library.registry)

            // Still exactly the photograph that was on screen, under the
            // profile it was rendered with. Nothing was substituted.
            #expect(document.captureProfile == profile)
            #expect(try Self.preview(document).captureProfile == profile)
            #expect(store.savedState(for: Self.url)?.captureProfile == profile.id)
            // And the library no longer offers it.
            #expect(!library.registry.contains(profile.id))
            #expect(!document.captureProfileChoices.map(\.id).contains(profile.id))
        }
    }

    // MARK: - Missing-profile recovery

    /// The end-to-end recovery this milestone owes the user: a photograph whose
    /// profile has been deleted refuses to open, says so, and can be reopened —
    /// **by an explicit action** — under the built-in profile with every one of
    /// its own adjustments intact.
    @Test("A photograph whose profile was deleted refuses, then recovers explicitly")
    func aDeletedProfileRefusesThenRecovers() async throws {
        try await withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let profile = try library.create(Self.draft(name: "To be deleted"))

            let log = WorkspaceEventLog()
            let store = StubPhotographProcessingStore(log: log)
            let document = Self.document(registry: library.registry, store: store, log: log)
            document.open(Self.url)
            try await Self.waitUntilSettled(document)
            document.setCaptureProfile(profile)
            document.setWhiteBalance(try Self.pickedPatch)
            document.setChannelMix(.redBlueSwap)
            try await Self.waitUntil("the state is saved") {
                store.savedState(for: Self.url)?.captureProfile == profile.id
                    && store.savedState(for: Self.url)?.adjustments.channelMix == .redBlueSwap
            }
            let savedAdjustments = try #require(store.savedState(for: Self.url)).adjustments

            // The profile goes away, and the photograph is opened again.
            try library.delete(profile.id)
            document.updateCaptureProfiles(library.registry)
            document.open(Self.url)
            try await Self.waitUntilSettled(document)

            guard case .captureProfileUnusable(let failedURL, let error) = document.status else {
                Issue.record("Expected .captureProfileUnusable, got \(document.status)")
                return
            }
            #expect(failedURL == Self.url)
            #expect(error.failure == .unknownProfile(id: profile.id))
            // Nothing was repaired: the sidecar still names the missing profile.
            #expect(store.savedState(for: Self.url)?.captureProfile == profile.id)

            // The remedy, taken explicitly.
            #expect(document.captureProfileRecovery == .builtinUncalibrated)
            document.useUncalibratedCaptureProfile()
            try await Self.waitUntilSettled(document)

            guard case .decoded = document.status else {
                Issue.record("Expected a decoded document, got \(document.status)")
                return
            }
            #expect(document.captureProfile == .builtinUncalibrated)
            #expect(try Self.preview(document).captureProfileID == .builtinUncalibrated)

            // Every adjustment survived. A profile problem is no reason to
            // touch a person's editing decisions.
            #expect(document.whiteBalanceAdjustment == savedAdjustments.whiteBalance)
            #expect(document.channelMixAdjustment == savedAdjustments.channelMix)
            #expect(document.exposureAdjustment == savedAdjustments.exposure)
            #expect(document.orientationAdjustment == savedAdjustments.orientation)

            // And the recovery reached the sidecar, because it rendered.
            let recovered = try #require(store.savedState(for: Self.url))
            #expect(recovered.captureProfile == .builtinUncalibrated)
            #expect(recovered.adjustments == savedAdjustments)
            #expect(document.adjustmentPersistence.isDurable)
        }
    }

    /// The recovery is available for a camera mismatch too: the same explicit
    /// edit, for the other way a saved profile can be unusable.
    @Test("A camera-mismatched profile can be recovered from as well")
    func aCameraMismatchCanBeRecoveredFrom() async throws {
        let wrongCamera = IRCaptureProfile(
            id: try IRCaptureProfileID("user.other-camera"),
            name: "Another Body",
            cameraMatch: .camera(make: "Nikon", model: "D70"),
            processingBasis: .uncalibratedSensorRGB
        )
        let registry = try IRCaptureProfileRegistry(userProfiles: [wrongCamera])

        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        store.preload(
            PhotographProcessingState(
                captureProfile: wrongCamera.id,
                adjustments: ImageAdjustments(channelMix: .redBlueSwap)
            ),
            for: Self.url
        )
        let document = Self.document(registry: registry, store: store, log: log)

        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        guard case .captureProfileUnusable(_, let error) = document.status else {
            Issue.record("Expected .captureProfileUnusable, got \(document.status)")
            return
        }
        guard case .cameraMismatch = error.failure else {
            Issue.record("Expected a camera mismatch, got \(error.failure)")
            return
        }

        document.useUncalibratedCaptureProfile()
        try await Self.waitUntilSettled(document)

        #expect(document.captureProfile == .builtinUncalibrated)
        #expect(document.channelMixAdjustment == .redBlueSwap)
        #expect(store.savedState(for: Self.url)?.captureProfile == .builtinUncalibrated)
    }

    // MARK: - Selection still travels the ordinary road

    /// A profile selection whose render refuses is not written, exactly as a
    /// refused adjustment is not. The sidecar keeps the last state that
    /// actually rendered.
    @Test("A profile selection whose render refuses leaves the sidecar alone")
    func aRefusedProfileSelectionIsNotSaved() async throws {
        try await withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let profile = try library.create(Self.draft(name: "Refused"))

            let log = WorkspaceEventLog()
            let store = StubPhotographProcessingStore(log: log)
            let document = DocumentState(
                decoder: RecordingMosaicDecoder(
                    wrapped: WorkspaceStubDecoder(
                        result: .success(RAWTestData.decodedRAW(url: Self.url)),
                        mosaic: .success(
                            WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12)
                        )
                    ),
                    log: log
                ),
                store: store,
                registry: library.registry,
                // Refuses every render after the opening one, which is the only
                // way to make a *selection* fail while the file still opens.
                render: RecordingRender(
                    log: log, refuses: { $0.channelMix == .redBlueSwap }
                ).render,
                prepareSource: RecordingPreparation(log: log).prepare
            )

            document.open(Self.url)
            try await Self.waitUntilSettled(document)
            document.setCaptureProfile(profile)
            try await Self.waitUntil("the profile is saved") {
                store.savedState(for: Self.url)?.captureProfile == profile.id
            }
            let saved = try #require(store.savedState(for: Self.url))

            // A state the render refuses. The profile stays selected on the
            // controls, and nothing is written.
            document.setChannelMix(.redBlueSwap)
            try await Self.waitUntil("the render refuses") {
                if case .renderRefused = document.adjustmentPersistence { return true }
                return false
            }
            #expect(store.savedState(for: Self.url) == saved)
            #expect(document.captureProfile == profile)
        }
    }

    // MARK: - Prefill is convenience, never selection

    /// Creating a profile from the open photograph's camera copies two strings
    /// a person can see and change. Nothing reads a camera name and selects or
    /// creates a profile on its own.
    @Test("The current camera is offered as a prefill and selects nothing")
    func theCurrentCameraIsOnlyAPrefill() async throws {
        try await withSandboxAsync { sandbox in
            let library = sandbox.makeLibrary()
            let log = WorkspaceEventLog()
            let store = StubPhotographProcessingStore(log: log)
            let document = Self.document(registry: library.registry, store: store, log: log)
            document.open(Self.url)
            try await Self.waitUntilSettled(document)

            let camera = try #require(document.currentCameraIdentity)
            #expect(camera.make == "Olympus")
            #expect(camera.model == "E-PL3")

            var draft = IRCaptureProfileDraft(name: "From this camera")
            draft.useCamera(make: camera.make, model: camera.model)
            let created = try library.create(draft)
            document.updateCaptureProfiles(library.registry)

            // It matches the photograph, and it was still not selected for it.
            #expect(created.applicability(to: RAWTestData.metadata()).isApplicable)
            #expect(document.captureProfile == .builtinUncalibrated)
            #expect(store.savedState(for: Self.url) == nil)
            // It is offered, and enabled, because it does describe this camera.
            let choice = try #require(
                document.captureProfileChoices.first { $0.id == created.id }
            )
            #expect(choice.isApplicable)
            #expect(!choice.isBuiltin)
        }
    }

    /// A profile for another body is **listed and disabled**, not hidden:
    /// somebody who just created it should see that it exists and why it does
    /// not apply here.
    @Test("A mismatched profile is offered as unavailable rather than hidden")
    func aMismatchedProfileIsListedAndDisabled() async throws {
        let wrongCamera = IRCaptureProfile(
            id: try IRCaptureProfileID("user.nikon"),
            name: "A Nikon",
            cameraMatch: .camera(make: "Nikon", model: "D70"),
            processingBasis: .uncalibratedSensorRGB
        )
        let registry = try IRCaptureProfileRegistry(userProfiles: [wrongCamera])
        let log = WorkspaceEventLog()
        let document = Self.document(
            registry: registry,
            store: StubPhotographProcessingStore(log: log),
            log: log
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let choices = document.captureProfileChoices
        // Built-in first, then user profiles by name.
        #expect(choices.map(\.id) == [.builtinUncalibrated, wrongCamera.id])
        let mismatched = try #require(choices.last)
        #expect(!mismatched.isApplicable)
        #expect(mismatched.refusalDescription != nil)
    }

    // MARK: - Async sandbox helper

    func withSandboxAsync(_ body: (Sandbox) async throws -> Void) async rethrows {
        let sandbox = Sandbox()
        do {
            try await body(sandbox)
        } catch {
            sandbox.cleanUp()
            throw error
        }
        sandbox.cleanUp()
    }
}
