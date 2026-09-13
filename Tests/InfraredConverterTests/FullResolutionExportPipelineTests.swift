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
