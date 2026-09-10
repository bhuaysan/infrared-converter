import Testing
import Foundation
@testable import InfraredConverter

/// The camera-native RGB → extended-linear-sRGB stage, on synthetic input
/// whose expected results are computed by hand.
///
/// The matrices here are mathematical test cases, not colour science. In
/// particular the channel-swap matrix is a test of the generic 3×3 primitive's
/// orientation, **not** an infrared creative channel mixer — that is a
/// separate, later stage that belongs after the working-space boundary.
///
/// There is deliberately no `convert(_:)` without a transform to test: every
/// entry point requires one, which is why no test here can accidentally
/// exercise a default.
@Suite("RAWWorkingColorConverter")
struct RAWWorkingColorConverterTests {

    // MARK: - Building input

    static func demosaicProcessing() -> RAWDemosaicProcessing {
        RAWDemosaicProcessing(
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
    }

    /// A camera-native image from interleaved `R G B` values.
    static func image(width: Int, height: Int, values: [Float]) -> DemosaicedRAWRGBImage {
        DemosaicedRAWRGBImage(
            width: width, height: height, values: values, processing: demosaicProcessing()
        )
    }

    /// One pixel, for hand-computable arithmetic.
    static func pixel(_ red: Float, _ green: Float, _ blue: Float) -> DemosaicedRAWRGBImage {
        image(width: 1, height: 1, values: [red, green, blue])
    }

    /// A synthetic 4×4 run of the whole application-owned pipeline, so the
    /// processed-state overloads can be exercised with real provenance and
    /// with metadata the caller controls.
    static func processedFixture(
        color: RAWMetadata.ColorMetadata = .init()
    ) throws -> DemosaicedProcessedRAWImage {
        let width = 4
        let height = 4
        var samples = [UInt16]()
        for index in 0..<(width * height) {
            samples.append(UInt16(150 + index * 53))
        }
        var metadata = RAWTestData.metadata()
        metadata.levels = .init(black: 0, perPlaneBlack: [0, 0, 0, 0], maximum: 4095)
        metadata.color = color
        let decoded = DecodedRAWMosaic(
            url: URL(fileURLWithPath: "/tmp/working-colour.orf"),
            metadata: metadata,
            mosaic: RAWMosaic(
                width: width,
                height: height,
                bytesPerRow: width * 2,
                samples: samples.withUnsafeBufferPointer { Data(buffer: $0) },
                sampleFormat: .uint16,
                sourceRawBitDepth: 12,
                sensorColorLayout: RAWTestData.bayerLayout()
            ),
            processing: RAWMosaicProcessing(
                decoderIdentifier: "Stub",
                sourceStorage: .singleChannel,
                sourceRowPitch: width,
                destinationRowStride: width
            )
        )
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let balanced = try RAWWhiteBalancer().apply(
            to: normalized,
            gains: RAWWhiteBalanceGains(plane0: 2, plane1: 1, plane2: 3, plane3: 1.5)
        )
        return try RAWDemosaicer().demosaic(balanced)
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

    @Test("Identity false colour preserves every bit pattern")
    func identityPreservesBits() throws {
        let input = Self.image(width: 2, height: 2, values: Self.awkwardValues)
        let output = try RAWWorkingColorConverter().convert(
            input, using: .sensorRGBIdentityFalseColor
        )

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
            // A spread that includes negatives, zeros and values above one.
            values.append(Float(index % 811) * 0.0037 - 1.25)
        }
        let input = Self.image(width: width, height: height, values: values)
        let output = try RAWWorkingColorConverter().convert(
            input, using: .sensorRGBIdentityFalseColor
        )

        #expect(output.values.count == width * height * 3)
        var mismatches = 0
        for index in 0..<input.values.count
        where output.values[index].bitPattern != input.values[index].bitPattern {
            mismatches += 1
        }
        #expect(mismatches == 0)
    }

    /// Documents — rather than mandates — that the identity path lets
    /// `Array`'s copy-on-write share one backing buffer, so the E-PL3's 148 MB
    /// is not duplicated to no purpose. Both sides are immutable `let` values,
    /// so sharing is unobservable except like this.
    @Test("Identity shares its source's storage rather than copying it")
    func identitySharesStorage() throws {
        let input = Self.image(width: 4, height: 4, values: (0..<48).map { Float($0) * 0.5 })
        let output = try RAWWorkingColorConverter().convert(
            input, using: .sensorRGBIdentityFalseColor
        )
        let inputAddress = input.values.withUnsafeBufferPointer { $0.baseAddress }
        let outputAddress = output.values.withUnsafeBufferPointer { $0.baseAddress }
        #expect(inputAddress == outputAddress)
    }

    @Test("An explicitly supplied identity matrix takes the same bit-preserving path")
    func explicitIdentityAlsoPreservesBits() throws {
        let input = Self.image(width: 2, height: 2, values: Self.awkwardValues)
        let output = try RAWWorkingColorConverter().convert(
            input, using: .explicit(matrix: .identity)
        )
        for index in 0..<input.values.count {
            #expect(output.values[index].bitPattern == input.values[index].bitPattern)
        }
        // The provenance still says where the matrix came from.
        #expect(output.processing.transformSource == .explicit)
    }

    // MARK: - Provenance

    @Test("Provenance records the space, the transform and the whole upstream chain")
    func provenanceIsComplete() throws {
        let input = Self.image(width: 1, height: 1, values: [0.25, 0.5, 0.75])
        let output = try RAWWorkingColorConverter().convert(
            input, using: .sensorRGBIdentityFalseColor
        )
        let processing = output.processing

        #expect(processing.workingColorSpace == .extendedLinearSRGB)
        #expect(processing.transform == .sensorRGBIdentityFalseColor)
        #expect(processing.transformSource == .sensorRGBIdentityFalseColor)
        #expect(processing.matrix == .identity)
        #expect(!processing.isValidatedInfraredCalibration)

        #expect(processing.workingColorRepresentationEstablished)
        #expect(processing.cameraToWorkingTransformApplied)
        #expect(!processing.clamped)
        #expect(!processing.gammaApplied)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.displayEncodingApplied)
        #expect(!processing.orientationApplied)

        // Upstream facts are read through, never restated.
        #expect(processing.demosaicProcessing == input.processing)
        #expect(processing.demosaiced)
        #expect(processing.whiteBalanceApplied)
        #expect(processing.blackLevelSubtracted)
        #expect(processing.normalized)
        #expect(processing.demosaicAlgorithm == .bilinearBayer)
        #expect(processing.whiteBalanceGains == input.processing.whiteBalanceGains)
    }

    @Test("The processed overload keeps the whole chain reachable")
    func processedOverloadRetainsTheChain() throws {
        let demosaiced = try Self.processedFixture()
        let result = try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )

        #expect(result.demosaicedImage == demosaiced.image)
        #expect(result.whiteBalancedMosaic == demosaiced.whiteBalancedMosaic)
        #expect(result.linearMosaic == demosaiced.linearMosaic)
        #expect(result.metadata == demosaiced.metadata)
        #expect(result.url == demosaiced.url)
        #expect(result.transform == .sensorRGBIdentityFalseColor)
        #expect(result.processing == result.image.processing)
        #expect(result.source.source.source.source.mosaic.width == 4)
    }

    // MARK: - Generic 3×3 arithmetic

    /// Hand-computed, with exact binary fractions throughout so `==` is the
    /// right comparison:
    ///
    /// ```text
    /// R' = 1.5*0.25   + (-0.25)*(-0.5) + 0.75*2   =  0.375   + 0.125   + 1.5 =  2.0
    /// G' = 0.5*0.25   +   2.0 *(-0.5)  + -1.25*2  =  0.125   - 1.0     - 2.5 = -3.375
    /// B' = -0.125*0.25 + 0.375*(-0.5)  +  3.0 *2  = -0.03125 - 0.1875  + 6.0 =  5.78125
    /// ```
    @Test("A non-symmetric matrix produces the hand-computed result")
    func generalMatrixMatchesHandComputation() throws {
        let transform = RAWCameraToWorkingColorTransform.explicit(
            matrix: try RAWColorMatrix3x3Tests.asymmetric()
        )
        let output = try RAWWorkingColorConverter().convert(
            Self.pixel(0.25, -0.5, 2.0), using: transform
        )
        let result = try #require(output.pixel(row: 0, column: 0))

        #expect(result.red == 2.0)
        #expect(result.green == -3.375)
        #expect(result.blue == 5.78125)

        // A transposed implementation would produce these instead, and does
        // not: rows are outputs, columns are inputs.
        let transposedRed = 1.5 * 0.25 + 0.5 * -0.5 + -0.125 * 2.0
        #expect(Float(transposedRed) != result.red)
    }

    @Test("A channel-swap matrix produces B G R")
    func channelSwapSwapsChannels() throws {
        let swap = try RAWColorMatrix3x3(
            m00: 0, m01: 0, m02: 1,
            m10: 0, m11: 1, m12: 0,
            m20: 1, m21: 0, m22: 0
        )
        let output = try RAWWorkingColorConverter().convert(
            Self.image(width: 2, height: 1, values: [0.25, 0.5, 0.75, 1.5, 2.5, 3.5]),
            using: .explicit(matrix: swap)
        )
        #expect(try #require(output.pixel(row: 0, column: 0))
                == RAWLinearRGBPixel(red: 0.75, green: 0.5, blue: 0.25))
        #expect(try #require(output.pixel(row: 0, column: 1))
                == RAWLinearRGBPixel(red: 3.5, green: 2.5, blue: 1.5))
    }

    @Test("Negative coefficients produce negative working values, unclamped")
    func negativeValuesSurvive() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: -1, m01: 0, m02: 0,
            m10: 0.5, m11: -2, m12: 0,
            m20: 0, m21: 0, m22: -0.25
        )
        let output = try RAWWorkingColorConverter().convert(
            Self.pixel(0.5, 0.25, 4.0), using: .explicit(matrix: matrix)
        )
        let result = try #require(output.pixel(row: 0, column: 0))
        #expect(result.red == -0.5)
        #expect(result.green == -0.25)   // 0.5*0.5 + (-2)*0.25 = 0.25 - 0.5
        #expect(result.blue == -1.0)
        #expect(!output.processing.clamped)
    }

    @Test("Values above one are preserved, unclipped")
    func aboveOneValuesSurvive() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 4, m01: 0, m02: 0,
            m10: 0, m11: 4, m12: 0,
            m20: 0, m21: 0, m22: 4
        )
        let output = try RAWWorkingColorConverter().convert(
            Self.pixel(0.5, 1.0, 2.0), using: .explicit(matrix: matrix)
        )
        let result = try #require(output.pixel(row: 0, column: 0))
        #expect(result.red == 2.0)
        #expect(result.green == 4.0)
        #expect(result.blue == 8.0)
    }

    @Test("A singular matrix is accepted and applied")
    func singularMatrixIsAccepted() throws {
        // Every output channel is the same combination: a rank-1 collapse to
        // a monochrome working image. Determinant 0, no inverse, legitimate.
        let matrix = try RAWColorMatrix3x3(
            m00: 0.25, m01: 0.5, m02: 0.25,
            m10: 0.25, m11: 0.5, m12: 0.25,
            m20: 0.25, m21: 0.5, m22: 0.25
        )
        #expect(matrix.determinant == 0)
        let output = try RAWWorkingColorConverter().convert(
            Self.pixel(1.0, 2.0, 3.0), using: .explicit(matrix: matrix)
        )
        // 0.25*1 + 0.5*2 + 0.25*3 = 0.25 + 1.0 + 0.75 = 2.0, in all three
        // output channels.
        let result = try #require(output.pixel(row: 0, column: 0))
        #expect(result.red == 2.0)
        #expect(result.green == 2.0)
        #expect(result.blue == 2.0)
    }

    /// The reason the dot products accumulate in `Double`.
    ///
    /// `2 × greatestFiniteMagnitude` is infinity in `Float32`, and infinity
    /// minus anything stays infinity — so a `Float` implementation would fail
    /// on a result that `Float` represents perfectly. In `Double` the same
    /// arithmetic is exact and the single narrowing lands on the maximum.
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
        let output = try RAWWorkingColorConverter().convert(
            Self.pixel(huge, huge, 0.5), using: .explicit(matrix: matrix)
        )
        let result = try #require(output.pixel(row: 0, column: 0))

        #expect(result.red.isFinite)
        #expect(result.red == huge)
        #expect(result.green == 0.5)
        #expect(result.blue == 0.5)

        // Storage is still Float32 throughout; the Double is an accumulator,
        // not a representation.
        #expect(MemoryLayout<Float>.stride == 4)
        #expect(output.values.count == 3)
    }

    // MARK: - Non-finite handling

    @Test("A non-finite input is reported with its coordinate and channel")
    func nonFiniteInputIsReported() throws {
        var values = [Float](repeating: 0.5, count: 2 * 2 * 3)
        // Row 1, column 0, green.
        values[(1 * 2 + 0) * 3 + 1] = .nan
        let input = Self.image(width: 2, height: 2, values: values)

        // The general path.
        #expect {
            _ = try RAWWorkingColorConverter().convert(
                input, using: .explicit(matrix: try RAWColorMatrix3x3Tests.asymmetric())
            )
        } throws: { error in
            guard case .nonFiniteWorkingColorInput(let row, let column, let channel, let value) =
                    error as? RAWProcessingError else { return false }
            return row == 1 && column == 0 && channel == .green && value.isNaN
        }

        // And the identity path defends the same boundary.
        #expect {
            _ = try RAWWorkingColorConverter().convert(
                input, using: .sensorRGBIdentityFalseColor
            )
        } throws: { error in
            guard case .nonFiniteWorkingColorInput(let row, let column, let channel, _) =
                    error as? RAWProcessingError else { return false }
            return row == 1 && column == 0 && channel == .green
        }

        // Infinities too, in either sign.
        for infinite in [Float.infinity, -.infinity] {
            var infiniteValues = [Float](repeating: 0.25, count: 3)
            infiniteValues[2] = infinite
            #expect {
                _ = try RAWWorkingColorConverter().convert(
                    Self.image(width: 1, height: 1, values: infiniteValues),
                    using: .sensorRGBIdentityFalseColor
                )
            } throws: { error in
                guard case .nonFiniteWorkingColorInput(_, _, let channel, let value) =
                        error as? RAWProcessingError else { return false }
                return channel == .blue && value == infinite
            }
        }
    }

    @Test("A result that overflows Float32 fails rather than being clamped")
    func nonFiniteResultIsReported() throws {
        // Finite in Double (6.8e38), not representable in Float32.
        let doubling = try RAWColorMatrix3x3(
            m00: 1, m01: 0, m02: 0,
            m10: 0, m11: 2, m12: 0,
            m20: 0, m21: 0, m22: 1
        )
        #expect {
            _ = try RAWWorkingColorConverter().convert(
                Self.pixel(1, Float.greatestFiniteMagnitude, 1),
                using: .explicit(matrix: doubling)
            )
        } throws: { error in
            guard case .nonFiniteWorkingColorResult(let row, let column, let channel) =
                    error as? RAWProcessingError else { return false }
            return row == 0 && column == 0 && channel == .green
        }

        // And a coefficient large enough to overflow the Double accumulation
        // itself fails the same way, rather than reaching the buffer.
        let enormous = try RAWColorMatrix3x3(
            m00: 1, m01: 0, m02: 0,
            m10: 0, m11: 1, m12: 0,
            m20: 0, m21: 0, m22: 1e300
        )
        #expect {
            _ = try RAWWorkingColorConverter().convert(
                Self.pixel(1, 1, Float.greatestFiniteMagnitude),
                using: .explicit(matrix: enormous)
            )
        } throws: { error in
            guard case .nonFiniteWorkingColorResult(_, _, let channel) =
                    error as? RAWProcessingError else { return false }
            return channel == .blue
        }
    }

    // MARK: - Storage and geometry

    @Test("Storage is tightly packed, row-major, interleaved R G B")
    func storageLayoutIsPinned() throws {
        let width = 3
        let height = 2
        var values = [Float]()
        for pixelIndex in 0..<(width * height) {
            values.append(Float(pixelIndex) + 0.125)      // R
            values.append(Float(pixelIndex) + 0.25)       // G
            values.append(Float(pixelIndex) + 0.5)        // B
        }
        let output = try RAWWorkingColorConverter().convert(
            Self.image(width: width, height: height, values: values),
            using: .sensorRGBIdentityFalseColor
        )

        #expect(output.values.count == width * height * 3)
        #expect(output.expectedValueCount == width * height * 3)
        #expect(output.pixelCount == width * height)
        #expect(output.valuesPerRow == width * 3)
        #expect(WorkingColorRGBImage.channelCount == 3)

        // Read straight out of the raw buffer, not through the accessors.
        for row in 0..<height {
            for column in 0..<width {
                let base = (row * width + column) * 3
                let pixelIndex = Float(row * width + column)
                #expect(output.values[base] == pixelIndex + 0.125)
                #expect(output.values[base + 1] == pixelIndex + 0.25)
                #expect(output.values[base + 2] == pixelIndex + 0.5)
                // And the accessors agree with the raw buffer.
                #expect(output.storageIndex(row: row, column: column) == base)
                #expect(output.value(row: row, column: column, channel: .red)
                        == output.values[base])
                #expect(output.value(row: row, column: column, channel: .blue)
                        == output.values[base + 2])
            }
        }

        // Out of bounds returns nil rather than trapping.
        #expect(output.pixel(row: -1, column: 0) == nil)
        #expect(output.pixel(row: 0, column: width) == nil)
        #expect(output.value(row: height, column: 0, channel: .red) == nil)
        #expect(output.storageIndex(row: 0, column: -1) == nil)
    }

    @Test("Malformed geometry is reported, not trapped")
    func malformedGeometryNeverTraps() throws {
        let processing = RAWWorkingColorProcessing(
            transform: .sensorRGBIdentityFalseColor,
            demosaicProcessing: Self.demosaicProcessing()
        )

        // Both multiplications overflow-check independently.
        let hugePixels = WorkingColorRGBImage(
            width: Int.max, height: 2, values: [], processing: processing
        )
        #expect(hugePixels.pixelCount == nil)
        #expect(hugePixels.expectedValueCount == nil)
        #expect(hugePixels.valuesPerRow == nil)
        #expect(!hugePixels.isGeometryConsistent)
        #expect(hugePixels.pixel(row: 0, column: 0) == nil)

        // The pixel count fits; three channels of it do not.
        let hugeChannels = WorkingColorRGBImage(
            width: Int.max / 3 + 1, height: 1, values: [], processing: processing
        )
        #expect(hugeChannels.pixelCount != nil)
        #expect(hugeChannels.expectedValueCount == nil)
        #expect(!hugeChannels.isGeometryConsistent)
        #expect(hugeChannels.pixel(row: 0, column: 0) == nil)

        let empty = WorkingColorRGBImage(
            width: 0, height: 0, values: [], processing: processing
        )
        #expect(!empty.isGeometryConsistent)
        #expect(empty.pixel(row: 0, column: 0) == nil)

        // A buffer shorter than its declared geometry reads what is genuinely
        // there and `nil` for the rest, exactly as the demosaiced image does.
        let short = WorkingColorRGBImage(
            width: 4, height: 4, values: [1, 2, 3], processing: processing
        )
        #expect(!short.isGeometryConsistent)
        #expect(short.pixel(row: 0, column: 0) == RAWLinearRGBPixel(red: 1, green: 2, blue: 3))
        #expect(short.pixel(row: 0, column: 1) == nil)

        // And the stage refuses inconsistent input rather than reading past it.
        let inconsistent = Self.image(width: 4, height: 4, values: [1, 2, 3])
        #expect {
            _ = try RAWWorkingColorConverter().convert(
                inconsistent, using: .sensorRGBIdentityFalseColor
            )
        } throws: { error in
            guard case .invalidGeometry = error as? RAWProcessingError else { return false }
            return true
        }
        #expect {
            _ = try RAWWorkingColorConverter().convert(
                inconsistent, using: .explicit(matrix: try RAWColorMatrix3x3Tests.asymmetric())
            )
        } throws: { error in
            guard case .invalidGeometry = error as? RAWProcessingError else { return false }
            return true
        }
    }

    // MARK: - Reprocessing

    @Test("Replacing the transform restarts from camera-native RGB, never composing")
    func reprocessingNeverComposes() throws {
        let demosaiced = try Self.processedFixture()
        let converter = RAWWorkingColorConverter()

        let first = try RAWColorMatrix3x3(
            m00: 2, m01: 0, m02: 0,
            m10: 0, m11: 2, m12: 0,
            m20: 0, m21: 0, m22: 2
        )
        let second = try RAWColorMatrix3x3(
            m00: 3, m01: 0, m02: 0,
            m10: 0, m11: 3, m12: 0,
            m20: 0, m21: 0, m22: 3
        )

        let afterFirst = try converter.convert(demosaiced, using: .explicit(matrix: first))
        let afterSecond = try converter.convert(
            using: .explicit(matrix: second), replacing: afterFirst
        )
        let directlySecond = try converter.convert(demosaiced, using: .explicit(matrix: second))

        // 3x the camera-native values, not 6x.
        #expect(afterSecond.image.values == directlySecond.image.values)
        for index in 0..<demosaiced.image.values.count {
            #expect(afterSecond.image.values[index]
                    == Float(3 * Double(demosaiced.image.values[index])))
        }

        // The camera-native source is what it reached through, unchanged.
        #expect(afterSecond.demosaicedImage == demosaiced.image)
        #expect(afterSecond.transform.matrix == second)

        // And the earlier result is untouched — nothing was mutated in place.
        #expect(afterFirst.transform.matrix == first)
    }

    // MARK: - Infrared safety invariants

    /// The central invariant: metadata never selects a transform on its own.
    @Test("An obviously non-identity rgbFromCamera has no effect unless it is asked for")
    func metadataIsNeverAutomatic() throws {
        let loudMatrix: [[Float]] = [
            [9, -8, 7, 0],
            [-6, 5, -4, 0],
            [3, -2, 1, 0],
        ]
        let demosaiced = try Self.processedFixture(
            color: RAWMetadata.ColorMetadata(
                cameraMultipliers: [2, 1, 4, 1],
                daylightMultipliers: [1.5, 1, 2, 1],
                rgbFromCamera: loudMatrix,
                cameraFromXYZ: [[1, 2, 3], [4, 5, 6], [7, 8, 9], [0, 0, 0]],
                asShotWhiteBalanceApplied: false
            )
        )
        // The metadata really does carry a transform that would change every
        // pixel if anything reached for it.
        #expect(demosaiced.metadata.color.rgbFromCamera == loudMatrix)

        let result = try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )

        // Identity in, identity out — bit for bit.
        #expect(result.image.values.count == demosaiced.image.values.count)
        for index in 0..<demosaiced.image.values.count {
            #expect(result.image.values[index].bitPattern
                    == demosaiced.image.values[index].bitPattern)
        }
        #expect(result.transform.source == .sensorRGBIdentityFalseColor)
        #expect(result.transform.matrix == .identity)

        // Asking for it explicitly is the only way it applies, and then it
        // does change the image.
        let metadataTransform = try RAWCameraToWorkingColorTransform.visibleLightMetadata(
            from: demosaiced.metadata.color
        )
        let transformed = try RAWWorkingColorConverter().convert(
            demosaiced, using: metadataTransform
        )
        #expect(transformed.image.values != result.image.values)
        #expect(transformed.transform.source == .visibleLightMetadataRGBFromCamera)
    }

    /// White balance happened in the mosaic domain. The camera and daylight
    /// multipliers cannot reach this stage, so absurd ones change nothing.
    @Test("Camera and daylight multipliers do not leak into the working transform")
    func whiteBalanceMetadataDoesNotLeak() throws {
        let sane = RAWMetadata.ColorMetadata(
            cameraMultipliers: [1, 1, 1, 1],
            daylightMultipliers: [1, 1, 1, 1],
            rgbFromCamera: nil,
            cameraFromXYZ: nil,
            asShotWhiteBalanceApplied: false
        )
        let absurd = RAWMetadata.ColorMetadata(
            cameraMultipliers: [1e6, -1e6, 0.000001, 42],
            daylightMultipliers: [-99999, 123456, 0, 7],
            rgbFromCamera: nil,
            cameraFromXYZ: nil,
            asShotWhiteBalanceApplied: true
        )

        let transform = RAWCameraToWorkingColorTransform.explicit(
            matrix: try RAWColorMatrix3x3Tests.asymmetric()
        )
        let converter = RAWWorkingColorConverter()
        let withSane = try converter.convert(
            try Self.processedFixture(color: sane), using: transform
        )
        let withAbsurd = try converter.convert(
            try Self.processedFixture(color: absurd), using: transform
        )

        #expect(withSane.image.values == withAbsurd.image.values)
        #expect(withSane.processing.whiteBalanceGains == withAbsurd.processing.whiteBalanceGains)
    }

    /// `cameraFromXYZ` is not read and nothing is inverted in this milestone.
    @Test("cameraFromXYZ is not used, present or absent")
    func cameraFromXYZIsNotUsed() throws {
        let without = RAWMetadata.ColorMetadata(rgbFromCamera: nil, cameraFromXYZ: nil)
        let with = RAWMetadata.ColorMetadata(
            rgbFromCamera: nil,
            cameraFromXYZ: [[0.7, -0.2, -0.05], [-0.3, 1.4, 0.1], [0.02, -0.4, 1.1], [0, 0, 0]]
        )

        let converter = RAWWorkingColorConverter()
        let a = try converter.convert(
            try Self.processedFixture(color: without), using: .sensorRGBIdentityFalseColor
        )
        let b = try converter.convert(
            try Self.processedFixture(color: with), using: .sensorRGBIdentityFalseColor
        )
        #expect(a.image.values == b.image.values)

        // And the visible-light adapter will not fall back to it either.
        #expect {
            _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(from: with)
        } throws: { error in
            guard case .missingVisibleLightCameraMatrix = error as? RAWProcessingError else {
                return false
            }
            return true
        }
    }
}
