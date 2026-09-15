import Testing
import CryptoKit
import Foundation
@testable import InfraredConverter

/// The capture-profile foundation on a real photograph.
///
/// > Existing photographs must migrate to a stable built-in "uncalibrated"
/// > capture profile with pixel-identical rendering.
///
/// Every test works on an **isolated copy** of the fixture in a temporary
/// directory, so whatever a developer has saved beside their own
/// `RAW/OLYMPUS.ORF` cannot change what these tests see, and nothing is ever
/// written into `RAW/`.
///
/// Nothing here is a claim that this profile is an E-PL3 infrared calibration.
/// The fixture is a **regression fixture**: it proves that a real twelve-
/// megapixel file renders the same way it did before capture profiles existed.
@Suite(
    "E-PL3 capture profile",
    .enabled(if: RAWFixtureMode.isEnabled, "\(RAWFixtureMode.disabledReason)"),
    .serialized
)
struct EPL3CaptureProfileTests {

    static let fullWidth = 4056
    static let fullHeight = 3040

    /// The transform every build applied before capture profiles existed,
    /// written out literally rather than read from the profile under test.
    static let historicalTransform = RAWCameraToWorkingColorTransform
        .sensorRGBIdentityFalseColor

    static func withIsolatedFixture<T>(_ body: (URL) throws -> T) throws -> T {
        try RAWFixtures.withIsolatedCopy(body)
    }

    static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A complete non-default state, so that no adjustment is silently ignored
    /// by both sides of a comparison equally.
    static func savedAdjustments() throws -> ImageAdjustments {
        ImageAdjustments(
            orientation: .quarterTurnLeft,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 0.95),
            whiteBalance: .neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: 0.15, originY: 0.2, width: 0.05, height: 0.0625
                )
            )
        )
    }

    // MARK: - Identity and applicability

    @Test("The fixture's camera identity resolves, and the built-in profile applies")
    func theBuiltInProfileAppliesToTheFixture() throws {
        try Self.withIsolatedFixture { url in
            let metadata = try LibRawDecoder().readMetadata(at: url)
            // The make and model are read, and are what a camera-specific
            // profile would have to match.
            let make = try #require(metadata.identity.make)
            let model = try #require(metadata.identity.model)
            #expect(make.uppercased().contains("OLYMPUS"))
            #expect(model.uppercased().contains("E-PL3"))

            // The built-in profile claims no camera, so it applies.
            let builtIn = IRCaptureProfile.builtinUncalibrated
            #expect(builtIn.applicability(to: metadata) == .matches)
            // And it claims no calibration for this camera, or any other.
            #expect(!builtIn.isValidatedInfraredCalibration)

            // A profile naming this exact camera also applies — matching is
            // exact after trimming and case folding, and nothing more.
            let specific = IRCaptureProfile(
                id: try IRCaptureProfileID("user.epl3-fixture"),
                name: "E-PL3",
                cameraMatch: .camera(make: make, model: model),
                processingBasis: .uncalibratedSensorRGB
            )
            #expect(specific.applicability(to: metadata) == .matches)
            // Naming a different body does not.
            let other = IRCaptureProfile(
                id: try IRCaptureProfileID("user.a7-fixture"),
                name: "A7",
                cameraMatch: .camera(make: "SONY", model: "ILCE-7"),
                processingBasis: .uncalibratedSensorRGB
            )
            #expect(specific.applicability(to: metadata).isApplicable)
            #expect(!other.applicability(to: metadata).isApplicable)
        }
    }

    // MARK: - The migration, on real pixels

    /// The acceptance criterion, on twelve megapixels: a version 4 sidecar
    /// migrates to `builtin.uncalibrated` and renders **bit-identically** to
    /// the constant it replaced.
    @Test("A version 4 sidecar migrates and renders bit-identically")
    func aVersionFourSidecarRendersIdentically() throws {
        try Self.withIsolatedFixture { url in
            let adjustments = try Self.savedAdjustments()
            let before = try Self.digest(of: url)

            // A real sidecar of the shape an older build wrote, on disk,
            // beside the copy.
            let sidecar = JSONSidecarPhotographProcessingStore.sidecarURL(for: url)
            try Self.writeVersionFourSidecar(adjustments, to: sidecar)

            let loaded = try #require(
                try JSONSidecarPhotographProcessingStore().load(for: url)
            )
            #expect(loaded.captureProfile == .builtinUncalibrated)
            #expect(loaded.adjustments == adjustments)

            // Reading changed nothing on disk — neither the RAW file nor the
            // sidecar was rewritten.
            #expect(try Self.digest(of: url) == before)
            let text = try String(contentsOf: sidecar, encoding: .utf8)
            #expect(text.contains("\"schemaVersion\" : 4"))

            let base = try RAWBasePreparationPipeline().prepare(
                decoding: url, using: LibRawDecoder()
            )
            #expect(base.activeAreaWidth == Self.fullWidth)
            #expect(base.activeAreaHeight == Self.fullHeight)

            // The old way: the constant, reached directly.
            let historical = try RAWWorkingImagePipeline().prepare(
                base,
                whiteBalance: adjustments.whiteBalance,
                cameraToWorkingTransform: Self.historicalTransform
            )
            // The new way: through the profile the record migrated to.
            let profile = try IRCaptureProfileRegistry.builtin.profile(
                for: loaded.captureProfile
            )
            let current = try RAWWorkingImagePipeline().prepare(
                base,
                whiteBalance: loaded.adjustments.whiteBalance,
                cameraToWorkingTransform: profile.cameraToWorkingTransform
            )

            // Same measured patch, same gains, same twelve million values.
            #expect(current.neutralPatch == historical.neutralPatch)
            #expect(
                current.whiteBalanceGains.gainsByColorPlane
                    == historical.whiteBalanceGains.gainsByColorPlane
            )
            #expect(current.image.width == historical.image.width)
            #expect(current.image.height == historical.image.height)
            #expect(
                current.image.values.map(\.bitPattern)
                    == historical.image.values.map(\.bitPattern)
            )
        }
    }

    /// The same claim at the two ends of the pipeline: the reduced preview the
    /// workspace shows, and the full-resolution values an export encodes.
    @Test("Preview and export values are unchanged by the migration")
    func bothEndPathsAreUnchanged() throws {
        try Self.withIsolatedFixture { url in
            let adjustments = try Self.savedAdjustments()
            let profile = IRCaptureProfile.builtinUncalibrated
            let decoder = LibRawDecoder()
            let pipeline = WorkspacePreviewPipeline()
            let base = try RAWBasePreparationPipeline().prepare(decoding: url, using: decoder)

            let current = try pipeline.prepareSource(
                base, whiteBalance: adjustments.whiteBalance, captureProfile: profile
            )
            let historicalPrepared = try RAWWorkingImagePipeline().prepare(
                base,
                whiteBalance: adjustments.whiteBalance,
                cameraToWorkingTransform: Self.historicalTransform
            )
            let historicalReduced = try SceneLinearPreviewReducer().reduce(
                historicalPrepared.image, policy: WorkspacePreviewPipeline.previewPolicy
            )
            #expect(
                current.preview.values.map(\.bitPattern)
                    == historicalReduced.values.map(\.bitPattern)
            )
            #expect(current.preview.width == historicalReduced.width)
            #expect(current.preview.height == historicalReduced.height)

            // And the export, compared before encoding so no quantisation can
            // hide a difference.
            let export = try FullResolutionExportPipeline().render(
                ExportRequest(rawURL: url, captureProfile: profile, adjustments: adjustments),
                using: decoder
            )
            let historicalExport = try FullResolutionExportPipeline().render(
                ExportRequest(
                    rawURL: url,
                    captureProfile: IRCaptureProfile(
                        id: .builtinUncalibrated,
                        name: "historical",
                        processingBasis: .uncalibratedSensorRGB
                    ),
                    adjustments: adjustments
                ),
                using: decoder
            )
            #expect(
                export.image.values.map(\.bitPattern)
                    == historicalExport.image.values.map(\.bitPattern)
            )
            #expect(export.captureProfileID == .builtinUncalibrated)
            #expect(!export.isValidatedInfraredCalibration)
            #expect(
                export.image.processing.cameraToWorkingTransform == Self.historicalTransform
            )
        }
    }

    // MARK: - The file system

    /// The RAW file is an input. Opening it, adjusting it, selecting a profile
    /// and exporting it write exactly one file, and it is the sidecar.
    @Test("Nothing is written beside the RAW file but its own sidecar")
    func nothingUnexpectedIsWritten() throws {
        try Self.withIsolatedFixture { url in
            let directory = url.deletingLastPathComponent()
            let before = try Self.digest(of: url)

            let store = JSONSidecarPhotographProcessingStore()
            try store.save(
                PhotographProcessingState(adjustments: try Self.savedAdjustments()),
                for: url
            )

            let contents = try FileManager.default
                .contentsOfDirectory(atPath: directory.path)
                .sorted()
            #expect(
                contents == [
                    url.lastPathComponent,
                    "\(url.lastPathComponent).\(JSONSidecarPhotographProcessingStore.sidecarSuffix)",
                ].sorted()
            )
            // No profile definition file, no registry, no cache, no index.
            #expect(!contents.contains { $0.contains("profile") })
            #expect(try Self.digest(of: url) == before)

            // And the sidecar is the new shape.
            let text = try String(
                contentsOf: JSONSidecarPhotographProcessingStore.sidecarURL(for: url),
                encoding: .utf8
            )
            #expect(text.contains("\"schemaVersion\" : 5"))
            #expect(text.contains("\"captureProfileID\" : \"builtin.uncalibrated\""))
            #expect(text.contains("\"adjustments\""))
        }
    }

    // MARK: - Writing a historical sidecar

    /// A version 4 record, in the flat shape an older build wrote, produced
    /// without going through this build's encoder — which only writes version
    /// 5 and would defeat the point.
    private static func writeVersionFourSidecar(
        _ adjustments: ImageAdjustments, to sidecar: URL
    ) throws {
        let region = try #require(adjustments.whiteBalance.selectedRegion)
        let json = """
            {
              "schemaVersion" : 4,
              "orientation" : "\(adjustments.orientation.persistedToken)",
              "channelMix" : { "kind" : "\(adjustments.channelMix.kind.rawValue)" },
              "exposureEV" : \(adjustments.exposure.ev),
              "whiteBalance" : {
                "kind" : "neutralPatch",
                "region" : {
                  "originX" : \(region.originX),
                  "originY" : \(region.originY),
                  "width" : \(region.width),
                  "height" : \(region.height)
                }
              }
            }
            """
        try Data(json.utf8).write(to: sidecar, options: [.atomic])
    }
}
