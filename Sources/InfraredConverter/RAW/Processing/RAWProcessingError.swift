import Foundation

/// Failures the application-owned RAW processing stages can report.
///
/// Deliberately separate from `RAWDecodingError`: that type describes the
/// decoder boundary (what LibRaw could or could not do with a file), while
/// these describe our own processing refusing to proceed on decoded input.
/// Sharing one type would blur the boundary the pipeline is built around, and
/// would make a processing bug read like a file problem in the UI.
///
/// Decoded metadata is treated as untrusted input here: a black or white
/// level that cannot produce a meaningful normalisation is reported, never
/// silently substituted with a plausible one.
public enum RAWProcessingError: Error, Equatable {
    /// The input mosaic's declared geometry does not add up (non-positive
    /// dimensions, a stride narrower than the width, a buffer too small, or
    /// arithmetic that would overflow).
    case invalidGeometry(reason: String)
    /// The sensor colour layout could not name a colour plane for a
    /// coordinate inside the mosaic, so the effective black level for that
    /// sample is unknown. Layouts with no per-pixel mosaic (Foveon, already
    /// full-colour files) and LibRaw's non-standard 16×16 CFA reach this.
    case missingColorPlane(row: Int, column: Int)
    /// The white level is not above the effective black level at this
    /// sample, so `white - black` is zero or negative and no normalisation
    /// denominator exists. Reported rather than worked around: substituting
    /// a different white level would silently change what every value in the
    /// image means.
    case invalidNormalizationRange(
        whiteLevel: UInt32,
        blackLevel: UInt32,
        row: Int,
        column: Int,
        colorPlane: Int
    )
}

extension RAWProcessingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The RAW mosaic's dimensions are inconsistent and cannot be processed."
        case .missingColorPlane:
            return "This sensor colour layout does not describe a colour plane for every sample."
        case .invalidNormalizationRange:
            return "The file's black and white levels do not describe a usable range."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .missingColorPlane(let row, let column):
            return "No colour plane at row \(row), column \(column)."
        case .invalidNormalizationRange(let white, let black, let row, let column, let plane):
            return """
                White level \(white) is not above the effective black level \(black) \
                at row \(row), column \(column), colour plane \(plane).
                """
        }
    }
}
