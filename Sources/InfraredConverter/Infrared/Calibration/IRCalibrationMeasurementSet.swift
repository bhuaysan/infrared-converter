import Foundation

/// What one colour plane produced inside one patch.
///
/// The **unbalanced** mean: black-level-subtracted, white-level-normalised, and
/// nothing else. Session white balance is derived from these and applied at fit
/// time rather than baked in here, so the evidence stays the thing the camera
/// actually produced and a different balancing rule can be applied later
/// without re-photographing anything.
public struct IRCalibrationPlaneMeasurement: Equatable, Sendable {

    /// The CFA colour-plane index, as the decoder's layout numbers them.
    public let colorPlane: Int

    /// Which RGB channel that plane's filter is.
    ///
    /// Carried explicitly rather than re-derived, because the plane-to-letter
    /// mapping lives in the file's own `colorDescription` and a reader of this
    /// record does not have the file.
    public let channel: RAWLinearRGBChannel

    public let sampleCount: Int

    /// The mean normalised sample value over this plane's sites in the patch.
    public let mean: Double

    /// How many of those samples were at or above the clipping threshold.
    public let clippedSampleCount: Int

    public init(
        colorPlane: Int,
        channel: RAWLinearRGBChannel,
        sampleCount: Int,
        mean: Double,
        clippedSampleCount: Int
    ) throws(IRCalibrationError) {
        guard mean.isFinite else {
            throw .nonFiniteValue(field: "plane\(colorPlane).mean", value: mean)
        }
        guard sampleCount > 0 else {
            throw .missingRequiredField(
                field: "plane\(colorPlane).sampleCount",
                reason: "A plane with no samples in the patch measured nothing there."
            )
        }
        guard clippedSampleCount >= 0, clippedSampleCount <= sampleCount else {
            throw .missingRequiredField(
                field: "plane\(colorPlane).clippedSampleCount",
                reason: """
                    \(clippedSampleCount) clipped of \(sampleCount) samples is not a count \
                    this patch could have produced.
                    """
            )
        }
        self.colorPlane = colorPlane
        self.channel = channel
        self.sampleCount = sampleCount
        self.mean = mean
        self.clippedSampleCount = clippedSampleCount
    }
}

/// Why a measured patch is not in the fit.
public enum IRCalibrationPatchExclusion: Equatable, Sendable {

    case clipped(clippedSamples: Int, totalSamples: Int)

    /// A colour plane the sensor layout has produced no samples inside this
    /// patch — a region too small, or too badly aligned, to contain whole CFA
    /// cells.
    case incompleteColorPlanes(missing: [Int])

    case nonFiniteSample

    /// The reference dataset has no value for this patch, so there is nothing
    /// to fit it towards.
    case noReferenceValue

    /// Excluded by whoever made the measurement.
    case excludedByOperator(reason: String)

    public var shortDescription: String {
        switch self {
        case .clipped(let clipped, let total):
            return "clipped (\(clipped) of \(total) samples at or above saturation)"
        case .incompleteColorPlanes(let missing):
            return "colour plane\(missing.count == 1 ? "" : "s") \(missing.map(String.init).joined(separator: ", ")) not sampled"
        case .nonFiniteSample:
            return "a sample was not a finite number"
        case .noReferenceValue:
            return "no reference value for this patch"
        case .excludedByOperator(let reason):
            return "excluded by the operator: \(reason)"
        }
    }
}

/// One target patch, as this camera recorded it.
public struct IRCalibrationPatchMeasurement: Equatable, Sendable {

    public let patch: IRCalibrationTargetPatchID

    /// Where in the active area the samples came from.
    ///
    /// Kept so the measurement can be repeated exactly, and so a reader can
    /// see how much of the patch was sampled.
    public let region: RAWActiveAreaRegion

    public let planes: [IRCalibrationPlaneMeasurement]

    /// Whether this patch is admitted to the fit, and if not, why.
    ///
    /// `nil` means included. Recorded per patch rather than by filtering the
    /// list, so a calibration can state how many patches were rejected and for
    /// what — a fit over 18 of 24 patches is a different claim from a fit over
    /// all 24, and the artefact has to be able to say which it is.
    public let exclusion: IRCalibrationPatchExclusion?

    public init(
        patch: IRCalibrationTargetPatchID,
        region: RAWActiveAreaRegion,
        planes: [IRCalibrationPlaneMeasurement],
        exclusion: IRCalibrationPatchExclusion? = nil
    ) throws(IRCalibrationError) {
        guard !planes.isEmpty else {
            throw .missingRequiredField(
                field: "patch.\(patch).planes",
                reason: "A patch with no plane measurements records nothing."
            )
        }
        var seen = Set<Int>()
        for plane in planes {
            guard seen.insert(plane.colorPlane).inserted else {
                throw .duplicateTargetPatch(patch: "\(patch) plane \(plane.colorPlane)")
            }
        }
        self.patch = patch
        self.region = region
        self.planes = planes.sorted { $0.colorPlane < $1.colorPlane }
        self.exclusion = exclusion
    }

    public var isIncluded: Bool { exclusion == nil }

    public var totalSampleCount: Int { planes.reduce(0) { $0 + $1.sampleCount } }

    public var clippedSampleCount: Int {
        planes.reduce(0) { $0 + $1.clippedSampleCount }
    }

    /// The measured planes belonging to one RGB channel.
    public func planes(for channel: RAWLinearRGBChannel) -> [IRCalibrationPlaneMeasurement] {
        planes.filter { $0.channel == channel }
    }
}

/// One camera, one target, one illumination, one occasion: the evidence.
///
/// ```text
/// IRCalibrationMeasurementSet
///  ├── id                  stable, generated, never derived from a name
///  ├── target              which chart, and therefore what the patch ids mean
///  ├── illuminant          what was lighting it
///  ├── captureContext      camera, conversion and filter, by value
///  ├── colorPlaneSignature which colour planes the sensor layout produced
///  ├── domain              where in the pipeline the responses were measured
///  ├── normalization       which normalisation produced the numbers
///  ├── clippingPolicy      what counted as too close to saturation
///  ├── whiteBalancePolicy  the session's own neutral reference
///  ├── patches             per-patch, per-plane means and sample counts
///  └── provenance          who, with what, when
/// ```
///
/// **Immutable, and never revised.** A measurement is a historical fact: this
/// camera, in front of this chart, under this light, produced these numbers. If
/// the fit was wrong, the fit is redone — a new ``IRCalibrationID`` naming this
/// same measurement set as its source — and the evidence is untouched. Editing
/// evidence to make a fit look better is the failure mode this separation
/// exists to make impossible.
///
/// It deliberately contains **no matrix and no metrics**. It is what was seen,
/// not what was concluded.
public struct IRCalibrationMeasurementSet: Equatable, Sendable {

    public let id: IRCalibrationMeasurementSetID
    public let measuredAt: Date
    public let target: IRCalibrationTarget
    public let illuminant: IRCalibrationIlluminant
    public let captureContext: IRCalibrationCaptureContext

    /// Which colour planes the sensor layout produced at the moment of
    /// measurement, and what each one is.
    ///
    /// The **expectation**, recorded from the sensor layout rather than
    /// derived from the patches, which is what lets every patch below be
    /// checked for completeness against something. See
    /// ``IRCalibrationColorPlaneSignature`` for why a union of the planes the
    /// patches happen to carry cannot serve.
    public let colorPlaneSignature: IRCalibrationColorPlaneSignature

    public let domain: IRCalibrationMeasurementDomain
    public let normalization: IRCalibrationNormalizationProvenance
    public let clippingPolicy: IRCalibrationClippingPolicy
    public let whiteBalancePolicy: IRCalibrationWhiteBalancePolicy
    public let patches: [IRCalibrationPatchMeasurement]
    public let provenance: IRCalibrationProvenance

    /// The name of the RAW file the measurements came from.
    ///
    /// The **file name**, never the path. A full path leaks a person's
    /// directory layout into an artefact they may share, and adds nothing: the
    /// evidence is the measurements, not their location on one machine.
    public let sourceFileName: String?

    public init(
        id: IRCalibrationMeasurementSetID = .generated(),
        measuredAt: Date,
        target: IRCalibrationTarget,
        illuminant: IRCalibrationIlluminant,
        captureContext: IRCalibrationCaptureContext,
        colorPlaneSignature: IRCalibrationColorPlaneSignature,
        domain: IRCalibrationMeasurementDomain = .default,
        normalization: IRCalibrationNormalizationProvenance,
        clippingPolicy: IRCalibrationClippingPolicy = .default,
        whiteBalancePolicy: IRCalibrationWhiteBalancePolicy,
        patches: [IRCalibrationPatchMeasurement],
        provenance: IRCalibrationProvenance,
        sourceFileName: String? = nil
    ) throws(IRCalibrationError) {
        guard !patches.isEmpty else { throw .emptyMeasurementSet }

        // One of the two domain boundaries that create calibration evidence,
        // and therefore one of the two places an illuminant identity is
        // checked and normalised. Decoding a persisted measurement set arrives
        // here too, so there is no separate validation on the wire.
        let illuminant = try illuminant.validated(field: "measurements.illuminant")

        var seen = Set<IRCalibrationTargetPatchID>()
        for measurement in patches {
            guard target.contains(measurement.patch) else {
                throw .unknownTargetPatch(
                    patch: measurement.patch.rawValue, target: target.displayName
                )
            }
            guard seen.insert(measurement.patch).inserted else {
                throw .duplicateTargetPatch(patch: measurement.patch.rawValue)
            }
            try Self.validate(measurement, against: colorPlaneSignature)
        }

        if let neutral = whiteBalancePolicy.neutralPatch {
            guard target.contains(neutral) else {
                throw .unknownTargetPatch(
                    patch: neutral.rawValue, target: target.displayName
                )
            }
            guard seen.contains(neutral) else {
                throw .missingRequiredField(
                    field: "whiteBalancePolicy.neutralPatch",
                    reason: """
                        The session's neutral reference is patch "\(neutral)", which was not \
                        measured. The gains it defines cannot be derived from this evidence, \
                        so the fit would not be reproducible from it.
                        """
                )
            }
        }

        self.id = id
        // Truncated to the precision the file format carries, so that a
        // calibration always equals itself after a round trip. See
        // `IRCalibrationTimestamp`.
        self.measuredAt = IRCalibrationTimestamp.recorded(measuredAt)
        self.target = target
        self.illuminant = illuminant
        self.captureContext = captureContext
        self.colorPlaneSignature = colorPlaneSignature
        self.domain = domain
        self.normalization = normalization
        self.clippingPolicy = clippingPolicy
        self.whiteBalancePolicy = whiteBalancePolicy
        self.patches = patches.sorted { $0.patch < $1.patch }
        self.provenance = provenance
        self.sourceFileName = sourceFileName
    }

    // MARK: - Completeness against the signature

    /// Checks one patch against the layout the session recorded.
    ///
    /// ```text
    /// plane not in the signature          refused, always
    /// plane recorded as another channel   refused, always
    /// every expected plane present        included, or excluded for any reason
    ///                                     except a claim of incompleteness
    /// a plane absent                      excluded, and a claim of
    ///                                     incompleteness must name exactly
    ///                                     the planes that are absent
    /// ```
    ///
    /// The asymmetry between included and excluded is the point. A **fitted**
    /// patch must be complete, because collapsing a channel from fewer planes
    /// than the sensor has silently changes what was measured — on an RGGB
    /// layout, a green taken from one phase instead of the mean of two. An
    /// **excluded** patch may be incomplete, because incompleteness is a real
    /// thing that happens to a region near the edge of the active area, and
    /// evidence has to be able to record it.
    ///
    /// What an excluded patch may not do is *misdescribe* it. An exclusion is
    /// the evidence's own account of why a patch was not fitted, and one
    /// naming planes other than the missing ones is a statement about a
    /// different patch. A patch excluded for some other reason entirely —
    /// a non-finite sample, an operator's judgement — is left alone: it makes
    /// no claim about which planes are present, so there is nothing to
    /// contradict.
    static func validate(
        _ patch: IRCalibrationPatchMeasurement,
        against signature: IRCalibrationColorPlaneSignature
    ) throws(IRCalibrationError) {
        for plane in patch.planes {
            guard let expected = signature.channel(forColorPlane: plane.colorPlane) else {
                throw .unexpectedColorPlane(
                    patch: patch.patch.rawValue, colorPlane: plane.colorPlane
                )
            }
            guard expected == plane.channel else {
                throw .colorPlaneChannelMismatch(
                    patch: patch.patch.rawValue,
                    colorPlane: plane.colorPlane,
                    expected: IRCalibrationColorPlaneSignature.name(of: expected),
                    found: IRCalibrationColorPlaneSignature.name(of: plane.channel)
                )
            }
        }

        let measured = Set(patch.planes.map(\.colorPlane))
        let missing = signature.colorPlanes.filter { !measured.contains($0) }

        if case .incompleteColorPlanes(let claimed) = patch.exclusion {
            guard Set(claimed) == Set(missing) else {
                throw .inconsistentPatchExclusion(
                    patch: patch.patch.rawValue,
                    claimed: claimed.sorted(),
                    missing: missing
                )
            }
            return
        }

        guard missing.isEmpty || !patch.isIncluded else {
            throw .incompletePatchMeasurement(
                patch: patch.patch.rawValue, missing: missing
            )
        }
    }

    public var includedPatches: [IRCalibrationPatchMeasurement] {
        patches.filter(\.isIncluded)
    }

    public var excludedPatches: [IRCalibrationPatchMeasurement] {
        patches.filter { !$0.isIncluded }
    }

    public var includedPatchCount: Int { includedPatches.count }
    public var excludedPatchCount: Int { excludedPatches.count }

    public func measurement(
        for patch: IRCalibrationTargetPatchID
    ) -> IRCalibrationPatchMeasurement? {
        patches.first { $0.patch == patch }
    }

    /// The same evidence with one patch's inclusion changed.
    ///
    /// The only mutation offered, and it is a replacement rather than an edit:
    /// pairing evidence with a reference dataset can discover that a patch has
    /// no reference value, which is a fact about the pairing rather than about
    /// the measurement. Nothing here can change a measured number.
    public func excluding(
        _ patch: IRCalibrationTargetPatchID, because reason: IRCalibrationPatchExclusion
    ) throws(IRCalibrationError) -> IRCalibrationMeasurementSet {
        guard let existing = measurement(for: patch) else {
            throw .unknownTargetPatch(patch: patch.rawValue, target: target.displayName)
        }
        let replacement = try IRCalibrationPatchMeasurement(
            patch: existing.patch,
            region: existing.region,
            planes: existing.planes,
            exclusion: existing.exclusion ?? reason
        )
        return try IRCalibrationMeasurementSet(
            id: id,
            measuredAt: measuredAt,
            target: target,
            illuminant: illuminant,
            captureContext: captureContext,
            colorPlaneSignature: colorPlaneSignature,
            domain: domain,
            normalization: normalization,
            clippingPolicy: clippingPolicy,
            whiteBalancePolicy: whiteBalancePolicy,
            patches: patches.map { $0.patch == patch ? replacement : $0 },
            provenance: provenance,
            sourceFileName: sourceFileName
        )
    }

    public var diagnosticDescription: String {
        """
        \(id) — \(patches.count) patches of \(target.displayName) \
        (\(includedPatchCount) included, \(excludedPatchCount) excluded), \
        \(captureContext.diagnosticDescription), \(illuminant.diagnosticDescription), \
        planes [\(colorPlaneSignature.diagnosticDescription)], \
        \(domain.diagnosticDescription), \(normalization.diagnosticDescription), \
        \(whiteBalancePolicy.diagnosticDescription), \(provenance.diagnosticDescription)
        """
    }
}
