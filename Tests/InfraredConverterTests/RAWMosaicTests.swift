import Testing
import Foundation
@testable import InfraredConverter

@Suite("RAWMosaic")
struct RAWMosaicTests {
    /// Builds a tightly packed UInt16 mosaic buffer, `value(row,column) = row * 100 + column`,
    /// so tests can assert on sample identity rather than a constant fill.
    private static func makeSamples(width: Int, height: Int) -> Data {
        var values = [UInt16]()
        values.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                values.append(UInt16(row * 100 + column))
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func mosaic(
        width: Int = 4,
        height: Int = 3,
        bytesPerRow: Int? = nil,
        layout: RAWMetadata.SensorColorLayout = RAWTestData.bayerLayout()
    ) -> RAWMosaic {
        RAWMosaic(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow ?? width * 2,
            samples: Self.makeSamples(width: width, height: height),
            sampleFormat: .uint16,
            sourceRawBitDepth: 12,
            sensorColorLayout: layout
        )
    }

    // MARK: - Valid geometry

    @Test("A tightly packed mosaic reports consistent geometry")
    func validGeometry() {
        let m = Self.mosaic(width: 4, height: 3)
        #expect(m.isGeometryConsistent)
        #expect(m.expectedByteCount == 4 * 3 * 2)
        #expect(m.bytesPerRow == 8)
    }

    @Test("A wider-than-tight stride is still consistent")
    func paddedStrideIsConsistent() {
        // 4 samples wide needs 8 bytes; declare 10 bytes of stride with padding.
        var values = [UInt16]()
        for row in 0..<3 {
            for column in 0..<4 { values.append(UInt16(row * 100 + column)) }
            values.append(0xFFFF) // one padding sample
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 10, samples: data,
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.isGeometryConsistent)
        // Row 1 must be read at its declared stride, not the tight width.
        #expect(m.sample(row: 1, column: 0) == 100)
    }

    // MARK: - Buffer-size validation / overflow rejection

    @Test("A buffer smaller than the declared geometry is inconsistent")
    func tooSmallBufferIsInconsistent() {
        let short = Data(repeating: 0, count: 4) // needs 24 bytes for 4x3x2
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 8, samples: short,
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
    }

    @Test("A stride narrower than width * bytesPerSample is inconsistent")
    func tooNarrowStrideIsInconsistent() {
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 6, samples: Self.makeSamples(width: 4, height: 3),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
    }

    @Test("Zero width or height is inconsistent")
    func zeroDimensionsAreInconsistent() {
        let zeroWidth = RAWMosaic(
            width: 0, height: 3, bytesPerRow: 0, samples: Data(),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!zeroWidth.isGeometryConsistent)

        let zeroHeight = RAWMosaic(
            width: 4, height: 0, bytesPerRow: 8, samples: Data(),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!zeroHeight.isGeometryConsistent)
    }

    @Test("Overflowing geometry is rejected rather than trapping")
    func overflowIsRejected() {
        let m = RAWMosaic(
            width: Int.max, height: 2, bytesPerRow: Int.max, samples: Data(),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.expectedByteCount == nil)
        #expect(!m.isGeometryConsistent)
    }

    // MARK: - Source RAW bit depth

    @Test("A reported source RAW bit depth of 0 is invalid, not trapped on")
    func zeroSourceRawBitDepthIsInconsistent() {
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 8, samples: Self.makeSamples(width: 4, height: 3),
            sampleFormat: .uint16, sourceRawBitDepth: 0, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
    }

    @Test("Every source RAW bit depth 1...16 is representable in .uint16 storage")
    func representableSourceRawBitDepths() {
        for depth in 1...16 {
            let m = RAWMosaic(
                width: 4, height: 3, bytesPerRow: 8, samples: Self.makeSamples(width: 4, height: 3),
                sampleFormat: .uint16, sourceRawBitDepth: depth,
                sensorColorLayout: RAWTestData.bayerLayout()
            )
            #expect(m.isGeometryConsistent, "depth \(depth) should be representable")
        }
    }

    @Test("A source RAW bit depth above the storage width is inconsistent, and never rescales samples")
    func oversizedSourceRawBitDepthIsInconsistent() {
        // A claim of more than 16 bits cannot be true of `.uint16` storage.
        // It is reported as inconsistent rather than accepted, and — the
        // point of the test — the samples are left exactly as they are; the
        // value is never used to rescale them.
        for depth in [17, 24, 32, Int.max] {
            let m = RAWMosaic(
                width: 4, height: 3, bytesPerRow: 8, samples: Self.makeSamples(width: 4, height: 3),
                sampleFormat: .uint16, sourceRawBitDepth: depth,
                sensorColorLayout: RAWTestData.bayerLayout()
            )
            #expect(!m.isGeometryConsistent, "depth \(depth) should not be accepted")
            #expect(m.sourceRawBitDepth == depth)
            #expect(m.sample(row: 1, column: 2) == 102)
        }
    }

    @Test("A negative reported source RAW bit depth is invalid")
    func negativeSourceRawBitDepthIsInconsistent() {
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 8, samples: Self.makeSamples(width: 4, height: 3),
            sampleFormat: .uint16, sourceRawBitDepth: -1, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
    }

    @Test("An unreported source RAW bit depth is valid: the samples are still usable")
    func unreportedBitsPerSampleIsConsistent() {
        // Precision the decoder did not report is nil, never a substituted
        // default — the geometry is still sound, so the mosaic is usable and
        // a later stage decides what to do about the unknown precision.
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 8, samples: Self.makeSamples(width: 4, height: 3),
            sampleFormat: .uint16, sourceRawBitDepth: nil, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.isGeometryConsistent)
        #expect(m.sourceRawBitDepth == nil)
        #expect(m.sample(row: 0, column: 0) != nil)
    }

    // MARK: - Active-coordinate semantics / sample lookup

    @Test("sample(row:column:) reads the value at active-image coordinates")
    func sampleLookupMatchesActiveCoordinates() {
        let m = Self.mosaic(width: 4, height: 3)
        #expect(m.sample(row: 0, column: 0) == 0)
        #expect(m.sample(row: 0, column: 3) == 3)
        #expect(m.sample(row: 2, column: 1) == 201)
    }

    @Test("sample(row:column:) is bounds-checked and never traps")
    func sampleLookupOutOfBounds() {
        let m = Self.mosaic(width: 4, height: 3)
        #expect(m.sample(row: -1, column: 0) == nil)
        #expect(m.sample(row: 0, column: -1) == nil)
        #expect(m.sample(row: 3, column: 0) == nil)   // height == 3, rows 0...2 valid
        #expect(m.sample(row: 0, column: 4) == nil)   // width == 4, columns 0...3 valid
    }

    @Test("Row stride is honoured, not the tight width, when reading samples")
    func sampleLookupHonoursDeclaredStride() {
        var values = [UInt16]()
        for row in 0..<2 {
            for column in 0..<2 { values.append(UInt16(row * 100 + column)) }
            values.append(0xDEAD) // padding sample per row
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let m = RAWMosaic(
            width: 2, height: 2, bytesPerRow: 6, samples: data,
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.sample(row: 0, column: 0) == 0)
        #expect(m.sample(row: 0, column: 1) == 1)
        #expect(m.sample(row: 1, column: 0) == 100) // would be 4 at tight stride; must be 100
        #expect(m.sample(row: 1, column: 1) == 101)
    }

    // MARK: - colorPlaneIndex agreement, including non-zero margins

    @Test("colorPlaneIndex agrees with the carried SensorColorLayout at active coordinates")
    func colorPlaneIndexAgreesWithLayout() {
        let layout = RAWTestData.bayerLayout(filters: 0xB4B4B4B4) // RGGB
        let m = Self.mosaic(width: 4, height: 4, layout: layout)

        for row in 0..<4 {
            for column in 0..<4 {
                #expect(m.colorPlaneIndex(row: row, column: column) == layout.colorPlaneIndex(row: row, column: column))
            }
        }
    }

    @Test("Margins are already applied by extraction: colorPlaneIndex must not apply them again")
    func marginsAreNotAppliedTwice() {
        // A geometry with non-zero margins, as a real sensor readout would
        // have (e.g. the E-PL3's optical-black border).
        let geometry = RAWMetadata.Geometry(
            rawWidth: 10, rawHeight: 10,
            visibleWidth: 4, visibleHeight: 4,
            topMargin: 1, leftMargin: 1,
            outputWidth: 4, outputHeight: 4,
            flip: 0, pixelAspect: 1
        )
        let layout = RAWTestData.bayerLayout(filters: 0xB4B4B4B4) // RGGB

        // `m`'s samples represent the *active area only* -- margins already
        // stripped by extraction, exactly like the real LibRaw shim copy.
        // Active coordinate (0,0) is the active area's top-left corner.
        let m = Self.mosaic(width: 4, height: 4, layout: layout)

        // Correct: the mosaic's own active-coordinate lookup must equal the
        // layout's lookup at the *same* (unshifted) coordinates, because the
        // layout's colorPlaneIndex(row:column:) convention is already
        // active-image-relative (see its documentation) and the margins were
        // already consumed by extraction -- they must not be added back in.
        for row in 0..<4 {
            for column in 0..<4 {
                #expect(m.colorPlaneIndex(row: row, column: column) == layout.colorPlaneIndex(row: row, column: column))
            }
        }

        // Guard against the specific regression this test exists for: if
        // code mistakenly treated the mosaic's active coordinates as
        // raw-readout coordinates and re-applied the margins (i.e. looked up
        // colorPlaneIndex(row: row + topMargin, column: column + leftMargin)
        // instead), it would silently read the wrong colour plane at (0,0).
        let correct = m.colorPlaneIndex(row: 0, column: 0)
        let wrongIfMarginsReapplied = layout.colorPlaneIndex(
            row: geometry.topMargin,
            column: geometry.leftMargin
        )
        #expect(correct != wrongIfMarginsReapplied)
    }

    @Test("colorPlaneIndex is bounds-checked against the mosaic's own extent")
    func colorPlaneIndexOutOfBounds() {
        let m = Self.mosaic(width: 4, height: 3)
        #expect(m.colorPlaneIndex(row: -1, column: 0) == nil)
        #expect(m.colorPlaneIndex(row: 0, column: 4) == nil)
    }

    // MARK: - sample() must never trap, for any publicly constructible value

    /// The public initialiser performs no validation, so `sample()` can be
    /// handed geometry whose offset arithmetic overflows even though the
    /// coordinate passes the row/column bounds check. Each case below would
    /// trap on unchecked `row * bytesPerRow + column * bytesPerSample`.
    ///
    /// These call `sample()` directly, without consulting
    /// `isGeometryConsistent` first — that is the guarantee being tested.

    @Test("Row-stride multiplication overflow returns nil instead of trapping")
    func rowStrideMultiplicationOverflow() {
        // row 1 is in bounds (height 2), but 1 * Int.max is fine while
        // 1 * bytesPerRow + column offset is not; use a row that overflows
        // the multiply itself.
        let m = RAWMosaic(
            width: 4, height: 4, bytesPerRow: Int.max, samples: Data(repeating: 0, count: 64),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.sample(row: 2, column: 0) == nil)   // 2 * Int.max overflows
        #expect(m.sample(row: 3, column: 3) == nil)
        // Row 0 does not overflow but still runs out of buffer.
        #expect(m.sample(row: 0, column: 0) == 0)
        #expect(m.sample(row: 1, column: 0) == nil)   // 1 * Int.max is in range, +2 is past the buffer
    }

    @Test("Column offset multiplication overflow returns nil instead of trapping")
    func columnOffsetMultiplicationOverflow() {
        // width is Int.max, so a column near it passes the bounds check while
        // column * 2 overflows.
        let m = RAWMosaic(
            width: Int.max, height: 1, bytesPerRow: 8, samples: Data(repeating: 0, count: 8),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.sample(row: 0, column: Int.max - 1) == nil)
        #expect(m.sample(row: 0, column: Int.max / 2 + 1) == nil)
    }

    @Test("Final offset addition overflow returns nil instead of trapping")
    func finalOffsetAdditionOverflow() {
        // Neither multiply overflows on its own: 1 * (Int.max - 4) is fine,
        // and 3 * 2 is fine, but their sum plus the sample size is not.
        let m = RAWMosaic(
            width: 8, height: 4, bytesPerRow: Int.max - 4, samples: Data(repeating: 0, count: 32),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.sample(row: 1, column: 3) == nil)
        #expect(m.sample(row: 1, column: 7) == nil)
    }

    @Test("Malformed data length returns nil instead of reading past the buffer")
    func malformedDataLength() {
        // Declared geometry needs 32 bytes; only 5 are present, and 5 is odd
        // so the last sample would also straddle the end.
        let m = RAWMosaic(
            width: 4, height: 4, bytesPerRow: 8, samples: Data(repeating: 0xAB, count: 5),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
        #expect(m.sample(row: 0, column: 0) == 0xABAB)
        #expect(m.sample(row: 0, column: 2) == nil)   // bytes 4...5, only byte 4 exists
        #expect(m.sample(row: 1, column: 0) == nil)
        #expect(m.sample(row: 3, column: 3) == nil)
    }

    @Test("A Data slice with a non-zero startIndex is indexed relative to that slice")
    func sliceBackedSamplesAreOffsetCorrectly() {
        // Data slices keep their parent's indices; sample() must fold
        // startIndex in rather than assuming 0.
        let backing = Self.makeSamples(width: 4, height: 3)
        let slice = backing.dropFirst(8)   // drop row 0
        let m = RAWMosaic(
            width: 4, height: 2, bytesPerRow: 8, samples: slice,
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.isGeometryConsistent)
        #expect(m.sample(row: 0, column: 0) == 100)
        #expect(m.sample(row: 1, column: 3) == 203)
        #expect(m.sample(row: 2, column: 0) == nil)
    }

    @Test("Extreme geometry combined with extreme coordinates still returns nil")
    func extremeGeometryNeverTraps() {
        let m = RAWMosaic(
            width: Int.max, height: Int.max, bytesPerRow: Int.max, samples: Data(repeating: 0, count: 4),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
        #expect(m.expectedByteCount == nil)
        #expect(m.sample(row: Int.max - 1, column: Int.max - 1) == nil)
        #expect(m.sample(row: 1, column: 1) == nil)
        // Row 0 is the one case whose arithmetic does not overflow, and its
        // first two samples genuinely fit the 4-byte buffer.
        #expect(m.sample(row: 0, column: 1) == 0)
        #expect(m.sample(row: 0, column: 2) == nil)
        #expect(m.colorPlaneIndex(row: Int.max - 1, column: Int.max - 1) != nil)
    }

    // MARK: - Invalid / unsupported data

    @Test("Empty samples with declared non-zero geometry is inconsistent")
    func emptyBufferWithNonZeroGeometryIsInconsistent() {
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 8, samples: Data(),
            sampleFormat: .uint16, sourceRawBitDepth: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
        #expect(m.sample(row: 0, column: 0) == nil)
    }
}

@Suite("RAWMosaicProcessing")
struct RAWMosaicProcessingTests {
    @Test("The processing facts are constant, self-evidently false, for every source storage")
    func processingFactsAreAlwaysFalse() {
        for storage: RAWMosaicProcessing.SourceStorage in [
            .singleChannel, .threeChannel, .fourChannel, .float, .none, .unsupportedLayout
        ] {
            let processing = RAWMosaicProcessing(
                decoderIdentifier: "Stub",
                sourceStorage: storage,
                sourceRowPitch: 8112,
                destinationRowStride: 8112
            )
            #expect(processing.blackLevelSubtracted == false)
            #expect(processing.normalizedToFullRange == false)
            #expect(processing.whiteBalanceApplied == false)
            #expect(processing.demosaiced == false)
            #expect(processing.cameraColorMatrixApplied == false)
            #expect(processing.gammaApplied == false)
            #expect(processing.orientationApplied == false)
        }
    }
}
