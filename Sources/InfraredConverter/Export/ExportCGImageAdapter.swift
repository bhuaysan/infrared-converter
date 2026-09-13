import CoreGraphics
import Foundation

/// Wraps 16-bit export samples as a `CGImage` tagged sRGB, for ImageIO to
/// write.
///
/// The counterpart of `DisplayPreviewCGImageAdapter`, and the **only** place
/// in the export path where samples become bytes and therefore the only place
/// a byte order exists. `ExportEncodedImage` deliberately stores `[UInt16]`
/// rather than `Data` so that every stage before this one is byte-order-free.
///
/// ```text
/// 16 bits per component, 48 bits per pixel, 3 components, no alpha
/// host byte order, declared to CoreGraphics rather than assumed
/// CGColorSpace.sRGB — the same profile the samples were encoded for
/// ```
///
/// ## Why the colour space is named here and not left to default
///
/// A `CGImage` with no colour space is interpreted by whatever reads it, and
/// ImageIO would then write a TIFF with no profile that other applications
/// would guess at. The samples carry the sRGB transfer function because
/// `ExportImageEncoder` applied it exactly once; tagging them sRGB is what
/// tells a reader not to apply it again. An untagged file and a mis-tagged
/// file both produce a double or missing transfer function, which looks like a
/// contrast error rather than a colour-management one.
enum ExportCGImageAdapter {
    static let bitsPerComponent = ExportEncodedImage.bitsPerComponent
    static let bitsPerPixel = ExportEncodedImage.bitsPerPixel

    /// The byte order of this host, declared rather than assumed.
    ///
    /// The samples are copied out of a `[UInt16]` in native order, so the flag
    /// has to say which that is. Hard-coding little-endian would be right on
    /// every Mac this project supports and wrong in a way that would only ever
    /// show up as colours shifted by multiples of 256.
    static let byteOrder: CGBitmapInfo =
        CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue)
            ? .byteOrder16Little
            : .byteOrder16Big

    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        .union(byteOrder)

    static func makeCGImage(from image: ExportEncodedImage) throws -> CGImage {
        guard image.isGeometryConsistent, let bytesPerRow = image.bytesPerRow else {
            throw TIFFExportError.invalidExportImage(
                reason: """
                    Export geometry \(image.width)x\(image.height) needs \
                    \(image.expectedSampleCount.map(String.init) ?? "an unrepresentable number of") \
                    samples, buffer holds \(image.samples.count).
                    """
            )
        }

        let data = image.samples.withUnsafeBufferPointer { Data(buffer: $0) }

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw TIFFExportError.imageUnavailable(
                reason: "The encoded export samples could not be wrapped for CoreGraphics."
            )
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw TIFFExportError.imageUnavailable(
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
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TIFFExportError.imageUnavailable(
                reason: """
                    CoreGraphics rejected a \(image.width)x\(image.height) sRGB image of \
                    \(bitsPerPixel) bits per pixel.
                    """
            )
        }
        return cgImage
    }
}
