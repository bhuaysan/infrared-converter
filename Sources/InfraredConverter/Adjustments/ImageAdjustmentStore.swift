import Foundation

/// Where one photograph's editing decisions are kept between sessions.
///
/// ```text
/// RAW file      an immutable input. Never written, never appended to,
///               never re-tagged. Not by us and not by a decoder.
/// sidecar       application-owned. Everything the user decided lives here,
///               and only here.
/// ```
///
/// The abstraction exists for three reasons, and deliberately no more:
///
/// 1. `DocumentState` should not know that adjustments are JSON, or that they
///    are files at all.
/// 2. A test can substitute an in-memory store and drive the workspace's open
///    and save behaviour without touching a disk.
/// 3. A future migration — a different format, a package, a database if this
///    project ever needs one — happens behind this line rather than inside
///    the workspace state.
///
/// It is not a general persistence framework and must not grow into one. Two
/// operations, one type, one photograph at a time.
///
/// ## Identity is stored, not implied
///
/// `ImageAdjustments.none` is written like any other value. A store must never
/// treat it as a reason to delete or skip the sidecar. "The user reset this
/// photograph" and "the user never adjusted this photograph" are different
/// facts, and the file is what tells them apart. See
/// `docs/decisions/0013-adjustment-sidecar.md`.
public protocol ImageAdjustmentStore: Sendable {
    /// The adjustments saved for a RAW file, or `nil` when none were ever
    /// saved.
    ///
    /// `nil` means exactly one thing: **no sidecar exists.** It is not a
    /// recovery value. Anything that exists and cannot be understood is
    /// thrown, never reported as an absence, because "no saved decisions" and
    /// "saved decisions we failed to read" would otherwise be the same answer.
    ///
    /// - Throws: `ImageAdjustmentPersistenceError` when a record exists and
    ///   cannot be read or decoded.
    func load(for rawURL: URL) throws(ImageAdjustmentPersistenceError) -> ImageAdjustments?

    /// Saves the adjustments for a RAW file, replacing whatever was there.
    ///
    /// The replacement must be atomic **at the destination path**: a reader —
    /// this application on its next launch, or a backup tool — must never
    /// observe a half-written record there, and a write that fails partway
    /// must leave the previous record in place.
    ///
    /// That is a statement about the replacement, not about durability. No
    /// store is asked to promise what survives a power loss.
    ///
    /// The RAW file itself is never opened, let alone modified.
    ///
    /// - Throws: `ImageAdjustmentPersistenceError.cannotWrite`.
    func save(
        _ adjustments: ImageAdjustments, for rawURL: URL
    ) throws(ImageAdjustmentPersistenceError)
}
