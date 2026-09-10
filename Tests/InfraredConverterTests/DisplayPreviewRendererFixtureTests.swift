import Testing
import CoreGraphics
import Foundation
@testable import InfraredConverter

/// The display boundary against a real RAW file, through the
/// application-owned pipeline only:
///
/// ```text
/// RAW file → decodeMosaic → RAWMosaicNormalizer → RAWWhiteBalanceEstimator
///          → RAWWhiteBalancer → RAWDemosaicer → RAWWorkingColorConverter
///          → IRChannelMixer → DisplayPreviewRenderer
/// ```
///
/// ## LibRaw is not the oracle here
///
/// `LibRawDecoder.decode()` is never called for anything asserted below, and
/// nothing is compared against its processed RGB output. That path applies a
/// camera colour matrix, its own gamma and its own black and white handling;
/// agreeing with it would mean this pipeline was doing something other than
/// what it says.
///
/// The purpose of the fixture is to prove **our own pipeline is internally
/// consistent** on real data — that the bytes on screen are the ones the
/// documented arithmetic produces from the decoded samples — not that it
/// reproduces dcraw's or Lightroom's rendering.
///
/// ## Nothing here is a colour validation
///
/// The image is displayable. That is a strictly weaker claim than correct: no
/// transform in this pipeline is a validated infrared calibration, and a
/// defined display encoding does not create one.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly without
/// it.
@Suite(
    "DisplayPreviewRenderer integration",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct DisplayPreviewRendererFixtureTests {

    /// The same deterministic diagnostic region every fixture suite measures.
    static let diagnosticRegion = RAWWhiteBalanceEstimatorFixtureTests.diagnosticRegion

    /// The whole owned chain up to and including the creative mix, with the
    /// identity false-colour camera-to-working transform — deliberately, so
    /// the fixture stays independent of the file's visible-light
    /// `rgbFromCamera`, whose validity for an infrared capture is exactly the
    /// open question.
    static func channelMixedFixture(
        mix: IRChannelMix
    ) throws -> IRChannelMixedProcessedRAWImage {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: normalized.mosaic, region: diagnosticRegion)
        let balanced = try RAWWhiteBalancer().apply(to: normalized, estimate: estimate)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)
        let working = try RAWWorkingColorConverter().convert(
            demosaiced, using: .sensorRGBIdentityFalseColor
        )
        return try IRChannelMixer().apply(to: working, mix: mix)
    }

    /// Coordinates spot-checked by hand below. Spread across the frame, on
    /// both parities of both axes, including all four corners, so a stride,
    /// phase or row-order mistake cannot miss every one of them.
    static let probeCoordinates = [
        (0, 0), (0, 4055), (3039, 0), (3039, 4055),
        (1, 1), (1500, 2000), (1501, 2001), (2048, 1024),
    ]

    // MARK: - The whole frame

    @Test("The owned pipeline reaches display-encoded pixels, deterministically")
    func theFixtureRendersToDisplayPixels() throws {
        let mixed = try Self.channelMixedFixture(mix: .identity)
        let settings = DisplayRenderSettings(
            exposureEV: 0,
            rangePolicy: .hardClipToDisplayRange,
            encoding: .sRGB
        )

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try DisplayPreviewRenderer().render(mixed, settings: settings)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let preview = result.image

        // Geometry is untouched: this stage is per-pixel and applies no
        // orientation.
        #expect(preview.width == 4056)
        #expect(preview.height == 3040)
        #expect(preview.width == mixed.image.width)
        #expect(preview.height == mixed.image.height)
        #expect(preview.bytes.count == 4056 * 3040 * 3)
        #expect(preview.bytes.count == 36_990_720)
        #expect(preview.bytesPerRow == 12_168)
        #expect(preview.pixelCount == 12_330_240)
        #expect(preview.isGeometryConsistent)

        // What this stage did, and did not do.
        let processing = preview.processing
        #expect(processing.exposureEV == 0)
        #expect(processing.exposureScale == 1)
        #expect(processing.rangePolicy == .hardClipToDisplayRange)
        #expect(processing.encoding == .sRGB)
        #expect(processing.exposureApplied)
        #expect(processing.displayRangeClippingApplied)
        #expect(processing.displayEncodingApplied)
        #expect(processing.quantized)
        #expect(!processing.sceneLinear)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.automaticExposureApplied)
        #expect(!processing.highlightReconstructionApplied)
        #expect(!processing.orientationApplied)
        #expect(!processing.isValidatedInfraredCalibration)
        #expect(processing.mixSource == .identity)
        #expect(processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
        #expect(processing.demosaicAlgorithm == .bilinearBayer)

        // The scene-linear input: how much of it lies outside the display
        // range, counted independently of the renderer.
        var sourceBelowZero = 0
        var sourceAboveOne = 0
        var sourceNonFinite = 0
        mixed.image.values.withUnsafeBufferPointer { input in
            for index in 0..<input.count {
                let value = input[index]
                if !value.isFinite { sourceNonFinite += 1 }
                else if value < 0 { sourceBelowZero += 1 }
                else if value > 1 { sourceAboveOne += 1 }
            }
        }
        #expect(sourceNonFinite == 0)

        // At 0 EV the clip counts must equal those source counts exactly:
        // nothing else can move a value across a boundary.
        #expect(processing.clippedLowSampleCount == sourceBelowZero)
        #expect(processing.clippedHighSampleCount == sourceAboveOne)
        #expect(processing.clippedSampleCount == sourceBelowZero + sourceAboveOne)

        // The scene-linear buffer is untouched: the values that clipped in the
        // preview are all still there.
        #expect(mixed.image.values.count == 36_990_720)
        #expect(mixed.image.values.contains { $0 < 0 } == (sourceBelowZero > 0))

        // Every byte is a legal sample, and every one of them was written —
        // a `Data(count:)` that was only partly filled would show as an
        // implausible run of zeros at the end.
        var histogram = [Int](repeating: 0, count: 256)
        preview.bytes.withUnsafeBytes { buffer in
            for byte in buffer { histogram[Int(byte)] += 1 }
        }
        #expect(histogram.reduce(0, +) == 36_990_720)
        #expect(histogram[255] > 0 || processing.clippedHighSampleCount == 0)

        var report = "\n--- Display preview rendering (Olympus E-PL3 fixture) ---\n"
        report += "DIAGNOSTIC ONLY. The image is displayable, which is a weaker claim than\n"
        report += "colour-correct. No transform in this pipeline is a validated infrared\n"
        report += "calibration, and a defined display encoding does not create one.\n"
        report += "camera-to-working transform: "
        report += "\(mixed.cameraToWorkingTransform.source.diagnosticDescription)\n"
        report += "channel mix: \(processing.mixSource.diagnosticDescription)\n"
        report += "settings: \(settings.diagnosticDescription)\n"
        report += "preview: \(preview.width) x \(preview.height), "
        report += "\(preview.bytes.count) bytes, \(preview.bytesPerRow ?? -1) bytes per row\n"
        report += "layout: 8 bits per component, three components R G B, no alpha\n"
        report += "colour space tagged on the CGImage: sRGB (non-linear)\n"
        report += "\nscene-linear input (extended linear sRGB, unclamped):\n"
        report += "  values:      \(mixed.image.values.count)\n"
        report += "  below zero:  \(sourceBelowZero)\n"
        report += "  above one:   \(sourceAboveOne)\n"
        report += "  non-finite:  \(sourceNonFinite)\n"
        report += "\nclipping performed by this stage, at 0 EV:\n"
        report += "  clipped low:  \(processing.clippedLowSampleCount)\n"
        report += "  clipped high: \(processing.clippedHighSampleCount)\n"
        report += "  total:        \(processing.clippedSampleCount) of 36990720 "
        report += "(\(Double(processing.clippedSampleCount) / 36_990_720 * 100) %)\n"
        report += "  detail outside 0...1 is DESTROYED here, not recovered; the scene-linear\n"
        report += "  buffer above still holds every one of those values.\n"
        report += "\nsample distribution:\n"
        report += "  at 0:   \(histogram[0])\n"
        report += "  at 255: \(histogram[255])\n"
        report += "render: \(milliseconds) ms (debug build, -Onone)\n"
        report += "---------------------------------------------------------\n"
        print(report)
    }

    // MARK: - Deterministic pixels, computed by hand

    /// Every arithmetic step written out here, from the scene-linear
    /// coordinate to the byte, with no production helper involved.
    @Test("Selected pixels match the arithmetic written out step by step")
    func selectedPixelsMatchHandComputedArithmetic() throws {
        let mixed = try Self.channelMixedFixture(mix: .identity)
        let exposureEV = 0.0
        let preview = try DisplayPreviewRenderer().render(
            mixed.image,
            settings: DisplayRenderSettings(
                exposureEV: exposureEV,
                rangePolicy: .hardClipToDisplayRange,
                encoding: .sRGB
            )
        )

        var report = "\n--- Deterministic preview pixels (Olympus E-PL3 fixture) ---\n"
        report += "Each step computed in the test, not by the renderer.\n"
        report += "0 EV, hard display-range clipping, piecewise sRGB, round to nearest.\n"

        for (row, column) in Self.probeCoordinates {
            let sceneLinear = try #require(mixed.image.pixel(row: row, column: column))
            let rendered = try #require(preview.pixel(row: row, column: column))

            report += "\n(\(row), \(column))\n"
            for channel in RAWLinearRGBChannel.allCases {
                let linear = Double(sceneLinear.value(channel))

                // 1. exposure
                let exposed = linear * exp2(exposureEV)
                // 2. clipping
                let clipped = min(max(exposed, 0), 1)
                // 3. sRGB encoding, written from the standard's definition
                let encoded = clipped <= 0.003_130_8
                    ? 12.92 * clipped
                    : 1.055 * pow(clipped, 1.0 / 2.4) - 0.055
                // 4. quantisation
                let expected = UInt8((encoded * 255).rounded())

                let actual = rendered.sample(channel)
                #expect(actual == expected, "\(channel) at (\(row), \(column))")

                report += "  \(channel): linear \(linear)"
                report += " → exposed \(exposed)"
                report += " → clipped \(clipped)"
                report += " → encoded \(encoded)"
                report += " → sample \(expected)\n"
            }
        }
        report += "------------------------------------------------------------\n"
        print(report)
    }

    /// A stop of exposure on real data, checked the same way — so the
    /// multiply is proven against the fixture and not only against synthetic
    /// values.
    @Test("A stop of exposure on the fixture is exactly a factor of two")
    func exposureOnTheFixture() throws {
        let mixed = try Self.channelMixedFixture(mix: .identity)
        let renderer = DisplayPreviewRenderer()

        let neutral = try renderer.render(
            mixed,
            settings: DisplayRenderSettings(
                exposureEV: 0, rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
            )
        )
        let brightened = try renderer.render(
            settings: DisplayRenderSettings(
                exposureEV: 1, rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
            ),
            replacing: neutral
        )

        // Re-rendering started from the same scene-linear image, not from the
        // 8-bit preview.
        #expect(brightened.channelMixedImage == mixed.image)
        #expect(brightened.image.bytes != neutral.image.bytes)

        // More is clipped high at +1 EV, and nothing more is clipped low: a
        // positive exposure cannot push a value below zero.
        #expect(brightened.processing.clippedHighSampleCount
            >= neutral.processing.clippedHighSampleCount)
        #expect(brightened.processing.clippedLowSampleCount
            == neutral.processing.clippedLowSampleCount)

        for (row, column) in Self.probeCoordinates {
            let sceneLinear = try #require(mixed.image.pixel(row: row, column: column))
            let rendered = try #require(brightened.image.pixel(row: row, column: column))
            for channel in RAWLinearRGBChannel.allCases {
                let exposed = Double(sceneLinear.value(channel)) * 2
                let clipped = min(max(exposed, 0), 1)
                let encoded = clipped <= 0.003_130_8
                    ? 12.92 * clipped
                    : 1.055 * pow(clipped, 1.0 / 2.4) - 0.055
                #expect(
                    rendered.sample(channel) == UInt8((encoded * 255).rounded()),
                    "\(channel) at (\(row), \(column))"
                )
            }
        }

        var report = "\n--- Exposure on the fixture (Olympus E-PL3) ---\n"
        report += "clipped high at  0 EV: \(neutral.processing.clippedHighSampleCount)\n"
        report += "clipped high at +1 EV: \(brightened.processing.clippedHighSampleCount)\n"
        report += "clipped low  at  0 EV: \(neutral.processing.clippedLowSampleCount)\n"
        report += "clipped low  at +1 EV: \(brightened.processing.clippedLowSampleCount)\n"
        report += "-----------------------------------------------\n"
        print(report)
    }

    // MARK: - The creative mix still decides the colour

    @Test("A red/blue swap swaps the preview's outer samples, exactly")
    func theMixIsVisibleInThePreview() throws {
        let settings = DisplayRenderSettings(
            exposureEV: 0, rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
        )
        let renderer = DisplayPreviewRenderer()

        let identity = try renderer.render(
            try Self.channelMixedFixture(mix: .identity), settings: settings
        )
        let swapped = try renderer.render(
            try Self.channelMixedFixture(mix: .redBlueSwap), settings: settings
        )

        // The display stage is per-component, so a permutation upstream shows
        // as exactly that permutation downstream — no cross-channel term can
        // hide in the encoding.
        for (row, column) in Self.probeCoordinates {
            let plain = try #require(identity.image.pixel(row: row, column: column))
            let mixed = try #require(swapped.image.pixel(row: row, column: column))
            #expect(mixed.red == plain.blue, "red at (\(row), \(column))")
            #expect(mixed.green == plain.green, "green at (\(row), \(column))")
            #expect(mixed.blue == plain.red, "blue at (\(row), \(column))")
        }

        // The clip counts are a permutation of each other too: the same set of
        // components, in different channels.
        #expect(swapped.processing.clippedLowSampleCount
            == identity.processing.clippedLowSampleCount)
        #expect(swapped.processing.clippedHighSampleCount
            == identity.processing.clippedHighSampleCount)
    }

    // MARK: - The platform image

    @Test("The fixture's preview becomes a correctly tagged CGImage")
    func theFixtureReachesCoreGraphics() throws {
        let mixed = try Self.channelMixedFixture(mix: .identity)
        let preview = try DisplayPreviewRenderer().render(
            mixed.image,
            settings: DisplayRenderSettings(
                exposureEV: 0, rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
            )
        )
        let cgImage = try DisplayPreviewCGImageAdapter.makeCGImage(from: preview)

        #expect(cgImage.width == 4056)
        #expect(cgImage.height == 3040)
        #expect(cgImage.bitsPerComponent == 8)
        #expect(cgImage.bitsPerPixel == 24)
        #expect(cgImage.bytesPerRow == 12_168)
        #expect(cgImage.alphaInfo == .none)
        #expect(cgImage.colorSpace?.name == CGColorSpace.sRGB)
        #expect(cgImage.colorSpace?.name != CGColorSpace.linearSRGB)
    }
}
