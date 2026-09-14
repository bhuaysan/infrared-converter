import Testing
import Foundation
@testable import InfraredConverter

/// The capture profile as document state: resolved before the first render,
/// refused rather than substituted, and invalidating exactly as much work as
/// its processing basis requires.
///
/// Serialised, because several tests hold a real preparation at a gate, and a
/// held pass occupies a cooperative-pool thread.
@Suite("Workspace capture profile", .serialized)
@MainActor
struct WorkspaceCaptureProfileTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/capture-profile.orf")
    nonisolated static let other = URL(fileURLWithPath: "/tmp/capture-profile-other.orf")

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

    static func waitForProfile(
        _ state: DocumentState, _ profile: IRCaptureProfile
    ) async throws -> WorkspacePreview {
        try await waitUntil("the preview is rendered under \(profile.id)") {
            guard case .decoded(let loaded) = state.status,
                  case .rendered(let preview) = loaded.owned
            else { return false }
            return preview.captureProfile == profile
        }
        return try preview(state)
    }

    /// A document wired to a registry of the caller's choosing, with the log
    /// threaded through the store, the preparation and the render.
    static func document(
        url: URL = WorkspaceCaptureProfileTests.url,
        registry: IRCaptureProfileRegistry = .builtin,
        store: StubPhotographProcessingStore,
        log: WorkspaceEventLog,
        prepare: DocumentState.SourcePreparation? = nil
    ) -> DocumentState {
        DocumentState(
            // Recording, so that "the file was decoded once, and a profile
            // change did not decode it again" is a counted fact rather than an
            // inference from the pictures.
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
            prepareSource: prepare ?? RecordingPreparation(log: log).prepare
        )
    }

    // MARK: - Resolution happens before the first owned render

    /// The open-ordering claim, restated for the new half of the record. A
    /// photograph whose sidecar names a profile is prepared **under that
    /// profile the first time**, not under the built-in one and then switched.
    @Test("A saved profile is used for the first owned preparation there is")
    func aSavedProfileReachesTheFirstPreparation() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        store.preload(
            PhotographProcessingState(captureProfile: TestCaptureProfiles.differentBasis.id),
            for: Self.url
        )
        let document = Self.document(
            registry: TestCaptureProfiles.withDifferentBasis, store: store, log: log
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        // Exactly one preparation, and it ran under the saved profile. Not two,
        // which is what "render the default, then apply the saved state" looks
        // like from here.
        #expect(log.preparedProfiles == [TestCaptureProfiles.differentBasis.id])
        #expect(log.renders.count == 1)
        #expect(try Self.preview(document).captureProfile == TestCaptureProfiles.differentBasis)
        #expect(document.captureProfile == TestCaptureProfiles.differentBasis)

        // And the sidecar is read before the mosaic is decoded, exactly as it
        // is for the adjustments.
        let loaded = try #require(log.firstIndex { if case .loadedAdjustments = $0 { return true } else { return false } })
        let decoded = try #require(log.firstIndex { $0 == .decodedMosaic })
        #expect(loaded < decoded)
    }

    @Test("A photograph with no sidecar opens on the built-in uncalibrated profile")
    func noSidecarMeansTheBuiltInProfile() async throws {
        let log = WorkspaceEventLog()
        let document = Self.document(
            store: StubPhotographProcessingStore(log: log), log: log
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        #expect(document.captureProfile == .builtinUncalibrated)
        let preview = try Self.preview(document)
        #expect(preview.captureProfileID == .builtinUncalibrated)
        // And the provenance says, from the transform's own source, that this
        // is not a calibration.
        #expect(!preview.isValidatedInfraredCalibration)
        #expect(preview.processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
    }

    /// Production offers exactly one profile, and the control shows it rather
    /// than pretending to be a choice.
    @Test("The available profiles are the registry's, deterministically")
    func theAvailableProfilesAreTheRegistrys() async throws {
        let log = WorkspaceEventLog()
        let document = Self.document(
            registry: TestCaptureProfiles.all,
            store: StubPhotographProcessingStore(log: log),
            log: log
        )
        #expect(
            document.availableCaptureProfiles.map(\.id)
                == TestCaptureProfiles.all.allProfiles.map(\.id)
        )
        #expect(DocumentState().availableCaptureProfiles == [.builtinUncalibrated])
    }

    // MARK: - A profile that cannot be used

    /// The forward-lifecycle case: a sidecar written on another machine, or
    /// one whose user profile has since been deleted.
    @Test("An unresolvable profile stops the open, and substitutes nothing")
    func anUnresolvableProfileStopsTheOpen() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        store.preload(
            PhotographProcessingState(captureProfile: TestCaptureProfiles.missingID),
            for: Self.url
        )
        let document = Self.document(store: store, log: log)

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        guard case .captureProfileUnusable(let failedURL, let error) = document.status else {
            Issue.record("Expected .captureProfileUnusable, got \(document.status)")
            return
        }
        #expect(failedURL == Self.url)
        #expect(error.url == Self.url)
        #expect(error.failure == .unknownProfile(id: TestCaptureProfiles.missingID))
        #expect(error.profileID == TestCaptureProfiles.missingID)
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.failureReason?.isEmpty == false)

        // Nothing was substituted, nothing was rendered, and nothing was
        // written. The refusal happens before the decode, so the expensive
        // work never starts either.
        #expect(log.decodeCount == 0)
        #expect(log.renders.isEmpty)
        #expect(log.preparations.isEmpty)
        #expect(store.writes.isEmpty)
        #expect(store.savedState(for: Self.url)?.captureProfile == TestCaptureProfiles.missingID)

        // And the document offers nothing: no adjustment, and no export.
        #expect(!document.canAdjust)
        #expect(document.exportRequest == nil)
        #expect(!document.canExport)
    }

    /// The camera check needs the file's metadata, so it happens after the
    /// decode and before anything is processed under the profile.
    @Test("A profile made for another camera stops the open")
    func aCameraMismatchStopsTheOpen() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        store.preload(
            PhotographProcessingState(captureProfile: TestCaptureProfiles.olympusEPL3.id),
            for: Self.url
        )
        let document = Self.document(
            registry: TestCaptureProfiles.withCameraSpecific, store: store, log: log
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        guard case .captureProfileUnusable(_, let error) = document.status else {
            Issue.record("Expected .captureProfileUnusable, got \(document.status)")
            return
        }
        guard case .cameraMismatch(let id, _, _, _, _) = error.failure else {
            Issue.record("Expected a camera mismatch, got \(error.failure)")
            return
        }
        #expect(id == TestCaptureProfiles.olympusEPL3.id)

        // The file decoded — the check needs its make and model — and nothing
        // was processed under the profile afterwards.
        #expect(log.decodeCount == 1)
        #expect(log.preparations.isEmpty)
        #expect(log.renders.isEmpty)
        #expect(store.writes.isEmpty)
        #expect(!document.canAdjust)
        #expect(document.exportRequest == nil)
    }

    @Test("The built-in profile opens every photograph the decoder can read")
    func theBuiltInProfileIsUniversal() async throws {
        let log = WorkspaceEventLog()
        let document = Self.document(
            registry: TestCaptureProfiles.withCameraSpecific,
            store: StubPhotographProcessingStore(log: log),
            log: log
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        guard case .decoded = document.status else {
            Issue.record("Expected .decoded, got \(document.status)")
            return
        }
        #expect(document.canAdjust)
    }

    /// Selection is refused at the control rather than accepted and then
    /// refused by a render: the document keeps the profile it has, and nothing
    /// is requested or written.
    @Test("Selecting a profile for another camera changes nothing")
    func selectingAMismatchedProfileChangesNothing() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let document = Self.document(
            registry: TestCaptureProfiles.withCameraSpecific, store: store, log: log
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        let rendersAfterOpen = log.renders.count

        document.setCaptureProfile(TestCaptureProfiles.olympusEPL3)
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(document.captureProfile == .builtinUncalibrated)
        #expect(log.renders.count == rendersAfterOpen)
        #expect(store.writes.isEmpty)
        #expect(document.adjustmentPersistence.isDurable)
    }

    // MARK: - What a profile change costs

    /// The rule asked of the data rather than of the UI: two profiles that
    /// share a processing basis produce identical pixels, so switching between
    /// them is a re-render for provenance and nothing more.
    @Test("A metadata-only profile change re-renders and does not re-prepare")
    func aMetadataOnlyChangeDoesNotReprepare() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let document = Self.document(
            registry: TestCaptureProfiles.withMetadataOnly, store: store, log: log
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let before = try Self.preview(document)
        #expect(log.preparations.count == 1)

        document.setCaptureProfile(TestCaptureProfiles.metadataOnly)
        let after = try await Self.waitForProfile(document, TestCaptureProfiles.metadataOnly)

        // One render more, no preparation more, and no decode more.
        #expect(log.preparations.count == 1)
        #expect(log.renders.count == 2)
        #expect(log.decodeCount == 1)

        // The pixels are identical, because the basis is: the claim the rule
        // rests on, checked rather than asserted.
        #expect(
            WorkspaceStubs.pixelBytes(after.image) == WorkspaceStubs.pixelBytes(before.image)
        )
        #expect(after.processing.cameraToWorkingTransform
            == before.processing.cameraToWorkingTransform)

        // And the selection reached disk with the adjustments, as one record.
        #expect(
            store.savedState(for: Self.url)
                == PhotographProcessingState(
                    captureProfile: TestCaptureProfiles.metadataOnly.id,
                    adjustments: .none
                )
        )
    }

    /// The other half of the same rule. A different basis is a different
    /// camera-to-working transform, which runs upstream of the reduction, so
    /// the reduced preview has to be made again.
    @Test("A profile whose basis differs re-prepares, and changes the pixels")
    func aBasisChangeRepreparesAndChangesPixels() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let document = Self.document(
            registry: TestCaptureProfiles.withDifferentBasis, store: store, log: log
        )

        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        let before = try Self.preview(document)

        document.setCaptureProfile(TestCaptureProfiles.differentBasis)
        let after = try await Self.waitForProfile(document, TestCaptureProfiles.differentBasis)

        #expect(
            log.preparedProfiles
                == [.builtinUncalibrated, TestCaptureProfiles.differentBasis.id]
        )
        // Re-prepared from the retained mosaic: no third cache, and no second
        // decode of the file.
        #expect(log.decodeCount == 1)
        #expect(
            WorkspaceStubs.pixelBytes(after.image) != WorkspaceStubs.pixelBytes(before.image)
        )
        #expect(after.processing.cameraToWorkingTransformSource == .explicit)
        #expect(before.processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
    }

    @Test("Selecting the profile already in force does nothing at all")
    func reselectingTheSameProfileDoesNothing() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let document = Self.document(
            registry: TestCaptureProfiles.withMetadataOnly, store: store, log: log
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        let renders = log.renders.count

        document.setCaptureProfile(.builtinUncalibrated)
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(log.renders.count == renders)
        #expect(store.writes.isEmpty)
    }

    /// Selecting a profile changes no adjustment, and a later adjustment is
    /// not overwritten by the selection.
    @Test("A profile selection and the adjustments do not overwrite each other")
    func theTwoHalvesAreIndependent() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let document = Self.document(
            registry: TestCaptureProfiles.withMetadataOnly, store: store, log: log
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        document.setChannelMix(.redBlueSwap)
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document, adjustments: ImageAdjustments(channelMix: .redBlueSwap)
            )
        )

        document.setCaptureProfile(TestCaptureProfiles.metadataOnly)
        _ = try await Self.waitForProfile(document, TestCaptureProfiles.metadataOnly)

        // The mix survived the profile change.
        #expect(document.channelMixAdjustment == .redBlueSwap)
        #expect(
            store.savedState(for: Self.url)
                == PhotographProcessingState(
                    captureProfile: TestCaptureProfiles.metadataOnly.id,
                    adjustments: ImageAdjustments(channelMix: .redBlueSwap)
                )
        )

        document.setExposure(try UserExposureAdjustment(ev: 0.5))
        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document,
                adjustments: ImageAdjustments(
                    channelMix: .redBlueSwap, exposure: try UserExposureAdjustment(ev: 0.5)
                )
            )
        )
        // And the profile survived the adjustment.
        #expect(document.captureProfile == TestCaptureProfiles.metadataOnly)
    }

    // MARK: - Profile changes and preparations in flight

    /// The race ADR 0020 exists to settle. A preparation started under one
    /// profile must never install into a document that has moved to another.
    @Test("A preparation from an earlier profile cannot install into a later one")
    func aStalePreparationCannotInstall() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let gate = GatedPreparation(log: log, holds: { !$0.isDefault })
        // The held pass finishes successfully even though it was superseded,
        // which is what puts the delivery guard — rather than cancellation —
        // on trial.
        gate.ignoresCancellation = true
        let document = Self.document(
            registry: TestCaptureProfiles.all, store: store, log: log, prepare: gate.prepare
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(originX: 0, originY: 0, width: 0.5, height: 0.5)
        )
        document.setWhiteBalance(patch)
        try await gate.waitForGatedPreparationToStart()

        // The document moves to a profile with a different basis while that
        // preparation is at the gate.
        document.setCaptureProfile(TestCaptureProfiles.differentBasis)
        gate.releaseOnePreparation()
        // And the restarted preparation is held too; let it through.
        try await gate.waitForGatedPreparationToStart()
        gate.releaseOnePreparation()

        _ = try await Self.waitForProfile(document, TestCaptureProfiles.differentBasis)

        // Whatever is on screen was prepared for the state the document
        // actually holds — never for the superseded pairing.
        let preview = try Self.preview(document)
        #expect(preview.captureProfile == TestCaptureProfiles.differentBasis)
        #expect(preview.whiteBalanceAdjustment == patch)
        #expect(
            store.savedState(for: Self.url)
                == PhotographProcessingState(
                    captureProfile: TestCaptureProfiles.differentBasis.id,
                    adjustments: ImageAdjustments(whiteBalance: patch)
                )
        )
        // Every preparation that ran, ran for one of the two profiles; none of
        // them installed a source under the wrong one.
        #expect(log.preparationRequests.allSatisfy { $0.whiteBalance == patch || $0.whiteBalance.isDefault })
    }

    /// The counterpart to the white balance's own guard: a second control
    /// moved during a preparation must not restart a pass that is already
    /// producing the right answer.
    @Test("An adjustment made during a preparation does not restart it")
    func anAdjustmentDuringAPreparationDoesNotRestartIt() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let gate = GatedPreparation(log: log, holds: { !$0.isDefault })
        let document = Self.document(
            registry: TestCaptureProfiles.all, store: store, log: log, prepare: gate.prepare
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(originX: 0, originY: 0, width: 0.5, height: 0.5)
        )
        document.setWhiteBalance(patch)
        try await gate.waitForGatedPreparationToStart()

        // An exposure change wants the same patch and the same profile, so the
        // pass at the gate is already producing the right pixels.
        document.setExposure(try UserExposureAdjustment(ev: 0.5))
        gate.releaseOnePreparation()

        _ = try #require(
            await WorkspaceStubs.waitForPreview(
                document,
                adjustments: ImageAdjustments(
                    exposure: try UserExposureAdjustment(ev: 0.5), whiteBalance: patch
                )
            )
        )
        // Two in total: the open's, and this patch's. Not three.
        #expect(log.preparations.count == 2)
    }

    // MARK: - Export

    /// The canonical state wins, exactly as it does for a patch that is still
    /// being prepared.
    @Test("An export uses the profile the document holds, not the one on screen")
    func anExportUsesTheCanonicalProfile() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let document = Self.document(
            registry: TestCaptureProfiles.withDifferentBasis, store: store, log: log
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)

        let onScreen = try Self.preview(document)
        #expect(onScreen.captureProfile == .builtinUncalibrated)

        document.setCaptureProfile(TestCaptureProfiles.differentBasis)
        // Before its render can have landed, the export snapshot already names
        // the new profile: the request is built from the canonical state.
        let request = try #require(document.exportRequest)
        #expect(request.captureProfile == TestCaptureProfiles.differentBasis)
        #expect(request.state.captureProfile == TestCaptureProfiles.differentBasis.id)
        #expect(request.rawURL == Self.url)

        _ = try await Self.waitForProfile(document, TestCaptureProfiles.differentBasis)
    }

    /// The preview and the export are handed the same resolved profile value,
    /// so they cannot resolve different ones.
    @Test("The preview and the export agree on the capture profile")
    func thePreviewAndTheExportAgree() async throws {
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let document = Self.document(
            registry: TestCaptureProfiles.withMetadataOnly, store: store, log: log
        )
        document.open(Self.url)
        try await Self.waitUntilSettled(document)
        document.setCaptureProfile(TestCaptureProfiles.metadataOnly)
        let preview = try await Self.waitForProfile(document, TestCaptureProfiles.metadataOnly)

        let request = try #require(document.exportRequest)
        #expect(request.captureProfile == preview.captureProfile)
        #expect(request.captureProfile.processingBasis == preview.captureProfile.processingBasis)
        #expect(
            request.captureProfile.cameraToWorkingTransform
                == preview.processing.cameraToWorkingTransform
        )
        #expect(
            request.captureProfile.isValidatedInfraredCalibration
                == preview.isValidatedInfraredCalibration
        )
    }

    // MARK: - Nothing is chosen automatically

    /// The claim that no evidence can prove but that a few absences can
    /// support: the filename says 720, the metadata names a camera a profile
    /// describes, and neither selects anything.
    @Test("Nothing selects a profile from a filename or from camera metadata")
    func nothingSelectsAProfileAutomatically() async throws {
        let suggestive = URL(fileURLWithPath: "/tmp/IR-720nm-full-spectrum.orf")
        let log = WorkspaceEventLog()
        let store = StubPhotographProcessingStore(log: log)
        let document = Self.document(
            url: suggestive,
            registry: TestCaptureProfiles.all,
            store: store,
            log: log
        )
        document.open(suggestive)
        try await Self.waitUntilSettled(document)

        #expect(document.captureProfile == .builtinUncalibrated)
        #expect(try Self.preview(document).captureProfileID == .builtinUncalibrated)
        // The same for the creative mix, for the same reason: only a person
        // may decide that a photograph is an infrared capture.
        #expect(document.channelMixAdjustment == .identity)
    }
}

/// The one guard that keeps a rendering's profile label honest, tested where it
/// lives rather than only through the workspace.
@Suite("Capture profile and the preview pipeline")
struct CaptureProfilePipelineTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/basis-guard.orf")

    static func source(
        captureProfile: IRCaptureProfile
    ) throws -> WorkspacePreviewPipeline.Source {
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url, width: 16, height: 12))
        )
        return try WorkspacePreviewPipeline().prepare(
            decoding: url,
            using: decoder,
            whiteBalance: .defaultNeutralPatch,
            captureProfile: captureProfile
        )
    }

    /// Two profiles that share a basis are interchangeable **by construction**,
    /// which is what makes a metadata-only change a cheap re-render.
    @Test("A profile sharing the source's basis renders it, and relabels it")
    func aSharedBasisRenders() throws {
        let source = try Self.source(captureProfile: .builtinUncalibrated)
        let relabelled = try WorkspacePreviewPipeline().render(
            source, captureProfile: TestCaptureProfiles.metadataOnly, adjustments: .none
        )
        let original = try WorkspacePreviewPipeline().render(source, adjustments: .none)

        #expect(relabelled.captureProfile == TestCaptureProfiles.metadataOnly)
        #expect(original.captureProfile == .builtinUncalibrated)
        // Identical pixels: the relabelling changed provenance and nothing else.
        #expect(
            WorkspaceStubs.pixelBytes(relabelled.image)
                == WorkspaceStubs.pixelBytes(original.image)
        )
    }

    /// The camera-to-working transform runs upstream of the reduction, so a
    /// reduced buffer is valid only for the basis that produced it. Rendering
    /// it under another would label these pixels with a decision they were not
    /// produced by.
    @Test("A profile whose basis differs is refused rather than relabelled")
    func aDifferentBasisIsRefused() throws {
        let source = try Self.source(captureProfile: .builtinUncalibrated)
        #expect(
            throws: IRCaptureProfileError.processingBasisMismatch(
                prepared: .builtinUncalibrated,
                requested: TestCaptureProfiles.differentBasis.id
            )
        ) {
            try WorkspacePreviewPipeline().render(
                source,
                captureProfile: TestCaptureProfiles.differentBasis,
                adjustments: .none
            )
        }
    }

    /// The default overload means "under the profile it was prepared with", so
    /// it can never be the one that disagrees.
    @Test("Rendering a source under its own profile always agrees")
    func theDefaultOverloadAlwaysAgrees() throws {
        for profile in [
            IRCaptureProfile.builtinUncalibrated,
            TestCaptureProfiles.metadataOnly,
            TestCaptureProfiles.differentBasis,
        ] {
            let source = try Self.source(captureProfile: profile)
            let preview = try WorkspacePreviewPipeline().render(source, adjustments: .none)
            #expect(preview.captureProfile == profile)
            #expect(
                preview.processing.cameraToWorkingTransform
                    == profile.cameraToWorkingTransform
            )
        }
    }
}
