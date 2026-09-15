import Foundation

/// Why a stored creative preset could not be read, written, deleted, or
/// admitted to the library.
///
/// The file-and-library boundary, kept apart from `IRCreativePresetRecordError`
/// exactly as `IRCaptureProfilePersistenceError` is kept apart from
/// `IRCaptureProfileRecordError`. That one is a **record** refusing to be
/// understood; this is the **file** refusing, or the library refusing to admit
/// what a file contains.
///
/// They meet in `cannotDecode`, which carries the refusal wrapped rather than
/// flattened, so a caller that wants to know whether a preset was written by a
/// newer build can still ask through `record`.
///
/// ## Nothing here repairs anything
///
/// No case rewrites a file, deletes one, or substitutes a preset for another.
/// A preset file that cannot be read is reported and skipped; the rest of the
/// library still loads. And no photograph is ever affected by any of it: a
/// photograph stores the resolved mix, not a reference to a preset, so a
/// library that is entirely unreadable still renders every photograph exactly
/// as it was rendering them. See
/// `docs/decisions/0024-reusable-creative-presets.md`.
public enum IRCreativePresetPersistenceError: Error {

    /// A preset file, or the preset directory, exists and could not be read.
    case cannotRead(url: URL, underlying: any Error)

    /// A preset file's bytes are not a record this build can read.
    ///
    /// Carries the refusal itself: an `IRCreativePresetRecordError` for an
    /// unsupported schema version, a missing field or an unknown token; an
    /// `IRCreativePresetError` for a malformed identifier; an
    /// `ImageAdjustmentError` for a channel mix that is not nine finite
    /// coefficients or is a built-in carrying a matrix; an
    /// `IRCaptureProfileDescriptorError` for a nominal cutoff that could not
    /// describe a filter; a `DecodingError` for bytes that are not that JSON.
    case cannotDecode(url: URL, underlying: any Error)

    /// A preset could not be written. Nothing was left at the destination: the
    /// replacement is atomic, so either the new definition is there or the
    /// previous one still is.
    case cannotWrite(url: URL, underlying: any Error)

    /// A preset file could not be removed, so the preset is still installed.
    ///
    /// Reported rather than swallowed, and the in-memory library is **not**
    /// changed: a library that dropped a preset whose file is still on disk
    /// would disagree with the disk the moment anything reloaded.
    case cannotDelete(url: URL, underlying: any Error)

    /// The preset directory could not be created, so nothing could be saved
    /// into it.
    case cannotCreateDirectory(url: URL, underlying: any Error)

    /// A user preset claims an identity in a namespace reserved for presets
    /// this build might ship.
    ///
    /// Refused in both directions: such a preset cannot be saved, and one
    /// already on disk is not admitted to the library.
    case reservedIdentifier(id: IRCreativePresetID, namespace: String)

    /// Two presets claim the same identity.
    ///
    /// Neither is admitted. Choosing one would make which mix a menu entry
    /// applies depend on enumeration order — an answer nobody chose, and one
    /// that can differ between machines.
    case duplicateIdentifier(id: IRCreativePresetID, paths: [URL])

    /// A preset file's name says one identity and its payload says another.
    ///
    /// Refused rather than reconciled. A file's name is its address: if the two
    /// may disagree, one preset's definition can be stored at another preset's
    /// address, and the next save of the second would overwrite the first.
    case filenameIdentityMismatch(
        url: URL, expected: IRCreativePresetID, found: IRCreativePresetID
    )

    /// A file wearing the `.irpreset.json` suffix whose name does not spell a
    /// valid ``IRCreativePresetID``.
    ///
    /// Not the same fault as a foreign file, and deliberately not the same
    /// outcome. `notes.txt` is somebody's note; `BAD PRESET!.irpreset.json` is
    /// a preset that cannot be addressed, and silence about it would leave a
    /// person staring at a library missing a preset whose file they can see.
    case invalidPresetFilename(url: URL, token: String, reason: String)

    /// There is no preset library on this machine: the application-owned
    /// storage location could not be determined.
    ///
    /// Photographs are unaffected, and so is the channel mixer: a preset is a
    /// convenience for reusing a mix, never a thing a rendering depends on.
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
        case .invalidPresetFilename(let url, _, _):
            return url
        case .duplicateIdentifier(_, let paths):
            return paths.first
        case .reservedIdentifier, .libraryUnavailable:
            return nil
        }
    }

    /// The identity this error is about, where it names one.
    public var presetID: IRCreativePresetID? {
        switch self {
        case .reservedIdentifier(let id, _), .duplicateIdentifier(let id, _):
            return id
        case .filenameIdentityMismatch(_, let expected, _):
            return expected
        case .cannotRead, .cannotDecode, .cannotWrite, .cannotDelete,
             .cannotCreateDirectory, .libraryUnavailable, .invalidPresetFilename:
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
        case .reservedIdentifier, .duplicateIdentifier, .filenameIdentityMismatch,
             .invalidPresetFilename:
            return nil
        }
    }

    /// The record's own refusal about its shape, when that is what refused.
    ///
    /// The projection that keeps the typed value alive across the file
    /// boundary: an unsupported schema version stays
    /// `.unsupportedSchemaVersion` rather than becoming a sentence about a file
    /// that could not be read.
    public var record: IRCreativePresetRecordError? {
        underlying as? IRCreativePresetRecordError
    }
}

extension IRCreativePresetPersistenceError: LocalizedError {

    /// A short sentence a person can act on, with no decoder text in it.
    ///
    /// The technical detail is in `failureReason`, which the interface shows
    /// underneath rather than instead.
    public var errorDescription: String? {
        switch self {
        case .cannotRead:
            return "A preset could not be read."
        case .cannotDecode:
            return "A preset file is not valid."
        case .cannotWrite:
            return "The preset could not be saved."
        case .cannotDelete:
            return "The preset could not be deleted."
        case .cannotCreateDirectory:
            return "The preset folder could not be created."
        case .reservedIdentifier:
            return "That preset identifier is reserved."
        case .duplicateIdentifier:
            return "Two preset files claim the same identifier."
        case .filenameIdentityMismatch:
            return "A preset file is stored under the wrong name."
        case .invalidPresetFilename:
            return "A preset file has a name that is not a preset identifier."
        case .libraryUnavailable:
            return "Your presets are unavailable."
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
                \(url.lastPathComponent) is not a preset this version can read: \
                \(detail ?? "") It was left exactly as it is, and every other preset still \
                loaded.
                """
        case .cannotWrite(let url, _):
            return """
                \(url.lastPathComponent) could not be written: \(detail ?? "") Any preset \
                already stored there is unchanged.
                """
        case .cannotDelete(let url, _):
            return """
                \(url.lastPathComponent) could not be removed: \(detail ?? "") The preset is \
                still installed.
                """
        case .cannotCreateDirectory(let url, _):
            return "\(url.path) could not be created: \(detail ?? "")"
        case .reservedIdentifier(let id, let namespace):
            return """
                "\(id)" is in the "\(namespace)." namespace, which is reserved for presets \
                this application ships. Your own presets are identified separately, and \
                renaming one never changes its identifier.
                """
        case .duplicateIdentifier(let id, let paths):
            let names = paths.map(\.lastPathComponent).joined(separator: " and ")
            let where_ = names.isEmpty ? "More than one stored preset" : names
            return """
                \(where_) claim "\(id)". None of them was loaded: which mix a menu entry \
                applied would otherwise depend on the order the folder was read in.
                """
        case .filenameIdentityMismatch(let url, let expected, let found):
            return """
                \(url.lastPathComponent) is named for "\(expected)" and contains "\(found)". \
                It was not loaded: a preset stored at another preset's address would be \
                overwritten the next time that one was saved.
                """
        case .invalidPresetFilename(let url, let token, let reason):
            return """
                \(url.lastPathComponent) is named as a preset, and "\(token)" is not a \
                preset identifier: \(reason) It was not loaded, and no identifier was \
                invented for it. Renaming it to "<identifier>.irpreset.json" — using the \
                identifier inside the file — makes it loadable again.
                """
        case .libraryUnavailable:
            return """
                The application support folder could not be located, so no presets could be \
                loaded or saved. \(detail ?? "") Photographs are unaffected: each one stores \
                the channel mix itself, not a reference to a preset.
                """
        }
    }
}
