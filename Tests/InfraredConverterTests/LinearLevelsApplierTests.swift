import Testing
import Foundation
@testable import InfraredConverter

/// The levels stage: what it applies, what it refuses, what it records, and
/// what it deliberately does not do.
@Suite("LinearLevelsApplier")
struct LinearLevelsApplierTests {

    static let tolerance: Float = 1e-6

    static func exposed(
        width: Int,
        height: Int,
        values: [Float],
        exposureEV: Double = 0
    ) -> ExposedSceneLinearRGBImage {
        DisplayPreviewTestData.exposedImage(
            width: width,
            height: height,
            values: values,
            processing: DisplayPreviewTestData.exposureProcessing(exposureEV: exposureEV)
        )
    }

    static func pixel(_ red: Float, _ green: Float, _ blue: Float)
        -> ExposedSceneLinearRGBImage {
        exposed(width: 1, height: 1, values: [red, green, blue])
    }

    static func levels(_ black: Double, _ white: Double) -> LinearLevels {
        LinearLevels(blackPoint: black, whitePoint: white)
    }

    // MARK: - The arithmetic, per component

    @Test("Every component is levelled by the documented equation")
    func everyComponentIsLevelled() throws {
        let values: [Float] = [
            -0.2, 0, 0.1,
            0.25, 0.5, 0.75,
            0.9, 1.0, 1.4,
            2.5, -1.0, 0.33,
        ]
        let levels = Self.levels(0.1, 0.9)
        let result = try LinearLevelsApplier().apply(
            to: Self.exposed(width: 2, height: 2, values: values), levels: levels
        )

        #expect(result.width == 2)
        #expect(result.height == 2)
        #expect(result.values.count == values.count)
        for (offset, input) in values.enumerated() {
            // Written out here rather than taken from the primitive.
            let expected = Float((Double(input) - 0.1) * (1 / 0.8))
            #expect(abs(result.values[offset] - expected) <= Self.tolerance, "element \(offset)")
        }
    }

    /// The three components of one pixel get the same two numbers. There are
    /// no per-channel levels and no way to ask for any.
    @Test("All three channels are levelled identically")
    func thereAreNoPerChannelLevels() throws {
        let result = try LinearLevelsApplier().apply(
            to: Self.pixel(0.4, 0.4, 0.4), levels: Self.levels(-0.1, 1.3)
        )
        let pixel = try #require(result.pixel(row: 0, column: 0))
        #expect(pixel.red == pixel.green)
        #expect(pixel.green == pixel.blue)
        #expect(!result.processing.perChannelLevelsApplied)
    }

    /// A component's result cannot depend on its neighbours in the pixel.
    @Test("A component's result does not depend on the other two")
    func componentsDoNotInfluenceEachOther() throws {
        let probe: Float = 0.4
        let levels = Self.levels(0.05, 0.95)
        let expected = try LinearLevelsApplier()
            .apply(to: Self.pixel(probe, probe, probe), levels: levels)
            .values[0]

        for (green, blue) in [(Float(0), Float(0)), (1, 1), (-3, 5), (0.001, 0.999)] {
            let result = try LinearLevelsApplier().apply(
                to: Self.pixel(probe, green, blue), levels: levels
            )
            #expect(result.values[0] == expected, "companions \(green), \(blue)")
        }
    }

    // MARK: - The identity

    /// Neutral levels hand the input's own buffer back, bit for bit — which is
    /// both the correctness claim and the reason a neutral export allocates
    /// nothing here.
    @Test("Neutral levels reproduce the input bit for bit")
    func neutralLevelsAreBitIdentical() throws {
        let values: [Float] = [
            -0.5, 0, 1e-30, 0.25, 0.5, 1, 1.5, -0.0, 12,
            .leastNonzeroMagnitude, .greatestFiniteMagnitude, 0.1,
        ]
        let input = Self.exposed(width: 2, height: 2, values: values)
        let result = try LinearLevelsApplier().apply(to: input, levels: .neutral)

        #expect(result.values == values)
        for index in 0..<values.count
        where result.values[index].bitPattern != values[index].bitPattern {
            Issue.record("element \(index) changed bit pattern")
        }
        // Still recorded as having run — asking for the identity is a
        // different fact from never traversing the stage.
        #expect(result.processing.levelsApplied)
        #expect(result.processing.levels.isIdentity)
    }

    // MARK: - No clipping

    /// The property the destination's range policy depends on: nothing here
    /// clamps, so an out-of-range result reaches the encoder with its
    /// magnitude intact.
    @Test("Out-of-range results survive the stage, in both directions")
    func nothingIsClipped() throws {
        let result = try LinearLevelsApplier().apply(
            to: Self.exposed(width: 2, height: 1, values: [-0.2, 0.5, 2.0, 0, 1, 1.4]),
            levels: Self.levels(0.1, 0.9)
        )

        #expect(result.values[0] < 0)
        #expect(abs(result.values[0] - Float(-0.375)) <= Self.tolerance)
        #expect(result.values[2] > 1)
        #expect(abs(result.values[2] - Float(2.375)) <= Self.tolerance)
        #expect(result.values[5] > 1)

        // And the record says so rather than leaving it to be inferred.
        #expect(!result.processing.clamped)
    }

    /// The mistake this stage must never make, stated as a test: a
    /// `min(max(x, 0), 1)` inside the stage would make these equal.
    @Test("A value pushed below zero is not the same as one pushed to zero")
    func theStageDoesNotClampToTheUnitCube() throws {
        let applier = LinearLevelsApplier()
        let levels = Self.levels(0.5, 1.0)
        let deep = try applier.apply(to: Self.pixel(0, 0, 0), levels: levels)
        let shallow = try applier.apply(to: Self.pixel(0.25, 0.25, 0.25), levels: levels)
        #expect(deep.values[0] < shallow.values[0])
        #expect(deep.values[0] < 0)
        #expect(shallow.values[0] < 0)
    }

    // MARK: - No composition

    /// Levels are a state, not a history. Applying a second setting to the
    /// exposed image is the second setting — never the composition of the two,
    /// which would be a third perfectly plausible affine map.
    @Test("A second levels setting restarts from the exposed image")
    func levelsNeverCompose() throws {
        let applier = LinearLevelsApplier()
        let source = Self.exposed(
            width: 2, height: 1, values: [0.1, 0.3, 0.5, 0.7, 0.9, 1.1]
        )
        let first = Self.levels(0.1, 0.9)
        let second = Self.levels(0.2, 1.5)

        let once = try applier.apply(to: source, levels: second)
        let twice = try applier.apply(
            to: Self.exposed(
                width: 2, height: 1,
                values: try applier.apply(to: source, levels: first).values
            ),
            levels: second
        )

        #expect(once.values != twice.values)
        // The composition is itself a valid affine map, which is exactly why
        // it would go unnoticed: it never looks malformed.
        #expect(twice.values.allSatisfy { $0.isFinite })

        // Returning to neutral reproduces the exposed source exactly, which
        // composition could not do: `neutral(second(source))` is `second`,
        // while `neutral` applied to `source` is `source`.
        let back = try applier.apply(to: source, levels: .neutral)
        #expect(back.values == source.values)

        // `LeveledProcessedRAWImage`'s `replacing:` overload makes this
        // structural rather than a matter of discipline; it is exercised over
        // the whole chain in `DisplayPreviewProvenanceTests`.
    }

    // MARK: - Refusals

    @Test("An image whose buffer does not match its dimensions is refused")
    func inconsistentGeometryIsRefused() {
        #expect {
            _ = try LinearLevelsApplier().apply(
                to: Self.exposed(
                    width: 2, height: 2, values: [Float](repeating: 0.5, count: 9)
                ),
                levels: .neutral
            )
        } throws: { error in
            guard case .invalidGeometry = error as? LinearLevelsError else { return false }
            return true
        }
    }

    @Test(
        "Levels that cannot be applied are refused, with their span and scale",
        arguments: [
            (Double.nan, 1.0), (0.0, Double.infinity), (0.5, 0.5), (0.9, 0.1),
            (-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
        ]
    )
    func inapplicableLevelsAreRefused(black: Double, white: Double) {
        #expect {
            _ = try LinearLevelsApplier().apply(
                to: Self.pixel(0.5, 0.5, 0.5), levels: Self.levels(black, white)
            )
        } throws: { error in
            guard case .nonApplicableLevels(let reportedBlack, _, _, _) =
                    error as? LinearLevelsError else { return false }
            return black.isNaN ? reportedBlack.isNaN : reportedBlack == black
        }
    }

    /// Geometry is checked before the levels, so a broken image reports the
    /// broken image rather than whatever the levels happen to be.
    @Test("Geometry is refused before the levels are even considered")
    func geometryIsCheckedFirst() {
        #expect {
            _ = try LinearLevelsApplier().apply(
                to: Self.exposed(
                    width: 4, height: 4, values: [Float](repeating: 0.5, count: 3)
                ),
                levels: Self.levels(.nan, .nan)
            )
        } throws: { error in
            guard case .invalidGeometry = error as? LinearLevelsError else { return false }
            return true
        }
    }

    @Test(
        "A non-finite input is refused with its coordinate, on both paths",
        arguments: [Float.nan, .infinity, -.infinity]
    )
    func nonFiniteInputsAreRefused(poison: Float) {
        // Both paths: the identity fast path runs its own sweep, so an image
        // containing a NaN is refused at neutral levels exactly as it is at
        // any other.
        for levels in [LinearLevels.neutral, Self.levels(0.1, 0.9)] {
            for channel in RAWLinearRGBChannel.allCases {
                var values = (0..<12).map { Float($0) * 0.05 }
                values[(1 * 2 + 0) * 3 + channel.storageOffset] = poison
                #expect {
                    _ = try LinearLevelsApplier().apply(
                        to: Self.exposed(width: 2, height: 2, values: values),
                        levels: levels
                    )
                } throws: { error in
                    guard case .nonFiniteLinearInput(let row, let column, let reported, _) =
                            error as? LinearLevelsError else { return false }
                    return row == 1 && column == 0 && reported == channel
                }
            }
        }
    }

    /// A finite input, finite levels, and a product `Float32` cannot hold.
    /// Refused rather than left to the clip: an infinity would clip to `1` and
    /// reach a file as an ordinary white pixel.
    @Test("A value that overflows Float32 is refused, not clipped")
    func overflowIsRefusedRatherThanClipped() {
        let levels = Self.levels(0, 1e-30)
        #expect(levels.isApplicable)
        #expect {
            _ = try LinearLevelsApplier().apply(
                to: Self.exposed(
                    width: 2, height: 1,
                    values: [0.5, 0.5, 0.5, 0.25, .greatestFiniteMagnitude, 0.75]
                ),
                levels: levels
            )
        } throws: { error in
            guard case .nonFiniteLeveledValue(let row, let column, let channel, _, _) =
                    error as? LinearLevelsError else { return false }
            return row == 0 && column == 1 && channel == .green
        }
    }

    @Test("Every case carries a description and a reason")
    func errorsDescribeThemselves() {
        let errors: [LinearLevelsError] = [
            .invalidGeometry(reason: "2x2 needs 12 values, buffer holds 9."),
            .nonApplicableLevels(blackPoint: 1, whitePoint: 0, span: -1, scale: -1),
            .nonFiniteLinearInput(row: 3, column: 4, channel: .green, value: .infinity),
            .nonFiniteLeveledValue(
                row: 5, column: 6, channel: .blue, blackPoint: 0, whitePoint: 1e-30
            ),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.failureReason?.isEmpty == false)
        }
        #expect(errors[2].failureReason?.contains("row 3, column 4") == true)
        #expect(errors[3].failureReason?.contains("row 5, column 6") == true)
    }

    // MARK: - Cancellation

    @Test("A signal that never fires is polled once per row plus once at entry")
    func aCompleteRunPollsOncePerRow() throws {
        for levels in [LinearLevels.neutral, Self.levels(0.1, 0.9)] {
            let probe = CancellationProbe()
            _ = try LinearLevelsApplier().apply(
                to: Self.exposed(
                    width: 4, height: 10,
                    values: (0..<120).map { Float($0) / 200 }
                ),
                levels: levels,
                cancellation: probe.cancellation
            )
            #expect(probe.pollCount == 1 + 10)
        }
    }

    @Test("A cancelled call throws before it allocates anything")
    func cancelledAtEntryDoesNoWork() {
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try LinearLevelsApplier().apply(
                to: Self.exposed(
                    width: 4, height: 10, values: (0..<120).map { Float($0) / 200 }
                ),
                levels: Self.levels(0.1, 0.9),
                cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 1)
    }

    /// Cancellation is not a processing failure, and produces no image at all
    /// — never a buffer with some rows levelled and the rest not.
    @Test("A cancelled call returns nothing, and is not a levels error")
    func cancellationIsNotAFailure() {
        let probe = CancellationProbe(cancelAfterPolls: 4)
        let result = Result {
            try LinearLevelsApplier().apply(
                to: Self.exposed(
                    width: 4, height: 10, values: (0..<120).map { Float($0) / 200 }
                ),
                levels: Self.levels(0.1, 0.9),
                cancellation: probe.cancellation
            )
        }
        guard case .failure(let error) = result else {
            Issue.record("Expected the work to be abandoned")
            return
        }
        #expect(error is CancellationError)
        #expect(!(error is LinearLevelsError))
        #expect(probe.pollCount == 4)
    }

    // MARK: - Provenance

    @Test("The record states what ran, what it means, and what did not run")
    func provenanceIsHonest() throws {
        let result = try LinearLevelsApplier().apply(
            to: Self.exposed(
                width: 1, height: 1, values: [0.2, 0.4, 0.6], exposureEV: 1.5
            ),
            levels: Self.levels(0.05, 1.2)
        )
        let processing = result.processing

        // What this stage did.
        #expect(processing.levelsApplied)
        #expect(processing.blackPoint == 0.05)
        #expect(processing.whitePoint == 1.2)
        #expect(processing.levels == Self.levels(0.05, 1.2))

        // What the values now are — and the one claim that stopped being true.
        #expect(processing.linearLightEncoded)
        #expect(!processing.sceneLinear)
        #expect(!processing.preservesProportionalityToSceneRadiance)

        // What it did not do. Every one of these names something an affine
        // rescale is routinely mistaken for.
        #expect(!processing.clamped)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.toneCurveApplied)
        #expect(!processing.contrastApplied)
        #expect(!processing.automaticLevelsApplied)
        #expect(!processing.histogramRead)
        #expect(!processing.highlightReconstructionApplied)
        #expect(!processing.shadowRecoveryApplied)
        #expect(!processing.gammaApplied)
        #expect(!processing.displayEncodingApplied)
        #expect(!processing.quantized)
        #expect(!processing.saturationApplied)
        #expect(!processing.sharpeningApplied)
        #expect(!processing.perChannelLevelsApplied)
        #expect(!processing.interpolated)
        #expect(!processing.scaled)
        #expect(!processing.cropped)

        // And the whole upstream chain is still readable through it.
        #expect(processing.exposureEV == 1.5)
        #expect(processing.exposureApplied)
        #expect(processing.exposureProcessing.sceneLinear)
        #expect(processing.orientation == .upright)
        #expect(processing.mix == .identity)
        #expect(processing.demosaicAlgorithm == .bilinearBayer)
        #expect(!processing.isValidatedInfraredCalibration)
    }

    /// A zero black point makes the map a pure gain, so proportionality
    /// survives — but `sceneLinear` stays `false`, because the question "is
    /// this scene-linear data?" should have one answer for a stage licensed to
    /// subtract an offset.
    @Test("A zero black point preserves proportionality without restoring sceneLinear")
    func aZeroBlackPointIsStillNotSceneLinear() throws {
        let result = try LinearLevelsApplier().apply(
            to: Self.pixel(0.2, 0.4, 0.6), levels: Self.levels(0, 2)
        )
        #expect(result.processing.preservesProportionalityToSceneRadiance)
        #expect(!result.processing.sceneLinear)
        #expect(result.processing.linearLightEncoded)

        // Neutral levels too: traversing the stage is what changes the claim,
        // not the numbers.
        let neutral = try LinearLevelsApplier().apply(
            to: Self.pixel(0.2, 0.4, 0.6), levels: .neutral
        )
        #expect(neutral.processing.preservesProportionalityToSceneRadiance)
        #expect(!neutral.processing.sceneLinear)
    }

    @Test("Geometry is preserved exactly: no crop, no resample, no resize")
    func geometryIsPreserved() throws {
        let result = try LinearLevelsApplier().apply(
            to: Self.exposed(
                width: 4, height: 3, values: (0..<36).map { Float($0) * 0.01 }
            ),
            levels: Self.levels(0.05, 0.95)
        )
        #expect(result.width == 4)
        #expect(result.height == 3)
        #expect(result.values.count == 36)
        #expect(result.isGeometryConsistent)
        #expect(result.valuesPerRow == 12)
        #expect(result.pixelCount == 12)
        #expect(result.storageIndex(row: 2, column: 3) == 33)
        #expect(result.storageIndex(row: 3, column: 0) == nil)
        #expect(result.value(row: 0, column: 0, channel: .red) != nil)
        #expect(result.pixel(row: 5, column: 5) == nil)
    }
}
