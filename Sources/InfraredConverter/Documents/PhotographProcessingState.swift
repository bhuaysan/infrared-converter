import Foundation

/// Everything this application owns about one photograph: which capture
/// configuration produced it, and what the user decided about it.
///
/// ```text
/// PhotographProcessingState
///  ├── captureProfile   a reference to a reusable capture configuration
///  └── adjustments      this photograph's own editing decisions
/// ```
///
/// ## Why the two halves are not one
///
/// They have different lifetimes and different owners, and merging them would
/// lose both facts at once.
///
/// ```text
/// capture profile   describes how the photograph was CAPTURED — camera, sensor
///                   conversion, filter — and is shared by every frame shot that
///                   way. Renaming it must not change any photograph.
///
/// adjustments       describes what the user DECIDED about this one frame — the
///                   neutral patch they clicked, the rotation, the mix, the
///                   exposure. Meaningless for any other photograph.
/// ```
///
/// A neutral patch at `(0.42, 0.31)` is the clearest case: it is a place in
/// *this* picture, and a reusable profile that carried it would be asserting
/// that the same rectangle is neutral in every photograph ever taken with that
/// camera. So `ImageAdjustments` does not gain a `captureProfile` field, and a
/// profile does not gain a patch. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`.
///
/// ## A reference, not a definition
///
/// The stored value is an `IRCaptureProfileID`. The definition lives in
/// `IRCaptureProfileRegistry`, is resolved once when a photograph is opened,
/// and is carried as a resolved `IRCaptureProfile` by the runtime document.
/// Persisting the definition instead would duplicate it into every sidecar and
/// leave stale copies behind the first time it was edited.
///
/// ## Not `DocumentState`
///
/// `DocumentState` is the runtime workspace controller: tasks, render slots,
/// status, the preview on screen. This is a value — `Equatable`, `Sendable`,
/// immutable by convention, free of anything that runs — and it is what a
/// sidecar holds, what an export is rendered from, and what a render request
/// names.
public struct PhotographProcessingState: Equatable, Sendable {

    /// Which capture profile this photograph is processed under, by stable
    /// identity.
    public var captureProfile: IRCaptureProfileID

    /// What the user decided about this photograph.
    public var adjustments: ImageAdjustments

    public init(
        captureProfile: IRCaptureProfileID = .builtinUncalibrated,
        adjustments: ImageAdjustments = .none
    ) {
        self.captureProfile = captureProfile
        self.adjustments = adjustments
    }

    /// A freshly opened photograph with no sidecar: the built-in uncalibrated
    /// profile, and no decisions.
    ///
    /// The profile half is not "no profile". There is no such state: every
    /// photograph is rendered under some camera-to-working transform, and
    /// naming the one that has always been used is more honest than pretending
    /// the choice has not been made.
    public static let none = PhotographProcessingState()

    /// Whether both halves are the values a freshly opened photograph gets.
    ///
    /// Deliberately **not** derived from `ImageAdjustments.isDefault` alone,
    /// and deliberately not folded into it: an adjustment record knows nothing
    /// about profiles and must not learn. See `ImageAdjustments.isDefault` for
    /// why "default" is a question about decisions rather than about pixels —
    /// the same distinction holds here, and a profile selection with the same
    /// processing basis changes no pixels at all while still being a decision.
    public var isDefault: Bool {
        captureProfile == .builtinUncalibrated && adjustments.isDefault
    }

    /// A one-line summary for diagnostics and logs.
    public var diagnosticDescription: String {
        """
        profile \(captureProfile), orientation \(adjustments.orientation.persistedToken), \
        mix \(adjustments.channelMix.kind.rawValue), \
        exposure \(adjustments.exposure.signedDescription), \
        white balance \(adjustments.whiteBalance.kind.rawValue)
        """
    }
}
