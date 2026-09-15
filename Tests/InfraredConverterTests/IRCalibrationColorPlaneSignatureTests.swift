import Testing
import Foundation
@testable import InfraredConverter

/// The recorded sensor colour-plane signature: that evidence states which
/// planes the layout produced, that every fitted patch is complete against
/// that statement, and that an incomplete patch can exist only as explicitly
/// excluded evidence which describes itself correctly.
///
/// The invariant the whole suite exists for:
///
/// > a colour plane missing from *every* patch cannot become invisible by
/// > being missing from every patch.
@Suite("IR calibration colour-plane signature")
struct IRCalibrationColorPlaneSignatureTests {

    typealias Entry = IRCalibrationColorPlaneSignature.Entry

    static let rggb = CalibrationTestData.bayerSignature

    // MARK: - The signature itself

    @Test("A signature is stored ascending by plane, whatever order it was given in")
    func deterministicOrder() throws {
        let signature = try IRCalibrationColorPlaneSignature([
            Entry(colorPlane: 3, channel: .green),
            Entry(colorPlane: 0, channel: .red),
            Entry(colorPlane: 2, channel: .blue),
            Entry(colorPlane: 1, channel: .green),
        ])
        #expect(signature.colorPlanes == [0, 1, 2, 3])
        #expect(signature == Self.rggb)
        #expect(signature.channel(forColorPlane: 3) == .green)
        #expect(signature.colorPlanes(for: .green) == [1, 3])
    }

    @Test("A signature that cannot describe a fittable layout is refused")
    func invalidSignatures() {
        // Empty: states no expectation at all.
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationColorPlaneSignature([])
        }
        // One plane twice: which channel it is would depend on ordering.
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationColorPlaneSignature([
                Entry(colorPlane: 0, channel: .red),
                Entry(colorPlane: 0, channel: .green),
                Entry(colorPlane: 2, channel: .blue),
            ])
        }
        // No blue plane: no number of patches determines the blue column.
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationColorPlaneSignature([
                Entry(colorPlane: 0, channel: .red),
                Entry(colorPlane: 1, channel: .green),
            ])
        }
        #expect(throws: IRCalibrationError.self) {
            try IRCalibrationColorPlaneSignature([
                Entry(colorPlane: -1, channel: .red),
                Entry(colorPlane: 1, channel: .green),
                Entry(colorPlane: 2, channel: .blue),
            ])
        }
    }

    // MARK: - Included patches are complete

    @Test("An included patch missing an expected plane is refused")
    func includedPatchMustBeComplete() {
        #expect(
            throws: IRCalibrationError.incompletePatchMeasurement(patch: "03", missing: [3])
        ) {
            _ = try Self.measurementSet(
                patches: [
                    CalibrationTestData.patchMeasurement(
                        CalibrationTestData.patch(1), red: 0.3, green: 0.4, blue: 0.2
                    ),
                    CalibrationTestData.patchMeasurement(
                        CalibrationTestData.patch(2), red: 0.5, green: 0.3, blue: 0.4
                    ),
                    CalibrationTestData.incompletePatchMeasurement(
                        CalibrationTestData.patch(3), missing: [3], exclusion: .some(nil)
                    ),
                ]
            )
        }
    }

    @Test("A plane recorded as a different channel from the layout's is refused")
    func channelMismatchIsRefused() throws {
        let wrong = try IRCalibrationPatchMeasurement(
            patch: CalibrationTestData.patch(1),
            region: RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 20, height: 20),
            planes: [
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 0, channel: .red, sampleCount: 100, mean: 0.3,
                    clippedSampleCount: 0
                ),
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 1, channel: .green, sampleCount: 100, mean: 0.4,
                    clippedSampleCount: 0
                ),
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 2, channel: .blue, sampleCount: 100, mean: 0.2,
                    clippedSampleCount: 0
                ),
                // Plane 3 is green on this layout, and is recorded as blue.
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 3, channel: .blue, sampleCount: 100, mean: 0.4,
                    clippedSampleCount: 0
                ),
            ]
        )

        #expect(
            throws: IRCalibrationError.colorPlaneChannelMismatch(
                patch: "01", colorPlane: 3, expected: "green", found: "blue"
            )
        ) {
            _ = try Self.measurementSet(patches: [wrong])
        }
    }

    @Test("A plane the layout does not have is refused, never quietly averaged in")
    func unexpectedPlaneIsRefused() throws {
        let extra = try IRCalibrationPatchMeasurement(
            patch: CalibrationTestData.patch(1),
            region: RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 20, height: 20),
            planes: CalibrationTestData.patchMeasurement(
                CalibrationTestData.patch(1), red: 0.3, green: 0.4, blue: 0.2
            ).planes + [
                try IRCalibrationPlaneMeasurement(
                    colorPlane: 4, channel: .red, sampleCount: 100, mean: 0.9,
                    clippedSampleCount: 0
                )
            ]
        )

        #expect(
            throws: IRCalibrationError.unexpectedColorPlane(patch: "01", colorPlane: 4)
        ) {
            _ = try Self.measurementSet(patches: [extra])
        }
    }

    // MARK: - Excluded patches may be incomplete, and must say so truthfully

    @Test("An incomplete patch that names exactly the planes it lacks is valid evidence")
    func incompleteExcludedPatchIsAccepted() throws {
        let measurements = CalibrationTestData.measurementSet(incomplete: [7: [3]])
        let patch = try #require(measurements.measurement(for: CalibrationTestData.patch(7)))

        #expect(!patch.isIncluded)
        #expect(patch.exclusion == .incompleteColorPlanes(missing: [3]))
        #expect(patch.planes.map(\.colorPlane) == [0, 1, 2])
        #expect(measurements.includedPatchCount == 23)
        // And it is still measured evidence: the numbers it did produce stand.
        #expect(patch.planes.allSatisfy { $0.mean > 0 })
    }

    @Test("An incomplete patch that names the wrong planes is refused")
    func inconsistentExclusionIsRefused() {
        #expect(
            throws: IRCalibrationError.inconsistentPatchExclusion(
                patch: "01", claimed: [2], missing: [3]
            )
        ) {
            _ = try Self.measurementSet(
                patches: [
                    CalibrationTestData.incompletePatchMeasurement(
                        CalibrationTestData.patch(1),
                        missing: [3],
                        exclusion: .incompleteColorPlanes(missing: [2])
                    )
                ]
            )
        }
    }

    @Test("A complete patch that claims to be incomplete is refused just as firmly")
    func completePatchClaimingIncompletenessIsRefused() {
        #expect(
            throws: IRCalibrationError.inconsistentPatchExclusion(
                patch: "01", claimed: [2, 3], missing: []
            )
        ) {
            _ = try Self.measurementSet(
                patches: [
                    CalibrationTestData.patchMeasurement(
                        CalibrationTestData.patch(1),
                        red: 0.3, green: 0.4, blue: 0.2,
                        exclusion: .incompleteColorPlanes(missing: [2, 3])
                    )
                ]
            )
        }
    }

    // MARK: - The regression this exists for

    /// Before the signature, evidence in which *every* patch lacked the second
    /// green plane was indistinguishable from evidence of a three-plane
    /// sensor. The fitter saw red, green and blue, collapsed a one-element
    /// green "pair", and produced a transform fitted to half the green sites
    /// with nothing anywhere saying so.
    @Test("A plane absent from every patch is refused, not read as a three-plane sensor")
    func systematicallyMissingPlaneIsVisible() throws {
        let responses = Array(CalibrationTestData.syntheticCameraResponses().prefix(8))
        let threePlanePatches = responses.enumerated().map { index, response in
            CalibrationTestData.incompletePatchMeasurement(
                CalibrationTestData.patch(index + 1),
                missing: [3],
                red: response.0, green: response.1, blue: response.2,
                exclusion: .some(nil)
            )
        }

        // Against the four-plane signature the sensor actually had: refused at
        // the first patch, rather than fitted from eight of them.
        #expect(
            throws: IRCalibrationError.incompletePatchMeasurement(patch: "01", missing: [3])
        ) {
            _ = try Self.measurementSet(patches: threePlanePatches)
        }

        // The same patches under a signature that says the sensor really has
        // three planes are complete and fit — which is the point: the
        // difference between the two cases is evidence, and it is recorded
        // rather than inferred from the patches, which are identical.
        let threePlane = try IRCalibrationColorPlaneSignature([
            Entry(colorPlane: 0, channel: .red),
            Entry(colorPlane: 1, channel: .green),
            Entry(colorPlane: 2, channel: .blue),
        ])
        let honest = try Self.measurementSet(
            patches: threePlanePatches, signature: threePlane
        )
        #expect(honest.includedPatchCount == 8)
        #expect(honest.colorPlaneSignature == threePlane)
    }

    /// And if every patch is *correctly* recorded as incomplete, the evidence
    /// stands — it is a true account of a bad capture — and the fit refuses it
    /// for having nothing to fit.
    @Test("Evidence in which every patch is legitimately incomplete fits nothing")
    func everyPatchIncompleteFitsNothing() throws {
        let responses = Array(CalibrationTestData.syntheticCameraResponses().prefix(8))
        let measurements = try Self.measurementSet(
            patches: responses.enumerated().map { index, response in
                CalibrationTestData.incompletePatchMeasurement(
                    CalibrationTestData.patch(index + 1),
                    missing: [3],
                    red: response.0, green: response.1, blue: response.2
                )
            }
        )
        #expect(measurements.includedPatchCount == 0)
        #expect(measurements.excludedPatchCount == 8)

        // Built under this suite's own illuminant, so that the fit refuses for
        // the reason under test rather than for pairing two illuminants.
        let reference = CalibrationTestData.referenceDataset(
            for: CalibrationTestData.measurementSet(),
            matrix: CalibrationTestData.syntheticMatrix,
            illuminant: .d65
        )
        #expect(throws: IRCalibrationFitError.noIncludedPatches) {
            _ = try IRCalibrationFitter().fit(
                measurements: measurements, reference: reference,
                now: CalibrationTestData.fittedAt
            )
        }
    }

    // MARK: - The pipeline is the authority

    @Test("The measurement pipeline records the signature the sensor layout actually has")
    func pipelineRecordsTheLayout() throws {
        let four = try IRCalibrationMeasurementPipeline.channelsByColorPlane(
            in: BayerTestLayouts.rggb
        )
        #expect(
            try IRCalibrationColorPlaneSignature(channelsByColorPlane: four)
                == Self.rggb
        )

        // A layout whose two green sites share one plane genuinely has three
        // planes, and the signature says three rather than four.
        let three = try IRCalibrationMeasurementPipeline.channelsByColorPlane(
            in: BayerTestLayouts.rggbThreePlane
        )
        let signature = try IRCalibrationColorPlaneSignature(channelsByColorPlane: three)
        #expect(signature.colorPlanes == [0, 1, 2])
        #expect(signature.colorPlanes(for: .green) == [1])
    }

    @Test("A measured chart carries the signature of the mosaic it was measured from")
    func measuredEvidenceCarriesTheSignature() throws {
        let set = try IRCalibrationMeasurementPipeline().measure(
            IRCalibrationMeasurementPipelineTests.source(
                IRCalibrationMeasurementPipelineTests.mosaic(
                    responses: IRCalibrationMeasurementPipelineTests.flatResponses(),
                    chart: IRCalibrationMeasurementPipelineTests.chart
                )
            ),
            session: try IRCalibrationMeasurementPipelineTests.session(
                chart: IRCalibrationMeasurementPipelineTests.chart
            )
        )
        #expect(set.colorPlaneSignature == Self.rggb)
        // Every included patch is complete against it, by construction rather
        // than by luck.
        for patch in set.includedPatches {
            #expect(patch.planes.map(\.colorPlane) == set.colorPlaneSignature.colorPlanes)
        }
    }

    // MARK: - Persistence

    @Test("The signature survives a round trip exactly, order included")
    func roundTrip() throws {
        let calibration = try CalibrationTestData.calibration()
        let decoded = try IRCalibrationRecordTests.decode(
            try IRCalibrationRecordTests.encode(calibration)
        )
        #expect(decoded.measurements.colorPlaneSignature == Self.rggb)
        #expect(
            decoded.measurements.colorPlaneSignature.entries
                == calibration.measurements.colorPlaneSignature.entries
        )
    }

    @Test("The signature is written as an explicit array of plane and channel")
    func wireShape() throws {
        let data = try IRCalibrationRecordTests.encode(try CalibrationTestData.calibration())
        let object = try IRCalibrationRecordTests.object(data)
        let measurements = try #require(object["measurements"] as? [String: Any])
        let signature = try #require(measurements["colorPlaneSignature"] as? [[String: Any]])

        #expect(signature.count == 4)
        #expect(signature.map { $0["colorPlane"] as? Int } == [0, 1, 2, 3])
        #expect(
            signature.map { $0["channel"] as? String } == ["red", "green", "blue", "green"]
        )
    }

    @Test("A hand-edited plane-to-channel mapping is refused")
    func editedMappingIsRefused() throws {
        // The signature relabelled: plane 3 declared blue.
        try Self.expectRefusal { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            var signature = try #require(
                measurements["colorPlaneSignature"] as? [[String: Any]]
            )
            signature[3]["channel"] = "blue"
            measurements["colorPlaneSignature"] = signature
            object["measurements"] = measurements
        }

        // And the other direction: the patch relabelled instead.
        try Self.expectRefusal { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            var patches = try #require(measurements["patches"] as? [[String: Any]])
            var planes = try #require(patches[0]["planes"] as? [[String: Any]])
            planes[3]["channel"] = "blue"
            patches[0]["planes"] = planes
            measurements["patches"] = patches
            object["measurements"] = measurements
        }
    }

    @Test("A plane deleted from an included patch is refused")
    func deletedPlaneIsRefused() throws {
        try Self.expectRefusal { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            var patches = try #require(measurements["patches"] as? [[String: Any]])
            var planes = try #require(patches[0]["planes"] as? [[String: Any]])
            planes.removeLast()
            patches[0]["planes"] = planes
            measurements["patches"] = patches
            object["measurements"] = measurements
        }
    }

    @Test("A record with no signature at all is refused rather than inferred")
    func absentSignatureIsRefused() throws {
        try Self.expectRefusal { object in
            var measurements = try #require(object["measurements"] as? [String: Any])
            measurements.removeValue(forKey: "colorPlaneSignature")
            object["measurements"] = measurements
        }
    }

    // MARK: - Helpers

    static func measurementSet(
        patches: [IRCalibrationPatchMeasurement],
        signature: IRCalibrationColorPlaneSignature? = nil,
        whiteBalancePolicy: IRCalibrationWhiteBalancePolicy = .none
    ) throws -> IRCalibrationMeasurementSet {
        try IRCalibrationMeasurementSet(
            id: CalibrationTestData.measurementID(),
            measuredAt: CalibrationTestData.measuredAt,
            target: .colorCheckerClassic24,
            illuminant: .d65,
            captureContext: CalibrationTestData.context(),
            colorPlaneSignature: signature ?? rggb,
            normalization: CalibrationTestData.normalization(),
            whiteBalancePolicy: whiteBalancePolicy,
            patches: patches,
            provenance: CalibrationTestData.provenance()
        )
    }

    /// Encodes an honest calibration, lets `edit` change the JSON, and
    /// requires that the result no longer decodes.
    static func expectRefusal(_ edit: (inout [String: Any]) throws -> Void) throws {
        let data = try IRCalibrationRecordTests.encode(try CalibrationTestData.calibration())
        var object = try IRCalibrationRecordTests.object(data)
        try edit(&object)
        #expect(throws: (any Error).self) {
            _ = try IRCalibrationRecordTests.decode(
                try IRCalibrationRecordTests.data(object)
            )
        }
    }
}
