import Foundation

/// A reusable description of how a photograph was captured, and what
/// processing that configuration calls for.
///
/// ```text
/// IRCaptureProfile              reusable   "an E-PL3, full-spectrum, 720 nm"
/// ImageAdjustments              per photo  "this frame: this patch, +0.7 EV, …"
/// ```
///
/// The two both influence a rendering and are not the same kind of thing, which
/// is the whole point of this milestone. A profile outlives the photograph and
/// is shared by many of them; adjustments belong to one frame and to no other.
/// A photograph's sidecar therefore stores a profile **reference**, never a
/// copy of the definition. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`.
///
/// ## What it is allowed to claim
///
/// Almost nothing. `cameraMatch`, `sensorConversion` and `filter` are
/// **metadata**: descriptive facts about the capture that let a person tell two
/// profiles apart and let the application check that a profile was not applied
/// to the wrong camera. None of them reaches a processing stage. The single
/// field that does is `processingBasis`, and today it has one case.
///
/// So a profile named "720 nm" is not a calibrated 720 nm rendering, and this
/// type provides no way for it to pretend otherwise: `isValidatedInfraredCalibration`
/// is derived from the basis's transform provenance, not from the presence of a
/// wavelength or a camera name.
///
/// ## Immutable, and small
///
/// Every field is `let`. A profile a document resolved at open is the profile
/// that document renders with, and an export carries the resolved value rather
/// than an identifier it would have to look up again while running. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 10.
public struct IRCaptureProfile: Equatable, Sendable, Identifiable {

    /// The stable identity a sidecar refers to. Never derived from `name`.
    public let id: IRCaptureProfileID

    /// What a person calls this profile. Free to change without breaking a
    /// single photograph, which is the reason `id` exists.
    public let name: String

    /// Which camera the profile was made for, and the validity check that
    /// follows from it.
    public let cameraMatch: IRCameraMatch

    /// What was done to the body: unmodified, full-spectrum, internally
    /// converted, or unrecorded.
    public let sensorConversion: IRSensorConversion

    /// The filter used on the lens, as far as it is known. Separate from a
    /// filter built into the body, which belongs to `sensorConversion`.
    public let filter: IRFilterDescriptor

    /// The only field that changes pixels.
    public let processingBasis: IRCaptureProcessingBasis

    public init(
        id: IRCaptureProfileID,
        name: String,
        cameraMatch: IRCameraMatch = .any,
        sensorConversion: IRSensorConversion = .unknown,
        filter: IRFilterDescriptor = .unknown,
        processingBasis: IRCaptureProcessingBasis
    ) {
        self.id = id
        self.name = name
        self.cameraMatch = cameraMatch
        self.sensorConversion = sensorConversion
        self.filter = filter
        self.processingBasis = processingBasis
    }

    /// The transform the RAW front half runs for this profile.
    ///
    /// The one value that crosses from the profile system into processing.
    public var cameraToWorkingTransform: RAWCameraToWorkingColorTransform {
        processingBasis.cameraToWorkingTransform
    }

    /// Whether this profile's processing is a validated infrared colour
    /// calibration.
    ///
    /// Derived, never asserted. It asks the processing basis, which asks the
    /// transform's own provenance, which answers `false` for every source that
    /// exists. A named filter, a named camera and a named vendor change none of
    /// that — which is exactly the claim this property is here to refuse.
    public var isValidatedInfraredCalibration: Bool {
        processingBasis.isValidatedInfraredCalibration
    }

    /// Whether this profile may be used for a photograph with this metadata,
    /// and if not, why.
    public func applicability(to metadata: RAWMetadata) -> IRCaptureProfileApplicability {
        cameraMatch.applicability(to: metadata, profile: id)
    }

    /// A one-line summary for diagnostics.
    public var diagnosticDescription: String {
        """
        \(name) [\(id)] — camera \(cameraMatch.shortDescription), \
        \(sensorConversion.diagnosticDescription), \(filter.diagnosticDescription), \
        \(processingBasis.diagnosticDescription)
        """
    }
}

// MARK: - The profile this build ships

extension IRCaptureProfile {
    /// `builtin.uncalibrated` — the profile that represents exactly what this
    /// application did before capture profiles existed.
    ///
    /// ```text
    /// camera match        any
    /// sensor conversion   unknown
    /// filter              unknown
    /// processing basis    uncalibrated sensor RGB
    ///                     (RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor)
    /// calibrated          no
    /// ```
    ///
    /// ## It is a compatibility guarantee, not a recommendation
    ///
    /// Every photograph adjusted by an older build of this application carries
    /// a sidecar at schema version 1 to 4, and every one of those was rendered
    /// through the identity false-colour axis assignment. Migrating such a
    /// record to this profile is therefore **pixel-neutral** — the migration
    /// does not choose a plausible profile, it names the one that reproduces
    /// what the file was already rendered with. A test renders a version 4
    /// state and a migrated version 5 state and compares the buffers.
    ///
    /// It is also what a photograph with no sidecar at all gets, for the same
    /// reason: it is the only processing this application has ever done.
    ///
    /// The name is deliberately unflattering. "Uncalibrated / Generic" is what
    /// it is, and a user reading the inspector should not come away believing
    /// the application has characterised their camera.
    public static let builtinUncalibrated = IRCaptureProfile(
        id: .builtinUncalibrated,
        name: "Uncalibrated / Generic",
        cameraMatch: .any,
        sensorConversion: .unknown,
        filter: .unknown,
        processingBasis: .uncalibratedSensorRGB
    )
}
