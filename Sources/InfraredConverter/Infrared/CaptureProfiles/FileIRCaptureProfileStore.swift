import Foundation

/// Capture-profile definitions as one JSON file each, in an application-owned
/// folder.
///
/// ```text
/// ~/Library/Application Support/Infrared Converter/Profiles/
///   user.550e8400-e29b-41d4-a716-446655440000.irprofile.json
///   user.9c8f6b0d-2e4a-4d1b-8f3c-77a0b9d5e611.irprofile.json
/// ```
///
/// ## Why Application Support, and nowhere else
///
/// A profile is **application-owned reusable state**. It is not a document the
/// user filed somewhere, and it is not about one photograph.
///
/// ```text
/// beside the RAW files   would tie a reusable profile to one folder of photographs,
///                        and scatter copies across every import
/// Documents              a user's own space; we do not get to put private state there
/// the repository         developer state, not user state
/// a temporary directory  deleted without warning; a profile a photograph references
///                        would vanish and the photograph would stop opening
/// ```
///
/// The location is resolved through `FileManager`, never by building a path
/// from the home directory: a sandboxed build gets its container's Application
/// Support folder from exactly the same call.
///
/// ## One file per profile
///
/// Rather than one library file holding them all. Replacement is then atomic
/// per profile, deleting is removing one file, and a single corrupt file
/// isolates to a single missing profile instead of destroying the library. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
///
/// ## The name rule, stated once
///
/// **The validated profile identifier, plus `.irprofile.json`.**
/// `profileURL(for:)` is the only place that rule is expressed; nothing else in
/// the project concatenates a suffix onto a profile identity. The identifier is
/// safe as a filename by construction — `IRCaptureProfileID` admits only
/// lowercase `a–z`, `0–9`, `-` and `.` separators, so it contains no path
/// separator, and `.` and `..` are unrepresentable because every segment must
/// be non-empty and dot-free.
///
/// Identity appears twice — in the name and in the payload — and the two must
/// agree. A file whose name and contents disagree is refused rather than
/// reconciled: if they may differ, one profile's definition can live at another
/// profile's address, and the next save of the second silently destroys the
/// first.
public struct FileIRCaptureProfileStore: IRCaptureProfileStore {

    /// What is appended to the profile identifier.
    ///
    /// A wire format: changing it orphans every profile already written.
    public static let fileSuffix = "irprofile.json"

    /// The application-owned folder, under Application Support.
    public static let applicationDirectoryName = "Infrared Converter"

    /// The profile folder inside it.
    public static let profilesDirectoryName = "Profiles"

    /// Where this store reads and writes.
    ///
    /// Injected rather than resolved per call, so a test can point a store at a
    /// temporary directory and **no test ever touches the real Application
    /// Support folder**. A suite that wrote there would leave profiles on the
    /// machine it ran on and would pass or fail depending on what was already
    /// there.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The production location: `Application Support/Infrared Converter/Profiles`.
    ///
    /// Resolved with `create: false`. Reading an empty library must not create
    /// anything — a first launch that never saves a profile leaves the file
    /// system exactly as it found it — so the folder is created lazily, by the
    /// first save that needs it.
    ///
    /// - Throws: `IRCaptureProfilePersistenceError.libraryUnavailable` when the
    ///   location cannot be determined at all.
    public static func applicationSupportDirectory()
    throws(IRCaptureProfilePersistenceError) -> URL {
        let base: URL
        do {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw .libraryUnavailable(underlying: error)
        }
        return base
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent(profilesDirectoryName, isDirectory: true)
    }

    /// The file a profile identity is stored in. The one place the name rule
    /// lives.
    public static func profileURL(for id: IRCaptureProfileID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.rawValue).\(fileSuffix)")
    }

    /// The file a profile identity is stored in, in this store's directory.
    public func profileURL(for id: IRCaptureProfileID) -> URL {
        Self.profileURL(for: id, in: directory)
    }

    /// What a filename in the profile folder is.
    ///
    /// ```text
    /// not our suffix                     foreign      ignored in silence
    /// our suffix + valid identity        profile      loaded, or reported
    /// our suffix + invalid identity      malformed    reported
    /// ```
    ///
    /// Three outcomes rather than two, because "is this ours?" and "is this
    /// well-formed?" are different questions and collapsing them loses one of
    /// the answers. `BAD PROFILE!.irprofile.json` wears our suffix: whoever
    /// wrote it meant it to be a capture profile, and a store that quietly
    /// skipped it would leave somebody looking at a library missing a profile
    /// they can see in the Finder, with nothing said.
    public enum FilenameClassification: Equatable, Sendable {

        /// Not one of ours. The folder is allowed to contain `.DS_Store`, a
        /// note somebody left themselves, or a file a future version writes;
        /// none of those is a broken profile and none is reported as one.
        case foreign

        /// Ours, and its identity token is well-formed.
        case profile(IRCaptureProfileID)

        /// Ours by suffix, and its identity token is not a valid
        /// ``IRCaptureProfileID``. There is no identity to load it under and
        /// none is invented — the name is reported as it stands.
        case malformed(token: String, reason: String)
    }

    /// Classifies one filename in the profile folder.
    ///
    /// This is what decides **which files are scanned at all**, and — since
    /// the milestone that split `.foreign` from `.malformed` — which of the
    /// unscanned ones are still worth reporting.
    public static func classify(fileNamed name: String) -> FilenameClassification {
        let suffix = ".\(fileSuffix)"
        guard name.hasSuffix(suffix) else { return .foreign }

        // Deliberately no minimum-length guard: a file named exactly
        // ".irprofile.json" leaves an empty token, and an empty identity is a
        // malformed name of ours rather than a foreign file.
        let token = String(name.dropLast(suffix.count))
        do {
            return .profile(try IRCaptureProfileID(token))
        } catch let error as IRCaptureProfileError {
            return .malformed(
                token: token,
                reason: error.failureReason ?? error.localizedDescription
            )
        } catch {
            return .malformed(token: token, reason: error.localizedDescription)
        }
    }

    /// The identity a filename claims, or `nil` when the name is not one of
    /// ours *or* does not spell a valid identifier.
    ///
    /// A convenience over ``classify(fileNamed:)`` for callers that only want
    /// the identity. Loading uses the classification itself, because the
    /// difference between the two `nil` cases is the difference between
    /// silence and a reported failure.
    public static func profileID(forFileNamed name: String) -> IRCaptureProfileID? {
        guard case .profile(let id) = classify(fileNamed: name) else { return nil }
        return id
    }

    // MARK: - Loading

    public func loadAll() -> IRCaptureProfileLibraryLoad {
        let fileManager = FileManager.default

        // An absent folder is the ordinary first-run state, not a failure:
        // nothing has been saved yet, so there is nothing to load and nothing
        // to report. Reading a library never creates a directory.
        guard fileManager.fileExists(atPath: directory.path) else {
            return IRCaptureProfileLibraryLoad()
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        } catch {
            return IRCaptureProfileLibraryLoad(
                failures: [.cannotRead(url: directory, underlying: error)]
            )
        }

        var loaded: [(url: URL, profile: IRCaptureProfile)] = []
        var failures: [IRCaptureProfilePersistenceError] = []

        // Sorted, so that the library's order — and, far more importantly, the
        // order failures are reported in — does not depend on how the file
        // system happened to enumerate the folder.
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            switch Self.classify(fileNamed: url.lastPathComponent) {
            case .foreign:
                // Not one of ours. Ignored in silence, deliberately: a folder
                // is allowed to contain other things.
                continue

            case .malformed(let token, let reason):
                // Ours by suffix, and unloadable. Reported rather than
                // skipped: it is a profile file whose name nothing can resolve,
                // which is exactly the kind of fault a person can fix once
                // they are told about it.
                failures.append(
                    .invalidProfileFilename(url: url, token: token, reason: reason)
                )

            case .profile(let expected):
                do {
                    loaded.append((url: url, profile: try load(url, expecting: expected)))
                } catch {
                    failures.append(error)
                }
            }
        }

        // Defence in depth, and deliberately not reachable through this store.
        //
        // A file's name *is* its identity (`profileURL(for:)`), and `load`
        // refuses a payload whose id disagrees with the name it was found
        // under, so on disk one identity has exactly one address and two files
        // cannot both claim `user.abc`. The check stays because the invariant
        // it protects — ambiguity is refused, never resolved by enumeration
        // order — is worth being true of this type independently of the two
        // rules that currently imply it. The reachable refusal is the
        // registry's, which composes sources this store knows nothing about.
        // See `docs/decisions/0021-user-capture-profile-library.md`.
        var countsByID: [IRCaptureProfileID: [URL]] = [:]
        for entry in loaded {
            countsByID[entry.profile.id, default: []].append(entry.url)
        }
        let ambiguous = countsByID.filter { $0.value.count > 1 }
        for (id, paths) in ambiguous.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            failures.append(.duplicateIdentifier(id: id, paths: paths))
        }

        return IRCaptureProfileLibraryLoad(
            profiles: loaded
                .filter { ambiguous[$0.profile.id] == nil }
                .map(\.profile),
            failures: failures
        )
    }

    /// Reads one profile file, checking that it is where it says it is.
    private func load(
        _ url: URL, expecting expected: IRCaptureProfileID
    ) throws(IRCaptureProfilePersistenceError) -> IRCaptureProfile {
        // Refused before the bytes are even read. A file named for a built-in
        // identity cannot be admitted whatever it contains, and saying so
        // without decoding it is both cheaper and clearer.
        guard !expected.isReserved else {
            throw .reservedIdentifier(
                id: expected, namespace: IRCaptureProfileID.builtinNamespace
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .cannotRead(url: url, underlying: error)
        }

        let record: IRCaptureProfileRecord
        do {
            record = try JSONDecoder().decode(IRCaptureProfileRecord.self, from: data)
        } catch {
            // `IRCaptureProfileRecord.init(from:)` throws
            // `IRCaptureProfileRecordError` for a record shape it refuses,
            // `IRCaptureProfileError` for a malformed identifier,
            // `IRCaptureProfileDescriptorError` for a filter value it refuses,
            // and `DecodingError` for bytes that are not that record. All
            // arrive here intact, and all stay intact.
            throw .cannotDecode(url: url, underlying: error)
        }

        guard record.profile.id == expected else {
            throw .filenameIdentityMismatch(
                url: url, expected: expected, found: record.profile.id
            )
        }
        return record.profile
    }

    // MARK: - Saving

    public func save(
        _ profile: IRCaptureProfile
    ) throws(IRCaptureProfilePersistenceError) {
        guard !profile.id.isReserved else {
            throw .reservedIdentifier(
                id: profile.id, namespace: IRCaptureProfileID.builtinNamespace
            )
        }

        // Before anything is created or opened, so that a profile with no wire
        // format leaves no folder and no file behind.
        let record: IRCaptureProfileRecord
        do {
            record = try IRCaptureProfileRecord(profile)
        } catch {
            throw .unsupportedProcessingBasis(id: profile.id, underlying: error)
        }

        let url = profileURL(for: profile.id)

        let data: Data
        do {
            data = try Self.encoder().encode(record)
        } catch {
            throw .cannotWrite(url: url, underlying: error)
        }

        // Lazily, and only here: the first save is the first moment the folder
        // is genuinely needed.
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            throw .cannotCreateDirectory(url: directory, underlying: error)
        }

        do {
            // Foundation writes to a temporary file in the same directory and
            // renames it over the target. What that buys is the replacement:
            // nothing ever observes a half-written definition at a profile's
            // path, and a write that fails partway leaves the previous
            // definition where it was.
            //
            // It is not a durability guarantee. Foundation promises nothing
            // here about flushing to the device, so this says what the
            // mechanism does and stops there.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw .cannotWrite(url: url, underlying: error)
        }
    }

    // MARK: - Deleting

    public func delete(
        _ id: IRCaptureProfileID
    ) throws(IRCaptureProfilePersistenceError) {
        guard !id.isReserved else {
            throw .reservedIdentifier(
                id: id, namespace: IRCaptureProfileID.builtinNamespace
            )
        }

        let url = profileURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where Self.isMissingFile(error) {
            // The end state the caller asked for already holds. Reporting it as
            // a failure would make "delete a profile twice" an error condition
            // for no benefit.
            return
        } catch {
            throw .cannotDelete(url: url, underlying: error)
        }
    }

    /// Sorted keys and indentation, because a user is expected to be able to
    /// open a profile, read it, and recognise their own camera in it. Sorting
    /// also makes the bytes deterministic for a given definition.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func isMissingFile(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}
