import Foundation

/// The analytical path from a RAW file to calibration evidence.
///
/// ```text
/// RAW
///  ↓ decode                    the project's own decoder boundary
/// sensor mosaic
///  ↓ normalise                 black level, white level, unclamped, no clipping
/// normalised mosaic  ─────────────────────────────────────────────┐
///  ↓ per-patch, per-plane means over the chart's regions           │  evidence is
/// IRCalibrationMeasurementSet                                      │  taken here
/// ```
///
/// ## What this path is not
///
/// It is **not** the display renderer, and it must never become one. Nothing
/// here produces an image, a `CGImage`, a preview or an export; nothing here
/// applies white balance, demosaicing, a channel mix, exposure, a transfer
/// function or a range policy. A measurement taken from a display buffer would
/// be taken from 8-bit, clipped, gamma-encoded values — which is to say from
/// numbers that are no longer proportional to light, and from which no linear
/// transform can honestly be fitted. See
/// `docs/decisions/0008-display-preview-rendering.md` for what the display
/// boundary does to a value, and `docs/calibration-protocol.md` for why none of
/// it may happen before a measurement.
///
/// It stops at the normalised mosaic deliberately: that is the last
/// representation in this pipeline that is still one sample per site, with no
/// interpolation and no colour decision applied. See
/// ``IRCalibrationMeasurementDomain`` for why the mosaic rather than the
/// demosaiced image.
///
/// ## What it shares
///
/// The decode and the normalisation are the project's own — `RAWDecoder` and
/// `RAWMosaicNormalizer`, through the same `RAWBasePreparationPipeline` the
/// preview and the export both start from. There is no parallel black-level or
/// white-level interpretation for calibration, which is why the measurement set
/// can record *which* normalisation produced its numbers and have that mean
/// something.
public struct IRCalibrationMeasurementPipeline: Sendable {

    public init() {}

    /// Everything about a session that is not in the RAW file.
    public struct Session: Sendable {

        public let target: IRCalibrationTarget
        public let geometry: IRCalibrationChartGeometry
        public let illuminant: IRCalibrationIlluminant
        public let sensorConversion: IRSensorConversion
        public let filter: IRCalibrationFilterSnapshot
        public let bodyScope: IRCalibrationBodyScope
        public let whiteBalancePolicy: IRCalibrationWhiteBalancePolicy
        public let clippingPolicy: IRCalibrationClippingPolicy
        public let domain: IRCalibrationMeasurementDomain
        public let provenance: IRCalibrationProvenance

        /// The capture profile the session was shot under, if any. Context
        /// only — what was measured is the three fields above it, by value.
        public let measuredUnderProfile: IRCaptureProfileID?

        public init(
            target: IRCalibrationTarget,
            geometry: IRCalibrationChartGeometry,
            illuminant: IRCalibrationIlluminant,
            sensorConversion: IRSensorConversion,
            filter: IRCalibrationFilterSnapshot,
            bodyScope: IRCalibrationBodyScope,
            whiteBalancePolicy: IRCalibrationWhiteBalancePolicy,
            clippingPolicy: IRCalibrationClippingPolicy = .default,
            domain: IRCalibrationMeasurementDomain = .default,
            provenance: IRCalibrationProvenance,
            measuredUnderProfile: IRCaptureProfileID? = nil
        ) throws(IRCalibrationError) {
            guard geometry.target == target else {
                throw .targetMismatch(
                    measured: target.displayName, reference: geometry.target.displayName
                )
            }
            self.target = target
            self.geometry = geometry
            self.illuminant = illuminant
            self.sensorConversion = sensorConversion
            self.filter = filter
            self.bodyScope = bodyScope
            self.whiteBalancePolicy = whiteBalancePolicy
            self.clippingPolicy = clippingPolicy
            self.domain = domain
            self.provenance = provenance
            self.measuredUnderProfile = measuredUnderProfile
        }
    }

    /// Decodes, normalises and measures.
    ///
    /// `now` and `measurementSetID` are parameters so that a test can produce
    /// a byte-identical artefact twice.
    public func measure(
        at url: URL,
        using decoder: RAWDecoder,
        session: Session,
        measurementSetID: IRCalibrationMeasurementSetID = .generated(),
        now: Date = Date(),
        cancellation: ProcessingCancellation = .none
    ) throws -> IRCalibrationMeasurementSet {
        let source = try RAWBasePreparationPipeline().prepare(decoding: url, using: decoder)
        return try measure(
            source,
            session: session,
            measurementSetID: measurementSetID,
            now: now,
            cancellation: cancellation
        )
    }

    /// Measures an already normalised mosaic.
    ///
    /// Split out so the measurement rules can be tested against a synthetic
    /// mosaic without a RAW file, in exactly the way the white-balance
    /// estimator's are.
    func measure(
        _ source: NormalizedRAWSource,
        session: Session,
        measurementSetID: IRCalibrationMeasurementSetID = .generated(),
        now: Date = Date(),
        cancellation: ProcessingCancellation = .none
    ) throws -> IRCalibrationMeasurementSet {
        let identity = source.metadata.identity
        guard let make = Self.nonEmpty(identity.normalizedMake ?? identity.make),
              let model = Self.nonEmpty(identity.normalizedModel ?? identity.model)
        else {
            throw IRCalibrationMeasurementError.cameraUnidentified
        }

        let camera = try IRCalibrationBodyIdentity(
            make: make,
            model: model,
            serialNumber: nil,
            scope: session.bodyScope
        )

        let layout = source.mosaic.sensorColorLayout
        let channels = try Self.channelsByColorPlane(in: layout)

        // The one reading of the sensor layout in this path becomes the
        // evidence's recorded expectation. Not inferred afterwards from the
        // planes the patches happened to contain — that inference is exactly
        // what the signature exists to remove.
        let signature = try IRCalibrationColorPlaneSignature(channelsByColorPlane: channels)

        let regions = try session.geometry.patchRegions(
            activeAreaWidth: source.activeAreaWidth,
            activeAreaHeight: source.activeAreaHeight
        )

        var patches: [IRCalibrationPatchMeasurement] = []
        patches.reserveCapacity(regions.count)

        for (patch, region) in regions {
            try cancellation.check()
            patches.append(
                try Self.measurePatch(
                    patch,
                    region: region,
                    in: source.mosaic,
                    channels: channels,
                    clipping: session.clippingPolicy,
                    cancellation: cancellation
                )
            )
        }

        guard patches.contains(where: \.isIncluded) else {
            throw IRCalibrationMeasurementError.allPatchesExcluded(
                reason: """
                    All \(patches.count) patches were excluded. The usual cause is exposure: \
                    a calibration capture must place every patch below saturation, and one \
                    that clips even the darkest is measuring the top of the well rather than \
                    the chart.
                    """
            )
        }

        return try IRCalibrationMeasurementSet(
            id: measurementSetID,
            measuredAt: now,
            target: session.target,
            illuminant: session.illuminant,
            captureContext: IRCalibrationCaptureContext(
                camera: camera,
                sensorConversion: session.sensorConversion,
                filter: session.filter,
                measuredUnderProfile: session.measuredUnderProfile
            ),
            colorPlaneSignature: signature,
            domain: session.domain,
            normalization: IRCalibrationNormalizationProvenance(source.mosaic.processing),
            clippingPolicy: session.clippingPolicy,
            whiteBalancePolicy: session.whiteBalancePolicy,
            patches: patches,
            provenance: session.provenance,
            sourceFileName: source.url.lastPathComponent
        )
    }

    // MARK: - One patch

    private static func measurePatch(
        _ patch: IRCalibrationTargetPatchID,
        region: RAWActiveAreaRegion,
        in mosaic: LinearRAWMosaic,
        channels: [Int: RAWLinearRGBChannel],
        clipping: IRCalibrationClippingPolicy,
        cancellation: ProcessingCancellation
    ) throws -> IRCalibrationPatchMeasurement {
        try region.validate(in: mosaic)

        let width = mosaic.width
        let layout = mosaic.sensorColorLayout
        let rowLimit = region.originRow + region.height
        let columnLimit = region.originColumn + region.width

        var sums = [Int: Double]()
        var counts = [Int: Int]()
        var clipped = [Int: Int]()
        var sawNonFinite = false

        try mosaic.values.withUnsafeBufferPointer { input in
            for row in region.originRow..<rowLimit {
                try cancellation.check()
                let rowOffset = row * width
                for column in region.originColumn..<columnLimit {
                    guard let plane = layout.colorPlaneIndex(row: row, column: column) else {
                        throw RAWProcessingError.missingColorPlane(row: row, column: column)
                    }
                    let value = Double(input[rowOffset + column])
                    guard value.isFinite else {
                        sawNonFinite = true
                        continue
                    }
                    sums[plane, default: 0] += value
                    counts[plane, default: 0] += 1
                    if clipping.isClipped(value) {
                        clipped[plane, default: 0] += 1
                    }
                }
            }
        }

        var planes: [IRCalibrationPlaneMeasurement] = []
        var missing: [Int] = []
        for (plane, channel) in channels.sorted(by: { $0.key < $1.key }) {
            guard let count = counts[plane], count > 0, let sum = sums[plane] else {
                missing.append(plane)
                continue
            }
            planes.append(
                try IRCalibrationPlaneMeasurement(
                    colorPlane: plane,
                    channel: channel,
                    sampleCount: count,
                    mean: sum / Double(count),
                    clippedSampleCount: clipped[plane] ?? 0
                )
            )
        }

        // A patch that produced no plane at all cannot be represented, let
        // alone excluded with a reason, so this is the one case that refuses
        // rather than recording an exclusion.
        guard !planes.isEmpty else {
            throw IRCalibrationMeasurementError.unsupportedSensorLayout(
                reason: """
                    Patch "\(patch)" produced no samples of any colour plane in rows \
                    \(region.originRow)..<\(rowLimit), columns \
                    \(region.originColumn)..<\(columnLimit).
                    """
            )
        }

        let totalSamples = planes.reduce(0) { $0 + $1.sampleCount }
        let totalClipped = planes.reduce(0) { $0 + $1.clippedSampleCount }

        let exclusion: IRCalibrationPatchExclusion?
        if sawNonFinite {
            exclusion = .nonFiniteSample
        } else if !missing.isEmpty {
            exclusion = .incompleteColorPlanes(missing: missing)
        } else if clipping.excludes(clippedSamples: totalClipped, of: totalSamples) {
            exclusion = .clipped(clippedSamples: totalClipped, totalSamples: totalSamples)
        } else {
            exclusion = nil
        }

        return try IRCalibrationPatchMeasurement(
            patch: patch, region: region, planes: planes, exclusion: exclusion
        )
    }

    // MARK: - Colour planes

    /// Which RGB channel each colour plane of the layout is.
    ///
    /// Read from the decoder's own `colorDescription`, exactly as the
    /// demosaicer reads it, so the calibration path cannot disagree with the
    /// render path about which plane is green.
    static func channelsByColorPlane(
        in layout: RAWMetadata.SensorColorLayout
    ) throws -> [Int: RAWLinearRGBChannel] {
        let planes = try RAWWhiteBalanceEstimator.colorPlanes(in: layout)
        let letters = Array(layout.colorDescription)

        var result: [Int: RAWLinearRGBChannel] = [:]
        for plane in planes {
            guard plane >= 0, plane < letters.count else {
                throw IRCalibrationMeasurementError.unsupportedColorPlane(
                    colorPlane: plane, letter: "?"
                )
            }
            let letter = letters[plane]
            guard let channel = RAWLinearRGBChannel(colorDescriptionLetter: letter) else {
                throw IRCalibrationMeasurementError.unsupportedColorPlane(
                    colorPlane: plane, letter: String(letter)
                )
            }
            result[plane] = channel
        }

        let represented = Set(result.values)
        for channel in [RAWLinearRGBChannel.red, .green, .blue]
        where !represented.contains(channel) {
            throw IRCalibrationMeasurementError.unsupportedSensorLayout(
                reason: """
                    This sensor's colour layout has no \(channel) plane, so a 3x3 transform \
                    from its responses is not determined by any number of patches.
                    """
            )
        }

        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
