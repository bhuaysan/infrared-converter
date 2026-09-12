import Testing
import CryptoKit
import Foundation
@testable import InfraredConverter

/// The reduction on the real photograph.
///
/// Everything else about the reduction is proved on synthetic data, where the
/// expected value can be written out. This suite exists for the claims that
/// only a real RAW file can support: that a 12.3-megapixel Olympus frame opens
/// through the whole application-owned pipeline, that what the workspace keeps
/// afterwards is a 3.1-megapixel buffer and nothing else, and that the file on
/// disk is not touched.
@Suite(
    "E-PL3 preview resolution",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct EPL3PreviewResolutionTests {

    static let sourceWidth = 4056
    static let sourceHeight = 3040
    static let previewWidth = 2048
    static let previewHeight = 1535

    static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - What an open produces

    @Test("Opening the fixture produces a reduced preview that records its origin")
    func theFixtureOpensReduced() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let before = try Self.digest(of: url)

        let source = try WorkspacePreviewPipeline()
            .prepare(decoding: url, using: LibRawDecoder())

        // Reduced, and it says from what, by which rule, and by which method.
        #expect(source.preview.width == Self.previewWidth)
        #expect(source.preview.height == Self.previewHeight)
        #expect(source.resolution.sourceWidth == Self.sourceWidth)
        #expect(source.resolution.sourceHeight == Self.sourceHeight)
        #expect(source.resolution.isReduced)
        #expect(source.resolution.method == .areaAverage)
        #expect(source.resolution.policy == .workspace)
        #expect(max(source.preview.width, source.preview.height) == 2048)

        // The buffer is exactly the declared geometry's worth, so the saving
        // is the one the arithmetic predicts and not an accounting of it.
        let channels = SceneLinearPreviewImage.channelCount
        #expect(source.preview.values.count
            == Self.previewWidth * Self.previewHeight * channels)
        #expect(source.preview.values.count == 9_431_040)

        let fullSamples = Self.sourceWidth * Self.sourceHeight * channels
        let factor = Double(fullSamples) / Double(source.preview.values.count)
        #expect(abs(factor - 3.9222) < 0.001)

        // Processing stayed finite all the way through a real frame — not a
        // property any synthetic fixture can establish for this data.
        #expect(source.preview.values.allSatisfy { $0.isFinite })

        // The provenance chain is intact through the reduction.
        #expect(source.preview.processing.reducedForPreview)
        #expect(source.preview.processing.sceneLinear)
        #expect(!source.preview.processing.clamped)
        #expect(!source.preview.processing.gammaApplied)
        #expect(!source.preview.processing.displayEncodingApplied)
        #expect(source.preview.processing.workingColorSpace == .extendedLinearSRGB)
        #expect(source.preview.processing.demosaiced)
        #expect(source.preview.processing.whiteBalanceApplied)
        #expect(source.preview.processing.mix == .identity)

        // The metadata came through, and the white-balance region is still in
        // full-resolution sensor coordinates.
        #expect(source.metadata.geometry.orientation == .upright)
        #expect(source.url == url)
        #expect(source.neutralPatch.width == 190)
        #expect(source.neutralPatch.height == 190)

        // And the RAW file is exactly as it was.
        #expect(try Self.digest(of: url) == before)
    }

    // MARK: - Orientation on the real frame

    @Test("A quarter turn of the fixture exchanges the preview dimensions only")
    func aQuarterTurnWorksOnTheFixture() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let pipeline = WorkspacePreviewPipeline()
        let source = try pipeline.prepare(decoding: url, using: LibRawDecoder())

        let upright = try pipeline.render(source, adjustments: .none)
        #expect(upright.pixelWidth == Self.previewWidth)
        #expect(upright.pixelHeight == Self.previewHeight)

        let turned = try pipeline.render(
            source, adjustments: ImageAdjustments(orientation: .quarterTurnLeft)
        )
        #expect(turned.pixelWidth == Self.previewHeight)
        #expect(turned.pixelHeight == Self.previewWidth)
        #expect(turned.effectiveOrientation == .rotated270Clockwise)

        // The reduction record is identical either way: a rotation is not a
        // reduction, and it never re-decides the size.
        #expect(turned.resolution == upright.resolution)
        #expect(turned.resolution.sourceWidth == Self.sourceWidth)

        // The retained buffer is untouched by either render.
        #expect(source.preview.width == Self.previewWidth)
        #expect(source.preview.height == Self.previewHeight)
    }

    // MARK: - A smaller policy

    /// The production default happens to reduce this fixture, but the test
    /// should not depend on that coincidence: a smaller policy proves the
    /// limit is genuinely the thing in charge.
    @Test("A smaller injected policy reduces the fixture further")
    func aSmallerPolicyReducesFurther() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let source = try WorkspacePreviewPipeline().prepare(
            decoding: url,
            using: LibRawDecoder(),
            policy: PreviewResolutionPolicy(maximumLongestEdge: 512)
        )

        #expect(source.preview.width == 512)
        #expect(source.preview.height == 384)   // round(3040 × 512/4056)
        #expect(source.resolution.sourceWidth == Self.sourceWidth)
        #expect(source.preview.values.allSatisfy { $0.isFinite })
    }

    // MARK: - The file, and its sidecar

    /// Opening a photograph reads it and writes nothing. The sidecar is
    /// written only after an adjustment has rendered, and this suite makes
    /// none — so the fixture directory must look exactly as it did.
    @Test("Opening the fixture writes no sidecar and changes no bytes")
    func openingWritesNothing() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let sidecar = JSONSidecarImageAdjustmentStore.sidecarURL(for: url)
        let before = try Self.digest(of: url)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)

        _ = try WorkspacePreviewPipeline()
            .render(decoding: url, using: LibRawDecoder(), adjustments: .none)

        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(try Self.digest(of: url) == before)

        let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributesAfter[.size] as? Int == attributesBefore[.size] as? Int)
        #expect(
            attributesAfter[.modificationDate] as? Date
                == attributesBefore[.modificationDate] as? Date
        )
    }
}
