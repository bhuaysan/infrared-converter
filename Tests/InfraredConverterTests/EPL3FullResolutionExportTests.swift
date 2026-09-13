import Testing
import CoreGraphics
import CryptoKit
import ImageIO
import Foundation
@testable import InfraredConverter

/// The milestone's acceptance test, on a real photograph.
///
/// > A 2048-pixel reduced preview and a 4056-pixel full-resolution export must
/// > represent the same RAW file and the same `ImageAdjustments`, but the
/// > export must be derived independently from the RAW, never from preview
/// > pixels.
///
/// Every test here works on an **isolated copy** of the fixture in a temporary
/// directory. The copy has no sidecar beside it, so whatever a developer has
/// saved next to their own `RAW/OLYMPUS.ORF` cannot change what these tests
/// see; and nothing is ever written into `RAW/`.
@Suite(
    "E-PL3 full-resolution export",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)"),
    .serialized
)
struct EPL3FullResolutionExportTests {

    static let fullWidth = 4056
    static let fullHeight = 3040
    static let previewWidth = 2048
    static let previewHeight = 1535

    static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs `body` against an isolated temporary copy of the fixture.
    ///
    /// The copy is what makes these tests independent of the developer's own
    /// working state: an `.iradjustments.json` beside the original is simply
    /// not there beside the copy, and the directory contains exactly one file
    /// until a test writes into it. See `RAWFixtures.withIsolatedCopy`.
    static func withIsolatedFixture<T>(_ body: (URL) throws -> T) throws -> T {
        try RAWFixtures.withIsolatedCopy(body)
    }

    // MARK: - Dimensions

    @Test("The preview is 2048 wide and the export is 4056, from the same file")
    func thePreviewIsReducedAndTheExportIsNot() throws {
        try Self.withIsolatedFixture { url in
            let decoder = LibRawDecoder()
            let adjustments = ImageAdjustments.none

            // What the workspace holds.
            let source = try WorkspacePreviewPipeline()
                .prepare(decoding: url, using: decoder)
            let preview = try WorkspacePreviewPipeline()
                .render(source, adjustments: adjustments)
            #expect(preview.pixelWidth == Self.previewWidth)
            #expect(preview.pixelHeight == Self.previewHeight)
            #expect(preview.resolution.isReduced)
            #expect(preview.fullResolutionSourcePixelWidth == Self.fullWidth)

            // What the export produces, from the file, at the sensor's own
            // resolution — nearly four times as many pixels.
            let rendered = try FullResolutionExportPipeline().render(
                ExportRequest(rawURL: url, adjustments: adjustments), using: decoder
            )
            #expect(rendered.pixelWidth == Self.fullWidth)
            #expect(rendered.pixelHeight == Self.fullHeight)
            #expect(!rendered.image.processing.reducedForPreview)
            #expect(rendered.image.processing.previewResolution == nil)
            #expect(rendered.image.values.count == Self.fullWidth * Self.fullHeight * 3)
            // Real data stayed finite through every stage.
            #expect(rendered.image.values.allSatisfy { $0.isFinite })
        }
    }

    @Test("A quarter turn exchanges the exported dimensions")
    func aQuarterTurnExchangesTheExportedDimensions() throws {
        try Self.withIsolatedFixture { url in
            let rendered = try FullResolutionExportPipeline().render(
                ExportRequest(
                    rawURL: url,
                    adjustments: ImageAdjustments(orientation: .quarterTurnRight)
                ),
                using: LibRawDecoder()
            )
            #expect(rendered.pixelWidth == Self.fullHeight)
            #expect(rendered.pixelHeight == Self.fullWidth)
            #expect(rendered.orientation == .rotated90Clockwise)
        }
    }

    // MARK: - The written file

    @Test("A written export is a 16-bit sRGB TIFF of the full frame")
    func aWrittenExportIsAFullFrame16BitTIFF() throws {
        try Self.withIsolatedFixture { url in
            let before = try Self.digest(of: url)
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent(ExportDestinationPolicy.suggestedFilename(for: url))
            #expect(destination.lastPathComponent == "OLYMPUS.tif")

            let result = try FullResolutionExportPipeline().export(
                ExportRequest(rawURL: url, adjustments: .none),
                to: destination,
                using: LibRawDecoder()
            )

            #expect(result.pixelWidth == Self.fullWidth)
            #expect(result.pixelHeight == Self.fullHeight)
            #expect(result.bitsPerComponent == 16)
            #expect(result.channelCount == 3)
            #expect(result.sourceURL == url)
            #expect((result.fileSizeBytes ?? 0) > Self.fullWidth * Self.fullHeight)

            let read = try TIFFPixelReader(contentsOf: destination)
            #expect(read.width == Self.fullWidth)
            #expect(read.height == Self.fullHeight)
            #expect(read.bitsPerComponent == 16)
            #expect(read.bitsPerPixel == 48)
            #expect(read.alphaInfo == .none)
            #expect(read.colorSpaceModel == .rgb)
            #expect(read.colorSpaceName == CGColorSpace.sRGB as String)
            #expect(read.profileName?.contains("sRGB") == true)
            // Already oriented, so the file must not ask a reader to rotate.
            #expect(read.declaredOrientation == 1)
            #expect(read.tiffProperties[kCGImagePropertyTIFFModel] as? String == "E-PL3")

            // The RAW file is untouched, and nothing was written beside it
            // but the file the caller asked for.
            #expect(try Self.digest(of: url) == before)
            let contents = try FileManager.default.contentsOfDirectory(
                at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
            )
            #expect(
                Set(contents.map(\.lastPathComponent)) == ["OLYMPUS.ORF", "OLYMPUS.tif"]
            )
            // In particular, no sidecar: exporting is not editing.
            #expect(!contents.contains {
                $0.lastPathComponent.hasSuffix(JSONSidecarImageAdjustmentStore.sidecarSuffix)
            })
        }
    }

    @Test("An adjusted export turns the frame and remixes it, at full resolution")
    func anAdjustedExportTurnsAndRemixesTheFullFrame() throws {
        try Self.withIsolatedFixture { url in
            let decoder = LibRawDecoder()
            let adjustments = ImageAdjustments(
                orientation: .quarterTurnRight,
                channelMix: .redBlueSwap,
                exposure: try UserExposureAdjustment(ev: 1)
            )
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("adjusted.tif")

            let result = try FullResolutionExportPipeline().export(
                ExportRequest(rawURL: url, adjustments: adjustments),
                to: destination,
                using: decoder
            )
            #expect(result.pixelWidth == Self.fullHeight)
            #expect(result.pixelHeight == Self.fullWidth)
            #expect(result.adjustments == adjustments)

            let read = try TIFFPixelReader(contentsOf: destination)
            #expect(read.width == Self.fullHeight)
            #expect(read.height == Self.fullWidth)
            #expect(read.declaredOrientation == 1)

            // A stop of lift really did reach the file: a brighter rendering
            // clips at least as much as the neutral one, and this frame has
            // enough headroom for the difference to be real.
            let neutral = try FullResolutionExportPipeline().encode(
                try FullResolutionExportPipeline().render(
                    ExportRequest(rawURL: url, adjustments: .none), using: decoder
                )
            )
            #expect(result.clippedHighSampleCount >= neutral.processing.clippedHighSampleCount)
        }
    }

    // MARK: - Preview and export are the same rendering

    @Test("Preview and export agree about the photograph, at two resolutions")
    func previewAndExportAgreeAboutThePhotograph() throws {
        try Self.withIsolatedFixture { url in
            let decoder = LibRawDecoder()
            let adjustments = ImageAdjustments(
                orientation: .quarterTurnLeft,
                channelMix: .redBlueSwap,
                exposure: try UserExposureAdjustment(ev: 0.5)
            )

            let preview = try WorkspacePreviewPipeline().render(
                decoding: url, using: decoder, adjustments: adjustments
            )
            let pipeline = FullResolutionExportPipeline()
            let export = try pipeline.encode(
                try pipeline.render(
                    ExportRequest(rawURL: url, adjustments: adjustments), using: decoder
                )
            )

            // Deliberately different resolutions…
            #expect(preview.pixelWidth == Self.previewHeight)
            #expect(export.width == Self.fullHeight)

            // …and the same rendering decisions, all the way down.
            #expect(export.processing.exposureEV == preview.renderedExposureEV)
            #expect(export.processing.mix == preview.channelMix)
            #expect(export.processing.orientation == preview.effectiveOrientation)
            #expect(
                export.processing.cameraToWorkingTransform
                    == preview.processing.cameraToWorkingTransform
            )
            #expect(
                export.processing.whiteBalanceGains == preview.processing.whiteBalanceGains
            )
            #expect(export.processing.demosaicAlgorithm == preview.processing.demosaicAlgorithm)
            #expect(export.processing.workingColorSpace == preview.processing.workingColorSpace)

            // The mean level agrees: two renditions of one photograph, one
            // area-averaged to a quarter of the pixels. They cannot agree
            // sample for sample — that is what reduction means — but a
            // different exposure, a different mix or a different white balance
            // would move the mean well beyond this.
            func mean(_ samples: [Double]) -> Double {
                samples.reduce(0, +) / Double(samples.count)
            }
            let previewBytes = try #require(WorkspaceStubs.pixelBytes(preview.image))
            let previewMean = mean(previewBytes.map { Double($0) / 255 })
            let exportMean = mean(export.samples.map { Double($0) / 65535 })
            #expect(abs(previewMean - exportMean) < 0.01)
        }
    }

    // MARK: - The preview policy cannot reach the export

    @Test("Two preview policies produce byte-identical exports")
    func twoPreviewPoliciesProduceIdenticalExports() throws {
        try Self.withIsolatedFixture { url in
            let decoder = LibRawDecoder()
            let adjustments = ImageAdjustments(channelMix: .redBlueSwap)
            let pipeline = FullResolutionExportPipeline()

            func exportedSamples(previewPolicy: PreviewResolutionPolicy) throws -> [UInt16] {
                let source = try WorkspacePreviewPipeline().prepare(
                    decoding: url, using: decoder, policy: previewPolicy
                )
                #expect(max(source.preview.width, source.preview.height)
                    <= previewPolicy.maximumLongestEdge)
                return try pipeline.encode(
                    try pipeline.render(
                        ExportRequest(rawURL: url, adjustments: adjustments), using: decoder
                    )
                ).samples
            }

            let atWorkspacePolicy = try exportedSamples(previewPolicy: .workspace)
            let atTinyPolicy = try exportedSamples(
                previewPolicy: PreviewResolutionPolicy(maximumLongestEdge: 512)
            )
            #expect(atWorkspacePolicy.count == Self.fullWidth * Self.fullHeight * 3)
            #expect(atWorkspacePolicy == atTinyPolicy)
        }
    }

    // MARK: - Memory, stated rather than guessed

    @Test("The export's buffer sizes are the ones the arithmetic predicts")
    func theBufferSizesAreWhatTheArithmeticPredicts() throws {
        // Not a measurement of peak memory — nothing here claims one. It
        // states the sizes of the buffers the export path allocates, so the
        // figures in ADR 0018 are checked against the real frame rather than
        // asserted.
        let pixels = Self.fullWidth * Self.fullHeight
        #expect(pixels == 12_330_240)

        let floatRGBBytes = pixels * 3 * MemoryLayout<Float>.size
        #expect(floatRGBBytes == 147_962_880)

        let exportSampleBytes = pixels * 3 * MemoryLayout<UInt16>.size
        #expect(exportSampleBytes == 73_981_440)

        // The reduced preview the workspace retains instead, for comparison.
        let previewBytes = Self.previewWidth * Self.previewHeight * 3 * MemoryLayout<Float>.size
        #expect(previewBytes == 37_724_160)
        #expect(Double(floatRGBBytes) / Double(previewBytes) > 3.9)
    }
}
