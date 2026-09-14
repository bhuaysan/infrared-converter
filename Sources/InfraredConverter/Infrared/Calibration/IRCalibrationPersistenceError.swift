import Foundation

/// Why a stored calibration could not be read, written, deleted, or admitted
/// to the library.
///
/// The file-and-library boundary, kept apart from `IRCalibrationRecordError`
/// exactly as `IRCaptureProfilePersistenceError` is kept apart from
/// `IRCaptureProfileRecordError`. That one is a **record** refusing to be
/// understood; this is the **file** refusing, or the library refusing to
/// admit what a file contains.
///
/// They meet in `cannotDecode`, which carries the refusal wrapped rather than
/// flattened, so a caller that wants to know whether a calibration was
/// written by a newer build can still ask through `record`.
///
/// ## No reserved namespace
///
/// `IRCaptureProfilePersistenceError.reservedIdentifier` has no counterpart
/// here. A capture profile has a `builtin.` namespace because this project
/// ships built-in profiles; it ships **no** built-in calibrations — every
/// calibration is something somebody measured — so there is no namespace to
/// protect and no identity a user's own file could collide with except
/// another user file.
///
/// ## Nothing here repairs anything
///
/// No case rewrites a file, deletes one, or substitutes a calibration for
/// another. A calibration file that cannot be read is reported and skipped;
/// the rest of the library still loads. See
/// `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`.
public enum IRCalibrationPersistenceError: Error {

    /// A calibration file, or the calibration directory, exists and could not
    /// be read.
    case cannotRead(url: URL, underlying: any Error)

    /// A calibration file's bytes are not a record this build can read.
    ///
    /// Carries the refusal itself: an `IRCalibrationRecordError` for an
    /// unsupported schema version, a missing field or a value this build does
    /// not model; an `IRCalibrationError` for a domain invariant the
    /// reconstructed evidence, reference or fit violates; a `DecodingError`
    /// for bytes that are not that JSON at all. All arrive here intact, and
    /// all stay intact.
    case cannotDecode(url: URL, underlying: any Error)

    /// A calibration could not be written. Nothing was left at the
    /// destination: the replacement is atomic, so either the new record is
    /// there or the previous one still is.
    case cannotWrite(url: URL, underlying: any Error)

    /// A calibration file could not be removed, so the calibration is still
    /// installed.
    ///
    /// Reported rather than swallowed, and the in-memory library is **not**
    /// changed: a registry that dropped a calibration whose file is still on
    /// disk would disagree with the disk the moment anything reloaded.
    case cannotDelete(url: URL, underlying: any Error)

    /// The calibration directory could not be created, so nothing could be
    /// saved into it.
    case cannotCreateDirectory(url: URL, underlying: any Error)

    /// Two calibration files claim the same identity.
    ///
    /// Neither is admitted. Choosing one would make which record a caller
    /// resolves depend on directory-enumeration order — an answer nobody
    /// chose, that can differ between machines, and that changes which
    /// evidence and which fit a person believes they are looking at.
    case duplicateIdentifier(id: IRCalibrationID, paths: [URL])

    /// A calibration file's name says one identity and its payload says
    /// another.
    ///
    /// Refused rather than reconciled. A file's name is its address: if the
    /// two may disagree, one calibration's record can be stored at another
    /// calibration's address, and the next save of the second would overwrite
    /// the first.
    case filenameIdentityMismatch(
        url: URL, expected: IRCalibrationID, found: IRCalibrationID
    )

    /// A file wearing the `.ircalibration.json` suffix whose name does not
    /// spell a valid ``IRCalibrationID``.
    ///
    /// Applied from the first version of this store rather than added after
    /// the fact: the profile library shipped without this case first and
    /// added it once a malformed profile filename was found silently
    /// unreported. This store starts with the lesson already learned. Not the
    /// same fault as a foreign file, and deliberately not the same outcome:
    /// `notes.txt` is somebody's note; `BAD CALIBRATION!.ircalibration.json`
    /// is a calibration record that cannot be addressed, and silence about it
    /// would leave a person staring at a library missing an artefact whose
    /// file they can see.
    case invalidCalibrationFilename(url: URL, token: String, reason: String)

    /// There is no calibration library on this machine: the application-owned
    /// storage location could not be determined.
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
        case .invalidCalibrationFilename(let url, _, _):
            return url
        case .duplicateIdentifier(_, let paths):
            return paths.first
        case .libraryUnavailable:
            return nil
        }
    }

    /// The identity this error is about, where it names one.
    public var calibrationID: IRCalibrationID? {
        switch self {
        case .duplicateIdentifier(let id, _):
            return id
        case .filenameIdentityMismatch(_, let expected, _):
            return expected
        case .cannotRead, .cannotDecode, .cannotWrite, .cannotDelete,
             .cannotCreateDirectory, .libraryUnavailable, .invalidCalibrationFilename:
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
        case .duplicateIdentifier, .filenameIdentityMismatch, .invalidCalibrationFilename:
            return nil
        }
    }

    /// The record's own refusal about its shape, when that is what refused.
    ///
    /// The projection that keeps the typed value alive across the file
    /// boundary: an unsupported schema version stays
    /// `.unsupportedSchemaVersion` rather than becoming a sentence about a
    /// file that could not be read.
    public var record: IRCalibrationRecordError? {
        underlying as? IRCalibrationRecordError
    }
}

extension IRCalibrationPersistenceError: LocalizedError {

    /// A short sentence a person can act on, with no decoder text in it.
    ///
    /// The technical detail is in `failureReason`, which the interface shows
    /// underneath rather than instead. A raw `DecodingError` description is a
    /// diagnostic, not a message.
    public var errorDescription: String? {
        switch self {
        case .cannotRead:
            return "A calibration could not be read."
        case .cannotDecode:
            return "A calibration file is not valid."
        case .cannotWrite:
            return "The calibration could not be saved."
        case .cannotDelete:
            return "The calibration could not be deleted."
        case .cannotCreateDirectory:
            return "The calibration folder could not be created."
        case .duplicateIdentifier:
            return "Two calibration files claim the same identifier."
        case .filenameIdentityMismatch:
            return "A calibration file is stored under the wrong name."
        case .invalidCalibrationFilename:
            return "A calibration file has a name that is not a calibration identifier."
        case .libraryUnavailable:
            return "Your calibrations are unavailable."
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
                \(url.lastPathComponent) is not a calibration this version can read: \
                \(detail ?? "") It was left exactly as it is, and every other calibration \
                still loaded.
                """
        case .cannotWrite(let url, _):
            return """
                \(url.lastPathComponent) could not be written: \(detail ?? "") Any calibration \
                already stored there is unchanged.
                """
        case .cannotDelete(let url, _):
            return """
                \(url.lastPathComponent) could not be removed: \(detail ?? "") The calibration \
                is still installed.
                """
        case .cannotCreateDirectory(let url, _):
            return "\(url.path) could not be created: \(detail ?? "")"
        case .duplicateIdentifier(let id, let paths):
            let names = paths.map(\.lastPathComponent).joined(separator: " and ")
            return """
                \(names) both claim "\(id)". Neither was loaded: which record a caller means \
                would otherwise depend on the order the folder was read in.
                """
        case .filenameIdentityMismatch(let url, let expected, let found):
            return """
                \(url.lastPathComponent) is named for "\(expected)" and contains "\(found)". \
                It was not loaded: a record stored at another calibration's address would be \
                overwritten the next time that one was saved.
                """
        case .invalidCalibrationFilename(let url, let token, let reason):
            return """
                \(url.lastPathComponent) is named as a calibration, and "\(token)" is not a \
                calibration identifier: \(reason) It was not loaded, and no identifier was \
                invented for it. Renaming it to "<identifier>.ircalibration.json" — using the \
                identifier inside the file — makes it loadable again.
                """
        case .libraryUnavailable:
            return """
                The application support folder could not be located, so no calibrations could \
                be loaded or saved. \(detail ?? "")
                """
        }
    }
}
