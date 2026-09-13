import Testing
import Foundation
@testable import InfraredConverter

/// The export boundary: clip, encode, quantise to 16 bits — and refuse a
/// preview.
@Suite("Export image encoder")
struct ExportImageEncoderTests {

    private static let settings = ExportRenderSettings.standard

    private static func encode(
        _ values: [Float],
        width: Int = 2,
        height: Int = 1,
        exposureEV: Double = 0
    ) throws -> ExportEncodedImage {
        try ExportImageEncoder().encode(
            try ExportTestData.exposed(
                width: width, height: height, values: values, exposureEV: exposureEV
            ),
            settings: settings
        )
    }

    // MARK: - Quantisation

    @Test("The export encoder applies the shared transfer function, not its own")
    func theEncoderUsesTheSharedTransferFunction() {
        // The export's independent reference implementation and the display
        // path's agree with the one function both encoders call. Three
        // separately written curves that agree is the claim; a fourth that
        // did not would be a silently lighter or darker export.
        for value in [0.0, 0.001, 0.0031308, 0.01, 0.25, 0.5, 0.75, 1.0] {
            #expect(
                ExportImageEncoder.encode(value, as: .sRGB)
                    == SRGBTransferFunction.encode(value)
            )
            #expect(SRGBTransferFunction.encode(value) == ExportTestData.referenceEncode(value))
            #expect(
                SRGBTransferFunction.encode(value)
                    == DisplayPreviewTestData.referenceEncode(value)
            )
        }
    }

    @Test("The quantiser's endpoints are exact")
    func theQuantiserEndpointsAreExact() {
        #expect(ExportImageEncoder.quantize(0) == 0)
        #expect(ExportImageEncoder.quantize(1) == 65535)
        // The midpoint of the *encoded* range rounds half away from zero.
        #expect(ExportImageEncoder.quantize(0.5) == 32768)
        #expect(ExportImageEncoder.quantize(0.25) == 16384)
        #expect(ExportImageEncoder.quantize(0.75) == 49151)
    }

    @Test("An encoded 1 recovers 65535 because of the rounding, not in spite of it")
    func theTopEndpointDependsOnRounding() {
        // sRGB's OETF evaluates to one ULP below 1 at 1, so truncation would
        // give 65534 and a white that is not quite white.
        let encoded = SRGBTransferFunction.encode(1)
        #expect(encoded < 1)
        #expect(UInt16((encoded * 65535).rounded(.down)) == 65534)
        #expect(ExportImageEncoder.quantize(encoded) == 65535)
    }

    @Test("The quantiser rounds half away from zero, like the 8-bit one")
    func theQuantiserRoundsHalfAwayFromZero() {
        // One sample either side of a half-step.
        let half = 0.5 / 65535
        #expect(ExportImageEncoder.quantize(half) == 1)
        #expect(ExportImageEncoder.quantize(half * 0.99) == 0)
    }

    // MARK: - The full boundary

    @Test("Known linear values encode to the sRGB curve at 16 bits")
    func knownValuesEncodeToTheCurve() throws {
        let inputs: [Float] = [0, 0.25, 0.5, 0.75, 1]
        let image = try Self.encode(
            inputs.flatMap { [$0, $0, $0] }, width: 5, height: 1
        )
        for (column, value) in inputs.enumerated() {
            let expected = ExportTestData.referenceSample(sceneLinear: value)
            #expect(image.sample(row: 0, column: column, channel: .red) == expected)
            #expect(image.sample(row: 0, column: column, channel: .green) == expected)
            #expect(image.sample(row: 0, column: column, channel: .blue) == expected)
        }
        // And the two endpoints, spelled out.
        #expect(image.sample(row: 0, column: 0, channel: .red) == 0)
        #expect(image.sample(row: 0, column: 4, channel: .red) == 65535)
    }

    @Test("Channels keep their order: R, G, B")
    func channelsKeepTheirOrder() throws {
        let image = try Self.encode([1, 0, 0, 0, 0, 1], width: 2, height: 1)
        #expect(image.pixel(row: 0, column: 0) == ExportEncodedRGBPixel(
            red: 65535, green: 0, blue: 0
        ))
        #expect(image.pixel(row: 0, column: 1) == ExportEncodedRGBPixel(
            red: 0, green: 0, blue: 65535
        ))
    }

    @Test("Rows keep their order, top first")
    func rowsKeepTheirOrder() throws {
        let image = try Self.encode(
            [0, 0, 0, 1, 1, 1],
            width: 1, height: 2
        )
        #expect(image.pixel(row: 0, column: 0)?.red == 0)
        #expect(image.pixel(row: 1, column: 0)?.red == 65535)
        #expect(image.samples.first == 0)
        #expect(image.samples.last == 65535)
    }

    // MARK: - Extended range

    @Test("Values outside 0...1 are clipped, and the clipping is counted")
    func outOfRangeValuesAreClippedAndCounted() throws {
        // One component below zero, one inside, one above: the milestone's
        // extended-range case.
        let image = try Self.encode([-0.25, 0.5, 1.5], width: 1, height: 1)
        #expect(image.sample(row: 0, column: 0, channel: .red) == 0)
        #expect(
            image.sample(row: 0, column: 0, channel: .green)
                == ExportTestData.referenceSample(sceneLinear: 0.5)
        )
        #expect(image.sample(row: 0, column: 0, channel: .blue) == 65535)
        #expect(image.processing.clippedLowSampleCount == 1)
        #expect(image.processing.clippedHighSampleCount == 1)
        #expect(image.processing.clippedSampleCount == 2)
    }

    @Test("Exposure happens before clipping, so a lift is recoverable")
    func exposureHappensBeforeClipping() throws {
        // 1.5 at −1 EV is 0.75 and must be encoded as 0.75, which is only
        // possible if nothing clipped it to 1 on the way. This is the display
        // path's invariant, proven again on the export path.
        let image = try Self.encode([-0.25, 0.5, 1.5], width: 1, height: 1, exposureEV: -1)
        #expect(
            image.sample(row: 0, column: 0, channel: .blue)
                == ExportTestData.referenceSample(sceneLinear: 0.75)
        )
        #expect(image.processing.clippedHighSampleCount == 0)
        // The negative component is still negative after a negative exposure.
        #expect(image.sample(row: 0, column: 0, channel: .red) == 0)
        #expect(image.processing.clippedLowSampleCount == 1)
        #expect(image.processing.exposureEV == -1)
    }

    @Test("A lift above white is clipped, and counted")
    func aLiftAboveWhiteIsClipped() throws {
        let image = try Self.encode([0.5, 0.5, 0.5], width: 1, height: 1, exposureEV: 2)
        #expect(image.samples == [65535, 65535, 65535])
        #expect(image.processing.clippedHighSampleCount == 3)
        #expect(image.processing.clippedLowSampleCount == 0)
    }

    @Test("Nothing outside the range means nothing counted")
    func nothingOutsideTheRangeMeansNothingCounted() throws {
        let image = try Self.encode([0, 0.5, 1], width: 1, height: 1)
        #expect(image.processing.clippedSampleCount == 0)
    }

    // MARK: - Geometry and provenance

    @Test("Geometry and sample count are what the declaration says")
    func geometryIsConsistent() throws {
        let image = try Self.encode(
            Array(repeating: 0.5, count: 3 * 4 * 3), width: 3, height: 4
        )
        #expect(image.width == 3)
        #expect(image.height == 4)
        #expect(image.samples.count == 36)
        #expect(image.isGeometryConsistent)
        #expect(image.samplesPerRow == 9)
        #expect(image.bytesPerRow == 18)
        #expect(ExportEncodedImage.bitsPerComponent == 16)
        #expect(ExportEncodedImage.bitsPerPixel == 48)
        #expect(ExportEncodedImage.channelCount == 3)
    }

    @Test("The whole chain stays readable through the encoded image")
    func provenanceIsCarriedThrough() throws {
        let exposed = try ExportTestData.exposed(
            width: 1, height: 1,
            values: [0.2, 0.4, 0.6],
            exposureEV: 1.5,
            orientation: .rotated180,
            mix: .redBlueSwap
        )
        let image = try ExportImageEncoder().encode(exposed, settings: Self.settings)
        let processing = image.processing
        #expect(processing.rangePolicy == .hardClipToExportRange)
        #expect(processing.encoding == .sRGB)
        #expect(processing.exportRangeClippingApplied)
        #expect(processing.transferFunctionApplied)
        #expect(processing.quantized)
        #expect(!processing.sceneLinear)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.highlightReconstructionApplied)
        #expect(!processing.resampled)
        #expect(!processing.reducedForPreview)
        #expect(processing.exposureEV == 1.5)
        #expect(processing.exposureApplied)
        #expect(processing.orientation == .rotated180)
        #expect(processing.mix == .redBlueSwap)
        #expect(processing.channelMixApplied)
        #expect(processing.workingColorSpace == .extendedLinearSRGB)
        #expect(processing.demosaiced)
        #expect(processing.whiteBalanceApplied)
        #expect(!processing.isValidatedInfraredCalibration)
    }

    // MARK: - Refusals

    @Test("A reduced preview is refused, whatever else is right about it")
    func aReducedPreviewIsRefused() throws {
        let preview = try ExportTestData.exposedFromPreview(
            width: 2, height: 1, values: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        )
        do {
            _ = try ExportImageEncoder().encode(preview, settings: Self.settings)
            Issue.record("A preview-reduced image should never be exportable.")
        } catch let error as ExportEncodingError {
            guard case .previewReducedSource(let resolution) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(resolution.sourceWidth == 4056)
            #expect(resolution.isReduced)
        }
    }

    @Test("Inconsistent geometry is refused")
    func inconsistentGeometryIsRefused() {
        let broken = ExposedSceneLinearRGBImage(
            width: 4,
            height: 4,
            values: [0, 0, 0],
            processing: SceneLinearExposureProcessing(
                exposure: .neutral,
                orientationProcessing: DisplayPreviewTestData.orientationProcessing()
            )
        )
        #expect(throws: ExportEncodingError.self) {
            try ExportImageEncoder().encode(broken, settings: Self.settings)
        }
    }

    @Test("A non-finite value is refused rather than clipped to something plausible")
    func aNonFiniteValueIsRefused() {
        let broken = ExposedSceneLinearRGBImage(
            width: 2,
            height: 1,
            values: [0.1, 0.2, 0.3, 0.4, .infinity, 0.6],
            processing: SceneLinearExposureProcessing(
                exposure: .neutral,
                orientationProcessing: DisplayPreviewTestData.orientationProcessing()
            )
        )
        do {
            _ = try ExportImageEncoder().encode(broken, settings: Self.settings)
            Issue.record("An infinite component should have been refused.")
        } catch let error as ExportEncodingError {
            #expect(
                error == .nonFiniteSceneLinearInput(
                    row: 0, column: 1, channel: .green, value: .infinity
                )
            )
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - Cancellation

    @Test("A superseded call stops before it allocates")
    func aSupersededCallStopsImmediately() throws {
        let probe = CancellationProbe(cancelAfterPolls: 1)
        let exposed = try ExportTestData.exposed(
            width: 2, height: 1, values: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        )
        #expect(throws: CancellationError.self) {
            try ExportImageEncoder().encode(
                exposed, settings: Self.settings, cancellation: probe.cancellation
            )
        }
    }

    @Test("The pass polls once per row")
    func thePassPollsPerRow() throws {
        let probe = CancellationProbe()
        let exposed = try ExportTestData.exposed(
            width: 1, height: 4, values: Array(repeating: 0.5, count: 12)
        )
        _ = try ExportImageEncoder().encode(
            exposed, settings: Self.settings, cancellation: probe.cancellation
        )
        #expect(probe.pollCount == 5)
    }

    @Test("Cancelling mid-pass abandons the buffer")
    func cancellingMidPassAbandonsTheBuffer() throws {
        let probe = CancellationProbe(cancelAfterPolls: 3)
        let exposed = try ExportTestData.exposed(
            width: 1, height: 8, values: Array(repeating: 0.5, count: 24)
        )
        #expect(throws: CancellationError.self) {
            try ExportImageEncoder().encode(
                exposed, settings: Self.settings, cancellation: probe.cancellation
            )
        }
    }
}
