import Foundation

/// The file's saved adjustments exist and could not be used, so it was not
/// opened.
///
/// ## Why this is not a `DocumentOpenError`
///
/// They answer different questions, and the answers lead to different actions:
///
/// ```text
/// DocumentOpenError         the photograph could not be read
///                           → the RAW file or this application's support for it
///
/// DocumentAdjustmentError   the photograph is fine; the saved edits are not
///                           → one small JSON file beside it, which the user owns
/// ```
///
/// Folding the second into the first would tell a user that their RAW file
/// failed to decode when nothing of the kind happened — and would hide the one
/// file they can actually inspect, move aside or restore from a backup.
///
/// ## Why it stops the open rather than proceeding
///
/// The alternative is to render the photograph with `ImageAdjustments.none`.
/// That looks like success and is not: the application knows decisions were
/// saved for this image and cannot read them, and would be showing a
/// photograph the user did not ask for while offering no sign that anything
/// was lost. Worse, the next save would overwrite the unreadable record with
/// the substituted one and destroy it.
///
/// So the open stops, nothing is repaired, nothing is deleted, and the record
/// stays exactly as it is on disk. See
/// `docs/decisions/0013-adjustment-sidecar.md`.
public struct DocumentAdjustmentError: Error, LocalizedError {
    /// The RAW file that was being opened. Readable, as far as anyone knows:
    /// nothing decoded it before this refusal.
    public let url: URL

    /// What the persistence layer refused, kept as a value.
    public let failure: ImageAdjustmentPersistenceError

    public init(url: URL, failure: ImageAdjustmentPersistenceError) {
        self.url = url
        self.failure = failure
    }

    /// The sidecar file involved. What the user has to look at.
    public var sidecar: URL { failure.sidecar }

    /// The adjustment model's own refusal, when the record was what refused —
    /// an unsupported schema version, an unknown orientation token, a missing
    /// field.
    public var adjustment: ImageAdjustmentError? { failure.adjustment }

    public var errorDescription: String? {
        "The saved adjustments for \(url.lastPathComponent) could not be used."
    }

    public var failureReason: String? {
        let record = (failure.adjustment as? LocalizedError)?.failureReason
            ?? failure.failureReason
        return """
            \(record ?? failure.localizedDescription) \
            The photograph itself was not opened, and nothing was changed or deleted: \
            \(sidecar.lastPathComponent) is exactly as it was.
            """
    }
}
