import Testing
import Foundation
@testable import InfraredConverter

/// What the display rendering stage deliberately does **not** do, and what its
/// provenance therefore has to keep saying.
///
/// A stage's absences are as much a contract as its arithmetic. A tone curve,
/// an auto-exposure heuristic or a quiet saturation boost could all be added
/// here without any existing arithmetic test failing — the picture would just
/// change. This file is what would fail.
@Suite("DisplayPreviewRenderer policy")
struct DisplayPreviewRendererPolicyTests {

    /// A small image with values in every interesting region: below zero,
    /// inside the range, and above one.
    static func spreadImage(
        processing: IRChannelMixProcessing? = nil
    ) -> IRChannelMixedRGBImage {
        DisplayPreviewTestData.image(
            width: 3,
            height: 2,
            values: [
                -0.25, 0.05, 0.5,
                0.18, 0.9, 1.4,
                0.33, -0.02, 0.66,
                1.0, 0.42, 0.07,
                0.88, 2.5, 0.21,
                0.6, 0.11, -1.0,
            ],
            processing: processing
        )
    }

    // MARK: - Metadata cannot reach the rendering

    /// The core entry point takes an image and settings, so there is no
    /// parameter a `RAWMetadata` could arrive through. This proves the
    /// consequence: everything the upstream provenance carries can be varied
    /// and the bytes are identical.
    ///
    /// In particular `rgbFromCamera`, `cameraFromXYZ`, `cameraMultipliers` and
    /// `daylightMultipliers` cannot change a single sample — none of them is
    /// even reachable from here, and none is consulted.
    @Test("Varying every upstream fact leaves the rendered bytes identical")
    func upstreamProvenanceCannotChangeTheRendering() throws {
        let renderer = DisplayPreviewRenderer()
        let settings = DisplayPreviewTestData.settings(exposureEV: 0)

        let baseline = try renderer.render(Self.spreadImage(), settings: settings)

        // A completely different upstream history: a different creative mix, a
        // different camera-to-working transform, different white-balance gains
        // and a different white level. The scene-linear numbers are unchanged.
        let differentHistory = DisplayPreviewTestData.channelMixProcessing(
            mix: .redBlueSwap,
            transform: .explicit(
                matrix: try RAWColorMatrix3x3(
                    m00: 1.5, m01: -0.25, m02: 0.75,
                    m10: 0.5, m11: 2.0, m12: -1.25,
                    m20: -0.125, m21: 0.375, m22: 3.0
                )
            ),
            gains: RAWWhiteBalanceGains(plane0: 7, plane1: 0.25, plane2: 11, plane3: 3),
            whiteLevel: 16383
        )
        let varied = try renderer.render(
            Self.spreadImage(processing: differentHistory), settings: settings
        )

        #expect(varied.bytes == baseline.bytes)
        #expect(varied.processing.clippedLowSampleCount
            == baseline.processing.clippedLowSampleCount)
        #expect(varied.processing.clippedHighSampleCount
            == baseline.processing.clippedHighSampleCount)

        // The history is still readable through the result — unchanged, and
        // simply not consulted.
        #expect(varied.processing.mixSource == .redBlueSwap)
        #expect(baseline.processing.mixSource == .identity)
        #expect(varied.processing.cameraToWorkingTransformSource == .explicit)
        #expect(varied.processing.whiteBalanceGains.plane0 == 7)
    }

    // MARK: - Nothing automatic, nothing tonal

    /// A dark image and a bright one differ by exactly the amount their
    /// numbers differ. Any auto-exposure, auto-levels or histogram
    /// normalisation would pull them towards each other.
    @Test("Overall image brightness does not influence any sample")
    func nothingIsNormalisedToTheImage() throws {
        let renderer = DisplayPreviewRenderer()
        let settings = DisplayPreviewTestData.settings(exposureEV: 0)
        let probe: Float = 0.18

        // The same probe value, once among dark neighbours and once among
        // bright ones.
        let dark = DisplayPreviewTestData.image(
            width: 2, height: 1,
            values: [probe, 0.01, 0.01, 0.02, 0.01, 0.005]
        )
        let bright = DisplayPreviewTestData.image(
            width: 2, height: 1,
            values: [probe, 0.99, 0.97, 0.95, 1.0, 0.98]
        )

        let darkRendered = try renderer.render(dark, settings: settings)
        let brightRendered = try renderer.render(bright, settings: settings)

        let expected = DisplayPreviewTestData.referenceSample(
            sceneLinear: probe, exposureEV: 0
        )
        #expect(darkRendered.bytes[0] == expected)
        #expect(brightRendered.bytes[0] == expected)
        #expect(darkRendered.bytes[0] == brightRendered.bytes[0])
    }

    /// A tone curve is by definition not a per-component function of the value
    /// alone — or if it is, it is a different function from the sRGB encoding.
    /// Either way, every sample here would move.
    @Test("Every sample is exactly the documented per-component function")
    func nothingElseIsAppliedPerSample() throws {
        var values = [Float]()
        for step in 0..<(16 * 3) {
            values.append(Float(step) * 0.021 - 0.15)
        }
        let rendered = try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.image(width: 4, height: 4, values: values),
            settings: DisplayPreviewTestData.settings(exposureEV: 0.25)
        )
        for (offset, value) in values.enumerated() {
            #expect(
                rendered.bytes[offset]
                    == DisplayPreviewTestData.referenceSample(
                        sceneLinear: value, exposureEV: 0.25
                    ),
                "element \(offset)"
            )
        }
    }

    /// A saturation or contrast adjustment would make a component's output
    /// depend on its neighbours in the same pixel. This varies the other two
    /// channels wildly and requires the first to be unmoved.
    @Test("A component's sample does not depend on the other two")
    func componentsDoNotInfluenceEachOther() throws {
        let renderer = DisplayPreviewRenderer()
        let settings = DisplayPreviewTestData.settings(exposureEV: 0)
        let probe: Float = 0.4
        let expected = DisplayPreviewTestData.referenceSample(
            sceneLinear: probe, exposureEV: 0
        )

        let companions: [(Float, Float)] = [
            (0, 0), (1, 1), (0.4, 0.4), (-3, 5), (0.001, 0.999),
        ]
        for (green, blue) in companions {
            let rendered = try renderer.render(
                DisplayPreviewTestData.pixel(probe, green, blue), settings: settings
            )
            #expect(rendered.bytes[0] == expected, "companions \(green), \(blue)")
        }
    }

    // MARK: - Geometry and orientation

    /// The stage does not read orientation metadata and does not move a pixel.
    @Test("Geometry and pixel order are preserved, and orientation is not applied")
    func renderingIsGeometryPreserving() throws {
        let width = 4
        let height = 3
        var values = [Float]()
        for index in 0..<(width * height * 3) {
            values.append(Float(index % 97) * 0.01)
        }
        let image = DisplayPreviewTestData.image(width: width, height: height, values: values)
        let rendered = try DisplayPreviewRenderer().render(
            image, settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )

        #expect(rendered.width == image.width)
        #expect(rendered.height == image.height)
        #expect(!rendered.processing.orientationApplied)

        // A rotation or flip would move the corners. Each is checked against
        // the value that genuinely lives there.
        for (row, column) in [(0, 0), (0, width - 1), (height - 1, 0), (height - 1, width - 1)] {
            let source = try #require(image.pixel(row: row, column: column))
            let target = try #require(rendered.pixel(row: row, column: column))
            #expect(target.red == DisplayPreviewTestData.referenceSample(
                sceneLinear: source.red, exposureEV: 0
            ))
            #expect(target.blue == DisplayPreviewTestData.referenceSample(
                sceneLinear: source.blue, exposureEV: 0
            ))
        }
    }

    // MARK: - The provenance record

    @Test("Provenance states what ran and what did not")
    func provenanceRecordsTheStageHonestly() throws {
        let settings = DisplayPreviewTestData.settings(exposureEV: -0.75)
        let rendered = try DisplayPreviewRenderer().render(
            Self.spreadImage(), settings: settings
        )
        let processing = rendered.processing

        // What this stage did.
        #expect(processing.settings == settings)
        #expect(processing.exposureEV == -0.75)
        #expect(processing.rangePolicy == .hardClipToDisplayRange)
        #expect(processing.encoding == .sRGB)
        #expect(processing.exposureApplied)
        #expect(processing.displayRangeClippingApplied)
        #expect(processing.displayEncodingApplied)
        #expect(processing.quantized)

        // What it is not.
        #expect(!processing.sceneLinear)
        #expect(!processing.toneMappingApplied)
        #expect(!processing.automaticExposureApplied)
        #expect(!processing.contrastApplied)
        #expect(!processing.saturationApplied)
        #expect(!processing.highlightReconstructionApplied)
        #expect(!processing.sharpeningApplied)
        #expect(!processing.orientationApplied)

        // Displayable is not a colour claim.
        #expect(!processing.isValidatedInfraredCalibration)

        // The upstream chain, read through rather than copied.
        #expect(processing.channelMixApplied)
        #expect(processing.mixSource == .identity)
        #expect(processing.workingColorSpace == .extendedLinearSRGB)
        #expect(processing.cameraToWorkingTransformSource == .sensorRGBIdentityFalseColor)
        #expect(processing.demosaiced)
        #expect(processing.demosaicAlgorithm == .bilinearBayer)
        #expect(processing.whiteBalanceApplied)
        #expect(processing.whiteBalanceGains.plane2 == 3)
        #expect(processing.blackLevelSubtracted)
        #expect(processing.normalized)
    }

    /// Exposure at `0 EV` still counts as a traversed stage, for the same
    /// reason `IRChannelMix.identity` does: asking for `×1` is a different
    /// fact from never applying exposure.
    @Test("Zero EV still records that exposure ran")
    func zeroEVStillRecordsExposure() throws {
        let rendered = try DisplayPreviewRenderer().render(
            Self.spreadImage(), settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        #expect(rendered.processing.exposureApplied)
        #expect(rendered.processing.exposureEV == 0)
        #expect(rendered.processing.exposureScale == 1)
    }
}
