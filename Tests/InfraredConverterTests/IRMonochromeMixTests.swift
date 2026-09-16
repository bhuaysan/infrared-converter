import Testing
import Foundation
@testable import InfraredConverter

/// Monochrome authoring: three contributions to nine coefficients, back
/// again, and what the existing mixer does with the result.
///
/// The claim this milestone rests on is that monochrome is **not** a stage —
/// it is a shape of matrix. So the tests are about the shape (all nine
/// positions, exactly), about recognising it (exactly, with no tolerance), and
/// about the pixels the existing `IRChannelMixer` produces from it. No
/// monochrome arithmetic is written here; the expected values are hand-computed
/// dot products and the implementation under test is the one that already
/// existed.
@Suite("IR monochrome mix")
struct IRMonochromeMixTests {

    /// Deliberately asymmetric, with exact binary fractions, so a transposed
    /// or reordered implementation cannot agree by coincidence and the
    /// arithmetic below can be compared with `==`.
    static let asymmetric = IRMonochromeMix(red: 1.5, green: -0.25, blue: 0.125)

    // MARK: - Three coefficients become nine

    @Test("Three contributions build three identical rows, in every position")
    func threeContributionsBuildIdenticalRows() throws {
        let matrix = try Self.asymmetric.matrix()

        #expect(matrix.m00 == 1.5)
        #expect(matrix.m01 == -0.25)
        #expect(matrix.m02 == 0.125)
        #expect(matrix.m10 == 1.5)
        #expect(matrix.m11 == -0.25)
        #expect(matrix.m12 == 0.125)
        #expect(matrix.m20 == 1.5)
        #expect(matrix.m21 == -0.25)
        #expect(matrix.m22 == 0.125)

        // Read the other way round: every row is the same row.
        #expect(matrix.rows == [
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
        ])
        // Three identical rows are linearly dependent, so the map collapses
        // three channels onto one. That is the point, and nothing refuses it.
        #expect(matrix.determinant == 0)
    }

    /// Columns are input channels. `m02` is how much input blue contributes,
    /// and this is the assertion that fails if the coefficients are ever
    /// written down a column instead of across a row.
    @Test("Contributions are columns: red is column 0, green 1, blue 2")
    func contributionsAreColumns() throws {
        let matrix = try IRMonochromeMix(red: 7, green: 0, blue: 0).matrix()
        #expect(matrix.coefficient(row: 0, column: 0) == 7)
        #expect(matrix.coefficient(row: 1, column: 0) == 7)
        #expect(matrix.coefficient(row: 2, column: 0) == 7)
        #expect(matrix.coefficient(row: 0, column: 1) == 0)
        #expect(matrix.coefficient(row: 0, column: 2) == 0)
    }

    @Test("The adjustment it authors is .explicit, carrying exactly that matrix")
    func theAdjustmentIsExplicit() throws {
        let adjustment = try Self.asymmetric.adjustment()

        guard case .explicit(let matrix) = adjustment else {
            Issue.record("Expected .explicit, got \(adjustment)")
            return
        }
        #expect(matrix == (try Self.asymmetric.matrix()))
        #expect(adjustment.kind == .matrix)
        // The creative processing value, in the one working space — the same
        // provenance any authored matrix gets. There is no monochrome source.
        #expect(adjustment.mix.source == .explicit)
        #expect(adjustment.mix.workingColorSpace == .extendedLinearSRGB)
    }

    /// The nine numbers are the only thing that exists, so a monochrome mix
    /// and the same nine coefficients typed into the 3×3 editor are the same
    /// value — not merely equivalent.
    @Test("A monochrome mix equals the same nine coefficients typed by hand")
    func monochromeEqualsAHandTypedMatrix() throws {
        let authored = try Self.asymmetric.adjustment()
        let typed = UserChannelMixAdjustment.explicit(
            try RAWColorMatrix3x3(
                m00: 1.5, m01: -0.25, m02: 0.125,
                m10: 1.5, m11: -0.25, m12: 0.125,
                m20: 1.5, m21: -0.25, m22: 0.125
            )
        )
        #expect(authored == typed)
    }

    /// Nothing normalises, nothing clamps, nothing rejects a negative or an
    /// amplifying contribution.
    @Test("Coefficients are neither normalised nor clamped")
    func coefficientsAreLeftAlone() throws {
        let mix = IRMonochromeMix(red: 1.5, green: -0.5, blue: 0.25)
        let matrix = try mix.matrix()

        #expect(matrix.rows == [
            [1.5, -0.5, 0.25],
            [1.5, -0.5, 0.25],
            [1.5, -0.5, 0.25],
        ])
        // The row sum is 1.25 and stays 1.25.
        #expect(matrix.m00 + matrix.m01 + matrix.m02 == 1.25)
    }

    @Test("A non-finite contribution is refused by the matrix primitive")
    func aNonFiniteContributionIsRefused() {
        for (value, column) in [(Double.infinity, 0), (.nan, 1), (-.infinity, 2)] {
            let mix = IRMonochromeMix(
                red: column == 0 ? value : 1,
                green: column == 1 ? value : 1,
                blue: column == 2 ? value : 1
            )
            #expect(throws: RAWProcessingError.self) { _ = try mix.matrix() }
            #expect(throws: RAWProcessingError.self) { _ = try mix.adjustment() }
        }
    }

    // MARK: - Nine coefficients become three

    @Test("Identical rows are recognised and their contributions recovered exactly")
    func identicalRowsAreRecognised() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 0.5, m01: 0.4, m02: 0.1,
            m10: 0.5, m11: 0.4, m12: 0.1,
            m20: 0.5, m21: 0.4, m22: 0.1
        )
        let recovered = try #require(IRMonochromeMix(recognising: matrix))

        #expect(recovered.red == 0.5)
        #expect(recovered.green == 0.4)
        #expect(recovered.blue == 0.1)
        // And it round-trips back to the same nine numbers.
        #expect(try recovered.matrix() == matrix)
    }

    /// One coefficient out of place is enough. Each of the six positions that
    /// could differ is checked, so a recogniser that compares only two rows or
    /// only some columns cannot pass.
    @Test("One differing coefficient in any position is not monochrome")
    func oneDifferingCoefficientIsNotMonochrome() throws {
        let base: [Double] = [
            0.5, 0.4, 0.1,
            0.5, 0.4, 0.1,
            0.5, 0.4, 0.1,
        ]
        for index in 3..<9 {
            var coefficients = base
            coefficients[index] += 0.0001
            let matrix = try RAWColorMatrix3x3(
                m00: coefficients[0], m01: coefficients[1], m02: coefficients[2],
                m10: coefficients[3], m11: coefficients[4], m12: coefficients[5],
                m20: coefficients[6], m21: coefficients[7], m22: coefficients[8]
            )
            #expect(
                IRMonochromeMix(recognising: matrix) == nil,
                "Position \(index) differs, so this must not be recognised"
            )
        }
    }

    /// No epsilon, deliberately: a near-monochrome colour transform stays a
    /// colour transform, and reopening it as monochrome would let the editor
    /// rewrite it into something the person never authored.
    @Test("Nearly-identical rows are not monochrome — there is no tolerance")
    func nearlyIdenticalRowsAreNotMonochrome() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 1.0 / 3.0, m01: 1.0 / 3.0, m02: 1.0 / 3.0,
            m10: 1.0 / 3.0, m11: 1.0 / 3.0, m12: 1.0 / 3.0,
            m20: 1.0 / 3.0, m21: 1.0 / 3.0, m22: nextafter(1.0 / 3.0, 1)
        )
        #expect(IRMonochromeMix(recognising: matrix) == nil)
    }

    @Test("Neither built-in mix is monochrome")
    func neitherBuiltInIsMonochrome() {
        #expect(IRMonochromeMix(recognising: UserChannelMixAdjustment.identity) == nil)
        #expect(IRMonochromeMix(recognising: UserChannelMixAdjustment.redBlueSwap) == nil)
        #expect(IRMonochromeMix(recognising: RAWColorMatrix3x3.identity) == nil)
    }

    /// Recognition asks the matrix and never the case, so the route a matrix
    /// arrived by — typed, restored from a sidecar, applied from a preset —
    /// cannot change the answer.
    @Test("Recognition depends on the coefficients, never on where they came from")
    func recognitionIgnoresProvenance() throws {
        let authored = try Self.asymmetric.adjustment()
        let restored = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [1.5, -0.25, 0.125, 1.5, -0.25, 0.125, 1.5, -0.25, 0.125]
        )
        let fromPreset = IRCreativePreset(
            id: try IRCreativePresetID("user.mono-test"),
            name: "Mono",
            channelMix: authored
        ).channelMix

        for adjustment in [authored, restored, fromPreset] {
            let recovered = try #require(IRMonochromeMix(recognising: adjustment))
            #expect(recovered == Self.asymmetric)
        }
    }

    // MARK: - The four starting points

    @Test("Equal RGB is the arithmetic mean, exactly one third in each column")
    func equalRGBIsTheArithmeticMean() throws {
        let mix = IRMonochromeMix.equalRGB
        #expect(mix.red == 1.0 / 3.0)
        #expect(mix.green == 1.0 / 3.0)
        #expect(mix.blue == 1.0 / 3.0)
        // Deliberately not a luminance: none of the visible-light weights
        // appears anywhere in this type.
        #expect(mix.red != 0.2126)
        #expect(mix.green != 0.7152)
        #expect(mix.blue != 0.0722)

        #expect(try mix.matrix().rows == [
            [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
            [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
            [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
        ])
    }

    @Test("Red, green and blue only are the three single-channel selections")
    func singleChannelStartingPoints() throws {
        #expect(IRMonochromeMix.redOnly == IRMonochromeMix(red: 1, green: 0, blue: 0))
        #expect(IRMonochromeMix.greenOnly == IRMonochromeMix(red: 0, green: 1, blue: 0))
        #expect(IRMonochromeMix.blueOnly == IRMonochromeMix(red: 0, green: 0, blue: 1))

        #expect(try IRMonochromeMix.redOnly.matrix().rows == [
            [1, 0, 0], [1, 0, 0], [1, 0, 0],
        ])
        #expect(try IRMonochromeMix.greenOnly.matrix().rows == [
            [0, 1, 0], [0, 1, 0], [0, 1, 0],
        ])
        #expect(try IRMonochromeMix.blueOnly.matrix().rows == [
            [0, 0, 1], [0, 0, 1], [0, 0, 1],
        ])
    }

    @Test("The editor offers exactly those four, in order, and every one is monochrome")
    func theFourStartingPoints() throws {
        let points = IRMonochromeMix.startingPoints
        #expect(points.map(\.name) == ["Equal RGB", "Red Only", "Green Only", "Blue Only"])
        #expect(points.map(\.mix) == [.equalRGB, .redOnly, .greenOnly, .blueOnly])

        for point in points {
            let recovered = try #require(IRMonochromeMix(recognising: try point.mix.matrix()))
            #expect(recovered == point.mix)
        }
        // No visible-light luminance preset is offered under any name.
        #expect(!points.contains { $0.name.lowercased().contains("lumin") })
    }

    // MARK: - Rendering, through the existing mixer

    /// Provenance for a working-colour image, rich enough that a stage which
    /// overwrote it would be visible.
    static func workingColorProcessing() -> RAWWorkingColorProcessing {
        RAWWorkingColorProcessing(
            transform: .sensorRGBIdentityFalseColor,
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

    /// Six pixels whose channels all differ, including a negative and a value
    /// above one, so a clamping or channel-confusing implementation cannot
    /// pass.
    static let pixels: [(Float, Float, Float)] = [
        (0, 0, 0),
        (0.25, 0.5, 0.75),
        (1, 0, 0),
        (0, 1, 0),
        (0, 0, 1),
        (2.5, -0.5, 0.125),
    ]

    static func image() -> WorkingColorRGBImage {
        WorkingColorRGBImage(
            width: 3,
            height: 2,
            values: pixels.flatMap { [$0.0, $0.1, $0.2] },
            processing: workingColorProcessing()
        )
    }

    /// The whole rendering claim: every pixel comes out achromatic, and the
    /// value it comes out as is the hand-computed dot product. The mixer under
    /// test is the existing one — no monochrome arithmetic is written here.
    @Test("Every rendered pixel has R == G == B, equal to the dot product")
    func everyPixelIsAchromatic() throws {
        let mix = Self.asymmetric
        let mixed = try IRChannelMixer().apply(
            to: Self.image(), mix: .explicit(matrix: try mix.matrix())
        )

        #expect(mixed.width == 3)
        #expect(mixed.height == 2)
        #expect(mixed.values.count == Self.pixels.count * 3)

        for (index, pixel) in Self.pixels.enumerated() {
            let red = mixed.values[index * 3]
            let green = mixed.values[index * 3 + 1]
            let blue = mixed.values[index * 3 + 2]

            // Achromatic, bit for bit: the three outputs are one number.
            #expect(red.bitPattern == green.bitPattern, "pixel \(index)")
            #expect(green.bitPattern == blue.bitPattern, "pixel \(index)")

            // And that number is r·R + g·G + b·B, computed the way the mixer
            // computes it: Double coefficients, Float image values.
            let expected = Float(
                Double(pixel.0) * mix.red
                    + Double(pixel.1) * mix.green
                    + Double(pixel.2) * mix.blue
            )
            #expect(red == expected, "pixel \(index)")
        }

        // Ordinary creative provenance — nothing calls this calibrated, and
        // nothing records that it was monochrome.
        #expect(mixed.processing.mix.source == .explicit)
        #expect(mixed.processing.channelMixApplied)
        #expect(!mixed.processing.isValidatedInfraredCalibration)
    }

    /// Equal RGB, checked against the mean it claims to be, on values whose
    /// mean is exact in binary.
    @Test("Equal RGB renders the arithmetic mean of the three channels")
    func equalRGBRendersTheMean() throws {
        let image = WorkingColorRGBImage(
            width: 1, height: 1, values: [0.75, 1.5, 3.0],
            processing: Self.workingColorProcessing()
        )
        let mixed = try IRChannelMixer().apply(
            to: image, mix: .explicit(matrix: try IRMonochromeMix.equalRGB.matrix())
        )

        let expected = Float(
            (Double(Float(0.75)) + Double(Float(1.5)) + Double(Float(3.0))) / 3.0
        )
        #expect(mixed.values[0] == expected)
        #expect(mixed.values[1] == expected)
        #expect(mixed.values[2] == expected)
    }

    /// Nothing clips: a monochrome result may sit outside `0…1` exactly as any
    /// other scene-linear value may, and the range policy stays the display
    /// and export stages' business.
    @Test("A monochrome result is not clipped to 0…1")
    func aMonochromeResultIsNotClipped() throws {
        let image = WorkingColorRGBImage(
            width: 1, height: 1, values: [4, 4, 4],
            processing: Self.workingColorProcessing()
        )
        let mixed = try IRChannelMixer().apply(
            to: image, mix: .explicit(matrix: try IRMonochromeMix(red: 1, green: 1, blue: 1).matrix())
        )
        #expect(mixed.values == [12, 12, 12])
    }
}
