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

@Suite("RAW black-level model")
struct RAWLevelsTests {
    @Test("No pattern: only the global and per-plane terms contribute")
    func noPattern() {
        let levels = RAWMetadata.Levels(
            black: 100,
            perPlaneBlack: [10, 20, 20, 30],
            maximum: 4095
        )

        #expect(levels.blackPattern == nil)
        #expect(levels.blackLevel(row: 0, column: 0, colorPlane: 0) == 110)
        #expect(levels.blackLevel(row: 5, column: 7, colorPlane: 3) == 130)
        // An out-of-range colour plane contributes nothing rather than trapping.
        #expect(levels.blackLevel(row: 0, column: 0, colorPlane: 9) == 100)
        #expect(levels.blackLevel(row: 0, column: 0, colorPlane: -1) == 100)
    }

    @Test("Per-plane black only, with no global offset")
    func perPlaneBlackOnly() {
        let levels = RAWMetadata.Levels(
            black: 0,
            perPlaneBlack: [64, 64, 64, 64],
            maximum: 4095
        )

        #expect(levels.blackLevel(row: 0, column: 0, colorPlane: 0) == 64)
        #expect(levels.blackLevel(row: 100, column: 200, colorPlane: 2) == 64)
    }

    @Test("A repeating pattern contributes on top of the global and per-plane terms")
    func repeatingPattern() {
        // A 2×2 pattern with distinct values at every position.
        let pattern = RAWMetadata.Levels.BlackPattern(rows: 2, columns: 2, values: [1, 2, 3, 4])
        let levels = RAWMetadata.Levels(
            black: 100,
            perPlaneBlack: [0, 0, 0, 0],
            blackPattern: pattern,
            maximum: 4095
        )

        #expect(levels.blackLevel(row: 0, column: 0, colorPlane: 0) == 101)
        #expect(levels.blackLevel(row: 0, column: 1, colorPlane: 0) == 102)
        #expect(levels.blackLevel(row: 1, column: 0, colorPlane: 0) == 103)
        #expect(levels.blackLevel(row: 1, column: 1, colorPlane: 0) == 104)
    }

    @Test("Pattern coordinates wrap, including far beyond the pattern extent and negative coordinates")
    func patternWrapping() {
        let pattern = RAWMetadata.Levels.BlackPattern(rows: 2, columns: 3, values: [1, 2, 3, 4, 5, 6])

        // Two full periods out.
        #expect(pattern.value(row: 4, column: 6) == pattern.value(row: 0, column: 0))
        #expect(pattern.value(row: 5, column: 8) == pattern.value(row: 1, column: 2))
        // Far beyond the extent still wraps to an in-range index:
        // 1001 % 2 == 1, 2003 % 3 == 2.
        #expect(pattern.value(row: 1001, column: 2003) == pattern.value(row: 1, column: 2))
        // Negative coordinates wrap safely rather than producing a negative index.
        #expect(pattern.value(row: -1, column: -1) == pattern.value(row: 1, column: 2))
        #expect(pattern.value(row: -2, column: -3) == pattern.value(row: 0, column: 0))

        let levels = RAWMetadata.Levels(black: 0, perPlaneBlack: [], blackPattern: pattern, maximum: 4095)
        #expect(levels.blackLevel(row: -1, column: -1, colorPlane: 0)
                == levels.blackLevel(row: 1, column: 2, colorPlane: 0))
    }

    @Test("A degenerate pattern reports no value rather than trapping")
    func degeneratePattern() {
        let zeroRows = RAWMetadata.Levels.BlackPattern(rows: 0, columns: 3, values: [])
        #expect(zeroRows.value(row: 0, column: 0) == nil)

        let mismatchedCount = RAWMetadata.Levels.BlackPattern(rows: 2, columns: 2, values: [1, 2, 3])
        #expect(mismatchedCount.value(row: 0, column: 0) == nil)

        let levels = RAWMetadata.Levels(
            black: 50, perPlaneBlack: [], blackPattern: mismatchedCount, maximum: 4095
        )
        // The pattern contributes nothing when it is degenerate; only the
        // global term survives.
        #expect(levels.blackLevel(row: 0, column: 0, colorPlane: 0) == 50)
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

    @Test("Impossible dimensions are rejected", arguments: [0, -1, -100])
    func impossibleDimensions(dimension: Int) {
        let good = RAWTestData.image()

        let zeroWidth = RAWImage(
            width: dimension,
            height: good.height,
            channelCount: good.channelCount,
            bitsPerChannel: good.bitsPerChannel,
            bytesPerRow: good.bytesPerRow,
            samples: good.samples,
            encoding: good.encoding,
            colorSpace: good.colorSpace
        )
        #expect(zeroWidth.isGeometryConsistent == false)

        let zeroHeight = RAWImage(
            width: good.width,
            height: dimension,
            channelCount: good.channelCount,
            bitsPerChannel: good.bitsPerChannel,
            bytesPerRow: good.bytesPerRow,
            samples: good.samples,
            encoding: good.encoding,
            colorSpace: good.colorSpace
        )
        #expect(zeroHeight.isGeometryConsistent == false)
    }

    @Test("Non-byte-aligned bit depths are rejected")
    func nonByteAlignedBitDepth() {
        let good = RAWTestData.image()
        let bad = RAWImage(
            width: good.width,
            height: good.height,
            channelCount: good.channelCount,
            bitsPerChannel: 10,
            bytesPerRow: good.bytesPerRow,
            samples: good.samples,
            encoding: good.encoding,
            colorSpace: good.colorSpace
        )
        #expect(bad.isGeometryConsistent == false)
    }

    @Test("Geometry that would overflow Int is rejected rather than wrapping")
    func overflowingGeometry() {
        // width × channels × bytesPerSample overflows Int at this scale.
        let huge = RAWImage(
            width: Int.max / 2,
            height: Int.max / 2,
            channelCount: 3,
            bitsPerChannel: 16,
            bytesPerRow: Int.max,
            samples: Data([0, 1, 2, 3]),
            encoding: .linear,
            colorSpace: .cameraNative
        )

        #expect(huge.isGeometryConsistent == false)
        #expect(huge.expectedByteCount == nil)

        // bytesPerRow × height overflows even though each factor alone is
        // representable.
        let overflowingRowTimesHeight = RAWImage(
            width: 4,
            height: Int.max,
            channelCount: 3,
            bitsPerChannel: 16,
            bytesPerRow: Int.max,
            samples: Data([0, 1, 2, 3]),
            encoding: .linear,
            colorSpace: .cameraNative
        )
        #expect(overflowingRowTimesHeight.expectedByteCount == nil)
        #expect(overflowingRowTimesHeight.isGeometryConsistent == false)
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

    @Test("Orientation handling requested but the camera's own flip is a no-op")
    func orientationRequestedNoOpFlip() {
        var processing = RAWTestData.processing()
        processing.orientationHandlingRequested = true
        processing.appliedOrientationFlip = 0

        // Requested and honoured, but no geometric transform actually happened.
        #expect(processing.orientationHandlingRequested)
        #expect(processing.orientationTransformApplied == false)
    }

    @Test("Orientation handling requested and the camera's flip is non-zero")
    func orientationRequestedRealFlip() {
        var processing = RAWTestData.processing()
        processing.orientationHandlingRequested = true
        processing.appliedOrientationFlip = 6

        #expect(processing.orientationHandlingRequested)
        #expect(processing.orientationTransformApplied)
    }

    @Test("Orientation handling not requested never reports a transform")
    func orientationNotRequested() {
        var processing = RAWTestData.processing()
        processing.orientationHandlingRequested = false
        processing.appliedOrientationFlip = 0

        #expect(processing.orientationHandlingRequested == false)
        #expect(processing.orientationTransformApplied == false)
    }

    @Test("No warning bits map to no warnings")
    func noWarnings() {
        #expect(RAWDecoderProcessing.decode(rawWarningBits: 0).isEmpty)
    }

    @Test("Mapped LibRaw warning bits translate to the matching application warning")
    func mappedWarnings() {
        // LIBRAW_WARN_BAD_CAMERA_WB
        #expect(RAWDecoderProcessing.decode(rawWarningBits: 1 << 2) == [.badCameraWhiteBalance])
        // LIBRAW_WARN_NO_JPEGLIB
        #expect(RAWDecoderProcessing.decode(rawWarningBits: 1 << 4) == [.jpegDecodingUnavailable])
        // LIBRAW_WARN_FALLBACK_TO_AHD
        #expect(RAWDecoderProcessing.decode(rawWarningBits: 1 << 15) == [.fallbackToAHDDemosaic])
        // LIBRAW_WARN_PARSEFUJI_PROCESSED
        #expect(RAWDecoderProcessing.decode(rawWarningBits: 1 << 16) == [.fujiProcessingApplied])
        // LIBRAW_WARN_VENDOR_CROP_SUGGESTED
        #expect(RAWDecoderProcessing.decode(rawWarningBits: 1 << 25) == [.vendorCropSuggested])
    }

    @Test("Multiple simultaneous warning bits all map")
    func multipleWarnings() {
        let bits: UInt32 = (1 << 2) | (1 << 15)
        let warnings = RAWDecoderProcessing.decode(rawWarningBits: bits)
        #expect(Set(warnings) == Set([.badCameraWhiteBalance, .fallbackToAHDDemosaic]))
    }

    @Test("Unmapped bits produce no application warning but are not lost")
    func unmappedBitsAreNotMapped() {
        // LIBRAW_WARN_NO_METADATA — declared but never raised by this LibRaw
        // version's compiled sources; deliberately unmapped (see decode(_:)).
        let noMetadataBit: UInt32 = 1 << 3
        #expect(RAWDecoderProcessing.decode(rawWarningBits: noMetadataBit).isEmpty)

        // A mapped bit alongside an unmapped one: only the mapped bit
        // produces an application warning, but the caller can still keep the
        // full bitfield (rawWarningBits) for logging.
        let mixed: UInt32 = (1 << 2) | noMetadataBit
        #expect(RAWDecoderProcessing.decode(rawWarningBits: mixed) == [.badCameraWhiteBalance])

        var processing = RAWTestData.processing()
        processing.rawWarningBits = mixed
        processing.warnings = RAWDecoderProcessing.decode(rawWarningBits: mixed)
        #expect(processing.warnings == [.badCameraWhiteBalance])
        #expect(processing.rawWarningBits == mixed)
    }
}
