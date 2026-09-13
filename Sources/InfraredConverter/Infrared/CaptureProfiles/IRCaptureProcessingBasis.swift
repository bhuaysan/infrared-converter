import Foundation

/// The one part of a capture profile that reaches pixels: which camera-to-
/// working transform the RAW front half must run.
///
/// ```text
/// IRCaptureProfile
///  ├── id, name                  identity
///  ├── cameraMatch               context, and a validity check
///  ├── sensorConversion, filter  context — metadata about the capture
///  └── processingBasis           ← this: the only field that changes an image
/// ```
///
/// ## Why the split is load-bearing
///
/// It is what lets the workspace answer "does selecting this profile require
/// re-preparing the photograph?" from data rather than from a guess. Two
/// profiles that describe different cameras and different filters but share a
/// basis produce **identical pixels**, by construction, so switching between
/// them costs a provenance refresh and nothing more. A profile with a different
/// basis changes the camera-to-working transform, which is upstream of
/// everything, and costs a full re-preparation. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 8.
///
/// That claim is only true while this type is the sole route from a profile to
/// the pipeline. Nothing else on `IRCaptureProfile` is passed to a processing
/// stage, and nothing may become so without moving here.
///
/// ## Neither case is a calibration, and there is deliberately no third
///
/// A **validated infrared calibration** would be a third case carrying a
/// measured matrix and the evidence behind it. This project has no measured
/// data for any camera, any conversion or any filter, so inventing
/// coefficients and labelling them "720 nm" would be precisely the
/// plausible-looking claim `CLAUDE.md` forbids. The type is shaped so that case
/// can be added — the dispatch below is already exhaustive, and
/// `isValidatedInfraredCalibration` already asks the transform's own provenance
/// rather than returning a constant — and it is deliberately not added.
///
/// The second case that does exist, `explicitMatrix`, is not a step toward it.
/// It is the existing `RAWCameraToWorkingColorTransform.explicit(matrix:)`
/// escape hatch — present since [ADR 0006](../../../docs/decisions/0006-working-color-space.md),
/// and carrying no claim beyond finite coefficients — surfaced where a profile
/// can name it. It earns its place for one reason: without a second basis, the
/// rule that a change of basis re-prepares the photograph while a change of
/// metadata does not would be a branch nothing could ever exercise, and an
/// untested invalidation rule is worse than an unused enum case.
///
/// Neither case is persisted. No profile definition is written to disk in this
/// milestone, so there is no wire format here to version, and none is invented
/// ahead of a case that would need one.
public enum IRCaptureProcessingBasis: Equatable, Sendable {

    /// Camera-native sensor RGB is placed into the working space unchanged:
    /// `RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor`.
    ///
    /// Exactly what every build of this application has done since the working
    /// space was defined, which is why the built-in profile can represent the
    /// historical behaviour without changing a single pixel.
    ///
    /// A deliberate false-colour axis assignment, and not a calibration: the
    /// coordinates become well defined, and no claim is made about how the
    /// sensor's responses relate to any colour a person would perceive. See
    /// `docs/decisions/0006-working-color-space.md`.
    case uncalibratedSensorRGB

    /// A matrix the profile's author supplied deliberately.
    ///
    /// Exactly what `RAWCameraToWorkingColorTransform.explicit(matrix:)` means
    /// and no more: the project makes **no claim about it beyond that its
    /// coefficients are finite**. It is not a calibration, it is not derived
    /// from measurement, and `isValidatedInfraredCalibration` answers `false`
    /// for it — as it does for every source the colour layer defines.
    ///
    /// Nothing in the application produces one. There is no UI for it, no
    /// persisted profile format that could carry it, and no built-in profile
    /// that uses it. It exists so that a profile whose basis genuinely changes
    /// pixels can be constructed — by an experiment, or by a test proving that
    /// selecting such a profile re-prepares the photograph rather than
    /// relabelling it.
    case explicitMatrix(RAWColorMatrix3x3)

    /// The transform the RAW front half runs for this basis.
    ///
    /// The only thing a processing stage is ever handed from a profile.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        switch self {
        case .uncalibratedSensorRGB:
            return .sensorRGBIdentityFalseColor
        case .explicitMatrix(let matrix):
            return .explicit(matrix: matrix)
        }
    }

    /// Whether this basis is a validated infrared colour calibration.
    ///
    /// Asked of the transform's own provenance rather than answered here, so
    /// the profile system cannot claim a validation the colour layer does not
    /// make. Today that answer is `false` for every source
    /// `RAWCameraToWorkingColorTransformSource` defines, and this property
    /// exists so that the day one of them is `true`, a profile reports it
    /// because it *is* true rather than because someone edited a constant.
    public var isValidatedInfraredCalibration: Bool {
        cameraToWorkingTransform.source.isValidatedInfraredCalibration
    }

    /// A label for the inspector.
    public var shortDescription: String {
        switch self {
        case .uncalibratedSensorRGB: return "Uncalibrated sensor RGB"
        case .explicitMatrix: return "Explicit matrix (uncalibrated)"
        }
    }

    /// A longer label for diagnostics and provenance reports, worded so it
    /// cannot be read as a colour claim.
    public var diagnosticDescription: String {
        switch self {
        case .uncalibratedSensorRGB:
            return """
                uncalibrated sensor RGB — \
                \(cameraToWorkingTransform.source.diagnosticDescription)
                """
        case .explicitMatrix:
            return """
                explicit caller-supplied matrix, uncalibrated — \
                \(cameraToWorkingTransform.source.diagnosticDescription)
                """
        }
    }
}
