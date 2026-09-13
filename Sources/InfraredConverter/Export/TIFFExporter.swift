import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A TIFF export failing, at the step that failed.
///
/// Deliberately several cases rather than one "export failed": a user whose
/// disk is full, a user whose image is inconsistent and a user whose
/// destination directory disappeared have three different problems, and only
/// the middle one is ours.
public enum TIFFExportError: Error {
    /// The image handed to the writer does not describe itself consistently.
    case invalidExportImage(reason: String)
    /// CoreGraphics could not represent the samples as an image.
    case imageUnavailable(reason: String)
    /// A place to write could not be created — the temporary file, or the
    /// ImageIO destination for it.
    case destinationUnavailable(url: URL, reason: String)
    /// ImageIO accepted the image but could not finish writing the file.
    case encodingFailed(url: URL, reason: String)
    /// The file was written, but could not be put where the user asked.
    case finalizationFailed(destination: URL, underlying: any Error)
}

extension TIFFExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidExportImage:
            return "The rendered image could not be exported."
        case .imageUnavailable:
            return "The rendered image could not be prepared for writing."
        case .destinationUnavailable:
            return "The export file could not be created."
        case .encodingFailed:
            return "The TIFF file could not be written."
        case .finalizationFailed:
            return "The exported file could not be moved into place."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidExportImage(let reason), .imageUnavailable(let reason):
            return reason
        case .destinationUnavailable(let url, let reason):
            return "\(url.lastPathComponent): \(reason)"
        case .encodingFailed(let url, let reason):
            return "\(url.lastPathComponent): \(reason)"
        case .finalizationFailed(let destination, let underlying):
            return """
                \(destination.lastPathComponent) could not be replaced: \
                \(underlying.localizedDescription) Nothing was written to it, so whatever \
                was there is unchanged.
                """
        }
    }
}

/// What one completed export produced.
///
/// Small on purpose. It is a receipt, not a provenance graph: the full
/// processing record lives on the `ExportEncodedImage` the writer was given,
/// and anyone who needs it has that value.
public struct TIFFExportResult: Equatable, Sendable {
    /// Where the file is.
    public let destination: URL
    /// Which RAW file it was rendered from.
    public let sourceURL: URL
    /// The canonical adjustments it was rendered with — the export snapshot's
    /// own copy, not whatever the document holds now.
    public let adjustments: ImageAdjustments
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bitsPerComponent: Int
    public let channelCount: Int
    /// How many components the export range policy clipped, in each
    /// direction. Both destroy detail, and an export is worth saying so about.
    public let clippedLowSampleCount: Int
    public let clippedHighSampleCount: Int
    /// The file's size, when the file system reported one.
    public let fileSizeBytes: Int?

    public init(
        destination: URL,
        sourceURL: URL,
        adjustments: ImageAdjustments,
        pixelWidth: Int,
        pixelHeight: Int,
        bitsPerComponent: Int,
        channelCount: Int,
        clippedLowSampleCount: Int,
        clippedHighSampleCount: Int,
        fileSizeBytes: Int?
    ) {
        self.destination = destination
        self.sourceURL = sourceURL
        self.adjustments = adjustments
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bitsPerComponent = bitsPerComponent
        self.channelCount = channelCount
        self.clippedLowSampleCount = clippedLowSampleCount
        self.clippedHighSampleCount = clippedHighSampleCount
        self.fileSizeBytes = fileSizeBytes
    }

    public var clippedSampleCount: Int { clippedLowSampleCount + clippedHighSampleCount }

    public var diagnosticDescription: String {
        """
        \(destination.lastPathComponent): \(pixelWidth)x\(pixelHeight), \
        \(channelCount) channels at \(bitsPerComponent) bits, \
        \(clippedLowSampleCount) low and \(clippedHighSampleCount) high samples clipped
        """
    }
}

/// Writes an encoded export image to a TIFF file, and nothing else.
///
/// ```text
/// ExportEncodedImage  →  a 16-bit RGB TIFF on disk, tagged sRGB
/// ```
///
/// It does not decode RAW, does not know what an adjustment is, and makes no
/// processing decision. The pipeline prepares pixels; this writes them. See
/// `docs/decisions/0018-full-resolution-tiff-export.md`, Decision 8.
///
/// ## File safety
///
/// A failed export must not leave a half-written file that looks like a valid
/// TIFF. So the bytes are written to a **temporary file first**, in a
/// system-provided replacement directory on the destination's own volume, and
/// only a completed, finalised file is moved into place:
///
/// ```text
/// 1. ask the file system for a replacement directory next to the destination
/// 2. write and finalise the whole TIFF there
/// 3. move it onto the destination, replacing an existing file if there is one
/// 4. remove the replacement directory
/// ```
///
/// ImageIO has no commit semantics of its own: `CGImageDestinationFinalize`
/// returning `false` can leave a partial file behind, which is exactly why
/// step 2 happens somewhere disposable. If any step before 3 fails, the
/// destination is untouched — a user who exported over yesterday's file still
/// has yesterday's file.
///
/// Step 3 uses `replaceItemAt` when something is already there, which is the
/// file system's own atomic-where-possible replacement, and a plain move
/// otherwise. Overwriting is not decided here: a destination only exists
/// because the user chose it in a save panel, and the panel is where the
/// overwrite was agreed to.
///
/// ## What is written, and what is deliberately not
///
/// ```text
/// written        pixels, dimensions, 16-bit RGB, the sRGB profile,
///                orientation = 1, camera make and model
/// not written    adjustment JSON, XMP, private tags, recipes, a thumbnail,
///                the RAW file's EXIF, the capture date
/// ```
///
/// **Orientation is written as `1` deliberately.** The pixels have already
/// been permuted by `ImageOrienter`, so they are in viewing order; copying the
/// RAW file's orientation tag across would tell every reader to rotate them
/// again. A doubly rotated export is the classic version of this bug and it
/// looks like a pipeline error rather than a metadata one.
///
/// The **capture date** is left out rather than guessed. `RAWMetadata` carries
/// it as an instant, and a TIFF `DateTime` is a wall-clock string with no time
/// zone; writing one would require inventing the zone the photograph was taken
/// in. An absent field is honest, a wrong one is not.
public struct TIFFExporter: Sendable {
    public init() {}

    /// The file type written. One format; there is no chooser and no option.
    public static let contentType = UTType.tiff

    /// Writes one encoded image to `destination`.
    ///
    /// - Parameters:
    ///   - image: the encoded samples and their provenance.
    ///   - destination: where the user asked for the file. Its directory must
    ///     exist; the file itself need not.
    ///   - metadata: the RAW file's metadata, for the camera identity fields.
    ///   - sourceURL: the RAW file this was rendered from, for the receipt.
    ///   - adjustments: the snapshot this was rendered with, for the receipt.
    /// - Throws: `TIFFExportError`.
    @discardableResult
    public func write(
        _ image: ExportEncodedImage,
        to destination: URL,
        metadata: RAWMetadata,
        sourceURL: URL,
        adjustments: ImageAdjustments
    ) throws -> TIFFExportResult {
        let cgImage = try ExportCGImageAdapter.makeCGImage(from: image)

        let fileManager = FileManager.default
        let workingDirectory: URL
        do {
            workingDirectory = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: destination,
                create: true
            )
        } catch {
            throw TIFFExportError.destinationUnavailable(
                url: destination,
                reason: """
                    A temporary directory on the same volume could not be created: \
                    \(error.localizedDescription)
                    """
            )
        }
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let temporary = workingDirectory
            .appendingPathComponent(destination.lastPathComponent)

        try Self.encodeTIFF(cgImage, to: temporary, metadata: metadata)

        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw TIFFExportError.finalizationFailed(
                destination: destination, underlying: error
            )
        }

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize

        return TIFFExportResult(
            destination: destination,
            sourceURL: sourceURL,
            adjustments: adjustments,
            pixelWidth: image.width,
            pixelHeight: image.height,
            bitsPerComponent: ExportEncodedImage.bitsPerComponent,
            channelCount: ExportEncodedImage.channelCount,
            clippedLowSampleCount: image.processing.clippedLowSampleCount,
            clippedHighSampleCount: image.processing.clippedHighSampleCount,
            fileSizeBytes: size
        )
    }

    // MARK: - ImageIO

    private static func encodeTIFF(
        _ image: CGImage,
        to url: URL,
        metadata: RAWMetadata
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, contentType.identifier as CFString, 1, nil
        ) else {
            throw TIFFExportError.destinationUnavailable(
                url: url, reason: "ImageIO could not create a TIFF destination."
            )
        }

        CGImageDestinationAddImage(destination, image, properties(for: metadata) as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw TIFFExportError.encodingFailed(
                url: url,
                reason: """
                    ImageIO could not finalise the TIFF. Nothing was moved to the \
                    destination.
                    """
            )
        }
    }

    /// The file's metadata: upright orientation, and the camera's identity
    /// when the file names one.
    ///
    /// Orientation is stated in both the top-level property and the TIFF
    /// dictionary, because readers disagree about which they consult and
    /// "absent means 1" is a convention rather than a guarantee. Saying `1`
    /// twice costs nothing; being rotated twice costs the photograph.
    static func properties(for metadata: RAWMetadata) -> [CFString: Any] {
        var tiff: [CFString: Any] = [
            kCGImagePropertyTIFFOrientation: 1
        ]
        if let make = metadata.identity.make, !make.isEmpty {
            tiff[kCGImagePropertyTIFFMake] = make
        }
        if let model = metadata.identity.model, !model.isEmpty {
            tiff[kCGImagePropertyTIFFModel] = model
        }
        return [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: tiff
        ]
    }
}
