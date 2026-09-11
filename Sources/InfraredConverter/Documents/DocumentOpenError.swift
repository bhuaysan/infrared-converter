import Foundation

/// Why one part of opening a file refused, and which part it was.
///
/// The refusal itself is **kept**, not flattened to a sentence. The stages
/// throw four different error types between them — `RAWDecodingError`,
/// `RAWProcessingError`, `IRProcessingError`, `OrientationError` — and a
/// caller that has to ask "was this the orientation stage?" can only do so if
/// the value survived. Strings are for readers; the error is for code.
public struct RAWPathFailure: Error {

    /// Which part of the open refused.
    ///
    /// The two owned stages are kept apart because they mean different things.
    /// A preparation failure means there is no scene-linear state at all. A
    /// render failure means there is one and nothing can be shown from it —
    /// which is what `DocumentState.Loaded.isAdjustable` turns on.
    public enum Stage: Equatable {
        /// The application-owned pipeline before it had a scene-linear state:
        /// mosaic decode, normalise, estimate, balance, demosaic, convert,
        /// mix.
        case ownedPreparation
        /// The application-owned pipeline's orientation and display stages,
        /// with the scene-linear state already in hand.
        case ownedRender
        /// The LibRaw processed-RGB diagnostic decode.
        case legacyReference
    }

    public let stage: Stage

    /// The refusal, exactly as the stage threw it.
    public let underlying: any Error

    public init(stage: Stage, _ error: any Error) {
        self.stage = stage
        self.underlying = error
    }

    /// The decoder's own error, when the decoder was the stage that refused.
    public var decoding: RAWDecodingError? { underlying as? RAWDecodingError }

    /// The geometry stage's own error, when orientation was what refused.
    ///
    /// This is the projection `isAdjustable` is decided from, and the reason
    /// the underlying value is kept rather than described.
    public var orientation: OrientationError? { underlying as? OrientationError }

    /// What to show a reader. Free of LibRaw's internal integer codes: every
    /// error type here is `LocalizedError`, and the decoder's own
    /// `errorDescription` never carries the code.
    public var message: String { underlying.localizedDescription }

    /// The stage's own elaboration, where it has one. Also free of internal
    /// codes — `RAWDecodingError.failureReason` reports a diagnostic through
    /// `userFacingSummary`, which omits them.
    public var failureReason: String? {
        (underlying as? LocalizedError)?.failureReason
    }
}

/// Why the workspace could not open a file at all.
///
/// Reached only when **neither** path produced an image. Either one producing
/// one leaves the file open:
///
/// ```text
/// owned prepared + rendered / legacy ok      → workspace image + reference
/// owned prepared + rendered / legacy fails   → workspace image, reference missing
/// owned fails at prepare    / legacy ok      → the owned failure; never a fallback
/// owned fails at render     / legacy ok      → the owned failure; never a fallback
/// owned fails at prepare    / legacy fails   → this error
/// owned fails at render     / legacy fails   → this error
/// ```
///
/// The application-owned pipeline is the workspace image. The LibRaw
/// processed-RGB decode is a diagnostic reference beside it. Neither is a gate
/// on the other, and neither ever stands in for the other.
///
/// The last row is the one this type gained: a prepared scene-linear state is
/// not a photograph on screen, so "prepare succeeded" is not an open.
public struct DocumentOpenError: Error, LocalizedError {
    public let url: URL

    /// The application-owned pipeline's refusal, and which of its two halves
    /// produced it. The one that matters: it is the image the workspace would
    /// have shown.
    public let owned: RAWPathFailure

    /// The legacy diagnostic decode's refusal, kept because a difference
    /// between the two is itself the diagnosis. Two identical messages say the
    /// file is unreadable; two different ones say which stage disagreed.
    public let legacy: RAWPathFailure

    public init(url: URL, owned: RAWPathFailure, legacy: RAWPathFailure) {
        self.url = url
        self.owned = owned
        self.legacy = legacy
    }

    public var errorDescription: String? {
        "\(url.lastPathComponent) could not be opened."
    }

    public var failureReason: String? {
        """
        \(Self.label(for: owned.stage)) refused it: \(owned.message) \
        \(Self.label(for: legacy.stage)) refused it too: \(legacy.message)
        """
    }

    private static func label(for stage: RAWPathFailure.Stage) -> String {
        switch stage {
        case .ownedPreparation: return "The image pipeline"
        case .ownedRender: return "The image pipeline's render"
        case .legacyReference: return "The LibRaw diagnostic decode"
        }
    }
}
