import Foundation

/// Where one photograph's application-owned processing state is kept between
/// sessions.
///
/// ```text
/// RAW file      an immutable input. Never written, never appended to,
///               never re-tagged. Not by us and not by a decoder.
/// sidecar       application-owned. The capture profile the photograph is
///               processed under and everything the user decided about it
///               live here, and only here.
/// ```
///
/// ## It used to store adjustments alone
///
/// It was `ImageAdjustmentStore`, and its unit was `ImageAdjustments`. That
/// boundary became too narrow the moment a photograph also had a capture
/// profile: bolting a profile identifier onto some other piece of runtime state
/// would have left one photograph's settings split across two authorities with
/// no rule about which wins. So the unit widened to the whole record, and the
/// name with it. There is still exactly **one** sidecar per photograph, with
/// exactly the same filename. See
/// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 7.
///
/// The abstraction exists for three reasons, and deliberately no more:
///
/// 1. `DocumentState` should not know that this is JSON, or that it is a file
///    at all.
/// 2. A test can substitute an in-memory store and drive the workspace's open
///    and save behaviour without touching a disk.
/// 3. A future migration — a different format, a package, a database if this
///    project ever needs one — happens behind this line rather than inside the
///    workspace state.
///
/// It is not a general persistence framework and must not grow into one. Two
/// operations, one type, one photograph at a time. Reusable **profile
/// definitions** are a different artefact with a different lifetime and, when
/// they are eventually persisted, a different schema and a different location;
/// they do not belong here.
///
/// ## The default state is stored, not implied
///
/// `PhotographProcessingState.none` is written like any other value. A store
/// must never treat it as a reason to delete or skip the sidecar. "The user
/// reset this photograph" and "the user never adjusted this photograph" are
/// different facts, and the file is what tells them apart. See
/// `docs/decisions/0013-adjustment-sidecar.md`.
public protocol PhotographProcessingStore: Sendable {
    /// The state saved for a RAW file, or `nil` when none was ever saved.
    ///
    /// `nil` means exactly one thing: **no sidecar exists.** It is not a
    /// recovery value. Anything that exists and cannot be understood is thrown,
    /// never reported as an absence, because "no saved decisions" and "saved
    /// decisions we failed to read" would otherwise be the same answer.
    ///
    /// - Throws: `PhotographProcessingPersistenceError` when a record exists
    ///   and cannot be read or decoded.
    func load(
        for rawURL: URL
    ) throws(PhotographProcessingPersistenceError) -> PhotographProcessingState?

    /// Saves the state for a RAW file, replacing whatever was there.
    ///
    /// The profile selection and the adjustments are written **together**, as
    /// one record, because they are one record: a photograph whose profile
    /// reached disk without the adjustments it was rendered with would open
    /// showing something nobody ever saw.
    ///
    /// The replacement must be atomic **at the destination path**: a reader —
    /// this application on its next launch, or a backup tool — must never
    /// observe a half-written record there, and a write that fails partway must
    /// leave the previous record in place.
    ///
    /// That is a statement about the replacement, not about durability. No
    /// store is asked to promise what survives a power loss.
    ///
    /// The RAW file itself is never opened, let alone modified.
    ///
    /// - Throws: `PhotographProcessingPersistenceError.cannotWrite`.
    func save(
        _ state: PhotographProcessingState, for rawURL: URL
    ) throws(PhotographProcessingPersistenceError)
}
