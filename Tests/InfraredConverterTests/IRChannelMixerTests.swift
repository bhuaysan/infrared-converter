import Testing
import Foundation
@testable import InfraredConverter

/// The creative infrared channel-mix stage, on synthetic input whose expected
/// results are computed by hand.
///
/// Nothing here is colour science. The matrices are chosen so that a
/// transposed, reordered, clamped or wrongly-sourced implementation cannot
/// agree with them by coincidence.
///
/// There is deliberately no `apply(to:)` without a mix to test: every entry
/// point requires one, which is why no test here can accidentally exercise a
/// default.
@Suite("IRChannelMixer")
struct IRChannelMixerTests {

    // MARK: - Building input

    /// Provenance for a working-colour image, with an upstream chain rich
    /// enough that a stage which overwrote it would be visible.
    static func workingColorProcessing(
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor
    ) -> RAWWorkingColorProcessing {
        RAWWorkingColorProcessing(
            transform: transform,
            demosaicProcessing: RAWDemosaicProcessing(
                algorithm: .bilinearBayer,
                sourcePattern: RAWBayerCellPattern(
                    topLeft: .red, topRight: .green, bottomLeft: .green, bottomRight: .blue
                ),
                whiteBalanceProcessing: RAWWhiteBalanceProcessing(
                    gains: RAWWhiteBalanceGains(plane0: 2, plane1: 1, plane2: 3, plane3: 1),
                    gainSource: .explicit,
                    linearProcessing: RAWLinearProcessing(
                        whiteLevelPolicy: .metadataMaximum, whiteLevel: 4095
                    )
                )
            )
        )
    }

    /// A working-colour image from interleaved `R G B` values.
    static func image(width: Int, height: Int, values: [Float]) -> WorkingColorRGBImage {
        WorkingColorRGBImage(
            width: width, height: height, values: values, processing: workingColorProcessing()
        )
    }

    /// One pixel, for hand-computable arithmetic.
    static func pixel(_ red: Float, _ green: Float, _ blue: Float) -> WorkingColorRGBImage {
        image(width: 1, height: 1, values: [red, green, blue])
    }

    /// Deliberately non-symmetric, with exact binary-fraction coefficients so
    /// the expected arithmetic below is exact and can be compared with `==`.
    static func asymmetricMatrix() throws -> RAWColorMatrix3x3 {
        try RAWColorMatrix3x3(
            m00: 1.5, m01: -0.25, m02: 0.75,
            m10: 0.5, m11: 2.0, m12: -1.25,
            m20: -0.125, m21: 0.375, m22: 3.0
        )
    }

    // MARK: - Identity

    /// The values that most easily reveal an implementation that routes
    /// identity through arithmetic: `-0.0` becomes `+0.0` under
    /// `1×(-0.0) + 0×g + 0×b`, and the extremes reveal any narrowing.
    static let awkwardValues: [Float] = [
        -0.0, 0.0, 1.0, -1.0,
        0.5, -0.25, 2.5, 1_000_000.5,
        Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude,
        Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude,
    ]

    /// Every value here is finite, which is the stage's input contract. That
    /// the non-finite ones are *refused* rather than preserved is
    /// `IRChannelMixerErrorTests`; the two together are the whole policy.
    @Test("The identity mix preserves the bit pattern of every accepted value")
    func identityPreservesBits() throws {
        let input = Self.image(width: 2, height: 2, values: Self.awkwardValues)
        let output = try IRChannelMixer().apply(to: input, mix: .identity)

        #expect(output.values.count == input.values.count)
        for index in 0..<input.values.count {
            #expect(
                output.values[index].bitPattern == input.values[index].bitPattern,
                "element \(index)"
            )
        }

        // Specifically: negative zero survived as negative zero, which
        // arithmetic would not have preserved.
        #expect(output.values[0].sign == .minus)
        #expect(output.values[0] == 0)
        #expect(output.values[1].sign == .plus)

        // Geometry is untouched.
        #expect(output.width == 2)
        #expect(output.height == 2)
        #expect(output.isGeometryConsistent)
        #expect(output.pixelCount == 4)
        #expect(output.valuesPerRow == 6)
    }

    @Test("The identity mix records a traversed stage that changed nothing")
    func identityProvenance() throws {
        let input = Self.image(width: 2, height: 2, values: Self.awkwardValues)
        let output = try IRChannelMixer().apply(to: input, mix: .identity)
        let processing = output.processing

        #expect(processing.mixSource == .identity)
        #expect(processing.mix == .identity)
        #expect(processing.matrix == .identity)
        // The stage ran. That is a different fact from never reaching it.
        #expect(processing.channelMixApplied)
        // The colour space is unchanged, not re-established.
        #expect(processing.workingColorSpace == .extendedLinearSRGB)
        #expect(processing.workingColorSpace == input.processing.workingColorSpace)
        #expect(!processing.clamped)
        #expect(!processing.gammaApplied)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.displayEncodingApplied)
        #expect(!processing.orientationApplied)
        // A creative mix never turns anything into a calibration.
        #expect(!processing.isValidatedInfraredCalibration)
    }

    /// Bit identity over a buffer large enough that a per-pixel mistake would
    /// show up somewhere, rather than only at hand-picked coordinates.
    @Test("Identity is bit-identical over a whole synthetic image")
    func identityIsBitIdenticalOverAWholeImage() throws {
        let width = 97
        let height = 61
        var values = [Float]()
        values.reserveCapacity(width * height * 3)
        for index in 0..<(width * height * 3) {
            values.append(Float(index % 811) * 0.0037 - 1.25)
        }
        let input = Self.image(width: width, height: height, values: values)
        let output = try IRChannelMixer().apply(to: input, mix: .identity)

        var mismatches = 0
        for index in 0..<values.count
        where output.values[index].bitPattern != input.values[index].bitPattern {
            mismatches += 1
        }
        #expect(mismatches == 0)
        #expect(output.values.count == width * height * 3)
    }

    /// The identity path hands the same immutable array back rather than
    /// copying it. Bit identity is the contract; shared storage is the
    /// optimisation, and this observes it rather than assuming it.
    @Test("The identity path shares its source's storage, copy-on-write")
    func identitySharesStorage() throws {
        let input = Self.image(width: 8, height: 8, values: (0..<192).map { Float($0) * 0.5 })
        let output = try IRChannelMixer().apply(to: input, mix: .identity)

        let inputAddress = input.values.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        let outputAddress = output.values.withUnsafeBufferPointer {
            UInt(bitPattern: $0.baseAddress)
        }
        #expect(inputAddress == outputAddress)
    }

    // MARK: - Explicit identity

    /// The numerical path is decided by the matrix; the provenance by how the
    /// mix was made. An explicit identity matrix gets the fast path and keeps
    /// `.explicit`.
    @Test("An explicit identity matrix preserves accepted bits and stays .explicit")
    func explicitIdentityKeepsItsProvenance() throws {
        let input = Self.image(width: 2, height: 2, values: Self.awkwardValues)
        let mix = IRChannelMix.explicit(matrix: .identity)
        let output = try IRChannelMixer().apply(to: input, mix: mix)

        #expect(output.processing.mixSource == .explicit)
        for index in 0..<input.values.count {
            #expect(
                output.values[index].bitPattern == input.values[index].bitPattern,
                "element \(index)"
            )
        }
        #expect(output.values[0].sign == .minus)
    }

    // MARK: - Red/blue swap

    @Test("The red/blue swap exchanges exactly the outer channels, bit for bit")
    func redBlueSwapIsExact() throws {
        // Deliberately different in every channel of every pixel, with a
        // signed zero on a channel that moves.
        let values: [Float] = [
            0.25, 0.5, 0.75,
            -1.5, 2.0, -0.0,
            1_000_000.5, -0.25, Float.greatestFiniteMagnitude,
            Float.leastNonzeroMagnitude, -0.0, -3.5,
        ]
        let input = Self.image(width: 2, height: 2, values: values)
        let output = try IRChannelMixer().apply(to: input, mix: .redBlueSwap)

        #expect(output.values.count == values.count)
        for pixelIndex in 0..<4 {
            let base = pixelIndex * 3
            #expect(
                output.values[base].bitPattern == input.values[base + 2].bitPattern,
                "red at pixel \(pixelIndex)"
            )
            #expect(
                output.values[base + 1].bitPattern == input.values[base + 1].bitPattern,
                "green at pixel \(pixelIndex)"
            )
            #expect(
                output.values[base + 2].bitPattern == input.values[base].bitPattern,
                "blue at pixel \(pixelIndex)"
            )
        }

        // The signed zero that moved from blue to red is still negative: a
        // 0*R + 0*G + 1*B dot product would have made it +0.0.
        #expect(output.values[3].sign == .minus)
        #expect(output.values[3] == 0)
        #expect(output.processing.mixSource == .redBlueSwap)
        #expect(output.processing.matrix.rows == [[0, 0, 1], [0, 1, 0], [1, 0, 0]])
        #expect(!output.processing.clamped)
    }

    @Test("An explicit matrix equal to the swap swaps exactly and stays .explicit")
    func explicitSwapMatrixKeepsItsProvenance() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 0, m01: 0, m02: 1,
            m10: 0, m11: 1, m12: 0,
            m20: 1, m21: 0, m22: 0
        )
        let input = Self.image(width: 1, height: 2, values: [0.25, 0.5, -0.0, -1.5, 2.0, 3.5])
        let output = try IRChannelMixer().apply(to: input, mix: .explicit(matrix: matrix))

        // The optimised permutation path was taken — the signed zero proves
        // it — and provenance was not rewritten to `.redBlueSwap`.
        #expect(output.processing.mixSource == .explicit)
        #expect(output.values[0].bitPattern == input.values[2].bitPattern)
        #expect(output.values[0].sign == .minus)
        #expect(output.values[1].bitPattern == input.values[1].bitPattern)
        #expect(output.values[2].bitPattern == input.values[0].bitPattern)
        #expect(output.values[3].bitPattern == input.values[5].bitPattern)
        #expect(output.values[5].bitPattern == input.values[3].bitPattern)
    }

    // MARK: - General matrices

    /// Rows are output channels and columns are input channels. The expected
    /// values are computed here, by hand, from that reading — and the
    /// transposed reading is asserted *not* to match.
    @Test("A non-symmetric matrix confirms rows are outputs and columns inputs")
    func nonSymmetricMatrixOrientation() throws {
        let matrix = try Self.asymmetricMatrix()
        let output = try IRChannelMixer().apply(
            to: Self.pixel(1.0, 2.0, 4.0), mix: .explicit(matrix: matrix)
        )
        let result = try #require(output.pixel(row: 0, column: 0))

        // 1.5*1 + (-0.25)*2 + 0.75*4 = 1.5 - 0.5 + 3.0 = 4.0
        #expect(result.red == 4.0)
        // 0.5*1 + 2.0*2 + (-1.25)*4 = 0.5 + 4.0 - 5.0 = -0.5
        #expect(result.green == -0.5)
        // (-0.125)*1 + 0.375*2 + 3.0*4 = -0.125 + 0.75 + 12.0 = 12.625
        #expect(result.blue == 12.625)

        // The transposed reading would give different numbers everywhere, so
        // a transposed implementation cannot pass the assertions above.
        let transposedRed = 1.5 * 1.0 + 0.5 * 2.0 + (-0.125) * 4.0
        let transposedGreen = (-0.25) * 1.0 + 2.0 * 2.0 + 0.375 * 4.0
        let transposedBlue = 0.75 * 1.0 + (-1.25) * 2.0 + 3.0 * 4.0
        #expect(Float(transposedRed) != result.red)
        #expect(Float(transposedGreen) != result.green)
        #expect(Float(transposedBlue) != result.blue)
    }

    @Test("A general mix is applied to every pixel, with geometry untouched")
    func generalMixCoversTheWholeImage() throws {
        let matrix = try Self.asymmetricMatrix()
        let width = 5
        let height = 3
        var values = [Float]()
        for index in 0..<(width * height * 3) {
            values.append(Float(index) * 0.125 - 1.0)
        }
        let input = Self.image(width: width, height: height, values: values)
        let output = try IRChannelMixer().apply(to: input, mix: .explicit(matrix: matrix))

        #expect(output.width == width)
        #expect(output.height == height)
        #expect(output.values.count == values.count)
        #expect(output.isGeometryConsistent)

        for row in 0..<height {
            for column in 0..<width {
                let base = (row * width + column) * 3
                let red = Double(values[base])
                let green = Double(values[base + 1])
                let blue = Double(values[base + 2])
                let expectedRed = Float(1.5 * red - 0.25 * green + 0.75 * blue)
                let expectedGreen = Float(0.5 * red + 2.0 * green - 1.25 * blue)
                let expectedBlue = Float(-0.125 * red + 0.375 * green + 3.0 * blue)
                let actual = try #require(output.pixel(row: row, column: column))
                #expect(actual.red == expectedRed, "red at (\(row), \(column))")
                #expect(actual.green == expectedGreen, "green at (\(row), \(column))")
                #expect(actual.blue == expectedBlue, "blue at (\(row), \(column))")
            }
        }
    }

    @Test("Negative coefficients produce negative output, and it is not clamped")
    func negativeOutputIsPreserved() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: -1.5, m01: 0, m02: 0,
            m10: 0.25, m11: -1.0, m12: 0,
            m20: 0, m21: 0, m22: -0.5
        )
        let output = try IRChannelMixer().apply(
            to: Self.pixel(0.5, 0.25, 2.0), mix: .explicit(matrix: matrix)
        )
        let result = try #require(output.pixel(row: 0, column: 0))

        // -1.5*0.5 = -0.75; 0.25*0.5 - 1.0*0.25 = -0.125; -0.5*2.0 = -1.0
        #expect(result.red == -0.75)
        #expect(result.green == -0.125)
        #expect(result.blue == -1.0)
        #expect(!output.processing.clamped)
        #expect(output.values.allSatisfy { $0 < 0 })
    }

    @Test("Amplifying coefficients produce output above one, and it is not clipped")
    func aboveOneOutputIsPreserved() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 4, m01: 0, m02: 0,
            m10: 0, m11: 8, m12: 0,
            m20: 1, m21: 1, m22: 1
        )
        let output = try IRChannelMixer().apply(
            to: Self.pixel(0.5, 0.75, 0.25), mix: .explicit(matrix: matrix)
        )
        let result = try #require(output.pixel(row: 0, column: 0))

        #expect(result.red == 2.0)
        #expect(result.green == 6.0)
        #expect(result.blue == 1.5)
        #expect(output.values.allSatisfy { $0 > 1 })
        #expect(!output.processing.clamped)
    }

    /// A rank-1 matrix: all three output rows identical, so every pixel
    /// collapses to a single value repeated across the channels. The stage
    /// does not require invertibility, and this is not a built-in preset —
    /// only a proof that a valid singular creative matrix works.
    @Test("A singular monochrome-collapse matrix is accepted and applied")
    func singularMonochromeMatrix() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 0.25, m01: 0.5, m02: 0.125,
            m10: 0.25, m11: 0.5, m12: 0.125,
            m20: 0.25, m21: 0.5, m22: 0.125
        )
        #expect(matrix.determinant == 0)

        let values: [Float] = [0.5, 0.25, 2.0, -1.0, 0.75, 0.5]
        let output = try IRChannelMixer().apply(
            to: Self.image(width: 2, height: 1, values: values),
            mix: .explicit(matrix: matrix)
        )

        for column in 0..<2 {
            let result = try #require(output.pixel(row: 0, column: column))
            #expect(result.red == result.green)
            #expect(result.green == result.blue)
        }
        // 0.25*0.5 + 0.5*0.25 + 0.125*2.0 = 0.125 + 0.125 + 0.25 = 0.5
        #expect(try #require(output.pixel(row: 0, column: 0)).red == 0.5)
        // 0.25*(-1.0) + 0.5*0.75 + 0.125*0.5 = -0.25 + 0.375 + 0.0625 = 0.1875
        #expect(try #require(output.pixel(row: 0, column: 1)).red == 0.1875)
    }

    /// The reason the dot products accumulate in `Double`.
    ///
    /// `2 × greatestFiniteMagnitude` is infinity in `Float32`, and infinity
    /// minus anything stays infinity — so a `Float` implementation would fail
    /// on a result that `Float` represents perfectly. In `Double` the same
    /// arithmetic is exact and the single narrowing lands on the maximum. The
    /// expected value is written out here rather than obtained from any
    /// production helper.
    @Test("Double accumulation avoids an artificial Float32 intermediate overflow")
    func doubleAccumulationAvoidsArtificialOverflow() throws {
        let huge = Float.greatestFiniteMagnitude

        // The hazard is real, in Float.
        #expect(!(2 * huge).isFinite)
        #expect(!(2 * huge - huge).isFinite)

        let matrix = try RAWColorMatrix3x3(
            m00: 2, m01: -1, m02: 0,
            m10: 0, m11: 0, m12: 1,
            m20: 0, m21: 0, m22: 1
        )
        let output = try IRChannelMixer().apply(
            to: Self.pixel(huge, huge, 0.5), mix: .explicit(matrix: matrix)
        )
        let result = try #require(output.pixel(row: 0, column: 0))

        #expect(result.red.isFinite)
        #expect(result.red == huge)
        #expect(result.green == 0.5)
        #expect(result.blue == 0.5)

        // Storage is still Float32 throughout; the Double is an accumulator,
        // not a representation.
        #expect(MemoryLayout<Float>.size == 4)
        #expect(output.values.count == 3)
    }
}
