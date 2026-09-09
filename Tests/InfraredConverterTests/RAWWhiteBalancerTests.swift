import Foundation
import Testing
@testable import InfraredConverter

/// Synthetic tests for the infrared white-balance apply stage. Nothing here
/// touches a RAW file: every input is constructed, so every expectation is an
/// exact number rather than a tolerance.
@Suite("RAWWhiteBalancer")
struct RAWWhiteBalancerTests {

    // MARK: - Fixtures

    /// The reference camera's CFA arrangement. `0xB4B4B4B4` places the plane
    /// indices as
    ///
    /// ```text
    /// 0 1     R  G1
    /// 3 2     G2 B
    /// ```
    ///
    /// which is the case the four-slot gain model exists for: plane `3` is
    /// reachable even though `colorCount` is `3`.
    static let rgbg = RAWTestData.bayerLayout()

    static let linearProcessing = RAWLinearProcessing(
        whiteLevelPolicy: .metadataMaximum,
        whiteLevel: 4095
    )

    static func linear(
        width: Int,
        height: Int,
        values: [Float],
        layout: RAWMetadata.SensorColorLayout = rgbg
    ) -> LinearRAWMosaic {
        LinearRAWMosaic(
            width: width,
            height: height,
            values: values,
            sensorColorLayout: layout,
            processing: linearProcessing
        )
    }

    /// A 2×2 cell holding one sample of each CFA plane, all with the same
    /// value, so any difference in the output is attributable to the gain
    /// alone.
    static func uniformCell(_ value: Float) -> LinearRAWMosaic {
        linear(width: 2, height: 2, values: [value, value, value, value])
    }

    static let gains2345 = RAWWhiteBalanceGains(plane0: 2, plane1: 3, plane2: 4, plane3: 5)

    // MARK: - Identity

    @Test("Identity gains leave every finite value bit-identical")
    func identityIsExact() throws {
        // Negative, zero, fractional, exactly one, and above one — the whole
        // range the unclamped linear stage can hand over.
        let values: [Float] = [
            -1, -0.25, -0.0001, -0, 0, 0.0001, 0.25, 0.5, 1, 1.0000001, 2.4, 1_000, 3.4e38,
            Float.leastNormalMagnitude, Float.leastNonzeroMagnitude, Float.greatestFiniteMagnitude,
        ]
        let mosaic = Self.linear(width: values.count, height: 1, values: values)

        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)

        // Bit-identical, not merely close: `x * 1` is exact in IEEE 754 for
        // every finite x, and this stage adds nothing that would perturb it.
        #expect(balanced.values == values)
        for (index, value) in values.enumerated() {
            #expect(balanced.values[index].bitPattern == value.bitPattern,
                    "value \(value) at index \(index) changed bit pattern")
        }
    }

    // MARK: - Four distinct CFA planes

    @Test("Four CFA planes get four different gains, including plane 3 when colorCount is 3")
    func fourPlanesAreIndependent() throws {
        // The layout says colorCount == 3, but the CFA lookup returns 0...3.
        #expect(Self.rgbg.colorCount == 3)
        #expect(Self.rgbg.colorPlaneIndex(row: 0, column: 0) == 0)
        #expect(Self.rgbg.colorPlaneIndex(row: 0, column: 1) == 1)
        #expect(Self.rgbg.colorPlaneIndex(row: 1, column: 0) == 3)
        #expect(Self.rgbg.colorPlaneIndex(row: 1, column: 1) == 2)

        let balanced = try RAWWhiteBalancer()
            .apply(to: Self.uniformCell(1), gains: Self.gains2345)

        // Identical inputs, four distinct outputs, each matching its plane.
        #expect(balanced.value(row: 0, column: 0) == 2)  // plane 0
        #expect(balanced.value(row: 0, column: 1) == 3)  // plane 1
        #expect(balanced.value(row: 1, column: 0) == 5)  // plane 3
        #expect(balanced.value(row: 1, column: 1) == 4)  // plane 2

        // An implementation doing gain[plane % colorCount] would put plane
        // 3's sample on plane 0's gain and produce 2 here.
        #expect(balanced.value(row: 1, column: 0) != balanced.value(row: 0, column: 0))
        #expect(Set(balanced.values).count == 4)
    }

    @Test("The second green is independently addressable: G1 and G2 gains may differ")
    func secondGreenIsIndependent() throws {
        // Only the two green planes differ; everything else is held equal, so
        // any implementation that ties them together fails right here.
        let gains = RAWWhiteBalanceGains(plane0: 1, plane1: 3, plane2: 1, plane3: 7)
        let balanced = try RAWWhiteBalancer().apply(to: Self.uniformCell(0.5), gains: gains)

        let g1 = try #require(balanced.value(row: 0, column: 1))
        let g2 = try #require(balanced.value(row: 1, column: 0))
        #expect(g1 == 1.5)
        #expect(g2 == 3.5)
        #expect(g1 != g2)
    }

    @Test("Equal green gains are representable too, and are not a special case")
    func equalGreensAreOrdinary() throws {
        let gains = RAWWhiteBalanceGains(plane0: 2, plane1: 3, plane2: 4, plane3: 3)
        let balanced = try RAWWhiteBalancer().apply(to: Self.uniformCell(1), gains: gains)
        #expect(balanced.value(row: 0, column: 1) == balanced.value(row: 1, column: 0))
    }

    // MARK: - No clamping

    @Test("Negative values stay negative and are not clamped to zero")
    func negativesSurvive() throws {
        // Noise straddling the black point produces these, and later neutral
        // statistics depend on them not having been floored.
        let mosaic = Self.linear(
            width: 2, height: 2,
            values: [-0.01, -0.01, -0.01, -0.01]
        )
        let gains = RAWWhiteBalanceGains(plane0: 5, plane1: 5, plane2: 5, plane3: 5)
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: gains)

        #expect(balanced.values.allSatisfy { $0 < 0 })
        for value in balanced.values {
            #expect(abs(value - -0.05) < 1e-7)
        }
        #expect(balanced.processing.clamped == false)
    }

    @Test("Values above one stay above one and are not clamped to one")
    func aboveOneSurvives() throws {
        let mosaic = Self.linear(width: 1, height: 1, values: [0.6])
        let gains = RAWWhiteBalanceGains(plane0: 4, plane1: 4, plane2: 4, plane3: 4)
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: gains)

        let value = try #require(balanced.value(row: 0, column: 0))
        #expect(value > 1)
        #expect(abs(value - 2.4) < 1e-6)
    }

    @Test("A value already above one is amplified further, not capped")
    func alreadyLargeValuesGrow() throws {
        let mosaic = Self.linear(width: 1, height: 1, values: [3.5])
        let gains = RAWWhiteBalanceGains(plane0: 10, plane1: 10, plane2: 10, plane3: 10)
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: gains)
        #expect(balanced.value(row: 0, column: 0) == 35)
    }

    // MARK: - Literal gain scale

    @Test("Gains are literal multipliers and are never normalised")
    func gainScaleIsLiteral() throws {
        // Four positions each holding 0.25, with gains [2, 4, 6, 8]. An
        // implementation dividing through by the largest gain would produce
        // [0.25, 0.5, 0.75, 1.0] here instead of the literal products.
        let gains = RAWWhiteBalanceGains(plane0: 2, plane1: 4, plane2: 6, plane3: 8)
        let balanced = try RAWWhiteBalancer().apply(to: Self.uniformCell(0.25), gains: gains)

        #expect(balanced.value(row: 0, column: 0) == 0.5)   // plane 0, gain 2
        #expect(balanced.value(row: 0, column: 1) == 1.0)   // plane 1, gain 4
        #expect(balanced.value(row: 1, column: 1) == 1.5)   // plane 2, gain 6
        #expect(balanced.value(row: 1, column: 0) == 2.0)   // plane 3, gain 8
    }

    @Test("Green is not normalised to one")
    func greenIsNotNormalisedToOne() throws {
        // Every gain is above 1, so an implementation that made green 1 would
        // have to shrink all four.
        let gains = RAWWhiteBalanceGains(plane0: 6, plane1: 2, plane2: 8, plane3: 2)
        let balanced = try RAWWhiteBalancer().apply(to: Self.uniformCell(1), gains: gains)
        #expect(balanced.values.allSatisfy { $0 >= 2 })
        #expect(balanced.value(row: 0, column: 1) == 2)
        #expect(balanced.processing.gains == gains)
    }

    @Test("Doubling every gain doubles every output value")
    func scalingGainsScalesOutput() throws {
        // The direct consequence of literal gains: overall scale is the
        // caller's business, not this stage's.
        let mosaic = Self.linear(width: 2, height: 2, values: [0.1, 0.2, 0.3, 0.4])
        let doubled = RAWWhiteBalanceGains(
            plane0: Self.gains2345.plane0 * 2,
            plane1: Self.gains2345.plane1 * 2,
            plane2: Self.gains2345.plane2 * 2,
            plane3: Self.gains2345.plane3 * 2
        )
        let balancer = RAWWhiteBalancer()
        let once = try balancer.apply(to: mosaic, gains: Self.gains2345)
        let twice = try balancer.apply(to: mosaic, gains: doubled)

        for (a, b) in zip(once.values, twice.values) {
            #expect(b == a * 2)
        }
    }

    // MARK: - Extreme but valid gains

    @Test("A gain far below one is accepted and applied literally")
    func smallGainIsAccepted() throws {
        let gains = RAWWhiteBalanceGains(plane0: 0.01, plane1: 0.1, plane2: 0.01, plane3: 0.1)
        let balanced = try RAWWhiteBalancer().apply(to: Self.uniformCell(1), gains: gains)
        #expect(balanced.value(row: 0, column: 0) == 0.01)
        #expect(balanced.value(row: 0, column: 1) == 0.1)
    }

    @Test("A large gain is accepted: infrared white balance has no arbitrary ceiling")
    func largeGainIsAccepted() throws {
        // 100 is unremarkable for an IR capture where one plane is nearly
        // empty; an arbitrary maximum here would rule out real work.
        let gains = RAWWhiteBalanceGains(plane0: 100, plane1: 20, plane2: 5, plane3: 20)
        let balanced = try RAWWhiteBalancer().apply(to: Self.uniformCell(0.01), gains: gains)
        #expect(balanced.value(row: 0, column: 0) == 1)
        #expect(abs(try #require(balanced.value(row: 0, column: 1)) - 0.2) < 1e-7)
    }

    // MARK: - Gain validation

    @Test("Zero, negative and infinite gains are rejected per plane")
    func invalidGainsAreRejected() {
        let invalid: [Float] = [0, -0, -1, -0.5, .infinity, -.infinity]
        for plane in 0..<RAWWhiteBalanceGains.planeCount {
            for value in invalid {
                var gains = RAWWhiteBalanceGains(plane0: 1, plane1: 1, plane2: 1, plane3: 1)
                switch plane {
                case 0: gains.plane0 = value
                case 1: gains.plane1 = value
                case 2: gains.plane2 = value
                default: gains.plane3 = value
                }
                #expect(
                    throws: RAWProcessingError.invalidWhiteBalanceGain(colorPlane: plane, value: value)
                ) {
                    try RAWWhiteBalancer().apply(to: Self.uniformCell(1), gains: gains)
                }
            }
        }
    }

    @Test("A NaN gain is rejected, naming the plane")
    func nanGainIsRejected() {
        // Compared by case rather than by whole-error equality: NaN != NaN,
        // so an `==` on the error would fail even when it is the right error.
        for plane in 0..<RAWWhiteBalanceGains.planeCount {
            var gains = RAWWhiteBalanceGains(plane0: 1, plane1: 1, plane2: 1, plane3: 1)
            switch plane {
            case 0: gains.plane0 = .nan
            case 1: gains.plane1 = .nan
            case 2: gains.plane2 = .nan
            default: gains.plane3 = .nan
            }
            var caught: RAWProcessingError?
            do {
                _ = try RAWWhiteBalancer().apply(to: Self.uniformCell(1), gains: gains)
            } catch let error as RAWProcessingError {
                caught = error
            } catch {}

            guard case .invalidWhiteBalanceGain(let reported, let value) = caught else {
                Issue.record("expected invalidWhiteBalanceGain for plane \(plane), got \(String(describing: caught))")
                continue
            }
            #expect(reported == plane)
            #expect(value.isNaN)
        }
    }

    @Test("Gains are validated before any pixel is processed")
    func gainsAreValidatedUpFront() {
        // The mosaic is also malformed. The gain error is what surfaces,
        // which is only possible if validation ran first.
        let malformed = Self.linear(width: 4, height: 4, values: [1, 2, 3])
        let gains = RAWWhiteBalanceGains(plane0: 1, plane1: 0, plane2: 1, plane3: 1)
        #expect(throws: RAWProcessingError.invalidWhiteBalanceGain(colorPlane: 1, value: 0)) {
            try RAWWhiteBalancer().apply(to: malformed, gains: gains)
        }
    }

    @Test("Valid gains pass validation on their own")
    func validGainsValidate() throws {
        for gains: RAWWhiteBalanceGains in [
            .identity,
            Self.gains2345,
            .init(plane0: 0.01, plane1: 100, plane2: Float.leastNormalMagnitude, plane3: 3.4e38),
        ] {
            try gains.validate()
        }
    }

    // MARK: - Non-finite handling

    @Test("A finite input and a finite gain that overflow Float32 are a typed error")
    func overflowIsATypedError() {
        // 3.0e38 x 100 is far past Float32's ~3.4e38 ceiling. The stage
        // reports it rather than clamping to greatestFiniteMagnitude or
        // storing an infinity.
        let mosaic = Self.linear(width: 1, height: 1, values: [3.0e38])
        let gains = RAWWhiteBalanceGains(plane0: 100, plane1: 1, plane2: 1, plane3: 1)
        #expect(throws: RAWProcessingError.nonFiniteWhiteBalanceResult(
            row: 0, column: 0, colorPlane: 0, input: 3.0e38, gain: 100
        )) {
            try RAWWhiteBalancer().apply(to: mosaic, gains: gains)
        }
    }

    @Test("The overflowing coordinate is reported, not just the fact of overflow")
    func overflowNamesTheSample() throws {
        // Only plane 2 (position (1,1)) carries the huge value.
        let mosaic = Self.linear(width: 2, height: 2, values: [1, 1, 1, 3.0e38])
        let gains = RAWWhiteBalanceGains(plane0: 1, plane1: 1, plane2: 50, plane3: 1)

        var caught: RAWProcessingError?
        do {
            _ = try RAWWhiteBalancer().apply(to: mosaic, gains: gains)
        } catch let error as RAWProcessingError {
            caught = error
        }
        #expect(caught == .nonFiniteWhiteBalanceResult(
            row: 1, column: 1, colorPlane: 2, input: 3.0e38, gain: 50
        ))
    }

    @Test("An infinite input value is a typed error, not a propagated infinity")
    func infiniteInputIsATypedError() {
        for value: Float in [.infinity, -.infinity] {
            let mosaic = Self.linear(width: 2, height: 1, values: [0.5, value])
            #expect(throws: RAWProcessingError.nonFiniteInputValue(row: 0, column: 1, value: value)) {
                try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
            }
        }
    }

    @Test("A NaN input value is a typed error, not a propagated NaN")
    func nanInputIsATypedError() throws {
        let mosaic = Self.linear(width: 2, height: 1, values: [0.5, .nan])
        var caught: RAWProcessingError?
        do {
            _ = try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
        } catch let error as RAWProcessingError {
            caught = error
        }
        guard case .nonFiniteInputValue(let row, let column, let value) = caught else {
            Issue.record("expected nonFiniteInputValue, got \(String(describing: caught))")
            return
        }
        #expect(row == 0)
        #expect(column == 1)
        #expect(value.isNaN)
    }

    @Test("A result that merely underflows to zero is finite and accepted")
    func underflowIsNotAnError() throws {
        let mosaic = Self.linear(width: 1, height: 1, values: [Float.leastNonzeroMagnitude])
        let gains = RAWWhiteBalanceGains(plane0: 0.01, plane1: 1, plane2: 1, plane3: 1)
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: gains)
        let value = try #require(balanced.value(row: 0, column: 0))
        #expect(value.isFinite)
        #expect(value >= 0)
    }

    // MARK: - Layout and geometry validation

    @Test("A layout with no per-pixel colour plane is a typed error")
    func missingColorPlaneFails() {
        let noMosaic = RAWMetadata.SensorColorLayout(
            pattern: .none, filters: 0, colorDescription: "RGB", colorCount: 3
        )
        let mosaic = Self.linear(width: 1, height: 1, values: [0.5], layout: noMosaic)
        #expect(throws: RAWProcessingError.missingColorPlane(row: 0, column: 0)) {
            try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
        }
    }

    @Test("A colour plane outside the gain model's slots is a typed error, not folded onto one")
    func planeWithoutAGainFails() {
        // A layout naming plane 4 has no gain here. Reducing the index modulo
        // 4 would silently apply plane 0's gain instead, which is exactly the
        // class of bug this error exists to prevent.
        let sixPlanes = RAWMetadata.SensorColorLayout(
            pattern: .xTrans,
            filters: 9,
            colorDescription: "RGBG",
            colorCount: 3,
            xTransPattern: [
                [0, 1, 4, 2, 1, 0],
                [1, 2, 1, 0, 2, 1],
                [1, 0, 2, 1, 0, 2],
                [2, 1, 0, 2, 1, 0],
                [0, 2, 1, 0, 2, 1],
                [1, 0, 2, 1, 0, 2],
            ]
        )
        let mosaic = Self.linear(
            width: 6, height: 1,
            values: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            layout: sixPlanes
        )
        #expect(throws: RAWProcessingError.missingWhiteBalanceGain(row: 0, column: 2, colorPlane: 4)) {
            try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
        }
    }

    @Test("Malformed geometry is a typed error before any arithmetic")
    func malformedGeometryFails() {
        let cases: [LinearRAWMosaic] = [
            Self.linear(width: 4, height: 4, values: [1, 2, 3]),          // too few values
            Self.linear(width: 2, height: 2, values: [1, 2, 3, 4, 5]),    // too many values
            Self.linear(width: 0, height: 4, values: []),                 // zero width
            Self.linear(width: 4, height: 0, values: []),                 // zero height
            Self.linear(width: -2, height: 2, values: [1, 2, 3, 4]),      // negative width
            Self.linear(width: Int.max, height: 2, values: [1, 2]),       // overflowing product
        ]
        for mosaic in cases {
            #expect(throws: RAWProcessingError.self) {
                try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
            }
        }
    }

    // MARK: - Coordinates and CFA preservation

    @Test("Dimensions, coordinates and CFA planes survive white balance unchanged")
    func geometryAndCFAArePreserved() throws {
        var values = [Float]()
        for index in 0..<(7 * 5) { values.append(Float(index) / 100) }
        let mosaic = Self.linear(width: 7, height: 5, values: values)

        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: Self.gains2345)

        #expect(balanced.width == mosaic.width)
        #expect(balanced.height == mosaic.height)
        #expect(balanced.values.count == mosaic.values.count)
        #expect(balanced.sensorColorLayout == mosaic.sensorColorLayout)
        #expect(balanced.isGeometryConsistent)

        // No margin, crop or CFA phase change: same plane at every coordinate,
        // and every value is exactly its own input times its own plane's gain.
        for row in 0..<5 {
            for column in 0..<7 {
                let plane = try #require(mosaic.colorPlaneIndex(row: row, column: column))
                #expect(balanced.colorPlaneIndex(row: row, column: column) == plane)
                let input = try #require(mosaic.value(row: row, column: column))
                let gain = try #require(Self.gains2345.gain(forColorPlane: plane))
                #expect(balanced.value(row: row, column: column) == input * gain)
            }
        }
    }

    // MARK: - Provenance

    @Test("Provenance records the exact gains, not a label for them")
    func provenanceRecordsExactGains() throws {
        let balanced = try RAWWhiteBalancer().apply(to: Self.uniformCell(1), gains: Self.gains2345)
        let processing = balanced.processing

        #expect(processing.gains == Self.gains2345)
        #expect(processing.gains.gainsByColorPlane == [2, 3, 4, 5])
        #expect(processing.gainSource == .explicit)

        // The transformation is reproducible from provenance alone.
        let replayed = try RAWWhiteBalancer()
            .apply(to: Self.uniformCell(1), gains: processing.gains)
        #expect(replayed.values == balanced.values)
    }

    @Test("Provenance states what this stage did not do")
    func provenanceRecordsTheStageBoundary() throws {
        let balanced = try RAWWhiteBalancer().apply(to: Self.uniformCell(1), gains: Self.gains2345)
        let processing = balanced.processing

        #expect(processing.whiteBalanceApplied)
        #expect(!processing.clamped)
        #expect(!processing.demosaiced)
        #expect(!processing.cameraColorMatrixApplied)
        #expect(!processing.gammaApplied)
        #expect(!processing.orientationApplied)

        // The upstream record travels with it, so the whole chain reads from
        // one place.
        #expect(processing.linearProcessing == Self.linearProcessing)
        #expect(processing.linearProcessing.blackLevelSubtracted)
        #expect(processing.linearProcessing.normalized)
        #expect(!processing.linearProcessing.whiteBalanceApplied)
    }

    // MARK: - Gains model

    @Test("The gain model addresses four CFA planes and refuses anything else")
    func gainLookupIsByColorPlane() {
        let gains = Self.gains2345
        #expect(gains.gain(forColorPlane: 0) == 2)
        #expect(gains.gain(forColorPlane: 1) == 3)
        #expect(gains.gain(forColorPlane: 2) == 4)
        #expect(gains.gain(forColorPlane: 3) == 5)
        #expect(gains.gain(forColorPlane: 4) == nil)
        #expect(gains.gain(forColorPlane: -1) == nil)
        #expect(gains.gain(forColorPlane: Int.max) == nil)
        #expect(RAWWhiteBalanceGains.planeCount == 4)
    }

    @Test("Identity is all ones")
    func identityGains() {
        #expect(RAWWhiteBalanceGains.identity.gainsByColorPlane == [1, 1, 1, 1])
    }
}
