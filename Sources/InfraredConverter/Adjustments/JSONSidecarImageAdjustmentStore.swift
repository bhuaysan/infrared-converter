import Foundation

/// The user's adjustments, as one JSON file beside the RAW file.
///
/// ```text
/// /Pictures/IR/OLYMPUS.ORF
/// /Pictures/IR/OLYMPUS.ORF.iradjustments.json
/// ```
///
/// ## The name rule, stated once
///
/// **The RAW file's complete name, plus `.iradjustments.json`, in the RAW
/// file's own directory.** The full name, extension included — not the base
/// name — so `SCENE.ORF` and `SCENE.ARW` in one folder keep separate records
/// instead of fighting over one.
///
/// `sidecarURL(for:)` is the only place that rule is expressed. Nothing else
/// in the project concatenates a suffix onto a RAW path; a naming rule spelled
/// out in several places is a rule that eventually disagrees with itself.
///
/// The properties it was chosen for:
///
/// ```text
/// deterministic     derived from the RAW URL alone, with no index anywhere
/// non-colliding     a distinct extension; it can never name a RAW file
/// local             no central database, no hidden cache that outranks it
/// visible           a user can see it, copy it, back it up, and delete it
/// ```
///
/// ## What it is not
///
/// Not XMP, and deliberately not: this is an application-owned format for one
/// application's adjustment record, and dressing it as an interchange standard
/// would claim an interoperability nothing here implements. Not a recipe
/// either — it is the state of *this* photograph, not a reusable preset. See
/// `docs/decisions/0013-adjustment-sidecar.md`.
///
/// ## The RAW file is never touched
///
/// This type opens exactly one path, and it is the sidecar. The RAW URL is
/// read as a string to derive a name and is never itself opened, written,
/// renamed, deleted or truncated.
public struct JSONSidecarImageAdjustmentStore: ImageAdjustmentStore {

    /// What is appended to the RAW file's complete name.
    ///
    /// A wire format: changing it orphans every sidecar already written.
    public static let sidecarSuffix = "iradjustments.json"

    public init() {}

    /// The sidecar for a RAW file. The one place the naming rule lives.
    public static func sidecarURL(for rawURL: URL) -> URL {
        rawURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(rawURL.lastPathComponent).\(sidecarSuffix)")
    }

    /// The sidecar for a RAW file, for a caller holding a store rather than
    /// the type.
    public func sidecarURL(for rawURL: URL) -> URL {
        Self.sidecarURL(for: rawURL)
    }

    public func load(
        for rawURL: URL
    ) throws(ImageAdjustmentPersistenceError) -> ImageAdjustments? {
        let sidecar = Self.sidecarURL(for: rawURL)

        let data: Data
        do {
            data = try Data(contentsOf: sidecar)
        } catch let error as CocoaError where Self.isMissingFile(error) {
            // The ordinary case for a photograph nobody has adjusted. Not a
            // failure, and the only thing that may become `nil`.
            return nil
        } catch {
            throw .cannotRead(sidecar: sidecar, underlying: error)
        }

        do {
            return try JSONDecoder().decode(ImageAdjustments.self, from: data)
        } catch {
            // `ImageAdjustments.init(from:)` throws `ImageAdjustmentError`
            // for a record it refuses and `DecodingError` for bytes that are
            // not that record. Both arrive here intact, and both stay intact:
            // the case they are wrapped in keeps the value rather than its
            // description.
            throw .cannotDecode(sidecar: sidecar, underlying: error)
        }
    }

    public func save(
        _ adjustments: ImageAdjustments, for rawURL: URL
    ) throws(ImageAdjustmentPersistenceError) {
        let sidecar = Self.sidecarURL(for: rawURL)

        let data: Data
        do {
            data = try Self.encoder().encode(adjustments)
        } catch {
            // Not reachable for any value this type can hold — every field
            // encodes unconditionally — but an encoding failure is still a
            // failure to save, and is reported as one rather than trapped.
            throw .cannotWrite(sidecar: sidecar, underlying: error)
        }

        do {
            // Foundation writes the bytes to a temporary file in the same
            // directory and renames it over the target. What that buys is the
            // replacement: nothing ever observes a half-written record at the
            // sidecar's path, and a write that fails partway leaves the
            // previous record where it was.
            //
            // It is not a durability guarantee. Foundation promises nothing
            // here about flushing to the device, so this says what the
            // mechanism does and stops there.
            try data.write(to: sidecar, options: [.atomic])
        } catch {
            throw .cannotWrite(sidecar: sidecar, underlying: error)
        }
    }

    /// Sorted keys and indentation, because a user is expected to be able to
    /// open this file, read it, and recognise what it says about their
    /// photograph. Sorting also makes the bytes deterministic for a given
    /// record.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Whether a read failed because there is nothing there.
    ///
    /// Both codes mean the same thing for our purposes: the sidecar is absent,
    /// either as a file or because its directory is.
    private static func isMissingFile(_ error: CocoaError) -> Bool {
        error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }
}
