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

    /// The buffer size implied by the geometry, for consistency checking.
    public var expectedByteCount: Int {
        bytesPerRow * height
    }

    /// True when `samples` is large enough for the declared geometry and the
    /// declared row stride is consistent with width × channels × depth.
    public var isGeometryConsistent: Bool {
        guard width > 0, height > 0, channelCount > 0, bitsPerChannel % 8 == 0 else {
            return false
        }
        let minimumRowBytes = width * channelCount * (bitsPerChannel / 8)
        return bytesPerRow >= minimumRowBytes && samples.count >= expectedByteCount
    }
}
