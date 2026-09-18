import Foundation
import Testing
@testable import InfraredConverter

/// The contrast stage: what it does to an image, what it refuses, and what it
/// deliberately does not do.
@Suite("Global contrast applier")
struct GlobalContrastApplierTests {

    static let applier = GlobalContrastApplier()

    static func leveled(
        width: Int, height: Int, values: [Float],
        blackPoint: Double = 0, whitePoint: Double = 1
    ) -> LeveledLinearRGBImage {
        DisplayPreviewTestData.leveledImage(
            width: width, height: height, values: values,
            processing: DisplayPreviewTestData.levelsProcessing(
                blackPoint: blackPoint, whitePoint: whitePoint
            )
        )
    }

    /// A tiny decoded mosaic, so the wrapper chain can be built end to end
    /// without a fixture.
    static func decodedStub() -> DecodedRAWMosaic {
        let width = 4
        let height = 4
        let samples = (0..<(width * height)).map { UInt16(100 + $0 * 37) }
        let mosaic = RAWMosaic(
            width: width,
            height: height,
            bytesPerRow: width * 2,
            samples: samples.withUnsafeBufferPointer { Data(buffer: $0) },
            sampleFormat: .uint16,
            sourceRawBitDepth: 12,
            sensorColorLayout: RAWTestData.bayerLayout()
        )
        var metadata = RAWTestData.metadata()
        metadata.levels = .init(black: 0, perPlaneBlack: [0, 0, 0, 0], maximum: 4095)
        return DecodedRAWMosaic(
            url: URL(fileURLWithPath: "/tmp/contrast-stage.orf"),
            metadata: metadata,
            mosaic: mosaic,
            processing: RAWMosaicProcessing(
                decoderIdentifier: "Stub",
                sourceStorage: .singleChannel,
                sourceRowPitch: width,
                destinationRowStride: width
            )
        )
    }

    /// The curve, from the specification — not from `GlobalContrastCurve`.
    static func reference(_ value: Float, amount: Double) -> Float {
        guard value > 0, value < 1 else { return value }
        let k = exp2(amount)
        let x = Double(value)
        return Float(pow(x, k) / (pow(x, k) + pow(1 - x, k)))
    }

    // MARK: - Every channel gets the same curve

    @Test("All three channels are curved by the same single amount")
    func everyChannelUsesTheSameCurve() throws {
        // One pixel whose three components differ, so a per-channel curve
        // would have to be visible.
        let image = Self.leveled(width: 1, height: 1, values: [0.2, 0.5, 0.8])
        let result = try Self.applier.apply(
            to: image, curve: GlobalContrastCurve(amount: 0.6)
        )

        #expect(result.values[0] == Self.reference(0.2, amount: 0.6))
        #expect(result.values[1] == Self.reference(0.5, amount: 0.6))
        #expect(result.values[2] == Self.reference(0.8, amount: 0.6))

        // Equal inputs produce equal outputs in every channel, which is the
        // same claim from the other side.
        let flat = try Self.applier.apply(
            to: Self.leveled(width: 1, height: 1, values: [0.3, 0.3, 0.3]),
            curve: GlobalContrastCurve(amount: -0.4)
        )
        #expect(flat.values[0] == flat.values[1])
        #expect(flat.values[1] == flat.values[2])
    }

    /// There is no per-channel form at all: the stage's only parameter is one
    /// curve, and its provenance says so.
    @Test("The stage exposes no per-channel parameter")
    func thereIsNoPerChannelParameter() throws {
        let result = try Self.applier.apply(
            to: Self.leveled(width: 1, height: 1, values: [0.2, 0.5, 0.8]),
            curve: GlobalContrastCurve(amount: 0.5)
        )
        #expect(!result.processing.perChannelCurveApplied)
        #expect(result.processing.curve == GlobalContrastCurve(amount: 0.5))
    }

    // MARK: - Geometry

    @Test("Geometry is untouched, value by value")
    func geometryIsUnchanged() throws {
        let values = (0..<(3 * 4 * 3)).map { Float($0) / 100 }
        let image = Self.leveled(width: 3, height: 4, values: values)
        let result = try Self.applier.apply(
            to: image, curve: GlobalContrastCurve(amount: 0.5)
        )

        #expect(result.width == 3)
        #expect(result.height == 4)
        #expect(result.values.count == values.count)
        #expect(result.isGeometryConsistent)
        #expect(!result.processing.interpolated)
        #expect(!result.processing.scaled)
        #expect(!result.processing.cropped)

        // Each component is its own input's curve, in place — nothing moved.
        for (index, input) in values.enumerated() {
            #expect(result.values[index] == Self.reference(input, amount: 0.5))
        }
    }

    @Test("An image whose buffer does not match its dimensions is refused")
    func inconsistentGeometryIsRefused() {
        let broken = LeveledLinearRGBImage(
            width: 4, height: 4, values: [0, 0, 0],
            processing: DisplayPreviewTestData.levelsProcessing()
        )
        #expect(throws: GlobalContrastError.self) {
            try Self.applier.apply(to: broken, curve: .neutral)
        }
    }

    // MARK: - Refusals

    @Test("A non-finite input is refused, naming its coordinate and channel")
    func aNonFiniteInputIsRefused() {
        let broken = Self.leveled(
            width: 2, height: 1, values: [0.1, 0.2, 0.3, 0.4, .infinity, 0.6]
        )
        #expect(
            throws: GlobalContrastError.nonFiniteLinearInput(
                row: 0, column: 1, channel: .green, value: .infinity
            )
        ) {
            try Self.applier.apply(to: broken, curve: GlobalContrastCurve(amount: 0.5))
        }
    }

    /// Even at neutral contrast — the fast path validates too, so the stage's
    /// output contract holds identically on both paths.
    @Test("The neutral fast path refuses a non-finite input as well")
    func theNeutralPathValidatesItsInput() {
        let broken = Self.leveled(
            width: 2, height: 1, values: [0.1, 0.2, 0.3, 0.4, 0.5, .nan]
        )
        #expect(throws: GlobalContrastError.self) {
            try Self.applier.apply(to: broken, curve: .neutral)
        }
        // And the same image is refused at a non-neutral amount, so the two
        // paths agree about what is acceptable.
        #expect(throws: GlobalContrastError.self) {
            try Self.applier.apply(to: broken, curve: GlobalContrastCurve(amount: 1))
        }
    }

    @Test("A curve whose exponent is unusable is refused rather than applied")
    func anInapplicableCurveIsRefused() {
        let image = Self.leveled(width: 1, height: 1, values: [0.5, 0.5, 0.5])
        #expect(
            throws: GlobalContrastError.nonApplicableContrast(
                amount: .infinity, exponent: .infinity
            )
        ) {
            try Self.applier.apply(to: image, curve: GlobalContrastCurve(amount: .infinity))
        }
        #expect(throws: GlobalContrastError.self) {
            try Self.applier.apply(to: image, curve: GlobalContrastCurve(amount: 2000))
        }
    }

    @Test("The refusals carry readable reasons")
    func theRefusalsAreInformative() {
        let cases: [GlobalContrastError] = [
            .invalidGeometry(reason: "mismatch"),
            .nonApplicableContrast(amount: .nan, exponent: .nan),
            .nonFiniteLinearInput(row: 1, column: 2, channel: .red, value: .nan),
            .nonFiniteToneCurvedValue(
                row: 1, column: 2, channel: .blue,
                contrastAmount: 0.5, contrastExponent: 1.41
            ),
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.failureReason?.isEmpty == false)
        }
    }

    // MARK: - Cancellation

    @Test("A cancelled call throws before it allocates anything")
    func cancellationAtEntryDoesNoWork() {
        let probe = CancellationProbe(cancelAfterPolls: 1)
        let image = Self.leveled(
            width: 2, height: 3, values: Array(repeating: 0.5, count: 18)
        )
        #expect(throws: CancellationError.self) {
            try Self.applier.apply(
                to: image,
                curve: GlobalContrastCurve(amount: 0.5),
                cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 1)
    }

    /// Once at entry, then once per row — the established granularity, and the
    /// same on both the curved and the neutral paths.
    @Test("Cancellation is polled once at entry and once per row")
    func cancellationIsPolledPerRow() throws {
        let rows = 7
        let image = Self.leveled(
            width: 2, height: rows, values: Array(repeating: 0.5, count: rows * 2 * 3)
        )

        let curved = CancellationProbe()
        _ = try Self.applier.apply(
            to: image,
            curve: GlobalContrastCurve(amount: 0.5),
            cancellation: curved.cancellation
        )
        #expect(curved.pollCount == 1 + rows)

        let neutral = CancellationProbe()
        _ = try Self.applier.apply(
            to: image, curve: .neutral, cancellation: neutral.cancellation
        )
        #expect(neutral.pollCount == 1 + rows)
    }

    @Test("A cancelled pass returns no image, not a partially curved one")
    func cancellationReturnsNothing() {
        let probe = CancellationProbe(cancelAfterPolls: 3)
        let image = Self.leveled(
            width: 2, height: 20, values: Array(repeating: 0.5, count: 120)
        )
        let result = Result {
            try Self.applier.apply(
                to: image,
                curve: GlobalContrastCurve(amount: 0.5),
                cancellation: probe.cancellation
            )
        }
        guard case .failure(let error) = result else {
            Issue.record("A cancelled pass should not produce an image.")
            return
        }
        #expect(error is CancellationError)
        // Cancellation is not a processing failure.
        #expect(!(error is GlobalContrastError))
    }

    // MARK: - The neutral fast path

    @Test("Neutral contrast hands the same buffer back, bit for bit")
    func theNeutralPathIsTheIdentity() throws {
        let values: [Float] = [
            -0.0, 0, .leastNonzeroMagnitude, 0.25, 0.5, 1, 1.7, -0.25, 1e30,
        ]
        let image = Self.leveled(width: 3, height: 1, values: values)
        let result = try Self.applier.apply(to: image, curve: .neutral)

        #expect(result.values == values)
        for index in 0..<values.count {
            #expect(
                result.values[index].bitPattern == values[index].bitPattern,
                "component \(index) changed"
            )
        }
        // Including the sign of the negative zero.
        #expect(result.values[0].sign == .minus)
    }

    /// Bit-identical pixels, and provenance that still records the stage.
    @Test("Neutral contrast records that the stage was traversed")
    func theNeutralPathStillRecordsTheStage() throws {
        let image = Self.leveled(width: 1, height: 1, values: [0.2, 0.4, 0.6])
        let result = try Self.applier.apply(to: image, curve: .neutral)

        #expect(result.values == image.values)
        #expect(result.processing.contrastApplied)
        #expect(result.processing.toneCurveApplied)
        #expect(result.processing.contrastAmount == 0)
        #expect(result.processing.contrastExponent == 1)
        // The value-dependent fact is true here; the type's claim is not.
        #expect(result.processing.preservesLinearLightEncoding)
        #expect(!result.processing.linearLightEncoded)
    }

    // MARK: - Provenance

    @Test("The record states what ran and what did not")
    func provenanceIsHonest() throws {
        let image = Self.leveled(
            width: 1, height: 1, values: [0.2, 0.4, 0.6],
            blackPoint: 0.05, whitePoint: 0.95
        )
        let processing = try Self.applier.apply(
            to: image, curve: GlobalContrastCurve(amount: 0.35)
        ).processing

        // What this stage did.
        #expect(processing.contrastApplied)
        #expect(processing.toneCurveApplied)
        #expect(processing.contrastAmount == 0.35)
        #expect(processing.contrastExponent == exp2(0.35))
        #expect(!processing.preservesLinearLightEncoding)

        // What it is not.
        #expect(!processing.clamped)
        #expect(!processing.histogramRead)
        #expect(!processing.automaticContrastApplied)
        #expect(!processing.automaticLevelsApplied)
        #expect(!processing.localContrastApplied)
        #expect(!processing.perChannelCurveApplied)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.gammaApplied)
        #expect(!processing.displayEncodingApplied)
        #expect(!processing.quantized)
        #expect(!processing.saturationApplied)
        #expect(!processing.sharpeningApplied)
        #expect(!processing.highlightReconstructionApplied)
        #expect(!processing.shadowRecoveryApplied)

        // Neither linear-light nor scene-linear any more.
        #expect(!processing.linearLightEncoded)
        #expect(!processing.sceneLinear)

        // And the whole upstream chain is forwarded, not restated.
        #expect(processing.levelsApplied)
        #expect(processing.blackPoint == 0.05)
        #expect(processing.whitePoint == 0.95)
        #expect(processing.levelsProcessing.linearLightEncoded)
        #expect(processing.exposureApplied)
        #expect(processing.orientationApplied)
        #expect(processing.channelMixApplied)
        #expect(processing.demosaiced)
        #expect(processing.whiteBalanceApplied)
        #expect(processing.normalized)
        #expect(processing.diagnosticDescription.contains("no longer linear-light"))
    }

    // MARK: - No clipping

    @Test("Out-of-range values keep their magnitude and stay distinct")
    func nothingIsClipped() throws {
        let values: [Float] = [-0.25, -0.5, 1.4, 1.7, 5, -3, 0.5, 0.25, 0.75]
        let image = Self.leveled(width: 3, height: 1, values: values)
        let result = try Self.applier.apply(
            to: image, curve: GlobalContrastCurve(amount: 1)
        )

        #expect(result.values[0] == -0.25)
        #expect(result.values[1] == -0.5)
        #expect(result.values[2] == 1.4)
        #expect(result.values[3] == 1.7)
        #expect(result.values[4] == 5)
        #expect(result.values[5] == -3)
        #expect(result.values[0] != result.values[1])
        #expect(result.values[2] != result.values[3])
        #expect(!result.processing.clamped)

        // And the values inside the interval did move, so the stage is not
        // simply doing nothing.
        #expect(result.values[7] < 0.25)
        #expect(result.values[8] > 0.75)
    }

    // MARK: - Replacement, not composition

    @Test("A second curve replaces the first, starting from the levelled image")
    func curvesDoNotCompose() throws {
        let values: [Float] = [0.2, 0.4, 0.6, 0.8, 0.3, 0.7]
        let image = Self.leveled(width: 2, height: 1, values: values)

        let first = try Self.applier.apply(
            to: image, curve: GlobalContrastCurve(amount: 0.5)
        )
        let composedByHand = try Self.applier.apply(
            to: DisplayPreviewTestData.leveledImage(
                width: 2, height: 1, values: first.values
            ),
            curve: GlobalContrastCurve(amount: 0.75)
        )
        let second = try Self.applier.apply(
            to: image, curve: GlobalContrastCurve(amount: 0.75)
        )

        // Applying 0.75 to the source is not applying it to the 0.5 result,
        // and the difference is real rather than a rounding artefact.
        #expect(second.values != composedByHand.values)
        for index in 0..<values.count {
            #expect(second.values[index] == Self.reference(values[index], amount: 0.75))
        }

        // And two curves do not compose into a third amount of this family:
        // no single amount reproduces 0.5 then 0.75.
        #expect(
            composedByHand.values
                != values.map { Self.reference($0, amount: 1.25) }
        )
    }

    /// Structurally rather than by arithmetic: the wrapper's `replacing:`
    /// overload reaches through `source`, so it cannot chain even in principle.
    @Test("Replacing a curve on a wrapper restarts from the levelled source")
    func replacingRestartsFromTheSource() throws {
        let decoded = Self.decodedStub()
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let balanced = try RAWWhiteBalancer().apply(to: normalized, gains: .identity)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)
        let working = try RAWWorkingColorConverter()
            .convert(demosaiced, using: .sensorRGBIdentityFalseColor)
        let mixed = try IRChannelMixer().apply(to: working, mix: .identity)
        let oriented = try ImageOrienter().apply(to: mixed, orientation: .upright)
        let exposed = try SceneLinearExposer().apply(to: oriented, exposure: .neutral)
        let leveled = try LinearLevelsApplier().apply(to: exposed, levels: .neutral)

        let first = try Self.applier.apply(
            to: leveled, curve: GlobalContrastCurve(amount: 0.5)
        )
        let replaced = try Self.applier.apply(
            curve: GlobalContrastCurve(amount: -0.5), replacing: first
        )
        let direct = try Self.applier.apply(
            to: leveled, curve: GlobalContrastCurve(amount: -0.5)
        )

        #expect(replaced.image.values == direct.image.values)
        // The levelled buffer underneath is the same one, bit for bit — no
        // upstream stage reran.
        #expect(replaced.leveledImage.values == leveled.image.values)
        #expect(replaced.source.image == leveled.image)
        #expect(replaced.curve.amount == -0.5)
    }
}
