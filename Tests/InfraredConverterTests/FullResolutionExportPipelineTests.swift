import Testing
import CryptoKit
import Foundation
@testable import InfraredConverter

/// The export end path: from a RAW file, at full resolution, with the same
/// adjustments the preview has — and never from preview pixels.
@Suite("Full-resolution export pipeline")
struct FullResolutionExportPipelineTests {

    private static let url = URL(fileURLWithPath: "/tmp/synthetic-export.orf")

    private static func decoder(
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0,
        url: URL = FullResolutionExportPipelineTests.url
    ) -> WorkspaceStubDecoder {
        WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(
                WorkspaceStubs.mosaic(url: url, width: width, height: height, flip: flip)
            )
        )
    }

    private static func render(
        _ adjustments: ImageAdjustments,
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0
    ) throws -> FullResolutionExportRender {
        try FullResolutionExportPipeline().render(
            ExportRequest(rawURL: url, adjustments: adjustments),
            using: decoder(width: width, height: height, flip: flip)
        )
    }

    // MARK: - The neutral state

    @Test("An identity export is the neutral application state, at full resolution")
    func anIdentityExportIsTheNeutralState() throws {
        let rendered = try Self.render(.none)

        #expect(rendered.request.adjustments == .none)
        #expect(rendered.exposureEV == 0)
        #expect(rendered.mix == .identity)
        #expect(rendered.mix.matrix.isIdentity)
        // The file records no rotation, and nothing invents one.
        #expect(rendered.orientation == .upright)
        #expect(rendered.image.processing.channelMixApplied)
        #expect(rendered.image.processing.orientationApplied)
        #expect(rendered.image.processing.exposureApplied)
        // The same application choices the preview path makes.
        #expect(
            rendered.image.processing.cameraToWorkingTransform
                == WorkspacePreviewPipeline.initialTransform
        )
        #expect(rendered.image.processing.workingColorSpace == .extendedLinearSRGB)
        #expect(!rendered.image.processing.isValidatedInfraredCalibration)
        // Scene-linear and unclipped: the encoder owns the range policy.
        #expect(rendered.image.processing.sceneLinear)
        #expect(!rendered.image.processing.clamped)
        #expect(!rendered.image.processing.displayEncodingApplied)
        #expect(!rendered.image.processing.reducedForPreview)
        #expect(rendered.metadata.geometry.flip == 0)
    }

    @Test("Full resolution means the sensor's own, not the preview's")
    func fullResolutionIsTheSensorsOwn() throws {
        let decoder = Self.decoder(width: 16, height: 12)
        // A preview policy small enough to reduce heavily.
        let source = try WorkspacePreviewPipeline().prepare(
            decoding: Self.url,
            using: decoder,
            policy: PreviewResolutionPolicy(maximumLongestEdge: 4)
        )
        #expect(source.preview.width == 4)
        #expect(source.resolution.isReduced)

        let rendered = try FullResolutionExportPipeline().render(
            ExportRequest(rawURL: Self.url, adjustments: .none), using: decoder
        )
        #expect(rendered.pixelWidth == source.resolution.sourceWidth)
        #expect(rendered.pixelHeight == source.resolution.sourceHeight)
        #expect(rendered.pixelWidth == 16)
        #expect(rendered.pixelHeight == 12)
    }

    // MARK: - Mix, orientation and exposure at full resolution

    @Test("A red/blue swap, a quarter turn and a stop all land, before any encoding")
    func mixOrientationAndExposureAllLand() throws {
        let width = 8
        let height = 6
        let neutral = try Self.render(.none, width: width, height: height)
        let adjusted = try Self.render(
            ImageAdjustments(
                orientation: .quarterTurnRight,
                channelMix: .redBlueSwap,
                exposure: try UserExposureAdjustment(ev: 1)
            ),
            width: width, height: height
        )

        // Geometry: a quarter turn exchanges the two dimensions.
        #expect(neutral.pixelWidth == width)
        #expect(neutral.pixelHeight == height)
        #expect(adjusted.pixelWidth == height)
        #expect(adjusted.pixelHeight == width)
        #expect(adjusted.image.processing.orientationSwappedDimensions)

        // And every pixel: the value at the rotated position is the source
        // pixel's, with red and blue exchanged and every component doubled.
        //
        // `rotated90Clockwise` reads destination (r, c) from source
        // (sourceHeight − 1 − c, r).
        let lastRow = height - 1
        for row in 0..<adjusted.pixelHeight {
            for column in 0..<adjusted.pixelWidth {
                let source = try #require(
                    neutral.image.pixel(row: lastRow - column, column: row)
                )
                let result = try #require(adjusted.image.pixel(row: row, column: column))
                #expect(result.red == Float(Double(source.blue) * 2))
                #expect(result.green == Float(Double(source.green) * 2))
                #expect(result.blue == Float(Double(source.red) * 2))
            }
        }

        #expect(adjusted.mix == .redBlueSwap)
        #expect(adjusted.exposureEV == 1)
        #expect(adjusted.orientation == .rotated90Clockwise)
    }

    @Test("The range policy runs after exposure, not before it")
    func theRangePolicyRunsAfterExposure() throws {
        // A lifted export clips more than a neutral one, and a dimmed export
        // clips less. If clipping happened first, neither count could move.
        let request = { (ev: Double) in
            ExportRequest(
                rawURL: Self.url,
                adjustments: ImageAdjustments(
                    exposure: try! UserExposureAdjustment(ev: ev)
                )
            )
        }
        let pipeline = FullResolutionExportPipeline()
        let decoder = Self.decoder()

        let lifted = try pipeline.encode(
            try pipeline.render(request(6), using: decoder)
        )
        let dimmed = try pipeline.encode(
            try pipeline.render(request(-6), using: decoder)
        )
        #expect(lifted.processing.clippedHighSampleCount
            > dimmed.processing.clippedHighSampleCount)
        #expect(lifted.processing.exposureEV == 6)
        #expect(dimmed.processing.exposureEV == -6)
    }

    @Test("The file's own orientation is composed with the user's, not replaced")
    func theFilesOrientationIsComposedWithTheUsers() throws {
        // flip 6 is a quarter turn recorded by the camera.
        let recorded = try Self.render(.none, width: 8, height: 6, flip: 6)
        #expect(recorded.orientation == .rotated90Clockwise)
        #expect(recorded.pixelWidth == 6)
        #expect(recorded.pixelHeight == 8)

        // The user's correction composes onto it rather than replacing it.
        let corrected = try Self.render(
            ImageAdjustments(orientation: .quarterTurnLeft), width: 8, height: 6, flip: 6
        )
        #expect(corrected.orientation == .upright)
        #expect(corrected.pixelWidth == 8)
        #expect(corrected.pixelHeight == 6)
    }

    // MARK: - The same rendering as the preview

    @Test("Preview and export are the same rendering at two bit depths")
    func previewAndExportAgree() throws {
        // A synthetic frame small enough that the preview policy does not
        // reduce it, so the only remaining differences are the deliberate
        // ones: 8 bits against 16.
        let decoder = Self.decoder(width: 8, height: 6)
        let adjustments = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 0.75)
        )

        let preview = try WorkspacePreviewPipeline().render(
            decoding: Self.url, using: decoder, adjustments: adjustments
        )
        #expect(!preview.resolution.isReduced)

        let pipeline = FullResolutionExportPipeline()
        let export = try pipeline.encode(
            try pipeline.render(
                ExportRequest(rawURL: Self.url, adjustments: adjustments), using: decoder
            )
        )

        #expect(export.width == preview.pixelWidth)
        #expect(export.height == preview.pixelHeight)

        let previewBytes = try #require(WorkspaceStubs.pixelBytes(preview.image))
        #expect(previewBytes.count == export.width * export.height * 3)

        // Compared as normalised values, which is the only way two different
        // bit depths can be compared at all. The tolerance is one 8-bit step:
        // anything larger would be a different rendering, not a different
        // quantisation.
        var worst = 0.0
        for index in 0..<export.samples.count {
            let fromPreview = Double(previewBytes[previewBytes.startIndex + index]) / 255
            let fromExport = Double(export.samples[index]) / 65535
            worst = max(worst, abs(fromPreview - fromExport))
        }
        #expect(worst <= 1.0 / 255)
        // And the two paths agree about what they clipped, which they could
        // not if either applied a different exposure or a different policy.
        #expect(
            export.processing.clippedLowSampleCount
                == preview.processing.clippedLowSampleCount
        )
        #expect(
            export.processing.clippedHighSampleCount
                == preview.processing.clippedHighSampleCount
        )
        #expect(export.processing.exposureEV == preview.renderedExposureEV)
        #expect(export.processing.mix == preview.channelMix)
        #expect(export.processing.orientation == preview.effectiveOrientation)
    }


    /// An **authored** matrix, now that one can be authored, resolved by both
    /// paths from the same canonical adjustment.
    ///
    /// The mix reaches the export the way every adjustment does — inside one
    /// `ImageAdjustments`, from the RAW file — so there is no second place a
    /// creative matrix could be resolved, defaulted, or quietly turned into a
    /// built-in. Deliberately asymmetric and partly negative, so a
    /// transposition or a dropped coefficient shows up in the pixels.
    @Test("Preview and export resolve the same authored creative matrix")
    func previewAndExportResolveTheSameAuthoredMatrix() throws {
        let coefficients: [Double] = [
            1.8, -0.4, -0.4,
            -0.2, 1.4, -0.2,
            2.5, 0, -1.5,
        ]
        let authored = try UserChannelMixAdjustment.explicit(persistedMatrix: coefficients)
        let adjustments = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: authored,
            exposure: try UserExposureAdjustment(ev: 0.75),
            whiteBalance: .neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: 0.25, originY: 0.25, width: 0.5, height: 0.5
                )
            )
        )

        // Small enough that the preview policy does not reduce it, so the only
        // remaining difference is the deliberate one: 8 bits against 16.
        let decoder = Self.decoder(width: 8, height: 6)
        let preview = try WorkspacePreviewPipeline().render(
            decoding: Self.url, using: decoder, adjustments: adjustments
        )
        #expect(!preview.resolution.isReduced)

        let pipeline = FullResolutionExportPipeline()
        let rendered = try pipeline.render(
            ExportRequest(rawURL: Self.url, adjustments: adjustments), using: decoder
        )
        let export = try pipeline.encode(rendered)

        // Both paths applied the authored matrix, with its own coefficients and
        // its own provenance — not a built-in that happens to look like it.
        #expect(preview.channelMixAdjustment == authored)
        #expect(rendered.request.adjustments.channelMix == authored)
        #expect(preview.channelMix == rendered.mix)
        #expect(rendered.mix.source == .explicit)
        #expect(rendered.mix.matrix.rows.flatMap { $0 } == coefficients)
        #expect(export.processing.mix == preview.channelMix)

        // And the pixels agree, to one 8-bit step.
        #expect(export.width == preview.pixelWidth)
        #expect(export.height == preview.pixelHeight)
        let previewBytes = try #require(WorkspaceStubs.pixelBytes(preview.image))
        #expect(previewBytes.count == export.width * export.height * 3)
        var worst = 0.0
        for index in 0..<export.samples.count {
            let fromPreview = Double(previewBytes[previewBytes.startIndex + index]) / 255
            let fromExport = Double(export.samples[index]) / 65535
            worst = max(worst, abs(fromPreview - fromExport))
        }
        #expect(worst <= 1.0 / 255)
        // The same clipping, which two different matrices could not produce.
        #expect(
            export.processing.clippedLowSampleCount
                == preview.processing.clippedLowSampleCount
        )
        #expect(
            export.processing.clippedHighSampleCount
                == preview.processing.clippedHighSampleCount
        )
        #expect(export.processing.orientation == preview.effectiveOrientation)
        #expect(export.processing.exposureEV == preview.renderedExposureEV)
        // The same white balance, resolved from the file by each path.
        #expect(rendered.estimate.gains == preview.whiteBalanceGains)
        #expect(rendered.estimate.region == preview.neutralPatch)
    }

    /// Two different authored matrices export differently, which is what makes
    /// the agreement above a statement about this matrix rather than about any
    /// matrix.
    @Test("A different authored matrix exports different pixels")
    func adifferentAuthoredMatrixExportsDifferently() throws {
        func samples(_ coefficients: [Double]) throws -> [UInt16] {
            let mix = try UserChannelMixAdjustment.explicit(persistedMatrix: coefficients)
            let pipeline = FullResolutionExportPipeline()
            return try pipeline.encode(
                try pipeline.render(
                    ExportRequest(
                        rawURL: Self.url,
                        adjustments: ImageAdjustments(channelMix: mix)
                    ),
                    using: Self.decoder()
                )
            ).samples
        }

        let one = try samples([1.8, -0.4, -0.4, -0.2, 1.4, -0.2, 2.5, 0, -1.5])
        let other = try samples([0.5, 0.25, 0.25, 0.25, 0.5, 0.25, 0.25, 0.25, 0.5])
        #expect(one != other)

        // And an authored identity is the identity's own rendering: the same
        // pixels, from a different provenance.
        let authoredIdentity = try samples([1, 0, 0, 0, 1, 0, 0, 0, 1])
        let builtInIdentity = try FullResolutionExportPipeline()
            .encode(try Self.render(.none)).samples
        #expect(authoredIdentity == builtInIdentity)
    }

    // MARK: - The white balance

    /// The export resolves the user's patch through the same resolver the
    /// preview uses, measures it with the same estimator, and does so against
    /// the RAW file's own active area — not against anything a workspace
    /// happened to be holding.
    @Test("A custom neutral patch reaches the export's own estimate")
    func aCustomPatchReachesTheExport() throws {
        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.5, originY: 0.5, width: 0.5, height: 0.5
            )
        )
        let rendered = try Self.render(ImageAdjustments(whiteBalance: patch))

        #expect(rendered.request.adjustments.whiteBalance == patch)
        // The region measured is the one the adjustment names, resolved
        // against the sensor's own 8 × 6 active area by the one resolver.
        #expect(
            rendered.neutralPatch
                == (try patch.resolvedRegion(activeAreaWidth: 8, activeAreaHeight: 6))
        )
        try rendered.whiteBalanceGains.validate()
        // And the gains reached the pixels: the chain records them.
        #expect(rendered.image.processing.whiteBalanceGains == rendered.whiteBalanceGains)
        #expect(rendered.image.processing.whiteBalanceApplied)
    }

    @Test("Two different patches produce two different exports")
    func differentPatchesProduceDifferentExports() throws {
        let a = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0, originY: 0, width: 0.5, height: 0.5
            )
        )
        let b = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.5, originY: 0.5, width: 0.5, height: 0.5
            )
        )
        let first = try Self.render(ImageAdjustments(whiteBalance: a))
        let second = try Self.render(ImageAdjustments(whiteBalance: b))

        #expect(first.neutralPatch != second.neutralPatch)
        #expect(first.whiteBalanceGains != second.whiteBalanceGains)
        #expect(first.image.values != second.image.values)
    }

    /// The default case exports exactly what every build of this project
    /// exported before the white balance was adjustable.
    @Test("The default patch exports the historical centred square")
    func theDefaultPatchIsTheHistoricalOne() throws {
        let rendered = try Self.render(.none)
        #expect(
            rendered.neutralPatch
                == UserWhiteBalanceAdjustment.defaultRegion(width: 8, height: 6)
        )
    }

    /// The strongest form of "one estimator, one resolver": for the same file
    /// and the same patch, the preview and the export measure the same region
    /// and derive the same multipliers — bit for bit, not to a tolerance.
    @Test("Preview and export resolve and measure a custom patch identically")
    func previewAndExportAgreeOnTheWhiteBalance() throws {
        let decoder = Self.decoder(width: 8, height: 6)
        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.25, originY: 0.25, width: 0.5, height: 0.5
            )
        )
        let adjustments = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 0.75),
            whiteBalance: patch
        )

        let preview = try WorkspacePreviewPipeline().render(
            decoding: Self.url, using: decoder, adjustments: adjustments
        )
        #expect(!preview.resolution.isReduced)

        let export = try FullResolutionExportPipeline().render(
            ExportRequest(rawURL: Self.url, adjustments: adjustments), using: decoder
        )

        #expect(export.neutralPatch == preview.neutralPatch)
        #expect(export.whiteBalanceGains == preview.whiteBalanceGains)
        #expect(export.estimate.targetMean == preview.estimate.targetMean)
        #expect(export.estimate.statistics == preview.estimate.statistics)
        #expect(export.estimate.scalePolicy == preview.estimate.scalePolicy)
    }

    /// The whole point of persisting intent rather than gains: the record
    /// names a region, and the gains are re-derived. A record carrying
    /// multipliers would have frozen an estimator into every sidecar.
    @Test("The export request carries a patch, not gains")
    func theExportRequestCarriesIntentNotGains() throws {
        let patch = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.1, originY: 0.1, width: 0.2, height: 0.2
            )
        )
        let request = ExportRequest(
            rawURL: Self.url, adjustments: ImageAdjustments(whiteBalance: patch)
        )
        // `captureProfile` joined the snapshot in the capture-profile
        // milestone, and it is a resolved description rather than an
        // identifier to look up while the export runs. Still no preview, no
        // `Source`, no `CGImage` and no `PreviewResolutionPolicy`. See
        // `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 9.
        let labels = Mirror(reflecting: request).children.compactMap(\.label)
        #expect(labels == ["rawURL", "captureProfile", "adjustments"])

        let whiteBalanceLabels = Mirror(reflecting: request.adjustments.whiteBalance)
            .children.compactMap(\.label)
        #expect(!whiteBalanceLabels.contains("gains"))
        #expect(request.diagnosticDescription.contains("white balance neutralPatch"))
    }

    // MARK: - The preview policy cannot reach the export

    @Test("The export is identical whatever preview resolution the workspace used")
    func thePreviewPolicyDoesNotReachTheExport() throws {
        let decoder = Self.decoder(width: 16, height: 12)
        let adjustments = ImageAdjustments(
            orientation: .quarterTurnLeft,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: -0.5)
        )
        let pipeline = FullResolutionExportPipeline()

        func exportSamples(previewPolicy: PreviewResolutionPolicy) throws -> [UInt16] {
            // A workspace really does prepare a preview at this policy…
            let source = try WorkspacePreviewPipeline().prepare(
                decoding: Self.url, using: decoder, policy: previewPolicy
            )
            _ = try WorkspacePreviewPipeline().render(source, adjustments: adjustments)
            // …and the export, started from the same document, ignores it.
            return try pipeline.encode(
                try pipeline.render(
                    ExportRequest(rawURL: Self.url, adjustments: adjustments),
                    using: decoder
                )
            ).samples
        }

        let atLarge = try exportSamples(
            previewPolicy: PreviewResolutionPolicy(maximumLongestEdge: 2048)
        )
        let atSmall = try exportSamples(
            previewPolicy: PreviewResolutionPolicy(maximumLongestEdge: 4)
        )
        #expect(atLarge == atSmall)
        #expect(atLarge.count == 16 * 12 * 3)
    }

    @Test("The export request carries no preview and no policy, structurally")
    func theExportRequestCarriesNothingFromThePreview() throws {
        // Constructible from a URL and an adjustment state, and from nothing
        // else — `ExportRequest` has exactly two stored properties. There is
        // no initialiser taking a preview, a `Source`, a `CGImage` or a
        // `PreviewResolutionPolicy`, so an export cannot be handed preview
        // pixels or a preview size by mistake.
        let request = ExportRequest(rawURL: Self.url, adjustments: .none)
        #expect(request.rawURL == Self.url)
        #expect(request.adjustments == .none)
        #expect(request == ExportRequest(rawURL: Self.url, adjustments: .none))
        // And the pipeline's own entry point takes the request, a decoder and
        // a cancellation signal — this call compiles with no policy because
        // there is no parameter for one.
        _ = try FullResolutionExportPipeline().render(request, using: Self.decoder())
    }

    // MARK: - Writing a file

    @Test("The whole path writes a file and reports what it wrote")
    func theWholePathWritesAFile() throws {
        let adjustments = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 0.25)
        )
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("synthetic-export.tif")
            let result = try FullResolutionExportPipeline().export(
                ExportRequest(rawURL: Self.url, adjustments: adjustments),
                to: destination,
                using: Self.decoder(width: 8, height: 6)
            )
            #expect(result.destination == destination)
            #expect(result.sourceURL == Self.url)
            #expect(result.adjustments == adjustments)
            #expect(result.pixelWidth == 6)
            #expect(result.pixelHeight == 8)
            #expect(result.bitsPerComponent == 16)

            let read = try TIFFPixelReader(contentsOf: destination)
            #expect(read.width == 6)
            #expect(read.height == 8)
            #expect(read.bitsPerComponent == 16)
            #expect(read.declaredOrientation == 1)
        }
    }

    // MARK: - Refusals

    @Test("A RAW file that cannot be decoded fails as a preparation failure")
    func anUndecodableFileFailsAsPreparation() {
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: Self.url)),
            mosaic: .failure(.invalidDecodedImage(Self.url, reason: "synthetic"))
        )
        do {
            _ = try FullResolutionExportPipeline().render(
                ExportRequest(rawURL: Self.url, adjustments: .none), using: decoder
            )
            Issue.record("A corrupt mosaic should have failed the export.")
        } catch let error as FullResolutionExportError {
            guard case .rawPreparationFailed(let url, _) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(url == Self.url)
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("An orientation this version does not model fails as an adjustment failure")
    func anUnmodelledOrientationFailsAsAnAdjustment() {
        do {
            _ = try Self.render(.none, flip: 99)
            Issue.record("An unmodelled flip should have failed the export.")
        } catch let error as FullResolutionExportError {
            guard case .adjustmentProcessingFailed(let stage, let underlying) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(stage == .orientation)
            #expect(underlying is OrientationError)
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("A cancelled export is not a failure")
    func aCancelledExportIsNotAFailure() {
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try FullResolutionExportPipeline().render(
                ExportRequest(rawURL: Self.url, adjustments: .none),
                using: Self.decoder(),
                cancellation: probe.cancellation
            )
        }
    }
}
