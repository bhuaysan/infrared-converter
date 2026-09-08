import Testing
import Foundation
@testable import InfraredConverter

@Suite("RAW metadata model")
struct RAWMetadataTests {
    @Test("An RGGB layout maps sensor coordinates to colour planes")
    func rggbColorPlanes() {
        // 0xB4B4B4B4 is the packed code for RGGB, as used by dcraw/LibRaw.
        let layout = RAWTestData.bayerLayout(filters: 0xB4B4B4B4)

        #expect(layout.colorPlaneLetter(row: 0, column: 0) == "R")
        #expect(layout.colorPlaneLetter(row: 0, column: 1) == "G")
        #expect(layout.colorPlaneLetter(row: 1, column: 0) == "G")
        #expect(layout.colorPlaneLetter(row: 1, column: 1) == "B")

        // The pattern repeats every two rows and columns.
        #expect(layout.colorPlaneIndex(row: 2, column: 2) == layout.colorPlaneIndex(row: 0, column: 0))
        #expect(layout.colorPlaneIndex(row: 3, column: 2) == layout.colorPlaneIndex(row: 1, column: 0))

        // The two greens live in different planes of a four-letter description,
        // which is what a CFA-aware white balance has to respect.
        #expect(layout.colorPlaneIndex(row: 0, column: 1) == 1)
        #expect(layout.colorPlaneIndex(row: 1, column: 0) == 3)
    }

    @Test("A BGGR layout is not assumed to be RGGB")
    func bggrColorPlanes() {
        let layout = RAWTestData.bayerLayout(filters: 0x16161616)

        #expect(layout.colorPlaneLetter(row: 0, column: 0) == "B")
        #expect(layout.colorPlaneLetter(row: 1, column: 1) == "R")
    }

    @Test("An X-Trans layout uses its 6×6 pattern")
    func xTransColorPlanes() {
        let pattern = [
            [1, 1, 0, 1, 1, 2],
            [1, 1, 2, 1, 1, 0],
            [2, 0, 1, 0, 2, 1],
            [1, 1, 2, 1, 1, 0],
            [1, 1, 0, 1, 1, 2],
            [0, 2, 1, 2, 0, 1]
        ]
        let layout = RAWMetadata.SensorColorLayout(
            pattern: .xTrans,
            filters: 9,
            colorDescription: "RGBG",
            colorCount: 3,
            xTransPattern: pattern
        )

        #expect(layout.colorPlaneIndex(row: 0, column: 2) == 0)
        #expect(layout.colorPlaneIndex(row: 2, column: 0) == 2)
        #expect(layout.colorPlaneIndex(row: 0, column: 5) == 2)
        // Wraps at the 6×6 cell boundary rather than falling back to Bayer maths.
        #expect(layout.colorPlaneIndex(row: 6, column: 6) == pattern[0][0])
    }

    @Test("Layouts without a mosaic report no colour plane")
    func nonMosaicLayouts() {
        for pattern in [RAWMetadata.SensorColorLayout.Pattern.foveon, .none, .unknown] {
            let layout = RAWMetadata.SensorColorLayout(
                pattern: pattern,
                filters: 0,
                colorDescription: "RGB",
                colorCount: 3
            )
            #expect(layout.colorPlaneIndex(row: 0, column: 0) == nil)
        }
    }

    @Test("Missing values stay missing")
    func missingValuesAreExplicit() {
        let exposure = RAWMetadata.Exposure()
        #expect(exposure.iso == nil)
        #expect(exposure.aperture == nil)
        #expect(exposure.captureDate == nil)

        let color = RAWMetadata.ColorMetadata()
        #expect(color.cameraMultipliers == nil)
        #expect(color.daylightMultipliers == nil)
        #expect(color.asShotWhiteBalanceApplied == false)
    }

    @Test("Display name tolerates partial identity")
    func displayName() {
        #expect(RAWMetadata.Identity(make: "Olympus", model: "E-PL3").displayName == "Olympus E-PL3")
        #expect(RAWMetadata.Identity(model: "E-PL3").displayName == "E-PL3")
        #expect(RAWMetadata.Identity().displayName == nil)
    }
}

@Suite("RAW image model")
struct RAWImageTests {
    @Test("A well-formed buffer is consistent")
    func consistentGeometry() {
        let image = RAWTestData.image(width: 4, height: 3)

        #expect(image.expectedByteCount == 4 * 3 * 3 * 2)
        #expect(image.samples.count == image.expectedByteCount)
        #expect(image.isGeometryConsistent)
    }

    @Test("A truncated buffer is rejected")
    func truncatedBuffer() {
        let good = RAWTestData.image()
        let truncated = RAWImage(
            width: good.width,
            height: good.height,
            channelCount: good.channelCount,
            bitsPerChannel: good.bitsPerChannel,
            bytesPerRow: good.bytesPerRow,
            samples: good.samples.dropLast(2),
            encoding: good.encoding,
            colorSpace: good.colorSpace
        )

        #expect(truncated.isGeometryConsistent == false)
    }

    @Test("A stride narrower than a row is rejected")
    func impossibleStride() {
        let good = RAWTestData.image()
        let bad = RAWImage(
            width: good.width,
            height: good.height,
            channelCount: good.channelCount,
            bitsPerChannel: good.bitsPerChannel,
            bytesPerRow: good.bytesPerRow - 2,
            samples: good.samples,
            encoding: good.encoding,
            colorSpace: good.colorSpace
        )

        #expect(bad.isGeometryConsistent == false)
    }

    @Test("Padded rows are allowed")
    func paddedStride() {
        let good = RAWTestData.image()
        let padded = RAWImage(
            width: good.width,
            height: good.height,
            channelCount: good.channelCount,
            bitsPerChannel: good.bitsPerChannel,
            bytesPerRow: good.bytesPerRow + 8,
            samples: good.samples + Data(count: 8 * good.height),
            encoding: good.encoding,
            colorSpace: good.colorSpace
        )

        #expect(padded.isGeometryConsistent)
    }
}

@Suite("Decoder processing description")
struct RAWDecoderProcessingTests {
    @Test("Unity white balance is recognised")
    func unityWhiteBalance() {
        #expect(RAWTestData.processing().whiteBalanceIsUnity)
    }

    @Test("Applied white balance is recognised")
    func appliedWhiteBalance() {
        var processing = RAWTestData.processing()
        processing.appliedWhiteBalanceMultipliers = [2.26, 1.0, 1.21, 0]
        #expect(processing.whiteBalanceIsUnity == false)
    }
}
