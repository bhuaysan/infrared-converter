import Foundation

/// One export, as the two facts it is made of.
///
/// ```text
/// the RAW file  +  ImageAdjustments
/// ```
///
/// Which is the canonical editing state of a photograph, exactly as
/// [ADR 0015](../../../docs/decisions/0015-reduced-resolution-preview.md) says
/// it is. An export is therefore not a new kind of thing: it is that state,
/// rendered once more, at the sensor's own resolution, into a file.
///
/// ## It is a snapshot, and that is the point
///
/// Both values are captured when the export starts and never consulted again.
/// A user who rotates the photograph while a 12-megapixel export is running
/// gets the export they asked for, not a half-rotated one, and their rotation
/// applies to the next export. Nothing here reaches back into a document.
///
/// ## What it deliberately cannot carry
///
/// - No preview, no `WorkspacePreviewPipeline.Source`, no `CGImage`, no
///   pixels of any kind. The pipeline that consumes this **re-reads the RAW
///   file**; there is no field through which preview pixels could arrive, so
///   exporting from a preview is not something anyone can do by mistake.
/// - No `PreviewResolutionPolicy`. The interactive preview's size is a
///   property of a window, and it has no bearing on a file. Two documents of
///   the same photograph at different preview sizes produce byte-identical
///   exports, because the export path never learns what those sizes were.
/// - No saved-state or sidecar reference. The adjustments here are the ones
///   the user currently has, whether or not they have been written to disk;
///   persistence and export are separate questions. See
///   `docs/decisions/0018-full-resolution-tiff-export.md`, Decision 9.
public struct ExportRequest: Equatable, Sendable {
    /// The RAW file to render. Read; never written, moved or modified.
    public let rawURL: URL
    /// The complete canonical adjustment state to render it with.
    public let adjustments: ImageAdjustments

    public init(rawURL: URL, adjustments: ImageAdjustments) {
        self.rawURL = rawURL
        self.adjustments = adjustments
    }

    public var diagnosticDescription: String {
        """
        \(rawURL.lastPathComponent): orientation \(adjustments.orientation.persistedToken), \
        mix \(adjustments.channelMix.kind.rawValue), \
        exposure \(adjustments.exposure.signedDescription)
        """
    }
}

/// Where an export is suggested to go, and under what name.
///
/// One rule, in one place, for the same reason the sidecar's name has one:
/// a filename built by string concatenation at each call site is a rule
/// nobody can find and everybody can get slightly wrong.
///
/// ```text
/// OLYMPUS.ORF   →   OLYMPUS.tif
/// P1010101.orf  →   P1010101.tif
/// no extension  →   name.tif
/// ```
///
/// The RAW extension is **replaced**, not appended: `OLYMPUS.ORF.tif` would
/// suggest a file derived from the RAW container rather than a photograph, and
/// it reads badly in every file list. No suffix such as `-IR` is added — the
/// application does not know that a given photograph is infrared, which is the
/// same reason it does not choose the red/blue swap on a user's behalf.
///
/// This is a **suggestion**. The user chooses the real destination in a save
/// panel and may rename it to anything.
public enum ExportDestinationPolicy {
    /// The extension every export in this version uses. `tif` rather than
    /// `tiff` because it is what the save panel's type produces and what most
    /// photographic software writes; both are the same format.
    public static let fileExtension = "tif"

    /// The filename to suggest for a RAW file.
    public static func suggestedFilename(for rawURL: URL) -> String {
        let base = rawURL.deletingPathExtension().lastPathComponent
        let name = base.isEmpty ? "Export" : base
        return "\(name).\(fileExtension)"
    }
}
