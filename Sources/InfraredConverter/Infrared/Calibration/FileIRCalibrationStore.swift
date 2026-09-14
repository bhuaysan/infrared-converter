import Foundation

/// Calibration artefacts as one JSON file each, in an application-owned
/// folder.
///
/// ```text
/// ~/Library/Application Support/Infrared Converter/Calibrations/
///   calibration.550e8400-e29b-41d4-a716-446655440000.ircalibration.json
///   calibration.9c8f6b0d-2e4a-4d1b-8f3c-77a0b9d5e611.ircalibration.json
/// ```
///
/// The same location strategy as `FileIRCaptureProfileStore`, and for the
/// same reasons: this is application-owned reusable state, not a document a
/// user filed somewhere and not something tied to one photograph's folder. It
/// is resolved through `FileManager`, never by building a path from the home
/// directory, and it sits beside the `Profiles` folder rather than inside it
/// — a calibration and a capture profile are different artefacts with
/// different schemas, and nothing about their storage should suggest one is a
/// kind of the other.
///
/// ## One file per calibration, named by the name rule stated once
///
/// **The validated calibration identifier, plus `.ircalibration.json`.**
/// `calibrationURL(for:)` is the only place that rule is expressed. The
/// identifier is safe as a filename by construction —
/// `CalibrationIdentifierSyntax` admits only lowercase `a–z`, `0–9`, `-` and
/// `.` separators — and identity appears twice, in the name and in the
/// payload, and the two must agree: a file whose name and contents disagree
/// is refused rather than reconciled, exactly as a profile file is.
///
/// ## No reserved namespace
///
/// This project ships no built-in calibrations, so there is no `builtin.`
/// analogue to guard here and no `reservedIdentifier` refusal — every stored
/// calibration is a user's own measurement.
public struct FileIRCalibrationStore: IRCalibrationStore {

    /// What is appended to the calibration identifier.
    ///
    /// A wire format: changing it orphans every calibration already written.
    public static let fileSuffix = "ircalibration.json"

    /// The application-owned folder, under Application Support.
    public static let applicationDirectoryName = "Infrared Converter"

    /// The calibration folder inside it.
    public static let calibrationsDirectoryName = "Calibrations"

    /// Where this store reads and writes.
    ///
    /// Injected rather than resolved per call, so a test can point a store at
    /// a temporary directory and **no test ever touches the real Application
    /// Support folder**.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The production location:
    /// `Application Support/Infrared Converter/Calibrations`.
    ///
    /// Resolved with `create: false`. Reading an empty library must not
    /// create anything, so the folder is created lazily, by the first save
    /// that needs it.
    ///
    /// - Throws: `IRCalibrationPersistenceError.libraryUnavailable` when the
    ///   location cannot be determined at all.
    public static func applicationSupportDirectory()
    throws(IRCalibrationPersistenceError) -> URL {
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
            .appendingPathComponent(calibrationsDirectoryName, isDirectory: true)
    }

    /// The file a calibration identity is stored in. The one place the name
    /// rule lives.
    public static func calibrationURL(for id: IRCalibrationID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.rawValue).\(fileSuffix)")
    }

    /// The file a calibration identity is stored in, in this store's
    /// directory.
    public func calibrationURL(for id: IRCalibrationID) -> URL {
        Self.calibrationURL(for: id, in: directory)
    }

    /// What a filename in the calibration folder is.
    ///
    /// ```text
    /// not our suffix                     foreign      ignored in silence
    /// our suffix + valid identity        calibration  loaded, or reported
    /// our suffix + invalid identity      malformed    reported
    /// ```
    ///
    /// Three outcomes, not two, for the reason `FileIRCaptureProfileStore`
    /// gives: "is this ours?" and "is this well-formed?" are different
    /// questions, and a file wearing this store's suffix that cannot be
    /// addressed is a fault worth reporting, not a foreign file worth
    /// ignoring.
    public enum FilenameClassification: Equatable, Sendable {

        /// Not one of ours.
        case foreign

        /// Ours, and its identity token is well-formed.
        case calibration(IRCalibrationID)

        /// Ours by suffix, and its identity token is not a valid
        /// ``IRCalibrationID``.
        case malformed(token: String, reason: String)
    }

    /// Classifies one filename in the calibration folder.
    public static func classify(fileNamed name: String) -> FilenameClassification {
        let suffix = ".\(fileSuffix)"
        guard name.hasSuffix(suffix) else { return .foreign }

        // Deliberately no minimum-length guard: a file named exactly
        // ".ircalibration.json" leaves an empty token, and an empty identity
        // is a malformed name of ours rather than a foreign file.
        let token = String(name.dropLast(suffix.count))
        do {
            return .calibration(try IRCalibrationID(token))
        } catch {
            // `IRCalibrationID.init` is `throws(IRCalibrationError)`, so this
            // is always that type — unlike `IRCaptureProfileID.init`, which
            // throws untyped and needs the wider catch its own store keeps.
            return .malformed(token: token, reason: error.failureReason ?? error.localizedDescription)
        }
    }

    /// The identity a filename claims, or `nil` when the name is not one of
    /// ours *or* does not spell a valid identifier.
    public static func calibrationID(forFileNamed name: String) -> IRCalibrationID? {
        guard case .calibration(let id) = classify(fileNamed: name) else { return nil }
        return id
    }

    // MARK: - Loading

    public func loadAll() -> IRCalibrationLibraryLoad {
        let fileManager = FileManager.default

        // An absent folder is the ordinary first-run state, not a failure.
        guard fileManager.fileExists(atPath: directory.path) else {
            return IRCalibrationLibraryLoad()
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        } catch {
            return IRCalibrationLibraryLoad(
                failures: [.cannotRead(url: directory, underlying: error)]
            )
        }

        var loaded: [(url: URL, calibration: IRCalibration)] = []
        var failures: [IRCalibrationPersistenceError] = []

        // Sorted, so that the library's order — and, far more importantly,
        // the order failures are reported in — does not depend on how the
        // file system happened to enumerate the folder.
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            switch Self.classify(fileNamed: url.lastPathComponent) {
            case .foreign:
                continue

            case .malformed(let token, let reason):
                failures.append(
                    .invalidCalibrationFilename(url: url, token: token, reason: reason)
                )

            case .calibration(let expected):
                do {
                    loaded.append((url: url, calibration: try load(url, expecting: expected)))
                } catch {
                    failures.append(error)
                }
            }
        }

        // Defence in depth, for the same reason `FileIRCaptureProfileStore`
        // keeps its own copy of this check: a file's name is its identity,
        // and `load` refuses a payload whose id disagrees with the name it
        // was found under, so on disk one identity has exactly one address.
        // The check stays because the invariant it protects is worth being
        // true of this type independently of the rule that currently implies
        // it.
        var countsByID: [IRCalibrationID: [URL]] = [:]
        for entry in loaded {
            countsByID[entry.calibration.id, default: []].append(entry.url)
        }
        let ambiguous = countsByID.filter { $0.value.count > 1 }
        for (id, paths) in ambiguous.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            failures.append(.duplicateIdentifier(id: id, paths: paths))
        }

        return IRCalibrationLibraryLoad(
            calibrations: loaded
                .filter { ambiguous[$0.calibration.id] == nil }
                .map(\.calibration),
            failures: failures
        )
    }

    /// Reads one calibration file, checking that it is where it says it is.
    private func load(
        _ url: URL, expecting expected: IRCalibrationID
    ) throws(IRCalibrationPersistenceError) -> IRCalibration {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .cannotRead(url: url, underlying: error)
        }

        let record: IRCalibrationRecord
        do {
            record = try JSONDecoder().decode(IRCalibrationRecord.self, from: data)
        } catch {
            // `IRCalibrationRecord.init(from:)` throws
            // `IRCalibrationRecordError` for a record shape it refuses,
            // `IRCalibrationError` for a domain invariant the reconstructed
            // value violates, and `DecodingError` for bytes that are not that
            // record. All arrive here intact, and all stay intact.
            throw .cannotDecode(url: url, underlying: error)
        }

        guard record.calibration.id == expected else {
            throw .filenameIdentityMismatch(
                url: url, expected: expected, found: record.calibration.id
            )
        }
        return record.calibration
    }

    // MARK: - Saving

    public func save(_ calibration: IRCalibration) throws(IRCalibrationPersistenceError) {
        let record = IRCalibrationRecord(calibration)
        let url = calibrationURL(for: calibration.id)

        let data: Data
        do {
            data = try Self.encoder().encode(record)
        } catch {
            throw .cannotWrite(url: url, underlying: error)
        }

        // Lazily, and only here: the first save is the first moment the
        // folder is genuinely needed.
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            throw .cannotCreateDirectory(url: directory, underlying: error)
        }

        do {
            // Foundation writes to a temporary file in the same directory and
            // renames it over the target, so nothing ever observes a
            // half-written record at a calibration's path.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw .cannotWrite(url: url, underlying: error)
        }
    }

    // MARK: - Deleting

    public func delete(
        _ id: IRCalibrationID
    ) throws(IRCalibrationPersistenceError) {
        let url = calibrationURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where Self.isMissingFile(error) {
            // The end state the caller asked for already holds.
            return
        } catch {
            throw .cannotDelete(url: url, underlying: error)
        }
    }

    /// Sorted keys and indentation, for the same reason a profile file is
    /// written that way: a person is expected to be able to open a
    /// calibration file and read it, and sorting makes the bytes
    /// deterministic for a given record.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func isMissingFile(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}
