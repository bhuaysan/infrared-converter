import Foundation

/// Why a photograph could not be opened under the capture profile its saved
/// state names.
///
/// The document-level wrapper around `IRCaptureProfileError`, exactly as
/// `DocumentAdjustmentError` is the wrapper around a persistence failure: it
/// adds the one thing the profile system does not know, which photograph this
/// is about, and it keeps the typed refusal intact underneath.
///
/// ## What it means for the user
///
/// The RAW file is presumed fine — nothing about it failed — and so is the
/// sidecar, which was read successfully. What is missing, or wrong, is the
/// capture profile it points at. Two ways to reach it:
///
/// ```text
/// unknownProfile    the sidecar names a profile this machine does not have —
///                   written on another machine, or since deleted
/// cameraMismatch    the profile describes a different camera from the one
///                   that took this photograph
/// ```
///
/// In both cases nothing was substituted, repaired, deleted or rewritten. The
/// alternative — opening the photograph under some other profile that happens
/// to be installed — would change the rendering and report success, which is
/// the failure mode this whole milestone exists to prevent. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 5.
public struct DocumentCaptureProfileError: Error, LocalizedError {
    /// The RAW file that was not opened.
    public let url: URL

    /// The profile system's own refusal, intact.
    public let failure: IRCaptureProfileError

    public init(url: URL, failure: IRCaptureProfileError) {
        self.url = url
        self.failure = failure
    }

    /// The identity that could not be used, when the refusal names one.
    public var profileID: IRCaptureProfileID? {
        switch failure {
        case .invalidProfileID:
            return nil
        case .unknownProfile(let id),
             .duplicateProfileID(let id),
             .cameraMismatch(let id, _, _, _, _),
             .cameraUnknown(let id, _, _):
            return id
        case .processingBasisMismatch(_, let requested):
            return requested
        }
    }

    public var errorDescription: String? {
        "\(url.lastPathComponent) could not be opened with its saved capture profile."
    }

    public var failureReason: String? {
        let detail = failure.failureReason ?? failure.localizedDescription
        return """
            \(detail) The photograph itself was not opened, and nothing was changed or \
            deleted: its saved settings are exactly as they were.
            """
    }
}
