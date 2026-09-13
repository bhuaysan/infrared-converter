import Foundation

/// Why a capture profile could not be used.
///
/// Separate from `ImageAdjustmentError` and from
/// `PhotographProcessingStateError` for the reason every error type in this
/// project is separate from its neighbours: a different boundary. Those two are
/// a **record** refusing to be understood. This is the **profile system**
/// refusing: an identifier that is not well-formed, a reference to a profile
/// that does not exist, a registry that was handed the same identity twice, or
/// a profile that does not describe the camera that took the photograph.
///
/// ## Nothing here falls back
///
/// No case is recovered by substituting another profile. Silently rendering a
/// photograph under a profile the user did not choose would change its
/// appearance and report success, which is the one failure mode this whole
/// milestone exists to prevent. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`.
public enum IRCaptureProfileError: Error, Equatable {

    /// A string is not a well-formed capture profile identifier.
    case invalidProfileID(token: String, reason: String)

    /// A photograph references a profile no registry knows about.
    ///
    /// The ordinary way to reach this is a sidecar written on another machine,
    /// or one whose user profile has since been deleted. It is reported, never
    /// repaired: the reference is still on disk exactly as the user left it.
    case unknownProfile(id: IRCaptureProfileID)

    /// A registry was built from two profiles claiming the same identity.
    ///
    /// Refused at construction rather than resolved by "last one wins": which
    /// of the two a photograph meant would then depend on an ordering nobody
    /// chose.
    case duplicateProfileID(id: IRCaptureProfileID)

    /// The profile names a camera, and the photograph was taken with a
    /// different one.
    case cameraMismatch(
        id: IRCaptureProfileID,
        expectedMake: String,
        expectedModel: String,
        foundMake: String?,
        foundModel: String?
    )

    /// The profile names a camera, and the photograph does not say which
    /// camera took it.
    ///
    /// Distinct from a mismatch on purpose. A mismatch is a known
    /// disagreement; this is an absence of evidence, and treating the two as
    /// one would mean either refusing a file that might well match or
    /// accepting one that certainly might not.
    case cameraUnknown(id: IRCaptureProfileID, expectedMake: String, expectedModel: String)

    /// A prepared scene-linear source is being rendered under a profile whose
    /// processing basis is not the one that produced it.
    ///
    /// A safety net rather than a user-facing condition. The camera-to-working
    /// transform runs upstream of the preview reduction, so a reduced buffer is
    /// valid only for the basis it was prepared with; rendering it under a
    /// different one would label the pixels with a processing decision they
    /// were not produced by. Two profiles that share a basis are
    /// interchangeable and never reach this.
    case processingBasisMismatch(prepared: IRCaptureProfileID, requested: IRCaptureProfileID)
}

extension IRCaptureProfileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidProfileID:
            return "That is not a valid capture profile identifier."
        case .unknownProfile:
            return "The capture profile this photograph uses is not available."
        case .duplicateProfileID:
            return "Two capture profiles claim the same identifier."
        case .cameraMismatch:
            return "This capture profile was made for a different camera."
        case .cameraUnknown:
            return "This capture profile names a camera, and the file does not."
        case .processingBasisMismatch:
            return "The preview was prepared under a different capture profile."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidProfileID(let token, let reason):
            return "\"\(token)\": \(reason)"

        case .unknownProfile(let id):
            return """
                No profile with the identifier "\(id)" is installed. Nothing was changed, \
                and no other profile was substituted: rendering under a profile you did not \
                choose would silently change the photograph.
                """

        case .duplicateProfileID(let id):
            return """
                More than one profile claims the identifier "\(id)". Which photograph means \
                which would then depend on load order.
                """

        case .cameraMismatch(let id, let expectedMake, let expectedModel, let make, let model):
            let found = [make, model].compactMap { $0 }.filter { !$0.isEmpty }
            let foundText = found.isEmpty ? "an unnamed camera" : found.joined(separator: " ")
            return """
                "\(id)" describes \(expectedMake) \(expectedModel), and this photograph was \
                taken with \(foundText). Two bodies of different models do not share infrared \
                behaviour, so the profile is not applied.
                """

        case .cameraUnknown(let id, let expectedMake, let expectedModel):
            return """
                "\(id)" describes \(expectedMake) \(expectedModel), and this file records no \
                camera make or model, so there is nothing to check it against.
                """

        case .processingBasisMismatch(let prepared, let requested):
            return """
                These pixels were produced under "\(prepared)", whose camera-to-working \
                processing differs from "\(requested)". The camera transform runs before the \
                preview is reduced, so the reduced image must be prepared again rather than \
                relabelled.
                """
        }
    }
}
