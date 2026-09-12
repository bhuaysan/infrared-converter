import Testing
import Foundation
@testable import InfraredConverter

/// What the reduction does to pixels.
///
/// Every fixture here is synthetic and every expectation is computed by hand
/// from the area-average definition, so a failure names an arithmetic mistake
/// rather than a change of appearance.
@Suite("Scene-linear preview reduction")
struct SceneLinearPreviewReducerTests {

    static let reducer = SceneLinearPreviewReducer()

    /// Float32 accumulated in Double and narrowed once; a few ULPs of slack is
    /// the whole error budget for any of these fields.
    static let tolerance: Float = 1e-6

    // MARK: - Constant field

    /// The strongest statement available about a mean: averaging a constant
    /// gives the constant. A filter that mis-weighted its taps, read a
    /// neighbouring channel, or normalised by the wrong total would fail here
    /// before it failed anywhere subtler.
    @Test("A constant field reduces to the same constant")
    func constantFieldIsPreserved() throws {
        let image = PreviewTestData.working(width: 64, height: 48) { _, _, channel in
            [0.25, -0.5, 1.75][channel]
        }
        let reduced = try Self.reducer.reduce(
            image, policy: PreviewResolutionPolicy(maximumLongestEdge: 17)
        )

        #expect(reduced.width == 17)
        #expect(reduced.height == 13)   // round(48 × 17/64) = round(12.75)
        for row in 0..<reduced.height {
            for column in 0..<reduced.width {
                let pixel = try #require(reduced.pixel(row: row, column: column))
                #expect(abs(pixel.red - 0.25) < Self.tolerance)
                #expect(abs(pixel.green - (-0.5)) < Self.tolerance)
                #expect(abs(pixel.blue - 1.75) < Self.tolerance)
            }
        }
    }

    /// Extended-linear values are not restricted to `0...1`, and the reduction
    /// clamps nothing. A constant field of out-of-range values comes back
    /// out of range.
    @Test("Values below zero and above one survive the reduction")
    func extendedRangeSurvives() throws {
        let image = PreviewTestData.working(width: 40, height: 40) { _, _, channel in
            [-3.5, 0, 12.25][channel]
        }
        let reduced = try Self.reducer.reduce(
            image, policy: PreviewResolutionPolicy(maximumLongestEdge: 10)
        )
        let pixel = try #require(reduced.pixel(row: 5, column: 5))
        #expect(abs(pixel.red - (-3.5)) < Self.tolerance)
        #expect(pixel.green == 0)
        #expect(abs(pixel.blue - 12.25) < Self.tolerance)
        #expect(!reduced.processing.clamped)
    }

    // MARK: - Exact integer reduction

    /// A 2:1 reduction of a known 4x4 field, with every destination value
    /// written out. Exact binary fractions, so the comparison is exact.
    ///
    /// ```text
    /// source red        destination red
    /// 0  1  2  3        (0+1+4+5)/4 = 2.5   (2+3+6+7)/4 = 4.5
    /// 4  5  6  7        (8+9+12+13)/4 = 10.5 (10+11+14+15)/4 = 12.5
    /// 8  9 10 11
    /// 12 13 14 15
    /// ```
    @Test("A 2:1 reduction is the mean of each 2x2 block")
    func twoToOneIsTheBlockMean() throws {
        let image = PreviewTestData.working(width: 4, height: 4) { row, column, channel in
            channel == 0 ? Float(row * 4 + column) / 4 : 0
        }
        let reduced = try Self.reducer.reduce(
            image, policy: PreviewResolutionPolicy(maximumLongestEdge: 2)
        )

        #expect(reduced.width == 2)
        #expect(reduced.height == 2)
        let expected: [Float] = [2.5 / 4, 4.5 / 4, 10.5 / 4, 12.5 / 4]
        for (index, value) in expected.enumerated() {
            let pixel = try #require(
                reduced.pixel(row: index / 2, column: index % 2)
            )
            #expect(abs(pixel.red - value) < Self.tolerance)
        }
    }

    // MARK: - Gradient

    /// A horizontal ramp reduces to a horizontal ramp: monotonically
    /// increasing along a row, constant down a column, and with the block
    /// means exactly where the definition puts them.
    @Test("A linear gradient reduces to the block means of that gradient")
    func gradientReducesPlausibly() throws {
        let width = 96
        let image = PreviewTestData.working(width: width, height: 12) { _, column, _ in
            Float(column) / Float(width - 1)
        }
        let reduced = try Self.reducer.reduce(
            image, policy: PreviewResolutionPolicy(maximumLongestEdge: 12)
        )
        #expect(reduced.width == 12)
        #expect(reduced.height == 2)   // round(12 × 12/96) = round(1.5) = 2

        // Each destination column covers eight source columns, so its mean is
        // the mean of `column*8 ..< column*8+8` divided by 95.
        for column in 0..<12 {
            let first = column * 8
            let mean = (0..<8).map { Float(first + $0) }.reduce(0, +) / 8 / Float(width - 1)
            let pixel = try #require(reduced.pixel(row: 0, column: column))
            #expect(abs(pixel.red - mean) < 1e-5)
        }

        // Monotone along the row, and the same in both rows: the ramp has no
        // vertical component and the reduction must not invent one.
        for column in 1..<12 {
            let previous = try #require(reduced.pixel(row: 0, column: column - 1)).red
            let current = try #require(reduced.pixel(row: 0, column: column)).red
            #expect(current > previous)
            let below = try #require(reduced.pixel(row: 1, column: column)).red
            #expect(abs(below - current) < Self.tolerance)
        }
    }

    // MARK: - Channel independence

    /// Red varies, green is one constant, blue is another. If the filter ever
    /// read a neighbouring element instead of the one three apart, the two
    /// constants would drift into each other and into the ramp.
    @Test("Reduction never exchanges or blends channels")
    func channelsStayIndependent() throws {
        let width = 60
        let image = PreviewTestData.working(width: width, height: 30) { _, column, channel in
            switch channel {
            case 0: return Float(column) / Float(width - 1)
            case 1: return 0.125
            default: return -0.75
            }
        }
        let reduced = try Self.reducer.reduce(
            image, policy: PreviewResolutionPolicy(maximumLongestEdge: 15)
        )
        #expect(reduced.width == 15)
        #expect(reduced.height == 8)   // round(30 × 15/60) = round(7.5) = 8

        var reds: [Float] = []
        for column in 0..<reduced.width {
            let pixel = try #require(reduced.pixel(row: 3, column: column))
            #expect(abs(pixel.green - 0.125) < Self.tolerance)
            #expect(abs(pixel.blue - (-0.75)) < Self.tolerance)
            reds.append(pixel.red)
        }
        #expect(reds == reds.sorted())
        #expect(reds.first! < reds.last!)
    }

    // MARK: - High-frequency pattern

    /// The case that distinguishes an area average from point sampling.
    ///
    /// A one-pixel checkerboard of `0` and `1` has a mean of exactly `0.5`
    /// everywhere. Nearest-neighbour reduction of it returns `0` or `1` per
    /// destination pixel and produces a coarse plaid that was never in the
    /// photograph — the classic aliasing artefact, and exactly what foliage
    /// does under infrared.
    @Test("A one-pixel checkerboard averages to a flat half rather than aliasing")
    func checkerboardAveragesRatherThanAliases() throws {
        let image = PreviewTestData.working(width: 64, height: 64) { row, column, _ in
            (row + column) % 2 == 0 ? 0 : 1
        }
        let reduced = try Self.reducer.reduce(
            image, policy: PreviewResolutionPolicy(maximumLongestEdge: 16)
        )
        #expect(reduced.width == 16)
        #expect(reduced.height == 16)

        for row in 0..<16 {
            for column in 0..<16 {
                let pixel = try #require(reduced.pixel(row: row, column: column))
                // Exactly a half: each destination pixel covers a 4x4 block
                // with eight ones and eight zeros.
                #expect(abs(pixel.red - 0.5) < Self.tolerance)
                #expect(abs(pixel.green - 0.5) < Self.tolerance)
                #expect(abs(pixel.blue - 0.5) < Self.tolerance)
            }
        }

        // And the result is flat: no destination pixel differs from another,
        // which is precisely the property point sampling destroys.
        let first = try #require(reduced.pixel(row: 0, column: 0)).red
        for index in stride(from: 0, to: reduced.values.count, by: 3) {
            #expect(abs(reduced.values[index] - first) < Self.tolerance)
        }
    }

    /// A vertical one-pixel stripe pattern, reduced by an awkward non-integer
    /// factor. Point sampling would return all-zero or all-one columns; an
    /// area average returns values strictly inside the range.
    @Test("A striped pattern reduced by a non-integer factor stays inside its range")
    func nonIntegerReductionOfStripesStaysInRange() throws {
        let image = PreviewTestData.working(width: 101, height: 7) { _, column, _ in
            column % 2 == 0 ? 0 : 1
        }
        let reduced = try Self.reducer.reduce(
            image, policy: PreviewResolutionPolicy(maximumLongestEdge: 33)
        )
        #expect(reduced.width == 33)

        for column in 0..<reduced.width {
            let pixel = try #require(reduced.pixel(row: 1, column: column))
            #expect(pixel.red > 0.15)
            #expect(pixel.red < 0.85)
        }
    }

    // MARK: - The unreduced path

    /// An image already within the limit is not filtered at all, and its bit
    /// patterns — signed zeros included — survive exactly.
    @Test("An image within the limit keeps every bit pattern")
    func withinTheLimitEveryBitSurvives() throws {
        let awkward: [Float] = [
            -0.0, 0.0, -1.5, 2.5, .leastNonzeroMagnitude, -.greatestFiniteMagnitude,
            1e-30, -3.25, 7, 0.1, -0.2, 0.3,
        ]
        let image = PreviewTestData.working(width: 2, height: 2, values: awkward)
        let reduced = try Self.reducer.reduce(image, policy: .workspace)

        #expect(reduced.width == 2)
        #expect(reduced.height == 2)
        #expect(reduced.processing.resolution.method == .unreduced)
        #expect(!reduced.processing.resampled)
        #expect(zip(reduced.values, awkward).allSatisfy { $0.bitPattern == $1.bitPattern })
    }

    // MARK: - Provenance

    @Test("The reduced image records what it was reduced from, and how")
    func provenanceIsComplete() throws {
        let image = PreviewTestData.working(width: 400, height: 300) { _, _, _ in 0.5 }
        let policy = PreviewResolutionPolicy(maximumLongestEdge: 100)
        let reduced = try Self.reducer.reduce(image, policy: policy)

        let resolution = reduced.processing.resolution
        #expect(resolution.sourceWidth == 400)
        #expect(resolution.sourceHeight == 300)
        #expect(resolution.width == 100)
        #expect(resolution.height == 75)
        #expect(resolution.policy == policy)
        #expect(resolution.method == .areaAverage)
        #expect(resolution.isReduced)

        // Stage facts, and the upstream chain read through, not copied.
        #expect(reduced.processing.reducedForPreview)
        #expect(reduced.processing.sceneLinear)
        #expect(!reduced.processing.clamped)
        #expect(!reduced.processing.gammaApplied)
        #expect(!reduced.processing.displayEncodingApplied)
        #expect(!reduced.processing.orientationApplied)
        #expect(!reduced.processing.cropped)
        #expect(reduced.processing.workingColorSpace == .extendedLinearSRGB)
        #expect(reduced.processing.demosaiced)
        #expect(reduced.processing.whiteBalanceApplied)
        #expect(reduced.processing.normalized)

        // The creative stage has not run on it, and the type says so: this is
        // the pre-creative working representation, and there is no field on it
        // a mix could be recorded in.
        #expect(!reduced.processing.channelMixApplied)
        #expect(reduced.isGeometryConsistent)
    }

    // MARK: - Refusals

    @Test("Inconsistent source geometry is refused")
    func inconsistentGeometryIsRefused() {
        let image = PreviewTestData.working(width: 4, height: 4, values: [0, 0, 0])
        #expect(throws: PreviewReductionError.self) {
            _ = try Self.reducer.reduce(image, policy: .workspace)
        }
    }

    @Test("A policy with no answer is refused rather than guessed at")
    func unusablePolicyIsRefused() throws {
        let image = PreviewTestData.working(width: 10, height: 10) { _, _, _ in 1 }
        #expect(throws: PreviewReductionError.unusablePreviewSize(
            sourceWidth: 10, sourceHeight: 10, maximumLongestEdge: 0
        )) {
            _ = try Self.reducer.reduce(
                image, policy: PreviewResolutionPolicy(maximumLongestEdge: 0)
            )
        }
    }

    /// A single NaN would otherwise poison every destination pixel whose
    /// footprint overlaps it. It is reported with the source coordinate a
    /// reader can go and look at.
    @Test("A non-finite source sample is reported with its coordinate")
    func nonFiniteInputIsReported() throws {
        var values = [Float](repeating: 0.5, count: 8 * 8 * 3)
        values[(3 * 8 + 5) * 3 + 1] = .nan
        let image = PreviewTestData.working(width: 8, height: 8, values: values)

        #expect(throws: PreviewReductionError.self) {
            _ = try Self.reducer.reduce(
                image, policy: PreviewResolutionPolicy(maximumLongestEdge: 4)
            )
        }
        do {
            _ = try Self.reducer.reduce(
                image, policy: PreviewResolutionPolicy(maximumLongestEdge: 4)
            )
            Issue.record("Expected a refusal")
        } catch let error as PreviewReductionError {
            guard case .nonFiniteInput(let row, let column, let channel, _) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(row == 3)
            #expect(column == 5)
            #expect(channel == .green)
        }
    }

    /// The unreduced path defends the same boundary, so a preview image this
    /// stage produced holds finite values whichever path made it.
    @Test("A non-finite sample is refused on the unreduced path too")
    func nonFiniteInputIsRefusedWhenUnreduced() {
        var values = [Float](repeating: 0.5, count: 2 * 2 * 3)
        values[7] = .infinity
        let image = PreviewTestData.working(width: 2, height: 2, values: values)
        #expect(throws: PreviewReductionError.self) {
            _ = try Self.reducer.reduce(image, policy: .workspace)
        }
    }

    // MARK: - Cancellation

    /// The same contract `ImageOrienter` and `DisplayPreviewRenderer` follow:
    /// one poll before anything is allocated, one per destination row.
    @Test("A complete reduction polls once plus once per destination row")
    func pollCountIsDeterministic() throws {
        let image = PreviewTestData.working(width: 40, height: 40) { _, _, _ in 0.25 }
        let probe = CancellationProbe()
        let reduced = try Self.reducer.reduce(
            image,
            policy: PreviewResolutionPolicy(maximumLongestEdge: 10),
            cancellation: probe.cancellation
        )
        #expect(reduced.height == 10)
        #expect(probe.pollCount == 11)
    }

    @Test("A reduction cancelled before it allocates throws and builds nothing")
    func cancellationBeforeAllocation() {
        let image = PreviewTestData.working(width: 40, height: 40) { _, _, _ in 0.25 }
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            _ = try Self.reducer.reduce(
                image,
                policy: PreviewResolutionPolicy(maximumLongestEdge: 10),
                cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 1)
    }

    /// Cancelling part-way abandons the buffer rather than returning an image
    /// with some rows written and the rest not.
    @Test("A reduction cancelled mid-pass stops there and returns no image")
    func cancellationMidPass() {
        let image = PreviewTestData.working(width: 100, height: 100) { _, _, _ in 0.25 }
        let probe = CancellationProbe(cancelAfterPolls: 4)
        #expect(throws: CancellationError.self) {
            _ = try Self.reducer.reduce(
                image,
                policy: PreviewResolutionPolicy(maximumLongestEdge: 25),
                cancellation: probe.cancellation
            )
        }
        // One before allocation, then rows 0, 1 and 2 before the fourth poll
        // refuses: three of twenty-five rows were written, not twenty-five.
        #expect(probe.pollCount == 4)
    }

    /// Cancellation is not a processing failure, and the types say so.
    @Test("Cancellation is CancellationError, never a PreviewReductionError")
    func cancellationIsNotAFailure() {
        let image = PreviewTestData.working(width: 40, height: 40) { _, _, _ in 0.25 }
        let probe = CancellationProbe(cancelAfterPolls: 2)
        do {
            _ = try Self.reducer.reduce(
                image,
                policy: PreviewResolutionPolicy(maximumLongestEdge: 10),
                cancellation: probe.cancellation
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Correct.
        } catch {
            Issue.record("Cancellation reported as \(type(of: error))")
        }
    }
}

/// The creative stage, on a reduced image.
@Suite("Channel mixing at preview resolution")
struct PreviewChannelMixTests {

    static func reduced() throws -> SceneLinearPreviewImage {
        let image = PreviewTestData.working(width: 8, height: 8) { row, column, channel in
            Float(row * 8 + column) / 64 + Float(channel) / 4
        }
        return try SceneLinearPreviewReducer().reduce(
            image, policy: PreviewResolutionPolicy(maximumLongestEdge: 4)
        )
    }

    @Test("A mix applied to a reduced image is recorded on it")
    func theMixIsRecorded() throws {
        let mixed = try IRChannelMixer().apply(to: try Self.reduced(), mix: .redBlueSwap)
        #expect(mixed.processing.mix == .redBlueSwap)
        #expect(mixed.processing.channelMixApplied)
        #expect(mixed.processing.channelMixProcessing.mixSource == .redBlueSwap)
        // The reduction record survives the mix untouched.
        #expect(mixed.processing.resolution.sourceWidth == 8)
        #expect(mixed.processing.resolution.width == 4)
    }

    @Test("The red/blue swap moves channels exactly, at preview resolution")
    func theSwapIsExact() throws {
        let reduced = try Self.reduced()
        let mixed = try IRChannelMixer().apply(to: reduced, mix: .redBlueSwap)
        for row in 0..<reduced.height {
            for column in 0..<reduced.width {
                let before = try #require(reduced.pixel(row: row, column: column))
                let after = try #require(mixed.pixel(row: row, column: column))
                #expect(after.red.bitPattern == before.blue.bitPattern)
                #expect(after.green.bitPattern == before.green.bitPattern)
                #expect(after.blue.bitPattern == before.red.bitPattern)
            }
        }
    }

    @Test("Identity leaves every bit pattern alone")
    func identityIsExact() throws {
        let reduced = try Self.reduced()
        let mixed = try IRChannelMixer().apply(to: reduced, mix: .identity)
        #expect(zip(mixed.values, reduced.values).allSatisfy { $0.bitPattern == $1.bitPattern })
    }

    // Two tests used to live here and cannot be written any more, which is
    // the point of them no longer existing:
    //
    //   "a second mix on an already-mixed preview is refused"
    //   "orienting an unmixed preview is refused"
    //
    // Both exercised runtime guards on one reduced image type that stood for
    // the pre-mix and post-mix states at once. There are now two types, so
    // `IRChannelMixer().apply(to: mixedPreview, ...)` and
    // `ImageOrienter().apply(to: unmixedPreview, ...)` do not compile, and a
    // test can no longer construct either mistake to assert that it is
    // refused. Mixes never compose because there is nothing to compose them
    // with. See `docs/decisions/0016-interactive-channel-mixer.md`.
    //
    // What can still be written is the positive half, and it is, below: a mix
    // runs exactly once on a pre-mix image, and orienting the result carries
    // the whole chain.

    /// The mix is applied to the reduced pre-mix values themselves, so two
    /// different mixes of one source are independent renderings rather than a
    /// sequence.
    @Test("Two mixes of one preview are each applied to the unmixed values")
    func eachMixStartsFromTheUnmixedValues() throws {
        let reduced = try Self.reduced()
        let mixer = IRChannelMixer()

        let swapped = try mixer.apply(to: reduced, mix: .redBlueSwap)
        let swappedAgain = try mixer.apply(to: reduced, mix: .redBlueSwap)
        let identity = try mixer.apply(to: reduced, mix: .identity)

        // Two swaps of the same source are the same rendering. Had the second
        // composed onto the first, it would be the identity instead.
        #expect(swapped.values == swappedAgain.values)
        #expect(
            zip(identity.values, reduced.values).allSatisfy {
                $0.bitPattern == $1.bitPattern
            }
        )
        // And the source itself is untouched by either.
        #expect(reduced.values == (try Self.reduced()).values)
    }

    @Test("Orienting a mixed preview records the reduction on its provenance")
    func orientationCarriesTheReduction() throws {
        let mixed = try IRChannelMixer().apply(to: try Self.reduced(), mix: .identity)
        let oriented = try ImageOrienter().apply(
            to: mixed, orientation: .rotated90Clockwise
        )
        #expect(oriented.width == 4)
        #expect(oriented.height == 4)
        #expect(oriented.processing.sourceReducedForPreview)
        #expect(oriented.processing.previewResolution?.sourceWidth == 8)
        #expect(oriented.processing.previewResolution?.width == 4)
        #expect(oriented.processing.orientationApplied)
        #expect(!oriented.processing.scaled)
    }
}
