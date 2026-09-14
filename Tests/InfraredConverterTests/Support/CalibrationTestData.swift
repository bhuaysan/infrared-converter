import Foundation
@testable import InfraredConverter

/// Synthetic calibration evidence.
///
/// **Every dataset here is synthetic and says so in its identifier.** No real
/// measurement of any camera, conversion or filter exists in this project, and
/// nothing in this file is a substitute for one: these values exist to exercise
/// arithmetic and refusals, not to characterise a sensor. A synthetic reference
/// dataset is named `synthetic.*` precisely so that no test can be mistaken for
/// evidence. See `docs/calibration-protocol.md`.
enum CalibrationTestData {

    // MARK: - Deterministic clocks and identities

    static let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let fittedAt = Date(timeIntervalSince1970: 1_700_000_600)

    static func measurementID(
        _ token: String = "measurement.00000000-0000-4000-8000-000000000001"
    ) -> IRCalibrationMeasurementSetID {
        try! IRCalibrationMeasurementSetID(token)
    }

    static func calibrationID(
        _ token: String = "calibration.00000000-0000-4000-8000-000000000002"
    ) -> IRCalibrationID {
        try! IRCalibrationID(token)
    }

    static func patch(_ index: Int) -> IRCalibrationTargetPatchID {
        try! IRCalibrationTargetPatchID(String(format: "%02d", index))
    }

    // MARK: - Context

    static func body(
        make: String = "OLYMPUS IMAGING CORP.",
        model: String = "E-PL3",
        serialNumber: String? = "SYNTHETIC-BODY-1",
        scope: IRCalibrationBodyScope = .specificBody
    ) -> IRCalibrationBodyIdentity {
        try! IRCalibrationBodyIdentity(
            make: make, model: model, serialNumber: serialNumber, scope: scope
        )
    }

    static func filter(
        manufacturer: String? = "Synthetic Optics",
        product: String? = "R72",
        nominalCutoffNanometers: Double? = 720,
        notes: String? = "batch 0"
    ) -> IRCalibrationFilterSnapshot {
        try! IRCalibrationFilterSnapshot(
            manufacturer: manufacturer,
            product: product,
            nominalCutoffNanometers: nominalCutoffNanometers,
            notes: notes
        )
    }

    static func context(
        camera: IRCalibrationBodyIdentity? = nil,
        sensorConversion: IRSensorConversion = .fullSpectrum(vendor: "Synthetic Conversions"),
        filter: IRCalibrationFilterSnapshot? = nil,
        measuredUnderProfile: IRCaptureProfileID? = nil
    ) -> IRCalibrationCaptureContext {
        IRCalibrationCaptureContext(
            camera: camera ?? body(),
            sensorConversion: sensorConversion,
            filter: filter ?? Self.filter(),
            measuredUnderProfile: measuredUnderProfile
        )
    }

    static func provenance(
        author: String = "Synthetic Operator",
        notes: String? = nil
    ) -> IRCalibrationProvenance {
        try! IRCalibrationProvenance(
            author: author, tool: "InfraredConverterTests", toolVersion: "0", notes: notes
        )
    }

    static func normalization() -> IRCalibrationNormalizationProvenance {
        IRCalibrationNormalizationProvenance(
            blackLevelSubtracted: true,
            whiteLevelPolicy: .metadataMaximum,
            whiteLevel: 4095
        )
    }

    // MARK: - Sensor layout

    /// The four-plane RGGB signature every synthetic patch below is measured
    /// against: `0 R, 1 G, 2 B, 3 G`.
    ///
    /// Written out here, in test data, rather than offered as a constant on
    /// `IRCalibrationColorPlaneSignature`. A named `.bayerRGGB` in the domain
    /// model would read as an assumption the project makes about sensors; the
    /// only authority for a real signature is the decoder's own layout, and
    /// the only authority for a synthetic one is the synthetic mosaic it goes
    /// with.
    static let bayerSignature = try! IRCalibrationColorPlaneSignature([
        .init(colorPlane: 0, channel: .red),
        .init(colorPlane: 1, channel: .green),
        .init(colorPlane: 2, channel: .blue),
        .init(colorPlane: 3, channel: .green),
    ])

    // MARK: - Patches

    /// A patch measured on a four-plane RGGB layout: planes 0=R, 1=G, 2=B,
    /// 3=G2.
    ///
    /// `greenSplit` shifts response between the two green planes while keeping
    /// their mean fixed, so a test can prove that the green collapse does not
    /// depend on how the response happened to divide between the two phases.
    static func patchMeasurement(
        _ patch: IRCalibrationTargetPatchID,
        red: Double,
        green: Double,
        blue: Double,
        greenSplit: Double = 0,
        sampleCount: Int = 400,
        clipped: Int = 0,
        exclusion: IRCalibrationPatchExclusion? = nil,
        region: RAWActiveAreaRegion = RAWActiveAreaRegion(
            originRow: 0, originColumn: 0, width: 20, height: 20
        )
    ) -> IRCalibrationPatchMeasurement {
        try! IRCalibrationPatchMeasurement(
            patch: patch,
            region: region,
            planes: [
                try! IRCalibrationPlaneMeasurement(
                    colorPlane: 0, channel: .red,
                    sampleCount: sampleCount / 4, mean: red, clippedSampleCount: clipped
                ),
                try! IRCalibrationPlaneMeasurement(
                    colorPlane: 1, channel: .green,
                    sampleCount: sampleCount / 4, mean: green + greenSplit,
                    clippedSampleCount: 0
                ),
                try! IRCalibrationPlaneMeasurement(
                    colorPlane: 2, channel: .blue,
                    sampleCount: sampleCount / 4, mean: blue, clippedSampleCount: 0
                ),
                try! IRCalibrationPlaneMeasurement(
                    colorPlane: 3, channel: .green,
                    sampleCount: sampleCount / 4, mean: green - greenSplit,
                    clippedSampleCount: 0
                ),
            ],
            exclusion: exclusion
        )
    }

    /// A patch the sensor layout produced fewer planes for than
    /// ``bayerSignature`` expects.
    ///
    /// By default it carries the exclusion that describes exactly that, which
    /// is the only shape of incomplete evidence a measurement set accepts.
    /// `exclusion` is overridable so a test can build the *contradictory*
    /// evidence and watch it be refused.
    static func incompletePatchMeasurement(
        _ patch: IRCalibrationTargetPatchID,
        missing: [Int],
        red: Double = 0.3,
        green: Double = 0.4,
        blue: Double = 0.2,
        exclusion: IRCalibrationPatchExclusion?? = nil,
        region: RAWActiveAreaRegion = RAWActiveAreaRegion(
            originRow: 0, originColumn: 0, width: 20, height: 20
        )
    ) -> IRCalibrationPatchMeasurement {
        let complete = patchMeasurement(patch, red: red, green: green, blue: blue)
        return try! IRCalibrationPatchMeasurement(
            patch: patch,
            region: region,
            planes: complete.planes.filter { !missing.contains($0.colorPlane) },
            exclusion: exclusion ?? .incompleteColorPlanes(missing: missing)
        )
    }

    // MARK: - A whole synthetic session

    /// Camera responses for `count` patches, spread so that the three channels
    /// are strongly independent — the case a solver should find easy.
    ///
    /// Deliberately not a model of any real sensor. It is a set of vectors that
    /// spans three dimensions.
    static func syntheticCameraResponses(count: Int = 24) -> [(Double, Double, Double)] {
        (0..<count).map { index in
            let a = Double((index * 7) % 11) / 11 + 0.05
            let b = Double((index * 5) % 13) / 13 + 0.05
            let c = Double((index * 3) % 17) / 17 + 0.05
            return (0.1 + 0.6 * a, 0.1 + 0.6 * b, 0.1 + 0.6 * c)
        }
    }

    /// A measurement set whose camera responses are `responses`, with no
    /// session white balance so that the responses reach the solver unchanged.
    static func measurementSet(
        responses: [(Double, Double, Double)]? = nil,
        whiteBalancePolicy: IRCalibrationWhiteBalancePolicy = .none,
        illuminant: IRCalibrationIlluminant = .measuredSPD(reference: "synthetic-spd-1"),
        context: IRCalibrationCaptureContext? = nil,
        exclusions: [Int: IRCalibrationPatchExclusion] = [:],
        clipped: [Int: Int] = [:],
        incomplete: [Int: [Int]] = [:],
        colorPlaneSignature: IRCalibrationColorPlaneSignature? = nil,
        clippingPolicy: IRCalibrationClippingPolicy = .default,
        id: IRCalibrationMeasurementSetID? = nil
    ) -> IRCalibrationMeasurementSet {
        let responses = responses ?? syntheticCameraResponses()
        let patches = responses.enumerated().map { index, response in
            if let missing = incomplete[index + 1] {
                return incompletePatchMeasurement(
                    patch(index + 1),
                    missing: missing,
                    red: response.0,
                    green: response.1,
                    blue: response.2
                )
            }
            return patchMeasurement(
                patch(index + 1),
                red: response.0,
                green: response.1,
                blue: response.2,
                clipped: clipped[index + 1] ?? 0,
                exclusion: exclusions[index + 1]
            )
        }
        return try! IRCalibrationMeasurementSet(
            id: id ?? measurementID(),
            measuredAt: measuredAt,
            target: .colorCheckerClassic24,
            illuminant: illuminant,
            captureContext: context ?? Self.context(),
            colorPlaneSignature: colorPlaneSignature ?? bayerSignature,
            normalization: normalization(),
            clippingPolicy: clippingPolicy,
            whiteBalancePolicy: whiteBalancePolicy,
            patches: patches,
            provenance: provenance(),
            sourceFileName: "SYNTHETIC.ORF"
        )
    }

    /// A reference dataset produced by applying `matrix` to a measurement
    /// set's camera responses.
    ///
    /// This is what makes an exact-fit test meaningful: the reference values
    /// are `M × c` by construction, so a correct solver must recover `M` and
    /// report zero residuals.
    static func referenceDataset(
        for measurements: IRCalibrationMeasurementSet,
        matrix: RAWColorMatrix3x3,
        noise: [IRCalibrationTargetPatchID: (Double, Double, Double)] = [:],
        identifier: String = "synthetic.exact",
        version: String = "1",
        illuminant: IRCalibrationIlluminant = .measuredSPD(reference: "synthetic-spd-1")
    ) -> IRCalibrationReferenceDataset {
        let gains = try! IRCalibrationFitter.sessionGains(for: measurements)
        var values: [IRCalibrationTargetPatchID: IRCalibrationReferenceRGB] = [:]
        for measurement in measurements.patches {
            // A patch short of a colour plane produces no camera RGB and is
            // never fitted, so it gets no reference value either. Skipped
            // rather than forced: inventing one would be exactly the
            // fabrication the reference dataset exists to prevent.
            guard
                let camera = try? IRCalibrationFitter.cameraRGB(
                    for: measurement,
                    gains: gains,
                    policy: measurements.domain.greenPolicy
                )
            else { continue }
            let fitted = IRCalibrationFitter.apply(matrix, to: camera)
            let offset = noise[measurement.patch] ?? (0, 0, 0)
            values[measurement.patch] = try! IRCalibrationReferenceRGB(
                red: max(0, fitted.x + offset.0),
                green: max(0, fitted.y + offset.1),
                blue: max(0, fitted.z + offset.2)
            )
        }
        return try! IRCalibrationReferenceDataset(
            identifier: identifier,
            version: version,
            source: "Synthesised inside the test suite; not a measurement of anything.",
            illuminant: illuminant,
            target: measurements.target,
            values: values
        )
    }

    /// A transform that is emphatically not the identity, so that a recovered
    /// matrix proves something.
    static let syntheticMatrix = try! RAWColorMatrix3x3(
        m00: 1.4, m01: -0.3, m02: 0.05,
        m10: -0.2, m11: 1.1, m12: 0.15,
        m20: 0.08, m21: -0.25, m22: 1.3
    )

    /// A whole synthetic calibration that fits exactly.
    static func calibration(
        matrix: RAWColorMatrix3x3 = CalibrationTestData.syntheticMatrix,
        measurements: IRCalibrationMeasurementSet? = nil,
        name: String = "Synthetic calibration",
        id: IRCalibrationID? = nil
    ) throws -> IRCalibration {
        let measurements = measurements ?? measurementSet()
        let reference = referenceDataset(for: measurements, matrix: matrix)
        let fit = try IRCalibrationFitter().fit(
            measurements: measurements, reference: reference, now: fittedAt
        )
        return try IRCalibration(
            id: id ?? calibrationID(),
            name: name,
            measurements: measurements,
            reference: reference,
            fit: fit
        )
    }

    // MARK: - Comparison helpers

    static func maximumCoefficientDifference(
        _ a: RAWColorMatrix3x3, _ b: RAWColorMatrix3x3
    ) -> Double {
        zip(a.rows.flatMap { $0 }, b.rows.flatMap { $0 })
            .map { abs($0 - $1) }
            .max() ?? 0
    }
}
