import Testing
import Foundation
@testable import InfraredConverter

/// The display rendering stage, on synthetic input whose expected results are
/// computed here rather than by asking the renderer what it produced.
///
/// Nothing in this file is a colour validation. What it pins is arithmetic:
/// the exposure equation, the clipping policy, the sRGB transfer function, the
/// quantisation rule and the storage layout. That the resulting picture is
/// *correct* is not claimed anywhere, and could not be — no transform upstream
/// of it is a validated infrared calibration.
///
/// There is deliberately no `render(_:)` without settings to test: every entry
/// point requires them, which is why no test here can accidentally exercise a
/// default exposure.
@Suite("DisplayPreviewRenderer")
struct DisplayPreviewRendererTests {

    // MARK: - Exposure

    /// The exposure equation, at the values where it is exactly checkable.
    ///
    /// ```text
    /// EV  0 → ×1
    /// EV +1 → ×2
    /// EV −1 → ×0.5
    /// EV +2 → ×4
    /// ```
    ///
    /// `exp2` is exact at integer stops, so these are equalities and not
    /// approximations.
    @Test(
        "Integer stops scale by exactly a power of two",
        arguments: [
            (0.0, 1.0), (1.0, 2.0), (-1.0, 0.5), (2.0, 4.0), (-2.0, 0.25), (3.0, 8.0),
        ]
    )
    func integerStopsScaleExactly(exposureEV: Double, expected: Double) {
        let settings = DisplayPreviewTestData.settings(exposureEV: exposureEV)
        #expect(settings.exposureScale == expected)
    }

    @Test("Fractional stops scale by 2 to that power")
    func fractionalStopsScale() {
        // `exp2` is correctly rounded but need not agree bit for bit with a
        // differently-associated expression, so the tolerance is one ULP of
        // the expected magnitude rather than an arbitrary epsilon.
        func agrees(_ exposureEV: Double, _ expected: Double) -> Bool {
            let scale = DisplayPreviewTestData.settings(exposureEV: exposureEV).exposureScale
            return abs(scale - expected) <= expected.ulp
        }
        #expect(agrees(0.5, 2.0.squareRoot()))
        #expect(agrees(-0.5, 1 / 2.0.squareRoot()))
        #expect(agrees(1.0 / 3.0, pow(2.0, 1.0 / 3.0)))
        #expect(agrees(-1.5, 1 / pow(2.0, 1.5)))
    }

    /// Exposure is a multiplication on the **linear** values, so doubling the
    /// exposure and doubling the input must produce the same byte — which is
    /// only true if the multiply happens before the transfer function.
    ///
    /// If exposure were applied after encoding, or after clipping, this would
    /// fail: the sRGB curve is not linear, so `encode(2x) ≠ 2·encode(x)`.
    @Test("Exposure multiplies the linear value, not the encoded one")
    func exposureHappensInTheLinearDomain() throws {
        let renderer = DisplayPreviewRenderer()

        let brightened = try renderer.render(
            DisplayPreviewTestData.pixel(0.1, 0.2, 0.3),
            settings: DisplayPreviewTestData.settings(exposureEV: 1)
        )
        let preScaled = try renderer.render(
            DisplayPreviewTestData.pixel(0.2, 0.4, 0.6),
            settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        #expect(brightened.bytes == preScaled.bytes)

        // And the same result is what the independent reference produces.
        for (offset, sceneLinear) in [Float(0.1), 0.2, 0.3].enumerated() {
            #expect(
                brightened.bytes[offset]
                    == DisplayPreviewTestData.referenceSample(
                        sceneLinear: sceneLinear, exposureEV: 1
                    )
            )
        }
    }

    @Test("Zero EV is mathematically neutral")
    func zeroEVChangesNothingBeforeEncoding() throws {
        let values: [Float] = [0.0, 0.18, 0.5, 0.75, 1.0, 0.003_130_8]
        for value in values {
            let rendered = try DisplayPreviewRenderer().render(
                DisplayPreviewTestData.pixel(value, value, value),
                settings: DisplayPreviewTestData.settings(exposureEV: 0)
            )
            let expected = DisplayPreviewTestData.referenceQuantize(
                DisplayPreviewTestData.referenceEncode(Double(value))
            )
            #expect(rendered.bytes[0] == expected, "linear \(value)")
        }
    }

    // MARK: - Clipping

    /// The clipping policy, stated as a table and checked as one.
    ///
    /// ```text
    /// negative → 0
    /// 0        → 0
    /// 0.25     → 0.25, unchanged, before encoding
    /// 1        → 1
    /// > 1      → 1
    /// ```
    @Test("Values outside 0...1 are hard clipped, values inside are untouched")
    func clippingFollowsTheStatedTable() throws {
        let renderer = DisplayPreviewRenderer()
        let settings = DisplayPreviewTestData.settings(exposureEV: 0)

        // Below zero and zero produce the same byte, and it is 0.
        let negative = try renderer.render(
            DisplayPreviewTestData.pixel(-5, -0.001, -0.0), settings: settings
        )
        #expect(Array(negative.bytes) == [0, 0, 0])
        let zero = try renderer.render(DisplayPreviewTestData.pixel(0, 0, 0), settings: settings)
        #expect(Array(zero.bytes) == [0, 0, 0])

        // Above one and one produce the same byte, and it is 255.
        let above = try renderer.render(
            DisplayPreviewTestData.pixel(1.0001, 5, 1e30), settings: settings
        )
        #expect(Array(above.bytes) == [255, 255, 255])
        let one = try renderer.render(DisplayPreviewTestData.pixel(1, 1, 1), settings: settings)
        #expect(Array(one.bytes) == [255, 255, 255])

        // A value inside the range reaches the encoder unchanged: 0.25 encodes
        // to the same byte whether or not any clipping code touched it.
        let inside = try renderer.render(
            DisplayPreviewTestData.pixel(0.25, 0.25, 0.25), settings: settings
        )
        let expected = DisplayPreviewTestData.referenceQuantize(
            DisplayPreviewTestData.referenceEncode(0.25)
        )
        #expect(inside.bytes[0] == expected)
        #expect(inside.processing.clippedSampleCount == 0)
    }

    @Test("Clipped components are counted, in each direction separately")
    func clippingIsCounted() throws {
        // Four pixels: two components below zero, three above one, the rest
        // inside.
        let values: [Float] = [
            -0.5, 0.25, 0.5,
            2.0, 0.75, -1.0,
            1.5, 0.1, 0.9,
            0.0, 1.0, 3.0,
        ]
        let rendered = try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.image(width: 2, height: 2, values: values),
            settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        #expect(rendered.processing.clippedLowSampleCount == 2)
        #expect(rendered.processing.clippedHighSampleCount == 3)
        #expect(rendered.processing.clippedSampleCount == 5)
        // Exactly 1.0 is not clipped: the policy is `> 1`, not `>= 1`.
        #expect(rendered.processing.clippedHighSampleCount == 3)
    }

    @Test("Exposure decides what clips, because it happens first")
    func exposureChangesWhatClips() throws {
        let renderer = DisplayPreviewRenderer()
        let image = DisplayPreviewTestData.pixel(0.6, 0.6, 0.6)

        let neutral = try renderer.render(
            image, settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        #expect(neutral.processing.clippedHighSampleCount == 0)

        // ×2 puts every component above 1.
        let brightened = try renderer.render(
            image, settings: DisplayPreviewTestData.settings(exposureEV: 1)
        )
        #expect(brightened.processing.clippedHighSampleCount == 3)
        #expect(Array(brightened.bytes) == [255, 255, 255])
    }

    /// The invariant that keeps "the preview clips" from becoming "the
    /// pipeline clips".
    @Test("The scene-linear input is bit-identical after rendering")
    func renderingDoesNotTouchItsInput() throws {
        let values: [Float] = [
            -2.5, 0.25, 4.0,
            -0.0, 1.5, 0.75,
            Float.greatestFiniteMagnitude, -1.0, Float.leastNonzeroMagnitude,
            0.18, -0.5, 1.0,
        ]
        let image = DisplayPreviewTestData.image(width: 2, height: 2, values: values)
        let before = image.values

        // −1 EV, so the largest finite magnitude in the buffer is halved
        // rather than overflowed: what is under test here is that the input
        // survives, not what an overflow does.
        _ = try DisplayPreviewRenderer().render(
            image, settings: DisplayPreviewTestData.settings(exposureEV: -1)
        )

        #expect(image.values.count == before.count)
        for index in 0..<before.count {
            #expect(
                image.values[index].bitPattern == before[index].bitPattern,
                "element \(index)"
            )
        }
        // Specifically: the values outside 0...1 are all still there, and
        // negative zero is still negative zero.
        #expect(image.values[0] == -2.5)
        #expect(image.values[2] == 4.0)
        #expect(image.values[3].sign == .minus)
        #expect(image.values.contains { $0 < 0 })
        #expect(image.values.contains { $0 > 1 })
    }

    // MARK: - The transfer function

    /// Reference points on both branches, derived here from the standard's
    /// definition and compared against the production encoder.
    @Test("The sRGB encoding matches the piecewise definition, on both branches")
    func transferFunctionReferencePoints() {
        let points: [Double] = [
            0,
            1e-6,
            0.001,
            0.002,
            // The threshold itself: the linear branch owns it.
            0.003_130_8,
            0.004,
            0.01,
            0.18,
            0.5,
            0.9,
            1,
        ]
        for point in points {
            let expected = DisplayPreviewTestData.referenceEncode(point)
            let actual = DisplayPreviewRenderer.encode(point, as: .sRGB)
            #expect(actual == expected, "linear \(point)")
        }

        // Named values, written out, so a change to the reference helper
        // cannot silently move the whole suite with it.
        #expect(DisplayPreviewRenderer.encode(0, as: .sRGB) == 0)
        #expect(DisplayPreviewRenderer.encode(0.001, as: .sRGB) == 12.92 * 0.001)
        #expect(DisplayPreviewRenderer.encode(0.003_130_8, as: .sRGB) == 12.92 * 0.003_130_8)
        let midTone = DisplayPreviewRenderer.encode(0.18, as: .sRGB)
        #expect(abs(midTone - 0.461_356_129_500_441_6) <= 1e-15)
        let white = DisplayPreviewRenderer.encode(1, as: .sRGB)
        #expect(abs(white - 1) <= white.ulp)
    }

    /// The threshold takes the linear branch, and the value immediately above
    /// it takes the other one.
    @Test("The branch boundary is at exactly 0.0031308, inclusive of the linear side")
    func branchBoundaryIsExact() {
        let threshold = 0.003_130_8
        #expect(DisplayPreviewRenderer.encode(threshold, as: .sRGB) == 12.92 * threshold)

        let justAbove = threshold.nextUp
        let nonlinear = 1.055 * pow(justAbove, 1.0 / 2.4) - 0.055
        #expect(DisplayPreviewRenderer.encode(justAbove, as: .sRGB) == nonlinear)
        // The two branches genuinely disagree there, which is why a branch has
        // to be chosen by fiat rather than by hoping they meet.
        #expect(DisplayPreviewRenderer.encode(justAbove, as: .sRGB)
            != 12.92 * justAbove)
    }

    /// A gamma-2.2 implementation would pass a loose tolerance and fail this.
    @Test("The encoding is not pow(x, 1/2.2)")
    func transferFunctionIsNotGamma22() {
        for point in [0.001, 0.01, 0.05, 0.18, 0.5] {
            let gamma22 = pow(point, 1.0 / 2.2)
            let actual = DisplayPreviewRenderer.encode(point, as: .sRGB)
            #expect(abs(actual - gamma22) > 1e-4, "linear \(point)")
        }
    }

    @Test("The encoding is monotonic and stays inside 0...1")
    func transferFunctionIsMonotonic() {
        var previous = -1.0
        for step in 0...1000 {
            let point = Double(step) / 1000
            let encoded = DisplayPreviewRenderer.encode(point, as: .sRGB)
            #expect(encoded > previous, "linear \(point)")
            #expect(encoded >= 0)
            #expect(encoded <= 1 + encoded.ulp)
            previous = encoded
        }
    }

    // MARK: - Quantisation

    @Test("Zero maps to 0 and one maps to 255")
    func quantisationEndpointsAreExact() {
        #expect(DisplayPreviewRenderer.quantize(0) == 0)
        #expect(DisplayPreviewRenderer.quantize(1) == 255)
        // The path the renderer actually takes to 255: encode(1) is one ULP
        // below 1 in Double, and rounding to nearest is what recovers 255.
        let encodedWhite = DisplayPreviewRenderer.encode(1, as: .sRGB)
        #expect(encodedWhite < 1)
        #expect(DisplayPreviewRenderer.quantize(encodedWhite) == 255)
    }

    /// Rounding is to nearest, half away from zero — every value here is
    /// non-negative, so that is plainly "half up".
    @Test("Rounding boundaries go to the nearer level, halves upward")
    func quantisationRoundsToNearest() {
        // Exactly halfway between 0 and 1.
        #expect(DisplayPreviewRenderer.quantize(0.5 / 255) == 1)
        #expect(DisplayPreviewRenderer.quantize((0.5 / 255).nextDown) == 0)
        // Exactly halfway between 127 and 128.
        #expect(DisplayPreviewRenderer.quantize(127.5 / 255) == 128)
        #expect(DisplayPreviewRenderer.quantize((127.5 / 255).nextDown) == 127)
        // Just under a whole level rounds up, not down: truncation would give
        // 127 here and would map 1 to 254.
        #expect(DisplayPreviewRenderer.quantize(127.9 / 255) == 128)
        #expect(DisplayPreviewRenderer.quantize(127.1 / 255) == 127)
    }

    @Test("Every sample of a swept image is a legal 8-bit value")
    func quantisationStaysInRange() throws {
        // A sweep well outside 0...1 in both directions, at an exposure that
        // pushes it further.
        var values = [Float]()
        for step in 0..<(64 * 3) {
            values.append(Float(step) * 0.05 - 1.5)
        }
        let rendered = try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.image(width: 8, height: 8, values: values),
            settings: DisplayPreviewTestData.settings(exposureEV: 1.5)
        )
        #expect(rendered.bytes.count == 8 * 8 * 3)
        // `UInt8` cannot hold anything else, so what this really pins is that
        // every byte was written, and matches the independent reference.
        for (offset, value) in values.enumerated() {
            let expected = DisplayPreviewTestData.referenceSample(
                sceneLinear: value, exposureEV: 1.5
            )
            #expect(rendered.bytes[offset] == expected, "element \(offset)")
        }
    }

    // MARK: - Channel independence

    /// Deliberately different in every channel of every pixel, so a channel
    /// swap, a shared accumulator or a wrong storage offset cannot pass.
    @Test("Each channel is encoded from its own value, in R G B order")
    func channelsAreIndependentAndOrdered() throws {
        let values: [Float] = [
            0.05, 0.35, 0.85,
            0.9, 0.02, 0.45,
            0.25, 0.6, 0.005,
            0.7, 0.15, 0.5,
        ]
        let rendered = try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.image(width: 2, height: 2, values: values),
            settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )

        for (offset, value) in values.enumerated() {
            let expected = DisplayPreviewTestData.referenceSample(
                sceneLinear: value, exposureEV: 0
            )
            #expect(rendered.bytes[offset] == expected, "element \(offset)")
        }

        // Read back through the accessors rather than the flat buffer, so the
        // index arithmetic is checked too.
        let topLeft = try #require(rendered.pixel(row: 0, column: 0))
        #expect(topLeft.red == DisplayPreviewTestData.referenceSample(
            sceneLinear: 0.05, exposureEV: 0
        ))
        #expect(topLeft.green == DisplayPreviewTestData.referenceSample(
            sceneLinear: 0.35, exposureEV: 0
        ))
        #expect(topLeft.blue == DisplayPreviewTestData.referenceSample(
            sceneLinear: 0.85, exposureEV: 0
        ))
        // The three are genuinely different, so an all-channels-equal bug
        // cannot pass this.
        #expect(topLeft.red != topLeft.green)
        #expect(topLeft.green != topLeft.blue)

        let bottomRight = try #require(rendered.pixel(row: 1, column: 1))
        #expect(bottomRight.red == DisplayPreviewTestData.referenceSample(
            sceneLinear: 0.7, exposureEV: 0
        ))
        #expect(bottomRight.sample(.green) == bottomRight.green)
    }

    @Test("Row order is preserved: pixel (r, c) comes from element (r*width + c)*3")
    func storageLayoutIsRowMajor() throws {
        let width = 5
        let height = 3
        var values = [Float]()
        for index in 0..<(width * height * 3) {
            values.append(Float(index) / Float(width * height * 3))
        }
        let rendered = try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.image(width: width, height: height, values: values),
            settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )

        #expect(rendered.width == width)
        #expect(rendered.height == height)
        #expect(rendered.bytesPerRow == width * 3)
        #expect(rendered.expectedByteCount == width * height * 3)
        #expect(rendered.pixelCount == width * height)
        #expect(rendered.isGeometryConsistent)

        for row in 0..<height {
            for column in 0..<width {
                let base = (row * width + column) * 3
                let pixel = try #require(rendered.pixel(row: row, column: column))
                #expect(pixel.red == DisplayPreviewTestData.referenceSample(
                    sceneLinear: values[base], exposureEV: 0
                ))
                #expect(pixel.blue == DisplayPreviewTestData.referenceSample(
                    sceneLinear: values[base + 2], exposureEV: 0
                ))
                #expect(rendered.byteIndex(row: row, column: column) == base)
            }
        }
    }

    // MARK: - Geometry accessors

    @Test("Out-of-bounds coordinates return nil rather than trapping")
    func accessorsRefuseOutOfBounds() throws {
        let rendered = try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.image(
                width: 2, height: 2, values: [Float](repeating: 0.5, count: 12)
            ),
            settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        #expect(rendered.byteIndex(row: -1, column: 0) == nil)
        #expect(rendered.byteIndex(row: 0, column: -1) == nil)
        #expect(rendered.byteIndex(row: 2, column: 0) == nil)
        #expect(rendered.byteIndex(row: 0, column: 2) == nil)
        #expect(rendered.pixel(row: 5, column: 5) == nil)
        #expect(rendered.sample(row: 5, column: 5, channel: .red) == nil)
    }

    /// Geometry whose implied storage cannot be represented reports `nil`
    /// rather than trapping on the multiplication.
    @Test("Overflowing geometry is reported, not trapped on")
    func overflowingGeometryIsSafe() {
        #expect(DisplayEncodedPreviewImage.expectedByteCount(
            width: Int.max, height: 2
        ) == nil)
        #expect(DisplayEncodedPreviewImage.expectedByteCount(
            width: Int.max / 2, height: 1
        ) == nil)
        #expect(DisplayEncodedPreviewImage.expectedByteCount(width: 4, height: 3) == 36)

        let absurd = DisplayEncodedPreviewImage(
            width: Int.max,
            height: 4,
            bytes: Data(count: 12),
            processing: DisplayPreviewProcessing(
                settings: DisplayPreviewTestData.settings(exposureEV: 0),
                orientationProcessing: DisplayPreviewTestData.orientationProcessing(),
                clippedLowSampleCount: 0,
                clippedHighSampleCount: 0
            )
        )
        #expect(absurd.bytesPerRow == nil)
        #expect(absurd.expectedByteCount == nil)
        #expect(!absurd.isGeometryConsistent)
        // Row 1 needs `1 * Int.max` to locate its start, which overflows.
        #expect(absurd.byteIndex(row: 1, column: 0) == nil)
        #expect(absurd.pixel(row: 1, column: 0) == nil)
        // Row 0 column 0 is genuinely at byte 0 even here, and the buffer is
        // long enough to hold that one pixel — the guards report what is
        // actually unrepresentable rather than refusing everything.
        #expect(absurd.byteIndex(row: 0, column: 0) == 0)
    }

    // MARK: - The single-case enums

    /// Exhaustive switches, so a second case cannot be added without this
    /// suite being revisited. The same device ADR 0007 uses for
    /// `RAWWorkingColorSpace`.
    @Test("Exactly one range policy and one encoding exist")
    func singleCaseEnumsAreStillSingleCase() {
        switch DisplayRangePolicy.hardClipToDisplayRange {
        case .hardClipToDisplayRange:
            #expect(DisplayRangePolicy.hardClipToDisplayRange.diagnosticDescription
                .contains("not tone mapping"))
        }
        switch DisplayEncoding.sRGB {
        case .sRGB:
            #expect(DisplayEncoding.sRGB.diagnosticDescription.contains("sRGB"))
        }
    }
}
