import Foundation
import Testing
@testable import InfraredConverter

/// What the demosaicing stage will and will not accept as a sensor colour
/// layout, tested before any pixel arithmetic is involved.
///
/// The point of this suite is that `pattern == .bayer` is **not** the test.
/// A layout can be `.bayer` and still be something a 2×2 Bayer algorithm must
/// refuse: a taller repeat, a plane index the colour description cannot name,
/// a filter colour that is not R/G/B, or a cell that is not one red, one blue
/// and two greens.
@Suite("RAWBayerCellPattern")
struct RAWBayerCellPatternTests {

    private func resolve(
        _ layout: RAWMetadata.SensorColorLayout
    ) throws -> RAWBayerCellPattern {
        try RAWBayerCellPattern.resolve(from: layout)
    }

    /// The reason text of an unsupported-layout error, or `nil` for any other
    /// outcome. Used so a test can assert *why* a layout was refused rather
    /// than only that something threw.
    private func unsupportedReason(
        _ layout: RAWMetadata.SensorColorLayout
    ) -> (pattern: RAWMetadata.SensorColorLayout.Pattern,
          algorithm: RAWDemosaicAlgorithm,
          reason: String)? {
        do {
            _ = try RAWBayerCellPattern.resolve(from: layout)
            return nil
        } catch let error as RAWProcessingError {
            guard case .unsupportedSensorLayoutForDemosaicing(
                let pattern, let algorithm, let reason
            ) = error else { return nil }
            return (pattern, algorithm, reason)
        } catch {
            return nil
        }
    }

    // MARK: - The four ordinary Bayer phases

    @Test("All four Bayer phases are accepted and resolved from the layout, not assumed")
    func allFourPhasesResolve() throws {
        let cases: [(String, RAWMetadata.SensorColorLayout, String)] = [
            ("RGGB", BayerTestLayouts.rggb, "RGGB"),
            ("BGGR", BayerTestLayouts.bggr, "BGGR"),
            ("GRBG", BayerTestLayouts.grbg, "GRBG"),
            ("GBRG", BayerTestLayouts.gbrg, "GBRG"),
        ]

        for (name, layout, expected) in cases {
            let pattern = try resolve(layout)
            #expect(pattern.phaseDescription == expected, "\(name)")

            // Each cell holds one red, one blue and two greens, wherever they
            // happen to sit.
            let channels = pattern.channels
            #expect(channels.filter { $0 == .red }.count == 1, "\(name)")
            #expect(channels.filter { $0 == .blue }.count == 1, "\(name)")
            #expect(channels.filter { $0 == .green }.count == 2, "\(name)")
        }
    }

    @Test("Parity lookup matches the layout's own colour-plane lookup everywhere")
    func parityLookupAgreesWithTheLayout() throws {
        for layout in [BayerTestLayouts.rggb, BayerTestLayouts.bggr,
                       BayerTestLayouts.grbg, BayerTestLayouts.gbrg] {
            let pattern = try resolve(layout)
            let letters = Array(layout.colorDescription)
            for row in 0..<9 {
                for column in 0..<9 {
                    let plane = try #require(layout.colorPlaneIndex(row: row, column: column))
                    let expected = try #require(
                        RAWLinearRGBChannel(colorDescriptionLetter: letters[plane])
                    )
                    #expect(pattern.channel(row: row, column: column) == expected)
                }
            }
        }
    }

    @Test("Negative coordinates wrap onto the cell rather than trapping")
    func negativeCoordinatesWrap() throws {
        let pattern = try resolve(BayerTestLayouts.rggb)
        #expect(pattern.channel(row: -2, column: -2) == pattern.channel(row: 0, column: 0))
        #expect(pattern.channel(row: -1, column: -1) == pattern.channel(row: 1, column: 1))
        #expect(pattern.channel(rowParity: -1, columnParity: -1) == pattern.bottomRight)
    }

    // MARK: - Three-plane and four-plane green representations

    @Test("A three-plane Bayer layout, both greens on plane 1, still resolves to R/G/G/B")
    func threePlaneGreenResolves() throws {
        let layout = BayerTestLayouts.rggbThreePlane
        // Plane 3 is genuinely never produced by this layout.
        var producedPlanes = Set<Int>()
        for row in 0..<8 {
            for column in 0..<2 {
                producedPlanes.insert(try #require(layout.colorPlaneIndex(row: row, column: column)))
            }
        }
        #expect(producedPlanes == [0, 1, 2])

        let pattern = try resolve(layout)
        #expect(pattern.phaseDescription == "RGGB")
        #expect(pattern.topRight == .green)
        #expect(pattern.bottomLeft == .green)
    }

    @Test("A four-plane RGBG layout maps plane 1 and plane 3 to the same output green")
    func fourPlaneGreenCollapsesToOneChannel() throws {
        let layout = BayerTestLayouts.rggb
        // The two green positions really are different plane indices.
        #expect(layout.colorPlaneIndex(row: 0, column: 1) == 1)
        #expect(layout.colorPlaneIndex(row: 1, column: 0) == 3)
        #expect(layout.colorCount == 3)

        let pattern = try resolve(layout)
        #expect(pattern.topRight == .green)
        #expect(pattern.bottomLeft == .green)
        // Same output channel, so the same storage offset.
        #expect(pattern.topRight.storageOffset == pattern.bottomLeft.storageOffset)
    }

    @Test("A three-plane and a four-plane green layout resolve identically")
    func threeAndFourPlaneGreensAgree() throws {
        #expect(try resolve(BayerTestLayouts.rggb) == resolve(BayerTestLayouts.rggbThreePlane))
    }

    // MARK: - Packed cells that are not 2×2

    @Test("A packed Bayer cell whose later rows differ is refused, not treated as 2x2")
    func nonRepeatingPackedCellIsRefused() throws {
        // Rows 0...1 are RGGB; rows 2...3 swap red and blue. The code is a
        // perfectly valid `.bayer` filters value, and every position names a
        // plane — it simply does not repeat every two rows.
        let layout = BayerTestLayouts.layout(cell: [[0, 1], [3, 2], [2, 1], [3, 0]])
        #expect(layout.colorPlaneIndex(row: 0, column: 0) == 0)
        #expect(layout.colorPlaneIndex(row: 2, column: 0) == 2)

        let failure = try #require(unsupportedReason(layout))
        #expect(failure.pattern == .bayer)
        #expect(failure.algorithm == .bilinearBayer)
        #expect(failure.reason.contains("repeat"))
    }

    @Test("A four-row cell whose second half differs semantically is refused")
    func fourRowRepeatIsRefused() throws {
        // Rows 0...1 are RGGB; rows 2...3 are R G / G R — no blue at all in
        // the lower half.
        let layout = BayerTestLayouts.layout(cell: [[0, 1], [3, 2], [0, 1], [3, 0]])
        let failure = try #require(unsupportedReason(layout))
        #expect(failure.reason.contains("repeat"))
    }

    @Test("Repeat validity is judged on colour, not on plane index")
    func repeatIsJudgedSemantically() throws {
        // Rows 0...1 put G1 top-right and G2 bottom-left; rows 2...3 swap
        // which green plane sits where. The plane indices differ between the
        // halves, the colours do not, and demosaicing only reads colours —
        // the two green planes were already told apart by white balance,
        // upstream, and each green sample is copied to output green either
        // way. So this is a genuine 2x2 mosaic and must be accepted.
        let layout = BayerTestLayouts.layout(cell: [[0, 1], [3, 2], [0, 3], [1, 2]])
        #expect(layout.colorPlaneIndex(row: 0, column: 1) == 1)
        #expect(layout.colorPlaneIndex(row: 2, column: 1) == 3)

        let pattern = try resolve(layout)
        #expect(pattern.phaseDescription == "RGGB")
    }

    // MARK: - Colour descriptions the algorithm cannot use

    @Test("A plane index colorDescription cannot name is refused")
    func unnameablePlaneIndexIsRefused() throws {
        // The CFA produces plane 3, but the description only describes three.
        let layout = BayerTestLayouts.layout(
            cell: [[0, 1], [3, 2]], colorDescription: "RGB", colorCount: 3
        )
        let failure = try #require(unsupportedReason(layout))
        #expect(failure.reason.contains("colorDescription"))
    }

    @Test("A filter colour that is not R, G or B is refused rather than mapped onto one")
    func nonRGBFilterColourIsRefused() throws {
        // An RGBE sensor: the fourth filter is emerald. Nothing here may
        // quietly fold it onto green.
        let rgbe = BayerTestLayouts.layout(
            cell: [[0, 1], [3, 2]], colorDescription: "RGBE", colorCount: 4
        )
        let emerald = try #require(unsupportedReason(rgbe))
        #expect(emerald.reason.contains("\"E\""))

        // A CMY-filtered sensor, likewise.
        let cmyg = BayerTestLayouts.layout(
            cell: [[0, 1], [3, 2]], colorDescription: "CMYG", colorCount: 4
        )
        #expect(unsupportedReason(cmyg) != nil)
    }

    @Test("A cell that is not one red, one blue and two greens is refused")
    func wrongChannelCountsAreRefused() throws {
        // Two reds and no blue: a valid packed code, a valid description, and
        // not a Bayer cell.
        let twoReds = BayerTestLayouts.layout(cell: [[0, 1], [3, 0]])
        let failure = try #require(unsupportedReason(twoReds))
        #expect(failure.reason.contains("exactly one red"))

        // All four positions red.
        #expect(unsupportedReason(BayerTestLayouts.layout(cell: [[0, 0], [0, 0]])) != nil)
        // Three greens, no blue.
        #expect(unsupportedReason(BayerTestLayouts.layout(cell: [[0, 1], [1, 3]])) != nil)
    }

    // MARK: - Layouts that are not Bayer at all

    @Test("X-Trans is recognised by name and refused by this algorithm, not by the project")
    func xTransIsRecognisedAndRefused() throws {
        let layout = RAWMetadata.SensorColorLayout(
            pattern: .xTrans,
            filters: 9,
            colorDescription: "RGBG",
            colorCount: 3,
            sourceRawBitDepth: 14,
            xTransPattern: [
                [1, 1, 0, 1, 1, 2],
                [1, 1, 2, 1, 1, 0],
                [2, 0, 1, 0, 2, 1],
                [1, 1, 2, 1, 1, 0],
                [1, 1, 0, 1, 1, 2],
                [0, 2, 1, 2, 0, 1],
            ]
        )

        let failure = try #require(unsupportedReason(layout))
        #expect(failure.pattern == .xTrans)
        #expect(failure.algorithm == .bilinearBayer)
        // The message must say the layout is understood and that it is the
        // algorithm that cannot handle it.
        #expect(failure.reason.contains("X-Trans"))
        #expect(failure.reason.contains("recognised"))
        #expect(failure.reason.contains("bilinearBayer"))

        // And it is refused outright: no 2×2 subset, no downsample, no
        // fallback to another algorithm.
        #expect(throws: RAWProcessingError.self) {
            _ = try RAWBayerCellPattern.resolve(from: layout)
        }
    }

    @Test("Foveon, full-colour and unknown layouts are refused with their own reasons")
    func nonMosaicLayoutsAreRefused() throws {
        func layout(_ pattern: RAWMetadata.SensorColorLayout.Pattern) -> RAWMetadata.SensorColorLayout {
            RAWMetadata.SensorColorLayout(
                pattern: pattern, filters: 0, colorDescription: "RGBG", colorCount: 3
            )
        }

        let foveon = try #require(unsupportedReason(layout(.foveon)))
        #expect(foveon.pattern == .foveon)
        #expect(foveon.reason.contains("stack"))

        let full = try #require(unsupportedReason(layout(.none)))
        #expect(full.pattern == .none)
        #expect(full.reason.contains("full-colour"))

        let unknown = try #require(unsupportedReason(layout(.unknown)))
        #expect(unknown.pattern == .unknown)
        #expect(unknown.reason.contains("did not describe"))
    }

    @Test("LibRaw's non-standard 16x16 layout (filters == 1) is refused")
    func sixteenBySixteenIsRefused() throws {
        let layout = RAWMetadata.SensorColorLayout(
            pattern: .bayer, filters: 1, colorDescription: "RGBG", colorCount: 3
        )
        let failure = try #require(unsupportedReason(layout))
        #expect(failure.reason.contains("16x16"))
    }
}
