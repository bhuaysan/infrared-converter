import Testing
import Foundation
@testable import InfraredConverter

/// Unit tests for the first application-owned RAW processing stage.
///
/// Everything here is synthetic: no RAW file is involved, so the arithmetic,
/// the black model and the error behaviour are pinned independently of any
/// camera. The E-PL3 fixture is exercised separately in
/// `RAWMosaicNormalizerFixtureTests`.
@Suite("RAWMosaicNormalizer")
struct RAWMosaicNormalizerTests {
    // MARK: - Helpers

    /// The reference camera's 2×2 Bayer packing, `0xB4B4B4B4`, whose plane
    /// indices are (0,0)=0, (0,1)=1, (1,0)=3, (1,1)=2 — four distinct planes,
    /// which is what makes per-plane black testable.
    private static let bayer = RAWTestData.bayerLayout()

    /// Builds a mosaic from row-major `UInt16` values. `bytesPerRow` defaults
    /// to tightly packed; pass a wider one to add per-row padding, which the
    /// source buffer may legitimately carry.
    private static func mosaic(
        width: Int,
        height: Int,
        values: [UInt16],
        bytesPerRow: Int? = nil,
        sourceRawBitDepth: Int? = 12,
        layout: RAWMetadata.SensorColorLayout = bayer
    ) -> RAWMosaic {
        let stride = bytesPerRow ?? width * 2
        let samplesPerRow = stride / 2
        var padded = [UInt16]()
        padded.reserveCapacity(samplesPerRow * height)
        for row in 0..<height {
            for column in 0..<width { padded.append(values[row * width + column]) }
            for _ in width..<samplesPerRow { padded.append(0xFFFF) }
        }
        return RAWMosaic(
            width: width,
            height: height,
            bytesPerRow: stride,
            samples: padded.withUnsafeBufferPointer { Data(buffer: $0) },
            sampleFormat: .uint16,
            sourceRawBitDepth: sourceRawBitDepth,
            sensorColorLayout: layout
        )
    }

    private static func levels(
        black: UInt32 = 0,
        perPlaneBlack: [UInt32] = [0, 0, 0, 0],
        blackPattern: RAWMetadata.Levels.BlackPattern? = nil,
        maximum: UInt32,
        linearMaximum: [Int32]? = nil
    ) -> RAWMetadata.Levels {
        RAWMetadata.Levels(
            black: black,
            perPlaneBlack: perPlaneBlack,
            blackPattern: blackPattern,
            maximum: maximum,
            linearMaximum: linearMaximum
        )
    }

    private static func isClose(_ lhs: Float, _ rhs: Float, tolerance: Float = 1e-6) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    // MARK: - Scalar black and white

    @Test("A global black level maps black to 0, midpoint to 0.5 and white to 1")
    func scalarBlackAndWhite() throws {
        let mosaic = Self.mosaic(width: 3, height: 1, values: [10, 60, 110])
        let result = try RAWMosaicNormalizer()
            .process(mosaic: mosaic, levels: Self.levels(black: 10, maximum: 110))

        #expect(Self.isClose(try #require(result.value(row: 0, column: 0)), 0))
        #expect(Self.isClose(try #require(result.value(row: 0, column: 1)), 0.5))
        #expect(Self.isClose(try #require(result.value(row: 0, column: 2)), 1))
    }

    @Test("Samples below the black level become negative and are not clamped")
    func negativeValuesArePreserved() throws {
        let mosaic = Self.mosaic(width: 2, height: 1, values: [5, 0])
        let result = try RAWMosaicNormalizer()
            .process(mosaic: mosaic, levels: Self.levels(black: 10, maximum: 110))

        // (5 - 10) / 100
        #expect(Self.isClose(try #require(result.value(row: 0, column: 0)), -0.05))
        // (0 - 10) / 100
        #expect(Self.isClose(try #require(result.value(row: 0, column: 1)), -0.1))
        #expect(result.processing.clamped == false)
    }

    @Test("Samples above the white level exceed 1 and are not clamped")
    func aboveWhiteValuesArePreserved() throws {
        let mosaic = Self.mosaic(width: 2, height: 1, values: [120, 210])
        let result = try RAWMosaicNormalizer()
            .process(mosaic: mosaic, levels: Self.levels(black: 10, maximum: 110))

        // (120 - 10) / 100
        #expect(Self.isClose(try #require(result.value(row: 0, column: 0)), 1.1))
        // (210 - 10) / 100
        #expect(Self.isClose(try #require(result.value(row: 0, column: 1)), 2.0))
        #expect(result.processing.clamped == false)
    }

    // MARK: - The black model

    @Test("Identical samples normalise differently when their colour planes have different black levels")
    func perPlaneBlackIsApplied() throws {
        // Every sample is 100. Planes: (0,0)=0, (0,1)=1, (1,0)=3, (1,1)=2.
        let mosaic = Self.mosaic(width: 2, height: 2, values: [100, 100, 100, 100])
        let levels = Self.levels(perPlaneBlack: [0, 20, 40, 60], maximum: 200)
        let result = try RAWMosaicNormalizer().process(mosaic: mosaic, levels: levels)

        // Sanity: the four positions really are four distinct planes.
        #expect(result.colorPlaneIndex(row: 0, column: 0) == 0)
        #expect(result.colorPlaneIndex(row: 0, column: 1) == 1)
        #expect(result.colorPlaneIndex(row: 1, column: 0) == 3)
        #expect(result.colorPlaneIndex(row: 1, column: 1) == 2)

        // plane 0: (100 - 0) / 200
        #expect(Self.isClose(try #require(result.value(row: 0, column: 0)), 0.5))
        // plane 1: (100 - 20) / 180
        #expect(Self.isClose(try #require(result.value(row: 0, column: 1)), 80.0 / 180.0))
        // plane 3: (100 - 60) / 140
        #expect(Self.isClose(try #require(result.value(row: 1, column: 0)), 40.0 / 140.0))
        // plane 2: (100 - 40) / 160
        #expect(Self.isClose(try #require(result.value(row: 1, column: 1)), 60.0 / 160.0))
    }

    @Test("A repeating black pattern is applied with row and column wrapping")
    func repeatingBlackPatternIsApplied() throws {
        // A 2x2 pattern over a 4x2 mosaic, so columns 2 and 3 must wrap back
        // onto pattern columns 0 and 1.
        let pattern = RAWMetadata.Levels.BlackPattern(rows: 2, columns: 2, values: [0, 10, 20, 30])
        let mosaic = Self.mosaic(
            width: 4, height: 2,
            values: [100, 100, 100, 100,
                     100, 100, 100, 100]
        )
        let levels = Self.levels(blackPattern: pattern, maximum: 200)
        let result = try RAWMosaicNormalizer().process(mosaic: mosaic, levels: levels)

        // Row 0: pattern black 0, 10, then wrapped 0, 10.
        #expect(Self.isClose(try #require(result.value(row: 0, column: 0)), 100.0 / 200.0))
        #expect(Self.isClose(try #require(result.value(row: 0, column: 1)), 90.0 / 190.0))
        #expect(Self.isClose(try #require(result.value(row: 0, column: 2)), 100.0 / 200.0))
        #expect(Self.isClose(try #require(result.value(row: 0, column: 3)), 90.0 / 190.0))
        // Row 1: pattern black 20, 30, then wrapped 20, 30.
        #expect(Self.isClose(try #require(result.value(row: 1, column: 0)), 80.0 / 180.0))
        #expect(Self.isClose(try #require(result.value(row: 1, column: 1)), 70.0 / 170.0))
        #expect(Self.isClose(try #require(result.value(row: 1, column: 2)), 80.0 / 180.0))
        #expect(Self.isClose(try #require(result.value(row: 1, column: 3)), 70.0 / 170.0))
    }

    @Test("Global, per-plane and pattern black all combine, exactly as Levels.blackLevel sums them")
    func blackTermsCombine() throws {
        let pattern = RAWMetadata.Levels.BlackPattern(rows: 1, columns: 2, values: [0, 5])
        let mosaic = Self.mosaic(width: 2, height: 1, values: [100, 100])
        let levels = Self.levels(black: 8, perPlaneBlack: [1, 2, 3, 4], blackPattern: pattern, maximum: 200)
        let result = try RAWMosaicNormalizer().process(mosaic: mosaic, levels: levels)

        // (0,0): plane 0 → 8 + 1 + 0 = 9. (0,1): plane 1 → 8 + 2 + 5 = 15.
        #expect(levels.blackLevel(row: 0, column: 0, colorPlane: 0) == 9)
        #expect(levels.blackLevel(row: 0, column: 1, colorPlane: 1) == 15)
        #expect(Self.isClose(try #require(result.value(row: 0, column: 0)), 91.0 / 191.0))
        #expect(Self.isClose(try #require(result.value(row: 0, column: 1)), 85.0 / 185.0))
    }

    @Test("Equivalent black decompositions produce bit-identical output")
    func equivalentBlackDecompositionsAgree() throws {
        let mosaic = Self.mosaic(
            width: 4, height: 4,
            values: (0..<16).map { UInt16(50 + $0 * 37) }
        )
        // The same effective black of 64, split three different ways —
        // including the pre-unpack and post-unpack splits LibRaw itself
        // produces for the E-PL3.
        let preUnpack = Self.levels(black: 0, perPlaneBlack: [64, 64, 64, 64], maximum: 4095)
        let postUnpack = Self.levels(black: 64, perPlaneBlack: [0, 0, 0, 0], maximum: 4095)
        let split = Self.levels(black: 24, perPlaneBlack: [40, 40, 40, 40], maximum: 4095)

        let normalizer = RAWMosaicNormalizer()
        let a = try normalizer.process(mosaic: mosaic, levels: preUnpack)
        let b = try normalizer.process(mosaic: mosaic, levels: postUnpack)
        let c = try normalizer.process(mosaic: mosaic, levels: split)

        #expect(a.values == b.values)
        #expect(a.values == c.values)
        // Not vacuous: the values must actually be the normalisation, not all zero.
        #expect(a.values.contains { $0 != 0 })
    }

    // MARK: - The white level

    @Test("linearMaximum is metadata only: a sample at maximum still maps to exactly 1")
    func linearMaximumDoesNotAffectNormalization() throws {
        let mosaic = Self.mosaic(width: 2, height: 1, values: [4095, 3680])
        let withLinear = Self.levels(
            black: 64, maximum: 4095, linearMaximum: [3680, 3680, 3680, 3680]
        )
        let withoutLinear = Self.levels(black: 64, maximum: 4095)

        let normalizer = RAWMosaicNormalizer()
        let a = try normalizer.process(mosaic: mosaic, levels: withLinear)
        let b = try normalizer.process(mosaic: mosaic, levels: withoutLinear)

        // The sample at `maximum` is exactly 1 — not above it, which is what
        // normalising against 3680 would have produced.
        #expect(Self.isClose(try #require(a.value(row: 0, column: 0)), 1))
        // The sample at `linearMaximum` is well below 1, i.e. nothing clipped
        // or rescaled there.
        #expect(Self.isClose(try #require(a.value(row: 0, column: 1)), (3680.0 - 64.0) / 4031.0))
        #expect(a.values == b.values)
        #expect(a.processing.whiteLevel == 4095)
    }

    @Test("A misleading source bit depth does not affect normalisation")
    func sourceBitDepthIsNotTheWhiteLevel() throws {
        // 12 bits would imply 4095; the metadata says 3800, and 3800 wins.
        let mosaic = Self.mosaic(width: 1, height: 1, values: [3800], sourceRawBitDepth: 12)
        let result = try RAWMosaicNormalizer()
            .process(mosaic: mosaic, levels: Self.levels(black: 0, maximum: 3800))

        #expect(Self.isClose(try #require(result.value(row: 0, column: 0)), 1))
        #expect(result.processing.whiteLevel == 3800)
    }

    @Test("An unreported source bit depth changes nothing")
    func unknownSourceBitDepthChangesNothing() throws {
        let values: [UInt16] = [10, 60, 110, 160]
        let known = Self.mosaic(width: 4, height: 1, values: values, sourceRawBitDepth: 12)
        let unknown = Self.mosaic(width: 4, height: 1, values: values, sourceRawBitDepth: nil)
        let levels = Self.levels(black: 10, maximum: 110)

        let normalizer = RAWMosaicNormalizer()
        let a = try normalizer.process(mosaic: known, levels: levels)
        let b = try normalizer.process(mosaic: unknown, levels: levels)
        #expect(a.values == b.values)
    }

    // MARK: - Invalid metadata

    @Test("A white level equal to the effective black level is a typed error")
    func whiteEqualToBlackFails() {
        let mosaic = Self.mosaic(width: 1, height: 1, values: [100])
        #expect(throws: RAWProcessingError.invalidNormalizationRange(
            whiteLevel: 64, blackLevel: 64, row: 0, column: 0, colorPlane: 0
        )) {
            try RAWMosaicNormalizer().process(mosaic: mosaic, levels: Self.levels(black: 64, maximum: 64))
        }
    }

    @Test("A white level below the effective black level is a typed error")
    func whiteBelowBlackFails() {
        let mosaic = Self.mosaic(width: 1, height: 1, values: [100])
        #expect(throws: RAWProcessingError.invalidNormalizationRange(
            whiteLevel: 50, blackLevel: 64, row: 0, column: 0, colorPlane: 0
        )) {
            try RAWMosaicNormalizer().process(mosaic: mosaic, levels: Self.levels(black: 64, maximum: 50))
        }
    }

    @Test("The failing coordinate and plane are reported, not just the fact of failure")
    func invalidRangeReportsTheOffendingSample() throws {
        // Only plane 1 (position (0,1)) has a black level at or above the
        // white level, so the error must name that exact sample.
        let mosaic = Self.mosaic(width: 2, height: 1, values: [100, 100])
        let levels = Self.levels(perPlaneBlack: [0, 200, 0, 0], maximum: 150)

        var caught: RAWProcessingError?
        do {
            _ = try RAWMosaicNormalizer().process(mosaic: mosaic, levels: levels)
        } catch let error as RAWProcessingError {
            caught = error
        }
        #expect(caught == .invalidNormalizationRange(
            whiteLevel: 150, blackLevel: 200, row: 0, column: 1, colorPlane: 1
        ))
    }

    @Test("A layout with no per-pixel colour plane is a typed error, not a silent global black")
    func missingColorPlaneFails() {
        let noMosaic = RAWMetadata.SensorColorLayout(
            pattern: .none, filters: 0, colorDescription: "RGB", colorCount: 3
        )
        let mosaic = Self.mosaic(width: 1, height: 1, values: [100], layout: noMosaic)
        #expect(throws: RAWProcessingError.missingColorPlane(row: 0, column: 0)) {
            try RAWMosaicNormalizer().process(mosaic: mosaic, levels: Self.levels(black: 10, maximum: 110))
        }
    }

    @Test("An inconsistent input geometry is rejected before any arithmetic")
    func inconsistentGeometryFails() {
        let mosaic = RAWMosaic(
            width: 4, height: 3,
            bytesPerRow: 8,
            samples: Data(repeating: 0, count: 4), // needs 24 bytes
            sampleFormat: .uint16,
            sourceRawBitDepth: 12,
            sensorColorLayout: Self.bayer
        )
        #expect(throws: RAWProcessingError.self) {
            try RAWMosaicNormalizer().process(mosaic: mosaic, levels: Self.levels(black: 10, maximum: 110))
        }
    }

    @Test("Extreme but well-formed levels still produce only finite values")
    func extremeLevelsStayFinite() throws {
        let mosaic = Self.mosaic(width: 2, height: 1, values: [0, 65535])
        // A white level at the top of UInt32 with a black level just below
        // it: the largest denominator and the largest numerators this stage
        // can be handed.
        let wide = Self.levels(black: 0, maximum: UInt32.max)
        let narrow = Self.levels(black: UInt32.max - 1, maximum: UInt32.max)

        for levels in [wide, narrow] {
            let result = try RAWMosaicNormalizer().process(mosaic: mosaic, levels: levels)
            #expect(result.values.allSatisfy { $0.isFinite })
        }
    }

    // MARK: - Geometry, layout and provenance

    @Test("Dimensions, CFA mapping and per-coordinate colour planes survive unchanged")
    func geometryAndLayoutArePreserved() throws {
        let source = Self.mosaic(
            width: 6, height: 4,
            values: (0..<24).map { UInt16(100 + $0) }
        )
        let result = try RAWMosaicNormalizer()
            .process(mosaic: source, levels: Self.levels(black: 10, maximum: 200))

        #expect(result.width == source.width)
        #expect(result.height == source.height)
        #expect(result.sensorColorLayout == source.sensorColorLayout)
        #expect(result.isGeometryConsistent)
        #expect(result.values.count == 24)
        #expect(result.valuesPerRow == 6)

        for row in 0..<4 {
            for column in 0..<6 {
                #expect(result.colorPlaneIndex(row: row, column: column)
                    == source.colorPlaneIndex(row: row, column: column))
            }
        }
    }

    @Test("A padded source stride is honoured on read and dropped from the output")
    func paddedSourceStrideIsNotCarriedOver() throws {
        // 3 samples per row of data, 10 bytes of stride: two padding samples
        // per row that must never appear in the result.
        let source = Self.mosaic(
            width: 3, height: 2,
            values: [10, 60, 110, 110, 60, 10],
            bytesPerRow: 10
        )
        let result = try RAWMosaicNormalizer()
            .process(mosaic: source, levels: Self.levels(black: 10, maximum: 110))

        #expect(result.values.count == 6)
        #expect(result.valuesPerRow == 3)
        #expect(Self.isClose(try #require(result.value(row: 1, column: 0)), 1))
        #expect(Self.isClose(try #require(result.value(row: 1, column: 2)), 0))
        #expect(result.values.allSatisfy { $0 <= 1.0 })
    }

    @Test("The processing record states exactly what happened, and what did not")
    func processingProvenanceIsRecorded() throws {
        let mosaic = Self.mosaic(width: 2, height: 1, values: [10, 110])
        let result = try RAWMosaicNormalizer()
            .process(mosaic: mosaic, levels: Self.levels(black: 10, maximum: 110))

        #expect(result.processing.blackLevelSubtracted == true)
        #expect(result.processing.normalized == true)
        #expect(result.processing.whiteLevelPolicy == .metadataMaximum)
        #expect(result.processing.whiteLevel == 110)
        #expect(result.processing.clamped == false)
        #expect(result.processing.whiteBalanceApplied == false)
        #expect(result.processing.demosaiced == false)
        #expect(result.processing.cameraColorMatrixApplied == false)
        #expect(result.processing.gammaApplied == false)
        #expect(result.processing.orientationApplied == false)
    }

    @Test("Processing a decoder result keeps the original UInt16 mosaic reachable")
    func decoderResultKeepsTheSourceMosaic() throws {
        let mosaic = Self.mosaic(width: 2, height: 1, values: [10, 110])
        var metadata = RAWTestData.metadata()
        metadata.levels = Self.levels(black: 10, maximum: 110)
        let decoded = DecodedRAWMosaic(
            url: URL(fileURLWithPath: "/tmp/synthetic.orf"),
            metadata: metadata,
            mosaic: mosaic,
            processing: RAWMosaicProcessing(
                decoderIdentifier: "Stub",
                sourceStorage: .singleChannel,
                sourceRowPitch: 4,
                destinationRowStride: 4
            )
        )

        let processed = try RAWMosaicNormalizer().process(decoded)

        #expect(processed.source.mosaic == mosaic)
        #expect(processed.source.mosaic.sample(row: 0, column: 1) == 110)
        #expect(processed.metadata.levels.maximum == 110)
        #expect(processed.processing.whiteLevel == 110)
        #expect(Self.isClose(try #require(processed.mosaic.value(row: 0, column: 1)), 1))
    }
}
