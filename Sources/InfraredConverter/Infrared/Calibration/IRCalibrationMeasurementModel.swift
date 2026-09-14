import Foundation

/// How the two green planes of a Bayer mosaic become one green response.
///
/// A Bayer cell has two green sites, at two phases. They are the same colour
/// filter, sampled twice, so a patch has two independent estimates of its green
/// response and the fit needs one number.
public enum IRCalibrationGreenChannelPolicy: String, Equatable, Sendable, Codable {

    /// The unweighted mean of the per-plane means.
    ///
    /// ```text
    /// green = (mean(G1) + mean(G2)) / 2
    /// ```
    ///
    /// Unweighted rather than sample-count weighted, deliberately. A patch
    /// rectangle can contain one more G1 site than G2 depending on where its
    /// top-left corner happens to land on the CFA grid, and a count-weighted
    /// mean would make the measured green response depend on that alignment —
    /// a geometric accident of how somebody dragged a rectangle, not a property
    /// of the patch. Equal weighting makes the rule phase-independent.
    ///
    /// The per-plane means are **kept** in the evidence either way
    /// (``IRCalibrationPlaneMeasurement``), so a different rule can be applied
    /// later without re-photographing anything. That is the point of recording
    /// planes rather than a collapsed RGB triple: no hidden channel collapse,
    /// and the collapse that does happen is named, versioned and reversible.
    case meanOfGreenPlaneMeans

    public var diagnosticDescription: String {
        switch self {
        case .meanOfGreenPlaneMeans:
            return "green = unweighted mean of the per-plane green means"
        }
    }
}

/// Where in the pipeline a calibration's patch responses were measured.
///
/// ```text
/// cfaPlaneMeans   normalised CFA samples, averaged per colour plane inside each patch
/// ```
///
/// ## Why the mosaic and not the demosaiced image
///
/// A calibration chart patch is a large, flat, uniform area — exactly the case
/// where a demosaicer has nothing to reconstruct and every interpolated value
/// inside the patch is a weighted average of neighbours that all carry the same
/// response. Averaging over the patch after demosaicing therefore measures very
/// nearly what averaging the mosaic measures, plus one extra variable: the
/// demosaicer.
///
/// Keeping the mosaic means the fit does not change when the interpolation
/// algorithm does, and this project's demosaicer is its own decision
/// (`docs/decisions/0005-application-owned-bayer-demosaicing.md`) that is
/// expected to improve. A calibration whose coefficients silently depended on
/// the bilinear reconstruction of 2026 would be a calibration of the
/// demosaicer.
///
/// It is also where the white-balance estimator already works, on the same
/// normalised buffer, with the same per-plane statistics — so the measurement
/// path is the machinery this project has, aimed at a grid of regions instead
/// of one.
///
/// Only near the patch **edges** does interpolation mix in the neighbouring
/// patch, and the protocol handles that by sampling the middle of each patch
/// rather than by choosing a domain. One case is modelled because one path
/// exists; a demosaiced-RGB domain would be a second case, added when a second
/// path is, rather than a placeholder now.
public enum IRCalibrationMeasurementDomain: Equatable, Sendable {

    case cfaPlaneMeans(green: IRCalibrationGreenChannelPolicy)

    public static let `default` = IRCalibrationMeasurementDomain
        .cfaPlaneMeans(green: .meanOfGreenPlaneMeans)

    public var greenPolicy: IRCalibrationGreenChannelPolicy {
        switch self {
        case .cfaPlaneMeans(let green): return green
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case .cfaPlaneMeans(let green):
            return """
                normalised CFA plane means, before demosaicing \
                (\(green.diagnosticDescription))
                """
        }
    }
}

/// Which normalisation produced the numbers in a measurement set.
///
/// Measured values are only meaningful relative to how the RAW samples were
/// turned into them. Recording this means a later reader can tell whether two
/// measurement sets are comparable, and whether a change to the normaliser
/// invalidates a stored calibration.
///
/// It is captured from ``RAWLinearProcessing`` rather than restated, so there
/// is no parallel black-level or white-level interpretation anywhere in the
/// calibration path. See `docs/decisions/0002-raw-normalization.md`.
public struct IRCalibrationNormalizationProvenance: Equatable, Sendable {

    public let blackLevelSubtracted: Bool
    public let whiteLevelPolicy: RAWWhiteLevelPolicy
    public let whiteLevel: UInt32

    /// Which revision of the normalisation contract these values came from.
    ///
    /// Bumped when the arithmetic changes in a way that makes older measured
    /// values incomparable to newer ones — not on every edit to the file.
    public static let currentVersion = 1

    public let version: Int

    public init(
        blackLevelSubtracted: Bool,
        whiteLevelPolicy: RAWWhiteLevelPolicy,
        whiteLevel: UInt32,
        version: Int = IRCalibrationNormalizationProvenance.currentVersion
    ) {
        self.blackLevelSubtracted = blackLevelSubtracted
        self.whiteLevelPolicy = whiteLevelPolicy
        self.whiteLevel = whiteLevel
        self.version = version
    }

    public init(_ processing: RAWLinearProcessing) {
        self.init(
            blackLevelSubtracted: processing.blackLevelSubtracted,
            whiteLevelPolicy: processing.whiteLevelPolicy,
            whiteLevel: processing.whiteLevel
        )
    }

    public var diagnosticDescription: String {
        """
        normalisation v\(version): black level \
        \(blackLevelSubtracted ? "subtracted" : "NOT subtracted"), white level \
        \(whiteLevel) by \(whiteLevelPolicy), unclamped
        """
    }
}

/// When a patch is too close to saturation to be fitted from.
///
/// ## Why clipping is fatal rather than noisy
///
/// A clipped sample is not a slightly wrong measurement, it is a **censored**
/// one: the sensor saw more than it could record and the value that came back
/// is the limit, not the response. Fitting a linear transform to censored data
/// pulls every coefficient towards the clip, and it does so silently — the
/// solver converges, the residuals look plausible, and the transform is wrong
/// in the highlights where it matters most.
///
/// So a calibration patch containing clipped samples is excluded from the fit
/// and said so, rather than being included with a warning.
public struct IRCalibrationClippingPolicy: Equatable, Sendable {

    /// A normalised sample at or above this is treated as clipped.
    ///
    /// `1.0` by default, which is exactly the sensor's saturation level after
    /// normalisation: `RAWMosaicNormalizer` maps the metadata white level onto
    /// `1.0` and does not clamp, so a value at or above it is a sample that
    /// reached the top of the well. This is a definition, not a tuned
    /// threshold; it is settable because a camera whose metadata white level
    /// is optimistic may need a margin, and that would be a documented
    /// decision about one camera rather than a silent constant here.
    public let normalizedClippingThreshold: Double

    /// The fraction of a patch's samples that may be clipped before the patch
    /// is excluded.
    ///
    /// `0` — any clipped sample excludes the patch. The alternative, a small
    /// tolerance, buys nothing: the protocol's answer to a clipped patch is to
    /// re-expose and re-photograph the chart, which is a two-minute operation,
    /// and a calibration is not the place to accept known-bad data because
    /// collecting good data was inconvenient.
    public let maximumClippedSampleFraction: Double

    public static let `default` = IRCalibrationClippingPolicy(
        normalizedClippingThreshold: 1.0,
        maximumClippedSampleFraction: 0
    )

    public init(normalizedClippingThreshold: Double, maximumClippedSampleFraction: Double) {
        self.normalizedClippingThreshold = normalizedClippingThreshold
        self.maximumClippedSampleFraction = maximumClippedSampleFraction
    }

    public func isClipped(_ value: Double) -> Bool {
        value >= normalizedClippingThreshold
    }

    public func excludes(clippedSamples: Int, of total: Int) -> Bool {
        guard total > 0 else { return true }
        return Double(clippedSamples) / Double(total) > maximumClippedSampleFraction
    }

    public var diagnosticDescription: String {
        """
        clipped at normalised >= \(normalizedClippingThreshold); a patch is excluded above \
        \(maximumClippedSampleFraction) clipped fraction
        """
    }
}

/// The white balance a calibration **session** was fitted under.
///
/// ## The distinction this type exists to make
///
/// ```text
/// ImageAdjustments.whiteBalance   one photograph's editing decision
/// IRCalibrationWhiteBalancePolicy the calibration session's own neutral reference
/// ```
///
/// These must never be the same thing. A photograph's neutral patch is a place
/// in *that* picture, chosen for how *that* picture should look; a calibration
/// is reusable across every frame shot with one camera and filter. Baking one
/// photograph's selected patch into a reusable matrix would make the transform
/// depend on a creative decision somebody made about an unrelated image — and
/// the symptom would be that the calibration works on that photograph and
/// subtly fails on every other.
///
/// So the calibration path never reads a sidecar and never sees an
/// `ImageAdjustments`. The session states its own neutral reference, drawn from
/// the target itself, and the gains are re-derived from the stored evidence
/// every time — the fit is reproducible from the measurement set alone.
public enum IRCalibrationWhiteBalancePolicy: Equatable, Sendable {

    /// Fit from the camera's raw normalised responses, with no balancing.
    ///
    /// Defensible, and the more conservative choice: a 3x3 fit can absorb
    /// per-channel scaling into its own diagonal, so balancing first is not
    /// mathematically necessary. It is offered because the resulting
    /// coefficients are then *only* a transform, with no gain folded into them,
    /// which is easier to reason about when comparing two calibrations.
    case none

    /// Derive gains from one named neutral patch of the target, then fit.
    ///
    /// The gains use exactly the rule the interactive white balance uses —
    /// `preserveStrongestMeasuredPlane`, so the strongest measured plane keeps
    /// a gain of 1 and nothing is scaled up past the data. There is one
    /// estimator rule in this project and this is it; a second one would be two
    /// definitions of neutral.
    case neutralPatch(IRCalibrationTargetPatchID)

    public var neutralPatch: IRCalibrationTargetPatchID? {
        guard case .neutralPatch(let patch) = self else { return nil }
        return patch
    }

    public var diagnosticDescription: String {
        switch self {
        case .none:
            return "no session white balance; fitted from raw normalised camera responses"
        case .neutralPatch(let patch):
            return """
                session white balance from target patch "\(patch)", strongest measured plane \
                preserved (never a photograph's neutral patch)
                """
        }
    }
}

/// Who made a measurement, with what, and anything they wanted to say about it.
public struct IRCalibrationProvenance: Equatable, Sendable {

    /// Who performed the measurement.
    ///
    /// Required. A calibration is a claim, and an anonymous claim cannot be
    /// followed up by whoever reads it later — including its author, two years
    /// on.
    public let author: String

    public let tool: String
    public let toolVersion: String
    public let notes: String?

    public init(
        author: String,
        tool: String,
        toolVersion: String,
        notes: String? = nil
    ) throws(IRCalibrationError) {
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let tool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolVersion = toolVersion.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !author.isEmpty else {
            throw .missingRequiredField(
                field: "provenance.author",
                reason: "A calibration is somebody's claim, and an unattributed one cannot be followed up."
            )
        }
        guard !tool.isEmpty, !toolVersion.isEmpty else {
            throw .missingRequiredField(
                field: "provenance.tool",
                reason: "Which software produced the measurements, and which version of it, is part of reproducing them."
            )
        }

        self.author = author
        self.tool = tool
        self.toolVersion = toolVersion
        self.notes = {
            let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }()
    }

    public var diagnosticDescription: String {
        "measured by \(author) using \(tool) \(toolVersion)" + (notes.map { " — \($0)" } ?? "")
    }
}
