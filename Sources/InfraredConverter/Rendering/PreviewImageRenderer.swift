import CoreGraphics
import Foundation

/// Builds a **display-only** `CGImage` from a decoded RAW buffer.
///
/// This is not a rendering pipeline and is not the project's render engine. It
/// exists so the workspace can show that a file decoded successfully.
///
/// What it does:
/// - wraps the decoder's 16-bit linear samples in a `CGImage` without copying
///   or rescaling them,
/// - tags them as linear sRGB so ColorSync applies a display transfer function.
///
/// What it explicitly does **not** do:
/// - apply white balance,
/// - apply any colour matrix,
/// - clamp, brighten or tone-map.
///
/// The camera-native samples are therefore only *interpreted* as linear sRGB
/// for display. Without white balance the preview will show the sensor's native
/// channel imbalance — for a visible-light frame, a green cast. That is the
/// correct appearance for unmodified camera-native data, and it is the honest
/// starting point for the infrared pipeline that replaces this later.
enum PreviewImageRenderer {
    static func makeCGImage(from image: RAWImage) -> CGImage? {
        guard image.isGeometryConsistent,
              image.channelCount == 3,
              image.bitsPerChannel == 16,
              let provider = CGDataProvider(data: image.samples as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)
        else {
            return nil
        }

        // The decoder hands back host-order 16-bit samples.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            .union(.byteOrder16Little)

        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerChannel,
            bitsPerPixel: image.bitsPerChannel * image.channelCount,
            bytesPerRow: image.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
