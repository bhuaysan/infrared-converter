import CoreGraphics
import Foundation

/// Wraps an application-owned `DisplayEncodedPreviewImage` in a `CGImage`,
/// correctly tagged.
///
/// This is an **adapter**, not a rendering stage. Every colour decision was
/// already made by `DisplayPreviewRenderer`; all that happens here is
/// describing bytes that already exist to CoreGraphics. The mathematics has no
/// reason to import CoreGraphics, so it does not, and this file does nothing
/// but the description.
///
/// ## What it declares, and why each part is not negotiable
///
/// ```text
/// colour space      CGColorSpace.sRGB      the bytes ARE sRGB-encoded
/// bits per component 8
/// bits per pixel    24                     three components, no alpha
/// bytes per row     width × 3              tightly packed, no padding
/// alpha             CGImageAlphaInfo.none  there is no alpha channel
/// byte order        default                one byte per component
/// ```
///
/// Tagging these bytes `linearSRGB` — which is what the legacy
/// `PreviewImageRenderer` correctly does for LibRaw's *linear* 16-bit samples
/// — would leave ColorSync to apply a transfer function to values that already
/// have one. Leaving the space unspecified would let it guess. Both produce an
/// image that looks like a rendering decision and is in fact a mistake, which
/// is why the two preview paths use two colour spaces and two types.
///
/// ## No conversion happens here
///
/// The buffer is handed to `CGDataProvider` as it stands. The pixel
/// representation was chosen so that this is possible: `CGImage` accepts
/// 24-bit-per-pixel RGB with `kCGImageAlphaNone` directly, so there is no
/// second full-frame pass, no padding to insert and no channel to reorder.
///
/// Nothing routes through LibRaw, and no Core Image filter is involved. A
/// `CIFilter` chain here would be an undocumented tone and colour pipeline
/// hidden behind a display call.
enum DisplayPreviewCGImageAdapter {
    /// Bits per component in the produced image. Always `8`.
    static let bitsPerComponent = DisplayEncodedPreviewImage.bitsPerComponent
    /// Bits per pixel in the produced image. Always `24`: three components,
    /// no alpha byte.
    static let bitsPerPixel =
        DisplayEncodedPreviewImage.bytesPerPixel * DisplayEncodedPreviewImage.bitsPerComponent

    /// The bitmap description these buffers require: no alpha channel, and the
    /// platform's default byte order, which is meaningless for single-byte
    /// components and is stated rather than left to chance.
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        .union(.byteOrderDefault)

    /// Builds a `CGImage` from rendered preview bytes.
    ///
    /// - Throws: `DisplayRenderingError.invalidGeometry` when the image's
    ///   declared geometry and buffer disagree, and
    ///   `.displayImageUnavailable` when CoreGraphics itself declines. The
    ///   second is reported rather than returned as `nil` so a preview that
    ///   cannot be shown is a failure with a reason rather than a blank pane.
    static func makeCGImage(from image: DisplayEncodedPreviewImage) throws -> CGImage {
        guard image.isGeometryConsistent, let bytesPerRow = image.bytesPerRow else {
            throw DisplayRenderingError.invalidGeometry(
                reason: """
                    Preview geometry \(image.width)x\(image.height) needs \
                    \(image.expectedByteCount.map(String.init) ?? "an unrepresentable number of") \
                    bytes, buffer holds \(image.bytes.count).
                    """
            )
        }
        guard let provider = CGDataProvider(data: image.bytes as CFData) else {
            throw DisplayRenderingError.displayImageUnavailable(
                reason: "The rendered preview bytes could not be wrapped for CoreGraphics."
            )
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DisplayRenderingError.displayImageUnavailable(
                reason: "The sRGB colour space is unavailable on this system."
            )
        }
        guard let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw DisplayRenderingError.displayImageUnavailable(
                reason: """
                    CoreGraphics rejected a \(image.width)x\(image.height) sRGB image of \
                    \(bitsPerPixel) bits per pixel.
                    """
            )
        }
        return cgImage
    }
}
