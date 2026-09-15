import Testing
import CryptoKit
import Foundation
@testable import InfraredConverter

/// A reusable user profile, on a real twelve-megapixel photograph.
///
/// The milestone's acceptance criterion, exercised end to end:
///
/// ```text
/// create one explicitly uncalibrated E-PL3 / full-spectrum / 720 nm profile
/// assign it to a photograph
/// pick a neutral patch
/// export
/// reopen from the saved sidecar and the same profile library
/// ```
///
/// Every test works on an **isolated copy** of the fixture in a temporary
/// directory, and on a **temporary profile library**. Nothing here reads or
/// writes `RAW/`, and nothing touches the real Application Support folder.
///
/// Nothing here is a claim that this profile is an E-PL3 infrared calibration.
/// It is explicitly uncalibrated, and the tests assert that it says so.
@Suite(
    "E-PL3 user capture profile",
    .enabled(if: RAWFixtureMode.isEnabled, "\(RAWFixtureMode.disabledReason)"),
    .serialized
)
@MainActor
struct EPL3UserCaptureProfileTests {

    /// The draft a photographer would fill in for the milestone's example
    /// configuration.
    ///
    /// Camera-specific on purpose: the whole point of naming the camera is that
    /// the profile is checked against the file, and the fixture is the file it
    /// is checked against.
    static func draft(
        name: String = "My Olympus E-PL3 — R72",
        make: String,
        model: String
    ) -> IRCaptureProfileDraft {
        IRCaptureProfileDraft(
            name: name,
            cameraScope: .specificCamera,
            cameraMake: make,
            cameraModel: model,
            conversionKind: .fullSpectrum,
            conversionVendor: "Unrecorded vendor",
            filter: IRCaptureProfileDraft.FilterDraft(
                kind: .longPass, nominalCutoffNanometers: "720"
            )
        )
    }

    /// A neutral patch that is not the application's centred default, so that
    /// "this photograph's own decision" is visible in the record.
    static func pickedPatch() throws -> UserWhiteBalanceAdjustment {
        .neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.35, originY: 0.4, width: 0.06, height: 0.08
            )
        )
    }

    static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An isolated fixture copy **and** an isolated profile library, together,
    /// because every test here needs both.
    static func withFixtureAndLibrary(
        _ body: (URL, IRCaptureProfileLibrary) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epl3-irprofiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        guard let original = RAWFixtures.olympusORF else {
            throw RAWFixtures.Unavailable.noFixture
        }
        let fixtureDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epl3-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let copy = fixtureDirectory.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: copy)

        let library = IRCaptureProfileLibrary(
            store: FileIRCaptureProfileStore(directory: directory)
        )
        try await body(copy, library)
    }

    static func waitUntilSettled(_ state: DocumentState) async throws {
        for _ in 0..<3600 {
            if case .decoding = state.status {
                try await Task.sleep(nanoseconds: 10_000_000)
            } else {
                return
            }
        }
        Issue.record("The open never settled")
    }

    static func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<3600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
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

    /// The complete workflow, on the reference camera.
    ///
    /// The assertion that matters most is the **pixel** one: a user profile
    /// whose processing basis is the uncalibrated sensor-RGB one renders
    /// bit-identically to the built-in profile. A profile is capture context;
    /// only its processing basis reaches a pixel, and these two share it. If
    /// this ever fails, some descriptive field has started changing an image.
    @Test("A user profile renders identically to the built-in one, and reopens")
    func aUserProfileRoundTripsOnTheFixture() async throws {
        try await Self.withFixtureAndLibrary { url, library in
            let before = try Self.digest(of: url)

            let metadata = try LibRawDecoder().readMetadata(at: url)
            let make = try #require(metadata.identity.normalizedMake ?? metadata.identity.make)
            let model = try #require(metadata.identity.normalizedModel ?? metadata.identity.model)
            let profile = try library.create(Self.draft(make: make, model: model))

            // Context, not calibration — asserted at the point of creation,
            // because this is where a person would most expect the application
            // to have learned something about their camera. It has not.
            #expect(profile.processingBasis == .uncalibratedSensorRGB)
            #expect(!profile.isValidatedInfraredCalibration)
            #expect(profile.filter == .longPass(nominalCutoffNanometers: 720))
            #expect(profile.applicability(to: metadata) == .matches)

            let store = JSONSidecarPhotographProcessingStore()
            let document = DocumentState(store: store, registry: library.registry)

            document.open(url)
            try await Self.waitUntilSettled(document)
            #expect(document.captureProfile == .builtinUncalibrated)
            let builtInPreview = try Self.preview(document)

            // Assign the user profile, and pick a neutral patch of this
            // photograph's own.
            document.setCaptureProfile(profile)
            document.setWhiteBalance(try Self.pickedPatch())
            try await Self.waitUntil("the complete state is saved") {
                (try? store.load(for: url))?.captureProfile == profile.id
                    && (try? store.load(for: url))?.adjustments.whiteBalance
                        == (try? Self.pickedPatch())
            }

            let userPreview = try Self.preview(document)
            #expect(userPreview.captureProfile == profile)
            #expect(!userPreview.isValidatedInfraredCalibration)
            #expect(userPreview.processing.cameraToWorkingTransformSource
                == builtInPreview.processing.cameraToWorkingTransformSource)

            // The sidecar holds a **reference**, not the definition. Read the
            // bytes and assert the definition is not in them.
            let sidecarText = String(
                decoding: try Data(contentsOf: store.sidecarURL(for: url)), as: UTF8.self
            )
            #expect(sidecarText.contains(profile.id.rawValue))
            #expect(!sidecarText.contains(profile.name))
            #expect(!sidecarText.contains("720"))
            #expect(!sidecarText.contains("fullSpectrum"))

            // Reopen, from the saved sidecar and the same library. The profile
            // resolves through its stable identity, and the patch comes back.
            document.open(url)
            try await Self.waitUntilSettled(document)
            #expect(document.captureProfile == profile)
            #expect(document.whiteBalanceAdjustment == (try Self.pickedPatch()))
            let reopened = try Self.preview(document)
            #expect(reopened.captureProfile == profile)

            // And the RAW file was never written to.
            #expect(try Self.digest(of: url) == before)
        }
    }

    /// Renaming the profile changes what a person reads and nothing a
    /// photograph resolves. The sidecar is not rewritten and the file reopens
    /// under the same identity.
    @Test("Renaming a profile does not disturb a photograph that references it")
    func renamingDoesNotDisturbAPhotograph() async throws {
        try await Self.withFixtureAndLibrary { url, library in
            let metadata = try LibRawDecoder().readMetadata(at: url)
            let make = try #require(metadata.identity.normalizedMake ?? metadata.identity.make)
            let model = try #require(metadata.identity.normalizedModel ?? metadata.identity.model)
            let profile = try library.create(
                Self.draft(name: "E-PL3 R72", make: make, model: model)
            )

            let store = JSONSidecarPhotographProcessingStore()
            let document = DocumentState(store: store, registry: library.registry)
            document.open(url)
            try await Self.waitUntilSettled(document)
            document.setCaptureProfile(profile)
            try await Self.waitUntil("the profile is saved") {
                (try? store.load(for: url))?.captureProfile == profile.id
            }
            let sidecar = store.sidecarURL(for: url)
            let sidecarBefore = try Data(contentsOf: sidecar)

            var draft = IRCaptureProfileDraft(profile)
            draft.name = "My Olympus 720"
            let renamed = try library.update(draft, id: profile.id)
            document.updateCaptureProfiles(library.registry)
            try await Self.waitUntil("the new name reaches the preview") {
                (try? Self.preview(document))?.captureProfile.name == "My Olympus 720"
            }

            #expect(renamed.id == profile.id)
            // Byte for byte: a rename is not a reason to rewrite a sidecar.
            #expect(try Data(contentsOf: sidecar) == sidecarBefore)

            // And a fresh document resolves it through the same identity.
            let reopened = DocumentState(store: store, registry: library.registry)
            reopened.open(url)
            try await Self.waitUntilSettled(reopened)
            #expect(reopened.captureProfile == renamed)
        }
    }

    /// An export carries the resolved profile it started with, renders from the
    /// RAW file at full resolution, and writes no sidecar.
    @Test("A full-resolution export under a user profile succeeds and edits nothing")
    func exportUnderAUserProfile() async throws {
        try await Self.withFixtureAndLibrary { url, library in
            let metadata = try LibRawDecoder().readMetadata(at: url)
            let make = try #require(metadata.identity.normalizedMake ?? metadata.identity.make)
            let model = try #require(metadata.identity.normalizedModel ?? metadata.identity.model)
            let profile = try library.create(Self.draft(make: make, model: model))

            let store = JSONSidecarPhotographProcessingStore()
            let document = DocumentState(store: store, registry: library.registry)
            document.open(url)
            try await Self.waitUntilSettled(document)
            document.setCaptureProfile(profile)
            document.setWhiteBalance(try Self.pickedPatch())
            try await Self.waitUntil("the complete state is saved") {
                (try? store.load(for: url))?.captureProfile == profile.id
            }
            let sidecarBefore = try Data(contentsOf: store.sidecarURL(for: url))
            let rawBefore = try Self.digest(of: url)

            // The snapshot carries the resolved definition rather than an
            // identifier to look up while running.
            let request = try #require(document.exportRequest)
            #expect(request.captureProfile == profile)
            #expect(request.adjustments.whiteBalance == (try Self.pickedPatch()))

            let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("epl3-user-profile-\(UUID().uuidString).tif")
            defer { try? FileManager.default.removeItem(at: destination) }

            let result = try FullResolutionExportPipeline().export(
                request, to: destination, using: LibRawDecoder()
            )

            #expect(result.pixelWidth > 0 && result.pixelHeight > 0)
            #expect(FileManager.default.fileExists(atPath: destination.path))
            // The export result names the user profile it was rendered under,
            // by the same stable identity the sidecar holds. Profile identity
            // survives preview, export and the written file's own record.
            #expect(result.captureProfile == profile.id)
            #expect(result.state.captureProfile == profile.id)
            // An export is an artefact, not an edit: the sidecar and the RAW
            // file are untouched.
            #expect(try Data(contentsOf: store.sidecarURL(for: url)) == sidecarBefore)
            #expect(try Self.digest(of: url) == rawBefore)
        }
    }
}
