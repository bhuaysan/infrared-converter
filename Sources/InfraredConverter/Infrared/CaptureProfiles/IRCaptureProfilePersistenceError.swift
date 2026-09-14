import Foundation

/// Why a stored capture profile could not be read, written, deleted, or
/// admitted to the library.
///
/// The file-and-library boundary, kept apart from `IRCaptureProfileRecordError`
/// exactly as `PhotographProcessingPersistenceError` is kept apart from
/// `PhotographProcessingStateError`. That one is a **record** refusing to be
/// understood; this is the **file** refusing, or the library refusing to admit
/// what a file contains.
///
/// They meet in `cannotDecode`, which carries the refusal wrapped rather than
/// flattened, so a caller that wants to know whether a profile was written by a
/// newer build can still ask through `record`.
///
/// ## Nothing here repairs anything
///
/// No case rewrites a file, deletes one, or substitutes a profile for another.
/// A profile file that cannot be read is reported and skipped; the rest of the
/// library still loads, and the built-in profile is always there. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
public enum IRCaptureProfilePersistenceError: Error {

    /// A profile file, or the profile directory, exists and could not be read.
    case cannotRead(url: URL, underlying: any Error)

    /// A profile file's bytes are not a record this build can read.
    ///
    /// Carries the refusal itself: an `IRCaptureProfileRecordError` for an
    /// unsupported schema version, a missing field or a basis with no wire
    /// format; an `IRCaptureProfileError` for a malformed identifier; an
    /// `IRCaptureProfileDescriptorError` for a nominal cutoff that could not
    /// describe a filter; a `DecodingError` for bytes that are not that JSON.
    case cannotDecode(url: URL, underlying: any Error)

    /// A profile could not be written. Nothing was left at the destination: the
    /// replacement is atomic, so either the new definition is there or the
    /// previous one still is.
    case cannotWrite(url: URL, underlying: any Error)

    /// A profile file could not be removed, so the profile is still installed.
    ///
    /// Reported rather than swallowed, and the in-memory library is **not**
    /// changed: a registry that dropped a profile whose file is still on disk
    /// would disagree with the disk the moment anything reloaded.
    case cannotDelete(url: URL, underlying: any Error)

    /// The profile directory could not be created, so nothing could be saved
    /// into it.
    case cannotCreateDirectory(url: URL, underlying: any Error)

    /// A user profile claims an identity in a namespace reserved for the
    /// profiles this build ships.
    ///
    /// Refused in both directions: such a profile cannot be saved, and one
    /// already on disk is not admitted to the library. It would otherwise
    /// shadow a built-in definition, and a photograph resolving to it would be
    /// rendered under a definition the application did not author while
    /// reporting the identity that it did.
    case reservedIdentifier(id: IRCaptureProfileID, namespace: String)

    /// Two profile files claim the same identity.
    ///
    /// Neither is admitted. Choosing one would make which definition a
    /// photograph resolves to depend on directory-enumeration order — an answer
    /// nobody chose, that can differ between machines, and that changes what
    /// the photograph looks like.
    case duplicateIdentifier(id: IRCaptureProfileID, paths: [URL])

    /// A profile file's name says one identity and its payload says another.
    ///
    /// Refused rather than reconciled. A file's name is its address: if the two
    /// may disagree, one profile's definition can be stored at another
    /// profile's address, and the next save of the second would overwrite the
    /// first.
    case filenameIdentityMismatch(
        url: URL, expected: IRCaptureProfileID, found: IRCaptureProfileID
    )

    /// A file wearing the `.irprofile.json` suffix whose name does not spell a
    /// valid ``IRCaptureProfileID``.
    ///
    /// Not the same fault as a foreign file, and deliberately not the same
    /// outcome. `notes.txt` is somebody's note; `BAD PROFILE!.irprofile.json`
    /// is a capture profile that cannot be addressed, and silence about it
    /// would leave a person staring at a library missing a profile whose file
    /// they can see.
    case invalidProfileFilename(url: URL, token: String, reason: String)

    /// A profile carries a processing basis that has no wire format, so it was
    /// not written.
    ///
    /// The milestone's central safety boundary, surfaced where a user would
    /// meet it. See `PersistedIRCaptureProcessingBasis`.
    case unsupportedProcessingBasis(id: IRCaptureProfileID, underlying: any Error)

    /// There is no profile library on this machine: the application-owned
    /// storage location could not be determined.
    ///
    /// The built-in profile is unaffected — it is a value, not a file — so the
    /// application still opens and renders photographs. Only user profiles are
    /// unavailable.
    case libraryUnavailable(underlying: any Error)

    /// The file this error is about, where it is about one.
    public var url: URL? {
        switch self {
        case .cannotRead(let url, _),
             .cannotDecode(let url, _),
             .cannotWrite(let url, _),
             .cannotDelete(let url, _),
             .cannotCreateDirectory(let url, _):
            return url
        case .filenameIdentityMismatch(let url, _, _):
            return url
        case .invalidProfileFilename(let url, _, _):
            return url
        case .duplicateIdentifier(_, let paths):
            return paths.first
        case .reservedIdentifier, .unsupportedProcessingBasis, .libraryUnavailable:
            return nil
        }
    }

    /// The identity this error is about, where it names one.
    public var profileID: IRCaptureProfileID? {
        switch self {
        case .reservedIdentifier(let id, _),
             .duplicateIdentifier(let id, _),
             .unsupportedProcessingBasis(let id, _):
            return id
        case .filenameIdentityMismatch(_, let expected, _):
            return expected
        case .cannotRead, .cannotDecode, .cannotWrite, .cannotDelete,
             .cannotCreateDirectory, .libraryUnavailable, .invalidProfileFilename:
            // A malformed filename names no identity. That is the fault being
            // reported, and deriving one from the token would be the very
            // repair this store does not perform.
            return nil
        }
    }

    /// The refusal exactly as it was thrown, where one was wrapped.
    public var underlying: (any Error)? {
        switch self {
        case .cannotRead(_, let underlying),
             .cannotDecode(_, let underlying),
             .cannotWrite(_, let underlying),
             .cannotDelete(_, let underlying),
             .cannotCreateDirectory(_, let underlying),
             .libraryUnavailable(let underlying):
            return underlying
        case .unsupportedProcessingBasis(_, let underlying):
            return underlying
        case .reservedIdentifier, .duplicateIdentifier, .filenameIdentityMismatch,
             .invalidProfileFilename:
            return nil
        }
    }

    /// The record's own refusal about its shape, when that is what refused.
    ///
    /// The projection that keeps the typed value alive across the file
    /// boundary: an unsupported schema version stays
    /// `.unsupportedSchemaVersion` rather than becoming a sentence about a file
    /// that could not be read.
    public var record: IRCaptureProfileRecordError? {
        underlying as? IRCaptureProfileRecordError
    }
}

extension IRCaptureProfilePersistenceError: LocalizedError {

    /// A short sentence a person can act on, with no decoder text in it.
    ///
    /// The technical detail is in `failureReason`, which the interface shows
    /// underneath rather than instead. A raw `DecodingError` description is a
    /// diagnostic, not a message.
    public var errorDescription: String? {
        switch self {
        case .cannotRead:
            return "A capture profile could not be read."
        case .cannotDecode:
            return "A capture profile file is not valid."
        case .cannotWrite:
            return "The capture profile could not be saved."
        case .cannotDelete:
            return "The capture profile could not be deleted."
        case .cannotCreateDirectory:
            return "The capture profile folder could not be created."
        case .reservedIdentifier:
            return "That capture profile identifier is reserved."
        case .duplicateIdentifier:
            return "Two capture profile files claim the same identifier."
        case .filenameIdentityMismatch:
            return "A capture profile file is stored under the wrong name."
        case .invalidProfileFilename:
            return "A capture profile file has a name that is not a profile identifier."
        case .unsupportedProcessingBasis:
            return "That capture profile's processing cannot be saved."
        case .libraryUnavailable:
            return "Your capture profiles are unavailable."
        }
    }

    public var failureReason: String? {
        let detail = underlying.map { error in
            (error as? LocalizedError)?.failureReason
                ?? (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }

        switch self {
        case .cannotRead(let url, _):
            return "\(url.lastPathComponent) exists but could not be read: \(detail ?? "")"
        case .cannotDecode(let url, _):
            return """
                \(url.lastPathComponent) is not a capture profile this version can read: \
                \(detail ?? "") It was left exactly as it is, and every other profile still \
                loaded.
                """
        case .cannotWrite(let url, _):
            return """
                \(url.lastPathComponent) could not be written: \(detail ?? "") Any profile \
                already stored there is unchanged.
                """
        case .cannotDelete(let url, _):
            return """
                \(url.lastPathComponent) could not be removed: \(detail ?? "") The profile is \
                still installed.
                """
        case .cannotCreateDirectory(let url, _):
            return "\(url.path) could not be created: \(detail ?? "")"
        case .reservedIdentifier(let id, let namespace):
            return """
                "\(id)" is in the "\(namespace)." namespace, which belongs to the profiles \
                this application ships. Your own profiles are identified separately, and \
                renaming one never changes its identifier.
                """
        case .duplicateIdentifier(let id, let paths):
            let names = paths.map(\.lastPathComponent).joined(separator: " and ")
            return """
                \(names) both claim "\(id)". Neither was loaded: which definition a \
                photograph means would otherwise depend on the order the folder was read in.
                """
        case .filenameIdentityMismatch(let url, let expected, let found):
            return """
                \(url.lastPathComponent) is named for "\(expected)" and contains "\(found)". \
                It was not loaded: a profile stored at another profile's address would be \
                overwritten the next time that one was saved.
                """
        case .invalidProfileFilename(let url, let token, let reason):
            return """
                \(url.lastPathComponent) is named as a capture profile, and "\(token)" is not \
                a capture profile identifier: \(reason) It was not loaded, and no identifier \
                was invented for it. Renaming it to "<identifier>.irprofile.json" — using the \
                identifier inside the file — makes it loadable again.
                """
        case .unsupportedProcessingBasis(let id, _):
            return """
                "\(id)" uses an internal experimental camera transform, which deliberately \
                has no file format. \(detail ?? "")
                """
        case .libraryUnavailable:
            return """
                The application support folder could not be located, so no user capture \
                profiles could be loaded or saved. \(detail ?? "") The built-in uncalibrated \
                profile is unaffected.
                """
        }
    }
}
