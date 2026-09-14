import Foundation

/// Turns measurement evidence plus a reference dataset into a fitted transform.
///
/// ## The chain, stated once
///
/// ```text
/// per-plane normalised means           what the evidence stores
///          ↓  session white balance    gains re-derived from the evidence
/// balanced per-plane means
///          ↓  green-channel policy     the only channel collapse, and it is named
/// camera RGB per patch
///          ↓  least squares            output = M × input
/// M : camera RGB -> working RGB
/// ```
///
/// Every step reads the measurement set and nothing else. There is no
/// photograph, no sidecar, no `ImageAdjustments` and no preview anywhere in
/// this path — which is what makes a fit reproducible from stored evidence, and
/// what keeps one photograph's creative neutral-patch choice out of a reusable
/// transform.
///
/// ## Where the result sits in the pipeline
///
/// ```text
/// normalised RAW → white balance → demosaic → CALIBRATION TRANSFORM → working RGB
/// ```
///
/// Exactly where `RAWCameraToWorkingColorTransform` sits today, because that is
/// the stage whose job it replaces: it is the map from camera-native RGB into
/// the working representation. Not after display encoding, where values are no
/// longer proportional to light and a linear transform means nothing; not
/// before white balance, because the camera responses it is fitted from are
/// balanced ones.
public struct IRCalibrationFitter: Sendable {

    public init() {}

    /// Fits a transform, or refuses.
    ///
    /// `now` is a parameter so that a test can produce a byte-identical
    /// artefact twice. Production passes the real clock.
    public func fit(
        measurements: IRCalibrationMeasurementSet,
        reference: IRCalibrationReferenceDataset,
        now: Date = Date()
    ) throws -> IRCalibrationFitResult {
        guard measurements.target == reference.target else {
            throw IRCalibrationError.targetMismatch(
                measured: measurements.target.displayName,
                reference: reference.target.displayName
            )
        }

        let derivation = try Self.derive(measurements: measurements, reference: reference)

        var residuals: [IRCalibrationPatchResidual] = []
        residuals.reserveCapacity(derivation.residuals.count)
        for residual in derivation.residuals {
            residuals.append(
                try IRCalibrationPatchResidual(
                    patch: residual.patch,
                    red: residual.red,
                    green: residual.green,
                    blue: residual.blue
                )
            )
        }

        return IRCalibrationFitResult(
            matrix: derivation.matrix,
            sourceMeasurementID: measurements.id,
            referenceDataset: reference.identity,
            whiteBalancePolicy: measurements.whiteBalancePolicy,
            method: .current,
            conditioning: derivation.conditioning,
            metrics: try IRCalibrationFitMetrics(
                residuals: residuals,
                excludedPatchCount: measurements.excludedPatchCount
            ),
            fittedAt: now
        )
    }

    // MARK: - The arithmetic, separated from the packaging

    /// One patch's signed residual, before it becomes an
    /// ``IRCalibrationPatchResidual``.
    struct DerivedResidual: Equatable, Sendable {
        let patch: IRCalibrationTargetPatchID
        let red: Double
        let green: Double
        let blue: Double
    }

    /// What deriving a transform from evidence actually produces: a matrix,
    /// the conditioning of the data it came from, and one residual per fitted
    /// patch, in fitted order.
    struct Derivation: Equatable, Sendable {
        let matrix: RAWColorMatrix3x3
        let conditioning: IRCalibrationConditioning
        let residuals: [DerivedResidual]
    }

    /// The one place a transform is derived from evidence.
    ///
    /// Separated from ``fit(measurements:reference:now:)`` so that
    /// ``IRCalibrationFitVerifier`` can recompute a stored artefact's numbers
    /// without a second implementation of the same arithmetic — and without
    /// building the ``IRCalibrationFitResult`` packaging it is about to
    /// compare against. There is one solver, one white-balance derivation and
    /// one green collapse in this project, and everything that needs them goes
    /// through here.
    ///
    /// It does not compare targets: pairing a chart's measurements with
    /// another chart's reference values is a rule about the record, enforced
    /// by `fit` and by ``IRCalibration``, not a property of the arithmetic.
    static func derive(
        measurements: IRCalibrationMeasurementSet,
        reference: IRCalibrationReferenceDataset
    ) throws(IRCalibrationFitError) -> Derivation {
        let included = measurements.includedPatches
        guard !included.isEmpty else { throw .noIncludedPatches }

        let gains = try Self.sessionGains(for: measurements)

        var patches: [IRCalibrationTargetPatchID] = []
        var samples: [IRCalibrationMatrixSolver.Sample] = []
        patches.reserveCapacity(included.count)
        samples.reserveCapacity(included.count)

        for patch in included {
            guard let referenceValue = reference.value(for: patch.patch) else {
                throw .missingReferenceValue(patch: patch.patch.rawValue)
            }
            let camera = try Self.cameraRGB(
                for: patch, gains: gains, policy: measurements.domain.greenPolicy
            )
            patches.append(patch.patch)
            samples.append(
                IRCalibrationMatrixSolver.Sample(
                    label: patch.patch.rawValue,
                    input: camera,
                    output: SIMD3(
                        referenceValue.red, referenceValue.green, referenceValue.blue
                    )
                )
            )
        }

        let solution = try IRCalibrationMatrixSolver().solve(samples)

        var residuals: [DerivedResidual] = []
        residuals.reserveCapacity(samples.count)
        for (patch, sample) in zip(patches, samples) {
            let fitted = Self.apply(solution.matrix, to: sample.input)
            let red = fitted.x - sample.output.x
            let green = fitted.y - sample.output.y
            let blue = fitted.z - sample.output.z
            for (name, value) in [("red", red), ("green", green), ("blue", blue)]
            where !value.isFinite {
                throw .nonFiniteSample(
                    patch: patch.rawValue, field: "residual \(name)", value: value
                )
            }
            residuals.append(
                DerivedResidual(patch: patch, red: red, green: green, blue: blue)
            )
        }

        return Derivation(
            matrix: solution.matrix, conditioning: solution.conditioning, residuals: residuals
        )
    }

    // MARK: - Session white balance

    /// The per-plane gains the session's neutral reference defines.
    ///
    /// Re-derived from the evidence on every fit rather than stored, so a fit
    /// cannot disagree with the measurements it claims to come from. The rule
    /// is the one ``RAWWhiteBalanceEstimator`` uses for a photograph's neutral
    /// patch — the strongest measured plane keeps a gain of `1` and the others
    /// are scaled up to meet it — because this project has one definition of
    /// neutral and a second one here would be a second definition.
    ///
    /// What differs is *which patch*: a calibration session's neutral is a
    /// patch of the target, chosen once for the session, and never a region
    /// somebody picked in a photograph they were editing.
    ///
    /// ## The neutral reference has to be usable, not merely present
    ///
    /// `IRCalibrationMeasurementSet` requires only that the named patch was
    /// *measured*, and that is the right rule there: evidence describes what
    /// the camera produced, and an exclusion is a judgement about it rather
    /// than a fact of the measurement. A session whose neutral patch turned
    /// out to be clipped is a real thing that happened, and the evidence must
    /// be able to say so.
    ///
    /// What must not happen is that the patch is then used anyway. Every gain
    /// multiplies every patch in the fit, so an excluded neutral reference
    /// does not affect one patch — it determines the white balance of the
    /// whole transform, through data the evidence itself marked unusable. So
    /// the refusal lives here, in the fit, where the judgement is acted on.
    static func sessionGains(
        for measurements: IRCalibrationMeasurementSet
    ) throws(IRCalibrationFitError) -> IRCalibrationSessionGains {
        guard let neutral = measurements.whiteBalancePolicy.neutralPatch else {
            return .unbalanced
        }
        guard let patch = measurements.measurement(for: neutral) else {
            throw .unmeasuredNeutralReference(patch: neutral.rawValue)
        }
        if let exclusion = patch.exclusion {
            throw .excludedNeutralReference(patch: neutral.rawValue, exclusion: exclusion)
        }

        // Zero clipped samples, whatever the general tolerance says.
        //
        // `IRCalibrationClippingPolicy.maximumClippedSampleFraction` decides
        // whether an *ordinary* patch is included, and that is a bounded
        // judgement: one tolerated patch contributes one row to a
        // least-squares problem with many rows. The neutral reference is not
        // one row. Its gains multiply every channel of every fitted patch, so
        // a single censored sample inside it would set the white balance of
        // the whole transform from a number the sensor did not record. A patch
        // may therefore be included by the policy and still be refused here,
        // and that is not an inconsistency between the two rules — it is the
        // difference between what a patch contributes and what a reference
        // decides.
        let clipped = patch.clippedSampleCount
        if clipped > 0 {
            throw .clippedNeutralReference(
                patch: neutral.rawValue,
                clippedSamples: clipped,
                totalSamples: patch.totalSampleCount
            )
        }

        // Every colour plane the layout produced has to be measured here,
        // because every plane of every fitted patch is about to be scaled by a
        // gain derived from this one. Checked against the evidence's recorded
        // signature rather than against "does it have red, green and blue?":
        // a four-plane RGGB neutral patch missing its second green still has
        // all three channels, and the gains it defines would balance green
        // from one phase.
        //
        // Valid evidence cannot fail this — an included patch is complete
        // against the signature, and an excluded neutral reference was already
        // refused above — which is the point of stating it here rather than
        // trusting it.
        let measured = Set(patch.planes.map(\.colorPlane))
        let missing = measurements.colorPlaneSignature.colorPlanes
            .filter { !measured.contains($0) }
        guard missing.isEmpty else {
            throw .incompleteNeutralReference(
                patch: neutral.rawValue, missingColorPlanes: missing
            )
        }

        var means: [Int: Double] = [:]
        for plane in patch.planes {
            guard plane.mean.isFinite else {
                throw .nonFiniteSample(
                    patch: neutral.rawValue,
                    field: "neutral plane \(plane.colorPlane) mean",
                    value: plane.mean
                )
            }
            guard plane.mean > 0 else {
                throw .nonFiniteSample(
                    patch: neutral.rawValue,
                    field: """
                        neutral plane \(plane.colorPlane) mean (a neutral reference at or \
                        below zero defines no gain)
                        """,
                    value: plane.mean
                )
            }
            means[plane.colorPlane] = plane.mean
        }

        guard let target = means.values.max() else {
            throw .missingChannelResponse(patch: neutral.rawValue, channel: "any")
        }

        return IRCalibrationSessionGains(
            neutralPatch: neutral, byColorPlane: means.mapValues { target / $0 }
        )
    }

    static func name(of channel: RAWLinearRGBChannel) -> String {
        switch channel {
        case .red: return "red"
        case .green: return "green"
        case .blue: return "blue"
        }
    }

    // MARK: - Camera RGB

    /// Collapses a patch's per-plane means into one `(R, G, B)` response.
    ///
    /// Two independent green planes become one green value by the measurement
    /// set's own recorded policy — never by an unnamed convention at a call
    /// site. See ``IRCalibrationGreenChannelPolicy``.
    static func cameraRGB(
        for patch: IRCalibrationPatchMeasurement,
        gains: IRCalibrationSessionGains,
        policy: IRCalibrationGreenChannelPolicy
    ) throws(IRCalibrationFitError) -> SIMD3<Double> {
        func response(
            _ channel: RAWLinearRGBChannel, _ name: String
        ) throws(IRCalibrationFitError) -> Double {
            let planes = patch.planes(for: channel)
            guard !planes.isEmpty else {
                throw .missingChannelResponse(
                    patch: patch.patch.rawValue, channel: name
                )
            }
            var total = 0.0
            for plane in planes {
                guard plane.mean.isFinite else {
                    throw .nonFiniteSample(
                        patch: patch.patch.rawValue,
                        field: "plane \(plane.colorPlane) mean",
                        value: plane.mean
                    )
                }
                total += try plane.mean
                    * gains.gain(forColorPlane: plane.colorPlane, of: patch.patch)
            }
            switch policy {
            case .meanOfGreenPlaneMeans:
                // Unweighted across the planes of this channel. For red and
                // blue there is one plane and the division is by one; for
                // green it is the documented collapse. Applying the same
                // expression to all three keeps the rule in one place.
                return total / Double(planes.count)
            }
        }

        let red = try response(.red, "red")
        let green = try response(.green, "green")
        let blue = try response(.blue, "blue")

        for (name, value) in [("red", red), ("green", green), ("blue", blue)]
        where !value.isFinite {
            throw .nonFiniteSample(
                patch: patch.patch.rawValue, field: "balanced \(name)", value: value
            )
        }

        return SIMD3(red, green, blue)
    }

    /// `output = M × input`, the project's one matrix convention.
    static func apply(_ matrix: RAWColorMatrix3x3, to input: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            matrix.m00 * input.x + matrix.m01 * input.y + matrix.m02 * input.z,
            matrix.m10 * input.x + matrix.m11 * input.y + matrix.m12 * input.z,
            matrix.m20 * input.x + matrix.m21 * input.y + matrix.m22 * input.z
        )
    }
}
