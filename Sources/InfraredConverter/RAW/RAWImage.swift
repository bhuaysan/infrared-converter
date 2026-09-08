import Foundation

/// A decoded, interleaved image buffer handed across the RAW decoder boundary.
///
/// This is intentionally the smallest representation that lets a later stage
/// interpret the samples correctly. It is *not* the project's working image
/// representation, and it deliberately carries no colour-management opinions of
/// its own — `encoding` and `colorSpace` state what the decoder produced.
public struct RAWImage: Equatable, Sendable {
    /// How sample values relate to scene luminance.
    public enum Encoding: String, Equatable, Sendable {
        /// Samples are proportional to scene linear light.
        case linear
        /// A transfer function has been applied by the decoder.
        case gammaEncoded
    }

    /// Which colour space the samples are expressed in.
    public enum ColorSpace: String, Equatable, Sendable {
        /// Camera-native RGB: demosaiced, but with no colour-matrix applied.
        /// There is no ICC profile that describes this; it is camera specific.
        case cameraNative
        /// The decoder applied a matrix into sRGB primaries.
        case sRGB
    }

    /// Pixel width of the buffer.
    public let width: Int
    /// Pixel height of the buffer.
    public let height: Int
    /// Interleaved channels per pixel (3 for RGB).
    public let channelCount: Int
    /// Bits per channel (16 for this project's default configuration).
    public let bitsPerChannel: Int
    /// Byte offset between the starts of consecutive rows.
    public let bytesPerRow: Int
    /// Interleaved samples in host byte order, channel-major within a pixel.
    /// For `channelCount == 3` the order is R, G, B.
    public let samples: Data
    public let encoding: Encoding
    public let colorSpace: ColorSpace

    public init(
        width: Int,
        height: Int,
        channelCount: Int,
        bitsPerChannel: Int,
        bytesPerRow: Int,
        samples: Data,
        encoding: Encoding,
        colorSpace: ColorSpace
    ) {
        self.width = width
        self.height = height
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
        self.bytesPerRow = bytesPerRow
        self.samples = samples
        self.encoding = encoding
        self.colorSpace = colorSpace
    }

    /// The buffer size implied by the geometry (`bytesPerRow × height`), for
    /// consistency checking.
    ///
    /// `nil` when that multiplication would overflow `Int` — geometry this
    /// project treats as untrustworthy input (e.g. a malformed decoded
    /// buffer) rather than as a value to silently wrap. Callers that need a
    /// size for allocation or copying must check this rather than force-
    /// unwrapping or falling back to unchecked arithmetic themselves.
    public var expectedByteCount: Int? {
        let (result, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        return overflow ? nil : result
    }

    /// The minimum row size implied by width × channels × bytes-per-sample,
    /// or `nil` when that multiplication would overflow `Int`.
    private var minimumRowByteCount: Int? {
        guard bitsPerChannel % 8 == 0 else { return nil }
        let bytesPerSample = bitsPerChannel / 8
        let (perPixel, pixelOverflow) = channelCount.multipliedReportingOverflow(by: bytesPerSample)
        guard !pixelOverflow else { return nil }
        let (perRow, rowOverflow) = width.multipliedReportingOverflow(by: perPixel)
        return rowOverflow ? nil : perRow
    }

    /// True when `samples` is large enough for the declared geometry and the
    /// declared row stride is consistent with width × channels × depth.
    ///
    /// Dimensions that are not positive, a bit depth that is not a whole
    /// number of bytes, or geometry whose implied byte count would overflow
    /// all make this `false` rather than trap.
    public var isGeometryConsistent: Bool {
        guard width > 0, height > 0, channelCount > 0, bitsPerChannel > 0, bitsPerChannel % 8 == 0 else {
            return false
        }
        guard let minimumRowBytes = minimumRowByteCount, let expected = expectedByteCount else {
            return false
        }
        return bytesPerRow >= minimumRowBytes && samples.count >= expected
    }
}
