import Testing
import Foundation
@testable import InfraredConverter

/// The acceptance criterion of the capture-profile milestone, as arithmetic:
/// a photograph adjusted by an older build renders **identically** after
/// migrating to `builtin.uncalibrated`.
///
/// ## Why this is not a tautology
///
/// In memory, a migrated version 4 record and a version 5 record naming the
/// built-in profile are the same value, so comparing them would prove nothing.
/// What has to be proved is the step before that: that the profile the
/// migration chooses supplies **the transform the old code applied**, which was
/// a constant nobody could select:
///
/// ```swift
/// // RAWWorkingImagePipeline, before this milestone
/// static let cameraToWorkingTransform = .sensorRGBIdentityFalseColor
/// ```
///
/// So the historical constant is written out here, literally, and every
/// rendering is made twice — once through it, once through the migrated
/// profile's basis — and compared bit for bit. If someone changes the built-in
/// profile's basis, this fails.
@Suite("Capture-profile migration renders identically")
struct CaptureProfileMigrationRenderingTests {

    /// The transform every build of this application applied before capture
    /// profiles existed. Not read from the profile under test, deliberately.
    static let historicalTransform = RAWCameraToWorkingColorTransform
        .sensorRGBIdentityFalseColor

    nonisolated static let url = URL(fileURLWithPath: "/tmp/migration.orf")

    /// A version 4 sidecar of the kind an older build wrote, with every
    /// adjustment away from its default so that none of them is silently
    /// ignored by both sides equally.
    static let versionFourJSON = #"""
        {"schemaVersion":4,"orientation":"rotate270Clockwise",
         "channelMix":{"kind":"redBlueSwap"},"exposureEV":0.95,
         "whiteBalance":{"kind":"neutralPatch","region":{"originX":0.25,
         "originY":0.5,"width":0.125,"height":0.125}}}
        """#

    static func migrated() throws -> PhotographProcessingState {
        try JSONDecoder().decode(
            PhotographProcessingState.self, from: Data(versionFourJSON.utf8)
        )
    }

    static func decoder(width: Int = 32, height: Int = 24) -> RAWDecoder {
        WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url, width: width, height: height))
        )
    }

    // MARK: - The migration itself

    @Test("A version 4 record migrates to the built-in uncalibrated profile")
    func theMigrationTargetIsTheBuiltInProfile() throws {
        let migrated = try Self.migrated()
        #expect(migrated.captureProfile == .builtinUncalibrated)
        #expect(migrated.adjustments.orientation == .quarterTurnLeft)
        #expect(migrated.adjustments.channelMix == .redBlueSwap)
        #expect(migrated.adjustments.exposure.ev == 0.95)
        #expect(migrated.adjustments.whiteBalance.kind == .neutralPatch)
    }

    /// The load-bearing equality: the profile the migration names supplies the
    /// transform the constant did.
    @Test("The built-in profile's basis is the historical transform")
    func theBuiltInBasisIsTheHistoricalTransform() {
        #expect(
            IRCaptureProfile.builtinUncalibrated.cameraToWorkingTransform
                == Self.historicalTransform
        )
        #expect(
            IRCaptureProfile.builtinUncalibrated.processingBasis.cameraToWorkingTransform
                == Self.historicalTransform
        )
        #expect(!IRCaptureProfile.builtinUncalibrated.isValidatedInfraredCalibration)
    }

    // MARK: - The reduced preview

    @Test("A migrated record's reduced preview is bit-identical to the old one")
    func thePreviewIsBitIdentical() throws {
        let migrated = try Self.migrated()
        let decoder = Self.decoder()
        let pipeline = WorkspacePreviewPipeline()
        let base = try RAWBasePreparationPipeline().prepare(decoding: Self.url, using: decoder)

        // How the application rendered before this milestone: the constant,
        // reached directly.
        let historical = try RAWWorkingImagePipeline().prepare(
            base,
            whiteBalance: migrated.adjustments.whiteBalance,
            cameraToWorkingTransform: Self.historicalTransform
        )
        let historicalReduced = try SceneLinearPreviewReducer().reduce(
            historical.image, policy: WorkspacePreviewPipeline.previewPolicy
        )

        // How it renders now: through the profile the record migrated to.
        let profile = try IRCaptureProfileRegistry.builtin.profile(
            for: migrated.captureProfile
        )
        let current = try pipeline.prepareSource(
            base, whiteBalance: migrated.adjustments.whiteBalance, captureProfile: profile
        )

        #expect(current.preview.width == historicalReduced.width)
        #expect(current.preview.height == historicalReduced.height)
        // Bit patterns, not a tolerance. Nothing about this may be approximate.
        #expect(
            current.preview.values.map(\.bitPattern)
                == historicalReduced.values.map(\.bitPattern)
        )
        // And the same measured white balance, from the same patch.
        #expect(current.estimate.region == historical.estimate.region)
        #expect(
            current.estimate.gains.gainsByColorPlane == historical.estimate.gains.gainsByColorPlane
        )
        #expect(
            current.preview.processing.cameraToWorkingTransform == Self.historicalTransform
        )
    }

    @Test("The whole display-encoded preview is byte-identical")
    func theDisplayedPreviewIsByteIdentical() throws {
        let migrated = try Self.migrated()
        let decoder = Self.decoder()
        let pipeline = WorkspacePreviewPipeline()

        let current = try pipeline.render(
            decoding: Self.url,
            using: decoder,
            adjustments: migrated.adjustments,
            captureProfile: try IRCaptureProfileRegistry.builtin.profile(
                for: migrated.captureProfile
            )
        )

        // The same adjustments through a source prepared with the historical
        // constant, assembled stage by stage the way the old pipeline did.
        let base = try RAWBasePreparationPipeline().prepare(decoding: Self.url, using: decoder)
        let historicalPrepared = try RAWWorkingImagePipeline().prepare(
            base,
            whiteBalance: migrated.adjustments.whiteBalance,
            cameraToWorkingTransform: Self.historicalTransform
        )
        let historicalSource = WorkspacePreviewPipeline.Source(
            preview: try SceneLinearPreviewReducer().reduce(
                historicalPrepared.image, policy: WorkspacePreviewPipeline.previewPolicy
            ),
            metadata: historicalPrepared.metadata,
            url: Self.url,
            captureProfile: .builtinUncalibrated,
            whiteBalance: migrated.adjustments.whiteBalance,
            estimate: historicalPrepared.estimate
        )
        let historical = try pipeline.render(
            historicalSource, adjustments: migrated.adjustments
        )

        #expect(current.pixelWidth == historical.pixelWidth)
        #expect(current.pixelHeight == historical.pixelHeight)
        #expect(
            WorkspaceStubs.pixelBytes(current.image)
                == WorkspaceStubs.pixelBytes(historical.image)
        )
        #expect(current.renderedExposureEV == 0.95)
        #expect(current.effectiveOrientation == historical.effectiveOrientation)
    }

    // MARK: - The full-resolution export

    /// The other end path, at the sensor's own resolution, compared **before**
    /// encoding so that no quantisation can hide a difference.
    @Test("A migrated record's full-resolution export values are bit-identical")
    func theExportValuesAreBitIdentical() throws {
        let migrated = try Self.migrated()
        let decoder = Self.decoder()

        let current = try FullResolutionExportPipeline().render(
            ExportRequest(
                rawURL: Self.url,
                captureProfile: try IRCaptureProfileRegistry.builtin.profile(
                    for: migrated.captureProfile
                ),
                adjustments: migrated.adjustments
            ),
            using: decoder
        )

        let historical = try FullResolutionExportPipeline().render(
            ExportRequest(
                rawURL: Self.url,
                captureProfile: IRCaptureProfile(
                    id: .builtinUncalibrated,
                    name: "historical",
                    processingBasis: .uncalibratedSensorRGB
                ),
                adjustments: migrated.adjustments
            ),
            using: decoder
        )

        #expect(current.pixelWidth == historical.pixelWidth)
        #expect(current.pixelHeight == historical.pixelHeight)
        #expect(
            current.image.values.map(\.bitPattern)
                == historical.image.values.map(\.bitPattern)
        )
        #expect(current.image.processing.cameraToWorkingTransform == Self.historicalTransform)
        #expect(current.captureProfileID == .builtinUncalibrated)
        #expect(!current.isValidatedInfraredCalibration)
    }

    /// And the preview and the export agree about the white balance the
    /// migrated record resolves to, which is the claim ADR 0019 made and this
    /// milestone must not have weakened.
    @Test("Preview and export resolve the migrated record identically")
    func thePreviewAndTheExportAgree() throws {
        let migrated = try Self.migrated()
        let decoder = Self.decoder()
        let profile = try IRCaptureProfileRegistry.builtin.profile(for: migrated.captureProfile)

        let preview = try WorkspacePreviewPipeline().render(
            decoding: Self.url,
            using: decoder,
            adjustments: migrated.adjustments,
            captureProfile: profile
        )
        let export = try FullResolutionExportPipeline().render(
            ExportRequest(
                rawURL: Self.url, captureProfile: profile, adjustments: migrated.adjustments
            ),
            using: decoder
        )

        #expect(preview.neutralPatch == export.neutralPatch)
        #expect(
            preview.whiteBalanceGains.gainsByColorPlane
                == export.whiteBalanceGains.gainsByColorPlane
        )
        #expect(preview.captureProfileID == export.captureProfileID)
        #expect(
            preview.processing.cameraToWorkingTransform
                == export.image.processing.cameraToWorkingTransform
        )
        #expect(preview.effectiveOrientation == export.orientation)
        #expect(preview.renderedExposureEV == export.exposureEV)
    }
}
