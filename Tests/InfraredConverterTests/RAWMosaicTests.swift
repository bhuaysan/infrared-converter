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
            bitsPerSample: 12,
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
            sampleFormat: .uint16, bitsPerSample: 12, sensorColorLayout: RAWTestData.bayerLayout()
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
            sampleFormat: .uint16, bitsPerSample: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
    }

    @Test("A stride narrower than width * bytesPerSample is inconsistent")
    func tooNarrowStrideIsInconsistent() {
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 6, samples: Self.makeSamples(width: 4, height: 3),
            sampleFormat: .uint16, bitsPerSample: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
    }

    @Test("Zero width or height is inconsistent")
    func zeroDimensionsAreInconsistent() {
        let zeroWidth = RAWMosaic(
            width: 0, height: 3, bytesPerRow: 0, samples: Data(),
            sampleFormat: .uint16, bitsPerSample: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!zeroWidth.isGeometryConsistent)

        let zeroHeight = RAWMosaic(
            width: 4, height: 0, bytesPerRow: 8, samples: Data(),
            sampleFormat: .uint16, bitsPerSample: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!zeroHeight.isGeometryConsistent)
    }

    @Test("Overflowing geometry is rejected rather than trapping")
    func overflowIsRejected() {
        let m = RAWMosaic(
            width: Int.max, height: 2, bytesPerRow: Int.max, samples: Data(),
            sampleFormat: .uint16, bitsPerSample: 12, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.expectedByteCount == nil)
        #expect(!m.isGeometryConsistent)
    }

    @Test("A nonsensical reported bitsPerSample is treated as invalid, not trapped on")
    func invalidBitsPerSampleIsInconsistent() {
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 8, samples: Self.makeSamples(width: 4, height: 3),
            sampleFormat: .uint16, bitsPerSample: 0, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(!m.isGeometryConsistent)
    }

    @Test("An unreported bitsPerSample is valid: the samples are still usable")
    func unreportedBitsPerSampleIsConsistent() {
        // Precision the decoder did not report is nil, never a substituted
        // default — the geometry is still sound, so the mosaic is usable and
        // a later stage decides what to do about the unknown precision.
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 8, samples: Self.makeSamples(width: 4, height: 3),
            sampleFormat: .uint16, bitsPerSample: nil, sensorColorLayout: RAWTestData.bayerLayout()
        )
        #expect(m.isGeometryConsistent)
        #expect(m.bitsPerSample == nil)
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
            sampleFormat: .uint16, bitsPerSample: 12, sensorColorLayout: RAWTestData.bayerLayout()
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

    // MARK: - Invalid / unsupported data

    @Test("Empty samples with declared non-zero geometry is inconsistent")
    func emptyBufferWithNonZeroGeometryIsInconsistent() {
        let m = RAWMosaic(
            width: 4, height: 3, bytesPerRow: 8, samples: Data(),
            sampleFormat: .uint16, bitsPerSample: 12, sensorColorLayout: RAWTestData.bayerLayout()
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
