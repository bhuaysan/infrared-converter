import Testing
import Foundation
@testable import InfraredConverter

/// Integration tests against a real RAW file.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly without it,
/// so the repository stays buildable and testable on CI and other machines.
@Suite("LibRawDecoder integration", .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)"))
struct LibRawDecoderFixtureTests {
    @Test("Reads metadata from a real Olympus ORF")
    func readsMetadata() throws {
        let url = try #require(RAWFixtures.olympusORF)

        let metadata = try LibRawDecoder().readMetadata(at: url)

        #expect(metadata.identity.make?.lowercased().contains("olympus") == true)
        #expect(metadata.identity.model?.isEmpty == false)

        // Geometry must be self-consistent: the active area fits inside the
        // full sensor readout, offset by the reported margins.
        #expect(metadata.geometry.rawWidth > 0)
        #expect(metadata.geometry.rawHeight > 0)
        #expect(metadata.geometry.visibleWidth > 0)
        #expect(metadata.geometry.visibleHeight > 0)
        #expect(metadata.geometry.leftMargin + metadata.geometry.visibleWidth
                <= metadata.geometry.rawWidth)
        #expect(metadata.geometry.topMargin + metadata.geometry.visibleHeight
                <= metadata.geometry.rawHeight)

        // A Bayer sensor with a describable colour layout.
        #expect(metadata.sensor.pattern == .bayer)
        #expect(metadata.sensor.colorCount == 3)
        #expect(metadata.sensor.colorDescription == "RGBG")
        #expect(metadata.sensor.filters != 0)
        let planes = (0..<2).flatMap { row in
            (0..<2).map { metadata.sensor.colorPlaneLetter(row: row, column: $0) }
        }
        #expect(planes.allSatisfy { $0 != nil })

        // Levels must be usable for our own black/white handling later.
        #expect(metadata.levels.maximum > 0)
        #expect(metadata.levels.perPlaneBlack.count == 4)

        // White-balance metadata must survive the boundary; without it we
        // cannot build an infrared white-balance stage on top.
        let cameraMultipliers = try #require(metadata.color.cameraMultipliers)
        #expect(cameraMultipliers.count == 4)
        #expect(cameraMultipliers[0] > 0)
        #expect(cameraMultipliers[1] > 0)
        #expect(cameraMultipliers[2] > 0)
        #expect(metadata.color.asShotWhiteBalanceApplied == false)

        #expect(metadata.color.daylightMultipliers?.count == 4)
    }

    @Test("Decodes pixel data from a real Olympus ORF")
    func decodesPixels() throws {
        let url = try #require(RAWFixtures.olympusORF)

        let decoded = try LibRawDecoder().decode(at: url)
        let image = decoded.image

        // Buffer shape.
        #expect(image.bitsPerChannel == 16)
        #expect(image.channelCount == 3)
        #expect(image.encoding == .linear)
        #expect(image.colorSpace == .cameraNative)
        #expect(image.isGeometryConsistent)
        #expect(image.bytesPerRow == image.width * image.channelCount * 2)
        #expect(image.samples.count == image.bytesPerRow * image.height)

        // Output geometry must match what the metadata promised.
        #expect(image.width == decoded.metadata.geometry.outputWidth)
        #expect(image.height == decoded.metadata.geometry.outputHeight)

        // The decoder must not have made colour decisions for us.
        #expect(decoded.processing.whiteBalanceIsUnity)
        #expect(decoded.processing.cameraColorMatrixApplied == false)
        #expect(decoded.processing.autoBrightnessApplied == false)
        #expect(decoded.processing.highlightReconstructionApplied == false)
        #expect(decoded.processing.demosaic == .ahd)

        // Sanity: real image content, not a constant buffer.
        let statistics = SampleStatistics(image: image)
        #expect(statistics.maximum > 0)
        #expect(statistics.maximum > statistics.minimum)
        #expect(statistics.mean > 0)
    }

    @Test("Half-size decode halves the output geometry")
    func decodesHalfSize() throws {
        let url = try #require(RAWFixtures.olympusORF)

        let decoder = LibRawDecoder()
        let full = try decoder.decode(at: url, options: .init())
        let half = try decoder.decode(at: url, options: .init(halfSize: true))

        #expect(half.image.width < full.image.width)
        #expect(half.image.height < full.image.height)
        #expect(half.image.bitsPerChannel == 16)
        #expect(half.image.isGeometryConsistent)
        #expect(half.processing.demosaic == nil)
    }

    @Test("Produces a preview image")
    func producesPreview() throws {
        let url = try #require(RAWFixtures.olympusORF)

        let decoded = try LibRawDecoder().decode(at: url, options: .init(halfSize: true))
        let preview = try #require(PreviewImageRenderer.makeCGImage(from: decoded.image))

        #expect(preview.width == decoded.image.width)
        #expect(preview.height == decoded.image.height)
    }

    /// Minimal 16-bit statistics helper, used only to assert the buffer has content.
    private struct SampleStatistics {
        let minimum: UInt16
        let maximum: UInt16
        let mean: Double

        init(image: RAWImage) {
            var minimum = UInt16.max
            var maximum = UInt16.min
            var total = 0.0
            var count = 0

            image.samples.withUnsafeBytes { buffer in
                let samples = buffer.bindMemory(to: UInt16.self)
                // Sample sparsely; a full 12 MP scan is not needed for a sanity check.
                for index in stride(from: 0, to: samples.count, by: 997) {
                    let value = samples[index]
                    minimum = Swift.min(minimum, value)
                    maximum = Swift.max(maximum, value)
                    total += Double(value)
                    count += 1
                }
            }

            self.minimum = minimum
            self.maximum = maximum
            self.mean = count > 0 ? total / Double(count) : 0
        }
    }
}
