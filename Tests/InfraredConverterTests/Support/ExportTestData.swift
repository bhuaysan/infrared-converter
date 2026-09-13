import CoreGraphics
import Foundation
import ImageIO
@testable import InfraredConverter

/// Builders and an independent reference implementation for the export path.
///
/// The reference arithmetic here is written out again rather than called from
/// the encoder, deliberately: a test that asserts `encoder == encoder` asserts
/// nothing. It is the same rule the display path's test data follows.
enum ExportTestData {

    // MARK: - Building input

    /// An oriented scene-linear image, full resolution by construction — no
    /// `previewResolution` in its provenance.
    static func oriented(
        width: Int,
        height: Int,
        values: [Float],
        orientation: RAWImageOrientation = .upright,
        mix: IRChannelMix = .identity
    ) -> OrientedSceneLinearRGBImage {
        DisplayPreviewTestData.image(
            width: width,
            height: height,
            values: values,
            processing: DisplayPreviewTestData.orientationProcessing(
                orientation: orientation, mix: mix
            )
        )
    }

    /// An oriented image whose provenance says it came from a **reduced
    /// preview** — what the export encoder must refuse.
    static func previewReducedOriented(
        width: Int,
        height: Int,
        values: [Float],
        sourceWidth: Int = 4056,
        sourceHeight: Int = 3040
    ) -> OrientedSceneLinearRGBImage {
        OrientedSceneLinearRGBImage(
            width: width,
            height: height,
            values: values,
            processing: ImageOrientationProcessing(
                orientation: .upright,
                channelMixProcessing: DisplayPreviewTestData.channelMixProcessing(),
                previewResolution: PreviewResolution(
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    width: width,
                    height: height,
                    policy: .workspace,
                    method: .areaAverage
                )
            )
        )
    }

    /// An exposed scene-linear image, ready for the encoder.
    static func exposed(
        width: Int,
        height: Int,
        values: [Float],
        exposureEV: Double = 0,
        orientation: RAWImageOrientation = .upright,
        mix: IRChannelMix = .identity
    ) throws -> ExposedSceneLinearRGBImage {
        try SceneLinearExposer().apply(
            to: oriented(
                width: width, height: height, values: values,
                orientation: orientation, mix: mix
            ),
            exposure: SceneLinearExposure(ev: exposureEV)
        )
    }

    /// An exposed image whose provenance says it came from a reduced preview.
    static func exposedFromPreview(
        width: Int,
        height: Int,
        values: [Float]
    ) throws -> ExposedSceneLinearRGBImage {
        try SceneLinearExposer().apply(
            to: previewReducedOriented(width: width, height: height, values: values),
            exposure: .neutral
        )
    }

    // MARK: - The reference implementation

    /// The sRGB OETF, written out again.
    static func referenceEncode(_ displayLinear: Double) -> Double {
        displayLinear <= 0.003_130_8
            ? 12.92 * displayLinear
            : 1.055 * pow(displayLinear, 1.0 / 2.4) - 0.055
    }

    /// `round(encoded × 65535)`, half away from zero.
    static func referenceQuantize(_ encoded: Double) -> UInt16 {
        UInt16((encoded * 65535).rounded())
    }

    /// One scene-linear component through the whole export boundary.
    static func referenceSample(sceneLinear: Float, exposureEV: Double = 0) -> UInt16 {
        let exposed = Double(sceneLinear) * exp2(exposureEV)
        let clipped = min(max(exposed, 0), 1)
        return referenceQuantize(referenceEncode(clipped))
    }

    // MARK: - Temporary directories

    /// A directory that exists for the duration of `body` and is then removed,
    /// whatever happens.
    ///
    /// Every export test writes here. Nothing is ever written into `RAW/`,
    /// beside a fixture, or anywhere a user's files live.
    static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("infrared-export-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }
}

/// Reads a written TIFF back through ImageIO, and reports what the file
/// actually contains rather than what we hoped we wrote.
///
/// It decodes samples according to the `CGImage`'s **own** reported byte order
/// and row stride rather than assuming either. That is deliberate: a reader
/// that assumed little-endian would pass even if the writer had swapped every
/// pair of bytes, which is one of the two failures 16-bit output is prone to
/// (the other being a silent drop to 8 bits, which `bitsPerComponent` catches).
struct TIFFPixelReader {
    enum ReadFailure: Error {
        case unreadable
        case noImage
        case noPixels
        case unexpectedLayout(String)
    }

    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let bitsPerPixel: Int
    let bytesPerRow: Int
    let alphaInfo: CGImageAlphaInfo
    let colorSpaceName: String?
    let colorSpaceModel: CGColorSpaceModel?
    /// Interleaved RGB samples, row-major, in reading order.
    let samples: [UInt16]
    /// The file's image properties as ImageIO reports them.
    let properties: [CFString: Any]

    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ReadFailure.unreadable
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ReadFailure.noImage
        }
        properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]) ?? [:]

        width = image.width
        height = image.height
        bitsPerComponent = image.bitsPerComponent
        bitsPerPixel = image.bitsPerPixel
        bytesPerRow = image.bytesPerRow
        alphaInfo = image.alphaInfo
        colorSpaceName = image.colorSpace?.name as String?
        colorSpaceModel = image.colorSpace?.model

        guard bitsPerComponent == 16 else {
            throw ReadFailure.unexpectedLayout(
                "expected 16 bits per component, file has \(bitsPerComponent)"
            )
        }
        guard bitsPerPixel == 48 else {
            throw ReadFailure.unexpectedLayout(
                "expected 48 bits per pixel, file has \(bitsPerPixel)"
            )
        }
        guard let data = image.dataProvider?.data as Data? else {
            throw ReadFailure.noPixels
        }

        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let littleEndian: Bool
        switch order {
        case .byteOrder16Little, .byteOrder32Little:
            littleEndian = true
        case .byteOrder16Big, .byteOrder32Big:
            littleEndian = false
        default:
            // `byteOrderDefault` on a little-endian host means host order.
            littleEndian = CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue)
        }

        var decoded: [UInt16] = []
        decoded.reserveCapacity(width * height * 3)
        for row in 0..<height {
            let rowStart = row * bytesPerRow
            for column in 0..<width {
                let pixelStart = rowStart + column * 6
                guard pixelStart + 6 <= data.count else {
                    throw ReadFailure.unexpectedLayout("row \(row) runs past the buffer")
                }
                for component in 0..<3 {
                    let offset = pixelStart + component * 2
                    let low = UInt16(data[data.startIndex + offset])
                    let high = UInt16(data[data.startIndex + offset + 1])
                    decoded.append(littleEndian ? (high << 8) | low : (low << 8) | high)
                }
            }
        }
        samples = decoded
    }

    func sample(row: Int, column: Int, channel: Int) -> UInt16 {
        samples[(row * width + column) * 3 + channel]
    }

    func pixel(row: Int, column: Int) -> (red: UInt16, green: UInt16, blue: UInt16) {
        (sample(row: row, column: column, channel: 0),
         sample(row: row, column: column, channel: 1),
         sample(row: row, column: column, channel: 2))
    }

    /// The TIFF dictionary ImageIO reports for the file, if any.
    var tiffProperties: [CFString: Any] {
        (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
    }

    /// The name of the embedded ICC profile, as ImageIO reports it.
    ///
    /// A different fact from `colorSpaceName`, which is CoreGraphics's own
    /// identifier for the space it resolved the profile to. Both are checked:
    /// one says the file carries an sRGB profile, the other says CoreGraphics
    /// recognised it as sRGB rather than as some arbitrary ICC-based space.
    var profileName: String? {
        properties[kCGImagePropertyProfileName] as? String
    }

    /// The orientation the file declares, if it declares one.
    var declaredOrientation: Int? {
        (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? (tiffProperties[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue
    }
}
