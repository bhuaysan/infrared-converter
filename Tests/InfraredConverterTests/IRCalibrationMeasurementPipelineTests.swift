import Testing
import Foundation
@testable import InfraredConverter

/// The measurement path, against synthetic normalised mosaics: that per-plane
/// means come out right, that clipping excludes a patch rather than being
/// averaged in, and that the path records which normalisation produced its
/// numbers.
///
/// No display buffer, no `CGImage`, no preview and no export appears anywhere
/// in this suite, because none appears anywhere in the path under test.
@Suite("IRCalibrationMeasurementPipeline")
struct IRCalibrationMeasurementPipelineTests {

    /// Paints a mosaic in which every patch of a chart occupying the whole
    /// frame carries a known per-channel response.
    ///
    /// The mosaic is RGGB: plane 0 red, planes 1 and 3 green, plane 2 blue.
    static func mosaic(
        width: Int = 240,
        height: Int = 160,
        responses: [(r: Double, g: Double, b: Double)],
        greenSplit: Double = 0,
        chart: IRCalibrationChartGeometry,
        whiteLevel: UInt32 = 4095
    ) -> LinearRAWMosaic {
        let layout = BayerTestLayouts.rggb
        var values = [Float](repeating: 0, count: width * height)

        let target = chart.target
        for row in 0..<height {
            for column in 0..<width {
                // Which patch this sample falls in, by inverting the
                // rectangular outline the tests use.
                let u = (Double(column) + 0.5) / Double(width)
                let v = (Double(row) + 0.5) / Double(height)
                let gridU = (u - chart.topLeft.x) / (chart.topRight.x - chart.topLeft.x)
                let gridV = (v - chart.topLeft.y) / (chart.bottomLeft.y - chart.topLeft.y)
                guard (0..<1).contains(gridU), (0..<1).contains(gridV) else { continue }

                let gridColumn = min(target.columns - 1, Int(gridU * Double(target.columns)))
                let gridRow = min(target.rows - 1, Int(gridV * Double(target.rows)))
                let index = gridRow * target.columns + gridColumn
                guard index < responses.count else { continue }
                let response = responses[index]

                let plane = layout.colorPlaneIndex(row: row, column: column) ?? 0
                let value: Double
                switch plane {
                case 0: value = response.r
                case 2: value = response.b
                case 1: value = response.g + greenSplit
                default: value = response.g - greenSplit
                }
                values[row * width + column] = Float(value)
            }
        }

        return LinearRAWMosaic(
            width: width,
            height: height,
            values: values,
            sensorColorLayout: layout,
            processing: RAWLinearProcessing(
                whiteLevelPolicy: .metadataMaximum, whiteLevel: whiteLevel
            )
        )
    }

    static func source(
        _ mosaic: LinearRAWMosaic,
        metadata: RAWMetadata = RAWTestData.metadata()
    ) -> NormalizedRAWSource {
        NormalizedRAWSource(
            mosaic: mosaic,
            metadata: metadata,
            url: URL(fileURLWithPath: "/synthetic/CHART.ORF")
        )
    }

    static func session(
        chart: IRCalibrationChartGeometry,
        whiteBalancePolicy: IRCalibrationWhiteBalancePolicy = .none,
        clipping: IRCalibrationClippingPolicy = .default
    ) throws -> IRCalibrationMeasurementPipeline.Session {
        try IRCalibrationMeasurementPipeline.Session(
            target: .colorCheckerClassic24,
            geometry: chart,
            illuminant: .measuredSPD(reference: "synthetic-spd"),
            sensorConversion: .fullSpectrum(vendor: "Synthetic Conversions"),
            filter: CalibrationTestData.filter(),
            bodyScope: .modelLevel,
            whiteBalancePolicy: whiteBalancePolicy,
            clippingPolicy: clipping,
            provenance: CalibrationTestData.provenance()
        )
    }

    static let chart = try! IRCalibrationChartGeometry.rectangular(
        target: .colorCheckerClassic24,
        originX: 0, originY: 0, width: 1, height: 1,
        patchSampleFraction: 0.5
    )

    static func flatResponses() -> [(r: Double, g: Double, b: Double)] {
        var result: [(r: Double, g: Double, b: Double)] = []
        result.reserveCapacity(24)
        for index in 0..<24 {
            let i = Double(index)
            let j = Double((index * 3) % 24)
            let k = Double((index * 5) % 24)
            result.append((r: 0.10 + i * 0.01, g: 0.20 + j * 0.008, b: 0.30 + k * 0.006))
        }
        return result
    }

    // MARK: - Means

    @Test("Each patch's per-plane means are the values painted into it")
    func planeMeans() throws {
        let responses = Self.flatResponses()
        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(Self.mosaic(responses: responses, chart: Self.chart)),
            session: try Self.session(chart: Self.chart),
            measurementSetID: CalibrationTestData.measurementID(),
            now: CalibrationTestData.measuredAt
        )

        #expect(set.patches.count == 24)
        for (index, patch) in set.patches.enumerated() {
            let expected = responses[index]
            let red = try #require(patch.planes.first { $0.colorPlane == 0 })
            let blue = try #require(patch.planes.first { $0.colorPlane == 2 })
            let greens = patch.planes(for: .green)

            #expect(red.channel == .red)
            #expect(blue.channel == .blue)
            #expect(greens.count == 2)
            #expect(abs(red.mean - expected.r) < 1e-6)
            #expect(abs(blue.mean - expected.b) < 1e-6)
            for green in greens {
                #expect(abs(green.mean - expected.g) < 1e-6)
            }
            #expect(patch.isIncluded)
        }
    }

    @Test("Both green planes are measured separately, and the split is preserved")
    func greenPlanesAreSeparate() throws {
        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(
                Self.mosaic(responses: Self.flatResponses(), greenSplit: 0.05, chart: Self.chart)
            ),
            session: try Self.session(chart: Self.chart)
        )

        let patch = try #require(set.measurement(for: CalibrationTestData.patch(1)))
        let plane1 = try #require(patch.planes.first { $0.colorPlane == 1 })
        let plane3 = try #require(patch.planes.first { $0.colorPlane == 3 })
        #expect(abs((plane1.mean - plane3.mean) - 0.10) < 1e-6)

        // And the collapse averages them back to the painted value.
        let camera = try IRCalibrationFitter.cameraRGB(
            for: patch, gains: [:], policy: .meanOfGreenPlaneMeans
        )
        #expect(abs(camera.y - Self.flatResponses()[0].g) < 1e-6)
    }

    @Test("Every plane is sampled equally often, because regions cover whole CFA cells")
    func equalPlaneCounts() throws {
        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(Self.mosaic(responses: Self.flatResponses(), chart: Self.chart)),
            session: try Self.session(chart: Self.chart)
        )

        for patch in set.patches {
            let counts = Set(patch.planes.map(\.sampleCount))
            #expect(counts.count == 1, "\(patch.patch) sampled its planes unequally: \(counts)")
            #expect(patch.planes.count == 4)
        }
    }

    // MARK: - Clipping

    @Test("A patch containing clipped samples is excluded, not averaged in")
    func clippedPatchExcluded() throws {
        var responses = Self.flatResponses()
        responses[4] = (r: 1.0, g: 0.5, b: 0.4)

        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(Self.mosaic(responses: responses, chart: Self.chart)),
            session: try Self.session(chart: Self.chart)
        )

        let clipped = try #require(set.measurement(for: CalibrationTestData.patch(5)))
        #expect(!clipped.isIncluded)
        guard case .clipped(let clippedSamples, let total) = try #require(clipped.exclusion) else {
            Issue.record("Expected .clipped, got \(String(describing: clipped.exclusion))")
            return
        }
        #expect(clippedSamples > 0)
        #expect(total > clippedSamples)
        #expect(set.includedPatchCount == 23)
        #expect(set.excludedPatchCount == 1)

        // The measured values survive even though the patch is excluded: the
        // evidence records what was seen, and the exclusion is a judgement
        // about it.
        #expect(clipped.planes.count == 4)
    }

    @Test("Values just below the threshold are not clipped")
    func justBelowThreshold() throws {
        var responses = Self.flatResponses()
        responses[4] = (r: 0.999999, g: 0.5, b: 0.4)

        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(Self.mosaic(responses: responses, chart: Self.chart)),
            session: try Self.session(chart: Self.chart)
        )
        #expect(try #require(set.measurement(for: CalibrationTestData.patch(5))).isIncluded)
    }

    @Test("A tighter clipping threshold excludes more patches, and is recorded in the evidence")
    func thresholdIsRecorded() throws {
        let policy = IRCalibrationClippingPolicy(
            normalizedClippingThreshold: 0.35, maximumClippedSampleFraction: 0
        )
        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(Self.mosaic(responses: Self.flatResponses(), chart: Self.chart)),
            session: try Self.session(chart: Self.chart, clipping: policy)
        )

        #expect(set.clippingPolicy == policy)
        #expect(set.excludedPatchCount > 0)
    }

    @Test("A capture in which every patch clips is refused rather than measured")
    func everythingClipped() throws {
        let responses = (0..<24).map { _ in (r: 1.2, g: 1.2, b: 1.2) }
        #expect(throws: IRCalibrationMeasurementError.self) {
            _ = try IRCalibrationMeasurementPipeline().measure(
                Self.source(Self.mosaic(responses: responses, chart: Self.chart)),
                session: try Self.session(chart: Self.chart)
            )
        }
    }

    // MARK: - Provenance

    @Test("The measurement set records which normalisation produced its numbers")
    func normalizationProvenance() throws {
        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(
                Self.mosaic(responses: Self.flatResponses(), chart: Self.chart, whiteLevel: 16383)
            ),
            session: try Self.session(chart: Self.chart)
        )

        #expect(set.normalization.whiteLevel == 16383)
        #expect(set.normalization.whiteLevelPolicy == .metadataMaximum)
        #expect(set.normalization.blackLevelSubtracted)
        #expect(set.normalization.version == IRCalibrationNormalizationProvenance.currentVersion)
    }

    @Test("The camera identity comes from the file, and a file that names none is refused")
    func cameraIdentity() throws {
        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(Self.mosaic(responses: Self.flatResponses(), chart: Self.chart)),
            session: try Self.session(chart: Self.chart)
        )
        #expect(set.captureContext.camera.model == "E-PL3")
        #expect(set.captureContext.camera.make == "Olympus")
        #expect(set.sourceFileName == "CHART.ORF")

        var anonymous = RAWTestData.metadata()
        anonymous.identity = .init()
        #expect(throws: IRCalibrationMeasurementError.cameraUnidentified) {
            _ = try IRCalibrationMeasurementPipeline().measure(
                Self.source(
                    Self.mosaic(responses: Self.flatResponses(), chart: Self.chart),
                    metadata: anonymous
                ),
                session: try Self.session(chart: Self.chart)
            )
        }
    }

    @Test("The session's own context is snapshotted into the evidence, by value")
    func contextSnapshot() throws {
        let set = try IRCalibrationMeasurementPipeline().measure(
            Self.source(Self.mosaic(responses: Self.flatResponses(), chart: Self.chart)),
            session: try Self.session(chart: Self.chart)
        )

        #expect(set.captureContext.sensorConversion == .fullSpectrum(vendor: "Synthetic Conversions"))
        #expect(set.captureContext.filter.product == "R72")
        #expect(set.captureContext.filter.nominalCutoffNanometers == 720)
        #expect(set.illuminant == .measuredSPD(reference: "synthetic-spd"))
    }

    // MARK: - Colour planes

    @Test("A layout whose planes are R, G and B maps each plane to its channel")
    func channelsByColorPlane() throws {
        let channels = try IRCalibrationMeasurementPipeline
            .channelsByColorPlane(in: BayerTestLayouts.rggb)
        #expect(channels[0] == .red)
        #expect(channels[1] == .green)
        #expect(channels[2] == .blue)
        #expect(channels[3] == .green)
    }

    @Test("A layout with a filter colour that is not R, G or B is refused, never remapped")
    func unsupportedFilterColor() {
        let rgbe = BayerTestLayouts.layout(
            cell: [[0, 1], [3, 2]], colorDescription: "RGBE", colorCount: 4
        )
        #expect(throws: IRCalibrationMeasurementError.self) {
            _ = try IRCalibrationMeasurementPipeline.channelsByColorPlane(in: rgbe)
        }
    }

    @Test("A layout with no blue plane is refused: no number of patches determines the transform")
    func missingChannelInLayout() {
        let redGreenOnly = BayerTestLayouts.layout(
            cell: [[0, 1], [1, 0]], colorDescription: "RGBG", colorCount: 3
        )
        #expect(throws: IRCalibrationMeasurementError.self) {
            _ = try IRCalibrationMeasurementPipeline.channelsByColorPlane(in: redGreenOnly)
        }
    }

    @Test("A sensor with no colour mosaic is refused")
    func noMosaic() {
        let foveon = RAWMetadata.SensorColorLayout(
            pattern: .foveon, filters: 0, colorDescription: "RGB",
            colorCount: 3, sourceRawBitDepth: 12
        )
        #expect(throws: (any Error).self) {
            _ = try IRCalibrationMeasurementPipeline.channelsByColorPlane(in: foveon)
        }
    }

    // MARK: - The whole path

    @Test("Measure, fit, assemble: a synthetic chart produces a coherent Measured calibration")
    func endToEnd() throws {
        let responses = Self.flatResponses()
        let measurements = try IRCalibrationMeasurementPipeline().measure(
            Self.source(Self.mosaic(responses: responses, chart: Self.chart)),
            session: try Self.session(
                chart: Self.chart,
                whiteBalancePolicy: .neutralPatch(CalibrationTestData.patch(20))
            ),
            measurementSetID: CalibrationTestData.measurementID(),
            now: CalibrationTestData.measuredAt
        )
        let reference = CalibrationTestData.referenceDataset(
            for: measurements, matrix: CalibrationTestData.syntheticMatrix
        )
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference,
            now: CalibrationTestData.fittedAt
        )
        let calibration = try IRCalibration(
            id: CalibrationTestData.calibrationID(),
            name: "Synthetic end to end",
            measurements: measurements,
            reference: reference,
            fit: fit
        )

        #expect(
            CalibrationTestData.maximumCoefficientDifference(
                calibration.matrix, CalibrationTestData.syntheticMatrix
            ) < 1e-8
        )
        // Complete evidence, and still only Measured.
        #expect(calibration.evidenceGaps.isEmpty)
        #expect(calibration.status == .measured)
        #expect(!calibration.isValidatedInfraredCalibration)
    }

    @Test("Measuring the same mosaic twice gives identical evidence")
    func determinism() throws {
        func measure() throws -> IRCalibrationMeasurementSet {
            try IRCalibrationMeasurementPipeline().measure(
                Self.source(Self.mosaic(responses: Self.flatResponses(), chart: Self.chart)),
                session: try Self.session(chart: Self.chart),
                measurementSetID: CalibrationTestData.measurementID(),
                now: CalibrationTestData.measuredAt
            )
        }
        #expect(try measure() == (try measure()))
    }
}
