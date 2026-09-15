import Foundation

/// Creative-preset definitions as one JSON file each, in an application-owned
/// folder.
///
/// ```text
/// ~/Library/Application Support/Infrared Converter/Presets/
///   user.550e8400-e29b-41d4-a716-446655440000.irpreset.json
///   user.9c8f6b0d-2e4a-4d1b-8f3c-77a0b9d5e611.irpreset.json
/// ```
///
/// A sibling of `Profiles/`, not a subfolder of it and not mixed into it. A
/// capture profile and a creative preset are different kinds of thing with
/// different schemas, and two artefacts sharing a folder would eventually share
/// a suffix, a counter, or a loader.
///
/// ## Why Application Support, and nowhere else
///
/// A preset is **application-owned reusable state**. It is not a document the
/// user filed somewhere, and it is not about one photograph.
///
/// ```text
/// beside the RAW files   would tie a reusable look to one folder of photographs
/// Documents              a user's own space; we do not get to put private state there
/// the repository         developer state, not user state
/// a temporary directory  deleted without warning
/// ```
///
/// The location is resolved through `FileManager`, never by building a path
/// from the home directory: a sandboxed build gets its container's Application
/// Support folder from exactly the same call.
///
/// ## One file per preset
///
/// Rather than one library file holding them all. Replacement is then atomic
/// per preset, deleting is removing one file, and a single corrupt file
/// isolates to a single missing preset instead of destroying the library.
///
/// ## The name rule, stated once
///
/// **The validated preset identifier, plus `.irpreset.json`.**
/// `presetURL(for:)` is the only place that rule is expressed; nothing else in
/// the project concatenates a suffix onto a preset identity. The identifier is
/// safe as a filename by construction — `IRCreativePresetID` admits only
/// lowercase `a–z`, `0–9`, `-` and `.` separators, so it contains no path
/// separator, and `.` and `..` are unrepresentable because every segment must
/// be non-empty and dot-free.
///
/// Identity appears twice — in the name and in the payload — and the two must
/// agree. A file whose name and contents disagree is refused rather than
/// reconciled: if they may differ, one preset's definition can live at another
/// preset's address, and the next save of the second silently destroys the
/// first.
public struct FileIRCreativePresetStore: IRCreativePresetStore {

    /// What is appended to the preset identifier.
    ///
    /// A wire format: changing it orphans every preset already written.
    public static let fileSuffix = "irpreset.json"

    /// The application-owned folder, under Application Support.
    ///
    /// Deliberately the same constant value the profile store uses, and
    /// deliberately not the same constant: the two are siblings in one
    /// application folder, and a shared symbol would make moving one of them
    /// move the other.
    public static let applicationDirectoryName = "Infrared Converter"

    /// The preset folder inside it.
    public static let presetsDirectoryName = "Presets"

    /// Where this store reads and writes.
    ///
    /// Injected rather than resolved per call, so a test can point a store at a
    /// temporary directory and **no test ever touches the real Application
    /// Support folder**.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The production location: `Application Support/Infrared Converter/Presets`.
    ///
    /// Resolved with `create: false`. Reading an empty library must not create
    /// anything — a first launch that never saves a preset leaves the file
    /// system exactly as it found it — so the folder is created lazily, by the
    /// first save that needs it.
    ///
    /// - Throws: `IRCreativePresetPersistenceError.libraryUnavailable` when the
    ///   location cannot be determined at all.
    public static func applicationSupportDirectory()
    throws(IRCreativePresetPersistenceError) -> URL {
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
            .appendingPathComponent(presetsDirectoryName, isDirectory: true)
    }

    /// The file a preset identity is stored in. The one place the name rule
    /// lives.
    public static func presetURL(for id: IRCreativePresetID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.rawValue).\(fileSuffix)")
    }

    /// The file a preset identity is stored in, in this store's directory.
    public func presetURL(for id: IRCreativePresetID) -> URL {
        Self.presetURL(for: id, in: directory)
    }

    /// What a filename in the preset folder is.
    ///
    /// ```text
    /// not our suffix                     foreign      ignored in silence
    /// our suffix + valid identity        preset       loaded, or reported
    /// our suffix + invalid identity      malformed    reported
    /// ```
    ///
    /// Three outcomes rather than two, because "is this ours?" and "is this
    /// well-formed?" are different questions and collapsing them loses one of
    /// the answers.
    public enum FilenameClassification: Equatable, Sendable {

        /// Not one of ours. The folder is allowed to contain `.DS_Store`, a
        /// note somebody left themselves, or a file a future version writes.
        case foreign

        /// Ours, and its identity token is well-formed.
        case preset(IRCreativePresetID)

        /// Ours by suffix, and its identity token is not a valid
        /// ``IRCreativePresetID``. There is no identity to load it under and
        /// none is invented — the name is reported as it stands.
        case malformed(token: String, reason: String)
    }

    /// Classifies one filename in the preset folder.
    public static func classify(fileNamed name: String) -> FilenameClassification {
        let suffix = ".\(fileSuffix)"
        guard name.hasSuffix(suffix) else { return .foreign }

        // Deliberately no minimum-length guard: a file named exactly
        // ".irpreset.json" leaves an empty token, and an empty identity is a
        // malformed name of ours rather than a foreign file.
        let token = String(name.dropLast(suffix.count))
        do {
            return .preset(try IRCreativePresetID(token))
        } catch {
            return .malformed(
                token: token,
                reason: error.failureReason ?? error.localizedDescription
            )
        }
    }

    /// The identity a filename claims, or `nil` when the name is not one of
    /// ours *or* does not spell a valid identifier.
    public static func presetID(forFileNamed name: String) -> IRCreativePresetID? {
        guard case .preset(let id) = classify(fileNamed: name) else { return nil }
        return id
    }

    // MARK: - Loading

    public func loadAll() -> IRCreativePresetLibraryLoad {
        let fileManager = FileManager.default

        // An absent folder is the ordinary first-run state, not a failure:
        // nothing has been saved yet, so there is nothing to load and nothing
        // to report. Reading a library never creates a directory.
        guard fileManager.fileExists(atPath: directory.path) else {
            return IRCreativePresetLibraryLoad()
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        } catch {
            return IRCreativePresetLibraryLoad(
                failures: [.cannotRead(url: directory, underlying: error)]
            )
        }

        var loaded: [(url: URL, preset: IRCreativePreset)] = []
        var failures: [IRCreativePresetPersistenceError] = []

        // Sorted, so that the order failures are reported in does not depend on
        // how the file system happened to enumerate the folder.
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            switch Self.classify(fileNamed: url.lastPathComponent) {
            case .foreign:
                continue

            case .malformed(let token, let reason):
                // Ours by suffix, and unloadable. Reported rather than skipped:
                // it is a preset file whose name nothing can resolve, which is
                // exactly the kind of fault a person can fix once they are told
                // about it.
                failures.append(
                    .invalidPresetFilename(url: url, token: token, reason: reason)
                )

            case .preset(let expected):
                do {
                    loaded.append((url: url, preset: try load(url, expecting: expected)))
                } catch {
                    failures.append(error)
                }
            }
        }

        // Defence in depth, and deliberately not reachable through this store.
        //
        // A file's name *is* its identity (`presetURL(for:)`), and `load`
        // refuses a payload whose id disagrees with the name it was found
        // under, so on disk one identity has exactly one address. The check
        // stays because the invariant it protects — ambiguity is refused, never
        // resolved by enumeration order — is worth being true of this type
        // independently of the two rules that currently imply it. The reachable
        // refusal is the library's, which composes sources this store knows
        // nothing about.
        var pathsByID: [IRCreativePresetID: [URL]] = [:]
        for entry in loaded {
            pathsByID[entry.preset.id, default: []].append(entry.url)
        }
        let ambiguous = pathsByID.filter { $0.value.count > 1 }
        for (id, paths) in ambiguous.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            failures.append(.duplicateIdentifier(id: id, paths: paths))
        }

        return IRCreativePresetLibraryLoad(
            presets: loaded
                .filter { ambiguous[$0.preset.id] == nil }
                .map(\.preset),
            failures: failures
        )
    }

    /// Reads one preset file, checking that it is where it says it is.
    private func load(
        _ url: URL, expecting expected: IRCreativePresetID
    ) throws(IRCreativePresetPersistenceError) -> IRCreativePreset {
        // Refused before the bytes are even read. A file named for a reserved
        // identity cannot be admitted whatever it contains, and saying so
        // without decoding it is both cheaper and clearer.
        guard !expected.isReserved else {
            throw .reservedIdentifier(
                id: expected, namespace: IRCreativePresetID.builtinNamespace
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .cannotRead(url: url, underlying: error)
        }

        let record: IRCreativePresetRecord
        do {
            record = try JSONDecoder().decode(IRCreativePresetRecord.self, from: data)
        } catch {
            // `IRCreativePresetRecord.init(from:)` throws
            // `IRCreativePresetRecordError` for a record shape it refuses,
            // `IRCreativePresetError` for a malformed identifier,
            // `ImageAdjustmentError` for a channel mix it refuses,
            // `IRCaptureProfileDescriptorError` for a filter value it refuses,
            // and `DecodingError` for bytes that are not that record. All
            // arrive here intact, and all stay intact.
            throw .cannotDecode(url: url, underlying: error)
        }

        guard record.preset.id == expected else {
            throw .filenameIdentityMismatch(
                url: url, expected: expected, found: record.preset.id
            )
        }
        return record.preset
    }

    // MARK: - Saving

    public func save(
        _ preset: IRCreativePreset
    ) throws(IRCreativePresetPersistenceError) {
        guard !preset.id.isReserved else {
            throw .reservedIdentifier(
                id: preset.id, namespace: IRCreativePresetID.builtinNamespace
            )
        }

        let url = presetURL(for: preset.id)

        let data: Data
        do {
            data = try Self.encoder().encode(IRCreativePresetRecord(preset))
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
            // nothing ever observes a half-written definition at a preset's
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
        _ id: IRCreativePresetID
    ) throws(IRCreativePresetPersistenceError) {
        guard !id.isReserved else {
            throw .reservedIdentifier(
                id: id, namespace: IRCreativePresetID.builtinNamespace
            )
        }

        let url = presetURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where Self.isMissingFile(error) {
            // The end state the caller asked for already holds.
            return
        } catch {
            throw .cannotDelete(url: url, underlying: error)
        }
    }

    /// Sorted keys and indentation, because a user is expected to be able to
    /// open a preset, read it, and recognise their own nine coefficients in it.
    /// Sorting also makes the bytes deterministic for a given definition.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func isMissingFile(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}
