import Foundation
import Testing
@testable import InfraredConverter

/// Synthetic tests for bilinear Bayer demosaicing. Nothing here touches a RAW
/// file: every sample is constructed, so every expected output value is
/// hand-computable and written out literally.
///
/// The oracle for this suite is the documented algorithm — native samples
/// copied exactly, axial and diagonal means over the in-bounds neighbours that
/// actually carry the wanted colour — not another implementation and
/// certainly not LibRaw, whose processed-RGB path applies a colour matrix,
/// gamma and its own border handling on top of a different interpolation.
@Suite("RAWDemosaicer")
struct RAWDemosaicerTests {

    // MARK: - Building mosaics

    static let linearProcessing = RAWLinearProcessing(
        whiteLevelPolicy: .metadataMaximum, whiteLevel: 4095
    )

    static func whiteBalanceProcessing(
        gains: RAWWhiteBalanceGains = .identity
    ) -> RAWWhiteBalanceProcessing {
        RAWWhiteBalanceProcessing(
            gains: gains, gainSource: .explicit, linearProcessing: linearProcessing
        )
    }

    static func mosaic(
        width: Int,
        height: Int,
        values: [Float],
        layout: RAWMetadata.SensorColorLayout = BayerTestLayouts.rggb
    ) -> WhiteBalancedRAWMosaic {
        WhiteBalancedRAWMosaic(
            width: width,
            height: height,
            values: values,
            sensorColorLayout: layout,
            processing: whiteBalanceProcessing()
        )
    }

    static func mosaic(
        width: Int,
        height: Int,
        layout: RAWMetadata.SensorColorLayout = BayerTestLayouts.rggb,
        sample: (Int, Int) -> Float
    ) -> WhiteBalancedRAWMosaic {
        var values = [Float]()
        values.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                values.append(sample(row, column))
            }
        }
        return mosaic(width: width, height: height, values: values, layout: layout)
    }

    /// The colour at a position in the `RGGB` test phase, written out here
    /// rather than asked of the production resolver, so expectations derived
    /// from it are independent of the code under test.
    ///
    /// ```text
    /// R G
    /// G B
    /// ```
    static func rggbChannel(row: Int, column: Int) -> RAWLinearRGBChannel {
        switch (row % 2, column % 2) {
        case (0, 0): return .red
        case (1, 1): return .blue
        default: return .green
        }
    }

    // MARK: - Native samples are copied, not recomputed

    @Test("Every CFA location's own colour is its native sample, bit for bit")
    func nativeSamplesArePreservedExactly() throws {
        // Deliberately awkward values: a negative zero, finite negatives, and
        // values well above 1. None may be clamped, rounded, or routed through
        // Double and back.
        let awkward: [Float] = [
            -0.0, 1.5, -2.25, 3.0, 0.1, -0.000_003_5, 12_345.75, 0.25,
            -1.0, 2.5, 7.125, -0.5, 1e-30, 4.0, -9.75, 1e20,
        ]
        let source = Self.mosaic(width: 4, height: 4, values: awkward)
        let image = try RAWDemosaicer().demosaic(source)

        for row in 0..<4 {
            for column in 0..<4 {
                let channel = Self.rggbChannel(row: row, column: column)
                let native = try #require(source.value(row: row, column: column))
                let output = try #require(
                    image.value(row: row, column: column, channel: channel)
                )
                // Bit patterns, not ==: -0.0 == 0.0 is true in Float, and the
                // point of this test is that the exact value survives.
                #expect(output.bitPattern == native.bitPattern,
                        "row \(row), column \(column), channel \(channel)")
            }
        }

        // The negative zero really is in there and really did survive.
        #expect(try #require(image.value(row: 0, column: 0, channel: .red)).bitPattern
                == Float(-0.0).bitPattern)
        #expect(try #require(image.value(row: 3, column: 3, channel: .blue)) == 1e20)
    }

    // MARK: - Interpolation at a red location

    @Test("At a red location, green is the axial mean and blue the diagonal mean")
    func redSiteInterpolation() throws {
        // A 5×5 RGGB mosaic. (2, 2) is a red location; its four axial
        // neighbours are green and its four diagonal neighbours are blue.
        //
        //        c0    c1    c2    c3    c4
        //   r1          10     1    20
        //   r2           3     7     4
        //   r3          30     2    40
        var values = [Float](repeating: 0, count: 25)
        func set(_ row: Int, _ column: Int, _ value: Float) { values[row * 5 + column] = value }
        set(2, 2, 7)                                        // native red
        set(1, 2, 1); set(3, 2, 2); set(2, 1, 3); set(2, 3, 4)   // N S W E, green
        set(1, 1, 10); set(1, 3, 20); set(3, 1, 30); set(3, 3, 40) // NW NE SW SE, blue

        let image = try RAWDemosaicer().demosaic(Self.mosaic(width: 5, height: 5, values: values))
        let pixel = try #require(image.pixel(row: 2, column: 2))

        #expect(pixel.red == 7)                                  // the native sample
        #expect(pixel.green == Float(1 + 2 + 3 + 4) / 4)         // 2.5
        #expect(pixel.blue == Float(10 + 20 + 30 + 40) / 4)      // 25
    }

    // MARK: - Interpolation at a blue location

    @Test("At a blue location, green is the axial mean and red the diagonal mean")
    func blueSiteInterpolation() throws {
        // Mirror of the red case. (1, 1) is a blue location in RGGB.
        var values = [Float](repeating: 0, count: 25)
        func set(_ row: Int, _ column: Int, _ value: Float) { values[row * 5 + column] = value }
        set(1, 1, 9)                                        // native blue
        set(0, 1, 1); set(2, 1, 2); set(1, 0, 3); set(1, 2, 4)   // N S W E, green
        set(0, 0, 10); set(0, 2, 20); set(2, 0, 30); set(2, 2, 40) // NW NE SW SE, red

        let image = try RAWDemosaicer().demosaic(Self.mosaic(width: 5, height: 5, values: values))
        let pixel = try #require(image.pixel(row: 1, column: 1))

        #expect(pixel.blue == 9)
        #expect(pixel.green == Float(1 + 2 + 3 + 4) / 4)         // 2.5
        #expect(pixel.red == Float(10 + 20 + 30 + 40) / 4)       // 25
    }

    // MARK: - The two green orientations

    @Test("The two green locations interpolate on opposite axes, as their phase dictates")
    func bothGreenOrientations() throws {
        // Value = channelBase + row * 10 + column, with red at 0, green at
        // 1000 and blue at 2000, so a channel swap or a wrong axis is
        // immediately visible in the magnitude.
        let source = Self.mosaic(width: 5, height: 5) { row, column in
            let base: Float
            switch Self.rggbChannel(row: row, column: column) {
            case .red: base = 0
            case .green: base = 1000
            case .blue: base = 2000
            }
            return base + Float(row * 10 + column)
        }
        let image = try RAWDemosaicer().demosaic(source)

        // (2, 1): even row, odd column. North and south are blue, west and
        // east are red — so red comes from the horizontal pair and blue from
        // the vertical pair.
        let g1 = try #require(image.pixel(row: 2, column: 1))
        #expect(g1.green == 1021)                    // native
        #expect(g1.red == (20 + 22) / 2)             // W (2,0), E (2,2)
        #expect(g1.blue == (2011 + 2031) / 2)        // N (1,1), S (3,1)

        // (1, 2): odd row, even column. The opposite arrangement — north and
        // south are red, west and east are blue.
        let g2 = try #require(image.pixel(row: 1, column: 2))
        #expect(g2.green == 1012)                    // native
        #expect(g2.red == (2 + 22) / 2)              // N (0,2), S (2,2)
        #expect(g2.blue == (2011 + 2013) / 2)        // W (1,1), E (1,3)

        // The two orientations really are different: had one axis been
        // hardcoded, one of these two pixels would have had no contributor of
        // the wanted colour at all.
        #expect(g1.red != g2.red)
        #expect(g1.blue != g2.blue)
    }

    @Test("Every Bayer phase reconstructs the same field, so no phase is hardcoded")
    func everyPhaseReconstructsTheSameField() throws {
        // One underlying constant-per-channel field, sampled through four
        // different CFA phases. The demosaiced result must be the same in all
        // four, because the phase only says where each colour was measured.
        let channelValue: [RAWLinearRGBChannel: Float] = [.red: 0.75, .green: 0.5, .blue: 0.125]
        let layouts: [(String, RAWMetadata.SensorColorLayout, [[Int]])] = [
            ("RGGB", BayerTestLayouts.rggb, [[0, 1], [3, 2]]),
            ("BGGR", BayerTestLayouts.bggr, [[2, 1], [3, 0]]),
            ("GRBG", BayerTestLayouts.grbg, [[1, 0], [2, 3]]),
            ("GBRG", BayerTestLayouts.gbrg, [[1, 2], [0, 3]]),
        ]

        for (name, layout, cell) in layouts {
            // The colour at each position, derived from the cell the test
            // itself declared rather than from the production resolver.
            let letters = Array(BayerTestLayouts.phase(cell))
            func channel(row: Int, column: Int) -> RAWLinearRGBChannel {
                RAWLinearRGBChannel(
                    colorDescriptionLetter: letters[(row % 2) * 2 + (column % 2)]
                )!
            }

            let source = Self.mosaic(width: 8, height: 8, layout: layout) { row, column in
                channelValue[channel(row: row, column: column)]!
            }
            let image = try RAWDemosaicer().demosaic(source)

            for row in 0..<8 {
                for column in 0..<8 {
                    let pixel = try #require(image.pixel(row: row, column: column))
                    #expect(pixel.red == 0.75, "\(name) (\(row), \(column))")
                    #expect(pixel.green == 0.5, "\(name) (\(row), \(column))")
                    #expect(pixel.blue == 0.125, "\(name) (\(row), \(column))")
                }
            }
            #expect(image.processing.sourcePattern.phaseDescription == name)
        }
    }

    // MARK: - Whole-algorithm invariants

    @Test("A constant field stays constant everywhere, borders and corners included")
    func constantFieldIsPreserved() throws {
        // Odd dimensions so every corner sits on a different CFA parity, and
        // both a partial row and a partial column exist at the far edges.
        for constant in [Float(0.25), 1.5, -0.75, 0] {
            let source = Self.mosaic(width: 7, height: 5) { _, _ in constant }
            let image = try RAWDemosaicer().demosaic(source)

            for row in 0..<5 {
                for column in 0..<7 {
                    let pixel = try #require(image.pixel(row: row, column: column))
                    // Exact, not approximate: a mean of one, two or four
                    // copies of a dyadic value is that value in Double, and
                    // narrowing it back is exact.
                    #expect(pixel.red == constant, "\(constant) at (\(row), \(column))")
                    #expect(pixel.green == constant, "\(constant) at (\(row), \(column))")
                    #expect(pixel.blue == constant, "\(constant) at (\(row), \(column))")
                }
            }
        }
    }

    @Test("A linear field is reproduced exactly across the interior")
    func affineFieldIsReproducedInTheInterior() throws {
        // R, G and B are each an affine function of row and column, with
        // deliberately different gradients — including a negative one — so
        // that a channel swap, a wrong phase, a wrong green axis or an
        // axial/diagonal confusion all change the answer.
        //
        // Every coefficient is dyadic and every value small, so the means are
        // exact in Double and narrow back to Float exactly. Bilinear
        // interpolation reproduces an affine field exactly wherever the
        // neighbourhood is symmetric, which is everywhere in the interior.
        func field(_ channel: RAWLinearRGBChannel, row: Int, column: Int) -> Float {
            let r = Float(row), c = Float(column)
            switch channel {
            case .red: return 1 + 0.5 * r + 0.25 * c
            case .green: return 2 + 0.25 * r + 0.5 * c
            case .blue: return 4 + 1.0 * r - 0.5 * c
            }
        }

        let width = 9, height = 9
        let source = Self.mosaic(width: width, height: height) { row, column in
            field(Self.rggbChannel(row: row, column: column), row: row, column: column)
        }
        let image = try RAWDemosaicer().demosaic(source)

        // Interior only. At the borders the one-sided contributor policy is a
        // different, deliberate rule, and this property does not hold there.
        for row in 1..<(height - 1) {
            for column in 1..<(width - 1) {
                let pixel = try #require(image.pixel(row: row, column: column))
                #expect(pixel.red == field(.red, row: row, column: column),
                        "red at (\(row), \(column))")
                #expect(pixel.green == field(.green, row: row, column: column),
                        "green at (\(row), \(column))")
                #expect(pixel.blue == field(.blue, row: row, column: column),
                        "blue at (\(row), \(column))")
            }
        }
    }

    // MARK: - G1 and G2 stay independent

    @Test("G1 and G2 keep their own white-balanced values through demosaicing")
    func greenPlanesRemainIndependent() throws {
        // A four-plane RGBG mosaic: plane 1 greens hold one value, plane 3
        // greens a clearly different one. They are then white-balanced with
        // different gains through the real white-balance stage, so the two
        // greens genuinely differ by the time demosaicing sees them.
        let layout = BayerTestLayouts.rggb
        let g1Sample: Float = 0.25
        let g2Sample: Float = 0.75
        let width = 8, height = 8

        var values = [Float]()
        for row in 0..<height {
            for column in 0..<width {
                switch layout.colorPlaneIndex(row: row, column: column) {
                case 0: values.append(0.5)      // red
                case 1: values.append(g1Sample) // G1
                case 2: values.append(0.125)    // blue
                default: values.append(g2Sample) // G2
                }
            }
        }
        let linear = LinearRAWMosaic(
            width: width, height: height, values: values,
            sensorColorLayout: layout, processing: Self.linearProcessing
        )

        let gains = RAWWhiteBalanceGains(plane0: 2, plane1: 4, plane2: 8, plane3: 16)
        let balanced = try RAWWhiteBalancer().apply(to: linear, gains: gains)
        let balancedG1 = g1Sample * 4      // 1.0
        let balancedG2 = g2Sample * 16     // 12.0
        #expect(balancedG1 != balancedG2)

        let image = try RAWDemosaicer().demosaic(balanced)

        for row in 0..<height {
            for column in 0..<width {
                let plane = try #require(layout.colorPlaneIndex(row: row, column: column))
                let green = try #require(image.value(row: row, column: column, channel: .green))
                switch plane {
                case 1:
                    // A G1 location keeps its own G1-balanced value exactly.
                    #expect(green.bitPattern == balancedG1.bitPattern,
                            "G1 at (\(row), \(column))")
                case 3:
                    // A G2 location keeps its own G2-balanced value exactly.
                    #expect(green.bitPattern == balancedG2.bitPattern,
                            "G2 at (\(row), \(column))")
                default:
                    // A red or blue location interpolates spatially, from
                    // whichever greens surround it. In the interior that is
                    // two of each kind, so the mean is halfway between them —
                    // a spatial result, not a global reconciliation.
                    if row > 0, row < height - 1, column > 0, column < width - 1 {
                        #expect(green == (balancedG1 * 2 + balancedG2 * 2) / 4,
                                "interpolated at (\(row), \(column))")
                    }
                }
            }
        }

        // Nothing anywhere forced the two greens to agree: both values are
        // still present in the output, unchanged.
        let greens = Set((0..<height).flatMap { row in
            (0..<width).compactMap { column in
                image.value(row: row, column: column, channel: .green)
            }
        })
        #expect(greens.contains(balancedG1))
        #expect(greens.contains(balancedG2))
    }

    // MARK: - Borders

    @Test("Borders average only their real contributors, never a fixed four")
    func borderDenominatorsMatchContributorCounts() throws {
        // A 4×4 RGGB mosaic with a distinct value everywhere, so a wrong
        // denominator cannot coincidentally produce the right answer.
        //
        //         c0   c1   c2   c3
        //   r0     R    G    R    G
        //   r1     G    B    G    B
        //   r2     R    G    R    G
        //   r3     G    B    G    B
        let source = Self.mosaic(width: 4, height: 4) { row, column in
            Float((row * 4 + column + 1) * 3)
        }
        func sample(_ row: Int, _ column: Int) -> Float { Float((row * 4 + column + 1) * 3) }
        let image = try RAWDemosaicer().demosaic(source)

        // Top-left corner, a red location: two axial greens (S, E) and one
        // diagonal blue (SE). Dividing by four would give a quarter and a
        // half of these.
        let topLeft = try #require(image.pixel(row: 0, column: 0))
        #expect(topLeft.red == sample(0, 0))
        #expect(topLeft.green == (sample(1, 0) + sample(0, 1)) / 2)
        #expect(topLeft.blue == sample(1, 1))

        // Top edge, a red location: three axial greens (S, W, E), two
        // diagonal blues (SW, SE).
        let topEdge = try #require(image.pixel(row: 0, column: 2))
        #expect(topEdge.red == sample(0, 2))
        #expect(topEdge.green == (sample(1, 2) + sample(0, 1) + sample(0, 3)) / 3)
        #expect(topEdge.blue == (sample(1, 1) + sample(1, 3)) / 2)

        // Left edge, a red location: three axial greens (N, S, E), two
        // diagonal blues (NE, SE).
        let leftEdge = try #require(image.pixel(row: 2, column: 0))
        #expect(leftEdge.red == sample(2, 0))
        #expect(leftEdge.green == (sample(1, 0) + sample(3, 0) + sample(2, 1)) / 3)
        #expect(leftEdge.blue == (sample(1, 1) + sample(3, 1)) / 2)

        // Bottom-right corner, a blue location: two axial greens (N, W), one
        // diagonal red (NW).
        let bottomRight = try #require(image.pixel(row: 3, column: 3))
        #expect(bottomRight.blue == sample(3, 3))
        #expect(bottomRight.green == (sample(2, 3) + sample(3, 2)) / 2)
        #expect(bottomRight.red == sample(2, 2))

        // Every location still produced exactly one pixel: nothing cropped.
        #expect(image.width == 4)
        #expect(image.height == 4)
        #expect(image.values.count == 4 * 4 * 3)
    }

    @Test("A minimal 2x2 Bayer cell demosaics completely")
    func minimalTwoByTwoIsDemosaicable() throws {
        //   R(1)  G(2)
        //   G(4)  B(8)
        let source = Self.mosaic(width: 2, height: 2, values: [1, 2, 4, 8])
        let image = try RAWDemosaicer().demosaic(source)

        #expect(image.width == 2)
        #expect(image.height == 2)

        let red = try #require(image.pixel(row: 0, column: 0))
        #expect(red.red == 1)
        #expect(red.green == (4 + 2) / 2)
        #expect(red.blue == 8)

        let greenTop = try #require(image.pixel(row: 0, column: 1))
        #expect(greenTop.green == 2)
        #expect(greenTop.red == 1)    // west only
        #expect(greenTop.blue == 8)   // south only

        let greenLeft = try #require(image.pixel(row: 1, column: 0))
        #expect(greenLeft.green == 4)
        #expect(greenLeft.red == 1)   // north only
        #expect(greenLeft.blue == 8)  // east only

        let blue = try #require(image.pixel(row: 1, column: 1))
        #expect(blue.blue == 8)
        #expect(blue.green == (2 + 4) / 2)
        #expect(blue.red == 1)
    }

    @Test("A geometry with no contributor for a channel fails with its coordinate")
    func missingNeighborsAreReported() throws {
        // 1×1: the single red location has no neighbour of any kind.
        #expect {
            _ = try RAWDemosaicer().demosaic(Self.mosaic(width: 1, height: 1, values: [1]))
        } throws: { error in
            guard case .missingDemosaicNeighbors(let row, let column, let channel) =
                    error as? RAWProcessingError else { return false }
            return row == 0 && column == 0 && channel == .green
        }

        // A single row: green exists to the east, but no row above or below
        // means no diagonal blue anywhere.
        #expect {
            _ = try RAWDemosaicer().demosaic(Self.mosaic(width: 4, height: 1, values: [1, 2, 3, 4]))
        } throws: { error in
            guard case .missingDemosaicNeighbors(let row, let column, let channel) =
                    error as? RAWProcessingError else { return false }
            return row == 0 && column == 0 && channel == .blue
        }

        // A single column, likewise.
        #expect {
            _ = try RAWDemosaicer().demosaic(Self.mosaic(width: 1, height: 4, values: [1, 2, 3, 4]))
        } throws: { error in
            guard case .missingDemosaicNeighbors(_, _, let channel) =
                    error as? RAWProcessingError else { return false }
            return channel == .blue
        }
    }

    // MARK: - Arithmetic

    @Test("Interpolation succeeds where a Float32 sum of the contributors would overflow")
    func doubleAccumulationAvoidsArtificialOverflow() throws {
        let huge = Float.greatestFiniteMagnitude
        // Two of these already overflow Float32 when added, four all the
        // more so — yet every mean below is perfectly representable.
        #expect(!(huge + huge).isFinite)

        // All four axial greens around the red location at (2, 2).
        var allFour = [Float](repeating: 1, count: 25)
        for (row, column) in [(1, 2), (3, 2), (2, 1), (2, 3)] { allFour[row * 5 + column] = huge }
        let fourImage = try RAWDemosaicer().demosaic(
            Self.mosaic(width: 5, height: 5, values: allFour)
        )
        // Sum 1.36e39 in Double, mean exactly the maximum.
        let fromFour = try #require(fourImage.value(row: 2, column: 2, channel: .green))
        #expect(fromFour == huge)
        #expect(fromFour.isFinite)

        // Two of the four axial greens around the blue location at (1, 1),
        // the other two at 1: their Float32 sum still overflows, their mean
        // does not.
        var twoOfFour = [Float](repeating: 1, count: 25)
        for (row, column) in [(0, 1), (1, 0)] { twoOfFour[row * 5 + column] = huge }
        let mixedImage = try RAWDemosaicer().demosaic(
            Self.mosaic(width: 5, height: 5, values: twoOfFour)
        )
        let mixed = try #require(mixedImage.value(row: 1, column: 1, channel: .green))
        #expect(mixed.isFinite)
        #expect(mixed == Float((Double(huge) + Double(huge) + 1 + 1) / 4))

        // Storage is still Float32 throughout — the Double is an accumulator,
        // not a representation.
        #expect(fourImage.values.count == 5 * 5 * 3)
        #expect(RGBImageStatistics(image: fourImage).nonFiniteCount == 0)
    }

    @Test("Non-finite samples fail with the offending coordinate, native or contributor")
    func nonFiniteSamplesAreReported() throws {
        // A NaN at a red location. Scanning reaches (1, 2) first, whose axial
        // red neighbours include (2, 2) — so the reported coordinate is the
        // contributor's own, not the pixel being written.
        var values = [Float](repeating: 1, count: 25)
        values[2 * 5 + 2] = .nan
        #expect {
            _ = try RAWDemosaicer().demosaic(Self.mosaic(width: 5, height: 5, values: values))
        } throws: { error in
            guard case .nonFiniteInputValue(let row, let column, let value) =
                    error as? RAWProcessingError else { return false }
            return row == 2 && column == 2 && value.isNaN
        }

        // An infinity at the very first location, reached as a native sample.
        var infinite = [Float](repeating: 1, count: 25)
        infinite[0] = .infinity
        #expect {
            _ = try RAWDemosaicer().demosaic(Self.mosaic(width: 5, height: 5, values: infinite))
        } throws: { error in
            guard case .nonFiniteInputValue(let row, let column, let value) =
                    error as? RAWProcessingError else { return false }
            return row == 0 && column == 0 && value == .infinity
        }

        // Nothing is emitted as NaN or infinity, and nothing is skipped: the
        // stage fails outright rather than producing a shorter buffer.
        var negativeInfinity = [Float](repeating: 1, count: 25)
        negativeInfinity[12] = -.infinity
        #expect(throws: RAWProcessingError.self) {
            _ = try RAWDemosaicer().demosaic(
                Self.mosaic(width: 5, height: 5, values: negativeInfinity)
            )
        }
    }

    @Test("Nothing is clamped: values below zero and above one survive interpolation")
    func nothingIsClamped() throws {
        let source = Self.mosaic(width: 6, height: 6) { row, column in
            // A ramp from clearly negative to clearly above one.
            Float(row * 6 + column) * 0.1 - 1.0
        }
        let image = try RAWDemosaicer().demosaic(source)

        let statistics = RGBImageStatistics(image: image)
        #expect(statistics.nonFiniteCount == 0)
        for channel in RAWLinearRGBChannel.allCases {
            #expect(statistics[channel].minimum < 0, "\(channel)")
            #expect(statistics[channel].maximum > 1, "\(channel)")
            #expect(statistics[channel].belowZeroCount > 0, "\(channel)")
            #expect(statistics[channel].aboveOneCount > 0, "\(channel)")
        }
        #expect(!image.processing.clamped)

        // A mean of negatives is negative, not zero.
        let interpolated = try #require(image.value(row: 1, column: 1, channel: .green))
        #expect(interpolated < 0)
    }

    // MARK: - Provenance

    @Test("Provenance states what this stage added and what it did not")
    func provenanceRecordsTheStageBoundary() throws {
        let gains = RAWWhiteBalanceGains(plane0: 2, plane1: 3, plane2: 4, plane3: 5)
        let linear = LinearRAWMosaic(
            width: 4, height: 4,
            values: (0..<16).map { Float($0) / 16 },
            sensorColorLayout: BayerTestLayouts.rggb,
            processing: Self.linearProcessing
        )
        let balanced = try RAWWhiteBalancer().apply(to: linear, gains: gains)
        let processing = try RAWDemosaicer().demosaic(balanced).processing

        #expect(processing.demosaiced)
        #expect(processing.whiteBalanceApplied)
        #expect(!processing.clamped)
        #expect(!processing.cameraColorMatrixApplied)
        #expect(!processing.gammaApplied)
        #expect(!processing.orientationApplied)

        // Upstream facts are read through the upstream record, not copied.
        #expect(processing.blackLevelSubtracted)
        #expect(processing.normalized)
        #expect(processing.whiteBalanceGains == gains)
        #expect(processing.whiteBalanceProcessing.gainSource == .explicit)
        #expect(processing.whiteBalanceProcessing.linearProcessing.whiteLevel == 4095)

        #expect(processing.algorithm == .bilinearBayer)
        #expect(processing.sourcePattern.phaseDescription == "RGGB")
    }

    @Test("No camera colour information reaches or affects this stage")
    func cameraColourMetadataHasNoEffect() throws {
        // Two runs of the identical pipeline whose only difference is the
        // file's colour metadata: camera multipliers, daylight multipliers
        // and both matrices. If any of it leaked in, the buffers would differ.
        func run(color: RAWMetadata.ColorMetadata) throws -> [Float] {
            var metadata = RAWTestData.metadata()
            metadata.color = color
            let samples: [UInt16] = (0..<16).map { UInt16(200 + $0 * 100) }
            let mosaic = samples.withUnsafeBufferPointer { buffer in
                RAWMosaic(
                    width: 4, height: 4, bytesPerRow: 8, samples: Data(buffer: buffer),
                    sampleFormat: .uint16, sourceRawBitDepth: 12,
                    sensorColorLayout: BayerTestLayouts.rggb
                )
            }
            let decoded = DecodedRAWMosaic(
                url: URL(fileURLWithPath: "/dev/null"),
                metadata: metadata,
                mosaic: mosaic,
                processing: RAWMosaicProcessing(
                    decoderIdentifier: "Stub", sourceStorage: .singleChannel,
                    sourceRowPitch: 8, destinationRowStride: 8
                )
            )
            let processed = try RAWMosaicNormalizer().process(decoded)
            let balanced = try RAWWhiteBalancer().apply(to: processed, gains: .identity)
            return try RAWDemosaicer().demosaic(balanced).image.values
        }

        let plain = try run(color: RAWMetadata.ColorMetadata())
        let loaded = try run(color: RAWMetadata.ColorMetadata(
            cameraMultipliers: [0.64, 1.0, 5.56, 0],
            daylightMultipliers: [2.26, 0.93, 1.21, 0],
            rgbFromCamera: [[2, -1, 0, 0], [-0.5, 1.7, -0.2, 0], [0.1, -0.9, 1.8, 0]],
            cameraFromXYZ: [[0.7, -0.2, -0.1], [-0.4, 1.3, 0.1], [-0.1, 0.2, 0.6], [0, 0, 0]]
        ))

        #expect(plain == loaded)
        #expect(!plain.isEmpty)
    }

    // MARK: - Unsupported layouts through the demosaicer

    @Test("Unsupported layouts fail at the demosaicer, with no fallback")
    func unsupportedLayoutsFailThroughTheAPI() throws {
        let xTrans = RAWMetadata.SensorColorLayout(
            pattern: .xTrans, filters: 9, colorDescription: "RGBG", colorCount: 3,
            xTransPattern: Array(repeating: [1, 1, 0, 1, 1, 2], count: 6)
        )
        #expect {
            _ = try RAWDemosaicer().demosaic(
                Self.mosaic(width: 6, height: 6,
                            values: [Float](repeating: 1, count: 36), layout: xTrans)
            )
        } throws: { error in
            guard case .unsupportedSensorLayoutForDemosaicing(let pattern, let algorithm, _) =
                    error as? RAWProcessingError else { return false }
            return pattern == .xTrans && algorithm == .bilinearBayer
        }

        for pattern in [RAWMetadata.SensorColorLayout.Pattern.foveon, .none, .unknown] {
            let layout = RAWMetadata.SensorColorLayout(
                pattern: pattern, filters: 0, colorDescription: "RGBG", colorCount: 3
            )
            #expect(throws: RAWProcessingError.self) {
                _ = try RAWDemosaicer().demosaic(
                    Self.mosaic(width: 4, height: 4,
                                values: [Float](repeating: 1, count: 16), layout: layout)
                )
            }
        }
    }

    @Test("Inconsistent geometry is refused rather than read past the buffer")
    func inconsistentGeometryIsRefused() throws {
        // Declares 4×4 but holds four values.
        let short = Self.mosaic(width: 4, height: 4, values: [1, 2, 3, 4])
        #expect(throws: RAWProcessingError.self) {
            _ = try RAWDemosaicer().demosaic(short)
        }
    }

    // MARK: - Storage contract

    @Test("Storage is exactly three interleaved Float32 per pixel")
    func storageIsInterleavedRGB() throws {
        //   R(1)  G(2)
        //   G(4)  B(8)
        let image = try RAWDemosaicer().demosaic(
            Self.mosaic(width: 2, height: 2, values: [1, 2, 4, 8])
        )

        #expect(image.values.count == 2 * 2 * 3)
        #expect(image.expectedValueCount == 12)
        #expect(image.pixelCount == 4)
        #expect(image.valuesPerRow == 6)
        #expect(image.isGeometryConsistent)
        #expect(DemosaicedRAWRGBImage.channelCount == 3)

        // The raw storage order itself, not just what the accessor returns.
        #expect(image.values == [
            1, 3, 8,   // (0,0) R: native 1, green (4+2)/2, blue 8
            1, 2, 8,   // (0,1) G: red 1, native 2, blue 8
            1, 4, 8,   // (1,0) G: red 1, native 4, blue 8
            1, 3, 8,   // (1,1) B: red 1, green (2+4)/2, native 8
        ])

        // The accessor agrees with the layout it documents.
        for row in 0..<2 {
            for column in 0..<2 {
                let base = try #require(image.storageIndex(row: row, column: column))
                #expect(base == (row * 2 + column) * 3)
                let pixel = try #require(image.pixel(row: row, column: column))
                #expect(pixel.red == image.values[base])
                #expect(pixel.green == image.values[base + 1])
                #expect(pixel.blue == image.values[base + 2])
                #expect(image.value(row: row, column: column, channel: .red) == pixel.red)
                #expect(image.value(row: row, column: column, channel: .green) == pixel.green)
                #expect(image.value(row: row, column: column, channel: .blue) == pixel.blue)
            }
        }

        // Out of bounds returns nil rather than trapping.
        #expect(image.pixel(row: -1, column: 0) == nil)
        #expect(image.pixel(row: 0, column: 2) == nil)
        #expect(image.value(row: 2, column: 0, channel: .red) == nil)
        #expect(image.storageIndex(row: 0, column: -1) == nil)
    }

    @Test("Malformed geometry is reported, not trapped")
    func malformedGeometryNeverTraps() {
        // Both multiplications overflow-check independently.
        let hugePixels = DemosaicedRAWRGBImage(
            width: Int.max, height: 2, values: [],
            processing: RAWDemosaicProcessing(
                algorithm: .bilinearBayer,
                sourcePattern: RAWBayerCellPattern(
                    topLeft: .red, topRight: .green, bottomLeft: .green, bottomRight: .blue
                ),
                whiteBalanceProcessing: Self.whiteBalanceProcessing()
            )
        )
        #expect(hugePixels.pixelCount == nil)
        #expect(hugePixels.expectedValueCount == nil)
        #expect(hugePixels.valuesPerRow == nil)
        #expect(!hugePixels.isGeometryConsistent)
        #expect(hugePixels.pixel(row: 0, column: 0) == nil)

        // The pixel count fits; three channels of it do not. Assuming the
        // second multiplication is safe because the first was would trap here.
        let hugeChannels = DemosaicedRAWRGBImage(
            width: Int.max / 3 + 1, height: 1, values: [],
            processing: hugePixels.processing
        )
        #expect(hugeChannels.pixelCount != nil)
        #expect(hugeChannels.expectedValueCount == nil)
        #expect(!hugeChannels.isGeometryConsistent)
        #expect(hugeChannels.pixel(row: 0, column: 0) == nil)

        // Non-positive and short-buffer geometry.
        let empty = DemosaicedRAWRGBImage(
            width: 0, height: 0, values: [], processing: hugePixels.processing
        )
        #expect(!empty.isGeometryConsistent)
        #expect(empty.pixel(row: 0, column: 0) == nil)

        // A buffer shorter than the declared geometry. Accessors report what
        // is genuinely present and `nil` for what is not, matching how
        // LinearRAWMosaic and WhiteBalancedRAWMosaic behave — the contract is
        // that nothing traps, not that a partial buffer becomes unreadable.
        // `isGeometryConsistent` is the check a processing stage makes, and
        // RAWDemosaicer makes it.
        let short = DemosaicedRAWRGBImage(
            width: 4, height: 4, values: [1, 2, 3], processing: hugePixels.processing
        )
        #expect(!short.isGeometryConsistent)
        #expect(short.pixel(row: 0, column: 0) == RAWLinearRGBPixel(red: 1, green: 2, blue: 3))
        #expect(short.pixel(row: 0, column: 1) == nil)
        #expect(short.value(row: 3, column: 3, channel: .blue) == nil)
        #expect(short.value(row: 0, column: 3, channel: .red) == nil)
    }

    // MARK: - Reprocessing

    @Test("The wrapper keeps the whole upstream chain reachable")
    func wrapperRetainsUpstreamState() throws {
        let samples: [UInt16] = [400, 800, 1200, 1600]
        let mosaic = samples.withUnsafeBufferPointer { buffer in
            RAWMosaic(
                width: 2, height: 2, bytesPerRow: 4, samples: Data(buffer: buffer),
                sampleFormat: .uint16, sourceRawBitDepth: 12,
                sensorColorLayout: BayerTestLayouts.rggb
            )
        }
        var metadata = RAWTestData.metadata()
        metadata.sensor = BayerTestLayouts.rggb
        let decoded = DecodedRAWMosaic(
            url: URL(fileURLWithPath: "/dev/null"),
            metadata: metadata, mosaic: mosaic,
            processing: RAWMosaicProcessing(
                decoderIdentifier: "Stub", sourceStorage: .singleChannel,
                sourceRowPitch: 4, destinationRowStride: 4
            )
        )

        let normalized = try RAWMosaicNormalizer().process(decoded)
        let balanced = try RAWWhiteBalancer().apply(
            to: normalized, gains: RAWWhiteBalanceGains(plane0: 2, plane1: 3, plane2: 4, plane3: 5)
        )
        let result = try RAWDemosaicer().demosaic(balanced)

        // Every earlier representation is still there, unchanged.
        #expect(result.whiteBalancedMosaic.values == balanced.mosaic.values)
        #expect(result.linearMosaic.values == normalized.mosaic.values)
        #expect(result.source.source.source.mosaic == mosaic)
        #expect(result.metadata.identity.model == metadata.identity.model)
        #expect(result.url == decoded.url)
        #expect(result.processing.algorithm == .bilinearBayer)

        // Changing the gains restarts from the normalised mosaic and then
        // demosaics again — not from the RGB buffer, which cannot be undone.
        let rebalanced = try RAWWhiteBalancer().apply(gains: .identity, replacing: result.source)
        let redemosaiced = try RAWDemosaicer().demosaic(rebalanced)
        #expect(redemosaiced.linearMosaic.values == normalized.mosaic.values)
        #expect(redemosaiced.image.values != result.image.values)

        // Demosaicing the same white-balanced mosaic twice is deterministic.
        let again = try RAWDemosaicer().demosaic(balanced)
        #expect(again.image.values == result.image.values)
    }
}
