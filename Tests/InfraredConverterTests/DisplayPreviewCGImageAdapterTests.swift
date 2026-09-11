import Testing
import CoreGraphics
import Foundation
@testable import InfraredConverter

/// The CoreGraphics adapter, tested as an adapter: what it declares about the
/// bytes, not what the bytes look like.
///
/// Nothing here is a snapshot test. What is checked is the description handed
/// to CoreGraphics — geometry, bit depth, stride, alpha, colour space — and
/// that the bytes it hands over are the ones it was given, unchanged.
@Suite("DisplayPreviewCGImageAdapter")
struct DisplayPreviewCGImageAdapterTests {

    private static func rendered(
        width: Int,
        height: Int,
        exposureEV: Double = 0
    ) throws -> DisplayEncodedPreviewImage {
        var values = [Float]()
        for index in 0..<(width * height * 3) {
            values.append(Float(index % 251) / 251)
        }
        return try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.image(width: width, height: height, values: values),
            settings: DisplayPreviewTestData.settings(exposureEV: exposureEV)
        )
    }

    @Test("The image is described with the documented layout")
    func layoutIsDeclaredExactly() throws {
        let preview = try Self.rendered(width: 7, height: 5)
        let cgImage = try DisplayPreviewCGImageAdapter.makeCGImage(from: preview)

        #expect(cgImage.width == 7)
        #expect(cgImage.height == 5)
        #expect(cgImage.bitsPerComponent == 8)
        #expect(cgImage.bitsPerPixel == 24)
        #expect(cgImage.bytesPerRow == 7 * 3)
        #expect(cgImage.bytesPerRow == preview.bytesPerRow)
        // Three components, no alpha byte: a 32-bit-per-pixel description
        // would mean a quarter of the buffer was padding.
        #expect(cgImage.bitsPerPixel == cgImage.bitsPerComponent * 3)
    }

    /// The tag has to be **non-linear** sRGB, because that is what the bytes
    /// are. Tagging them `linearSRGB` — which is right for the legacy
    /// 16-bit LibRaw preview and wrong for these — would leave ColorSync
    /// applying a transfer function to values that already have one.
    /// The adapter knows nothing about orientation. It is handed geometry
    /// that a stage upstream already decided, and describes it.
    ///
    /// This is the end-to-end proof that the pixel buffer itself is oriented:
    /// a dimension-swapping orientation reaches CoreGraphics as swapped
    /// dimensions, with no `CGImagePropertyOrientation`, no
    /// `CGAffineTransform` and no SwiftUI modifier anywhere in the path.
    @Test("A dimension-swapping orientation reaches CoreGraphics as swapped dimensions")
    func orientedDimensionsReachCoreGraphics() throws {
        let width = 6
        let height = 4
        var values = [Float]()
        for index in 0..<(width * height * 3) {
            values.append(Float(index % 251) / 251)
        }
        let mixed = OrientationTestData.image(width: width, height: height, values: values)

        for orientation in RAWImageOrientation.allCases {
            let oriented = try ImageOrienter().apply(to: mixed, orientation: orientation)
            let preview = try DisplayPreviewRenderer().render(
                oriented, settings: DisplayPreviewTestData.settings(exposureEV: 0)
            )
            let cgImage = try DisplayPreviewCGImageAdapter.makeCGImage(from: preview)

            let expectedWidth = orientation.swapsDimensions ? height : width
            let expectedHeight = orientation.swapsDimensions ? width : height

            #expect(cgImage.width == expectedWidth, "\(orientation) width")
            #expect(cgImage.height == expectedHeight, "\(orientation) height")
            #expect(cgImage.width == preview.width, "\(orientation)")
            #expect(cgImage.height == preview.height, "\(orientation)")
            #expect(cgImage.bytesPerRow == expectedWidth * 3, "\(orientation)")
        }
    }

    @Test("The pixels are tagged as standard sRGB, not linear sRGB")
    func colourSpaceIsStandardSRGB() throws {
        let preview = try Self.rendered(width: 4, height: 4)
        let cgImage = try DisplayPreviewCGImageAdapter.makeCGImage(from: preview)

        let colorSpace = try #require(cgImage.colorSpace)
        #expect(colorSpace.name == CGColorSpace.sRGB)
        #expect(colorSpace.name != CGColorSpace.linearSRGB)
        #expect(colorSpace.model == .rgb)
        #expect(colorSpace.numberOfComponents == 3)
    }

    @Test("There is no alpha channel and no skipped byte")
    func alphaIsAbsent() throws {
        let preview = try Self.rendered(width: 3, height: 3)
        let cgImage = try DisplayPreviewCGImageAdapter.makeCGImage(from: preview)

        #expect(cgImage.alphaInfo == .none)
        #expect(DisplayPreviewCGImageAdapter.bitmapInfo
            .contains(.byteOrderDefault))
        // A 16- or 32-bit byte-order flag would be meaningless for one-byte
        // components, and is absent.
        #expect(!DisplayPreviewCGImageAdapter.bitmapInfo.contains(.byteOrder16Little))
        #expect(!DisplayPreviewCGImageAdapter.bitmapInfo.contains(.byteOrder32Little))
        #expect(!DisplayPreviewCGImageAdapter.bitmapInfo.contains(.floatComponents))
    }

    /// The point of choosing this pixel representation: the adapter hands the
    /// buffer over as it stands, with no second full-frame pass.
    @Test("The bytes reach CoreGraphics unchanged")
    func bytesArePassedThroughUnchanged() throws {
        let preview = try Self.rendered(width: 6, height: 4, exposureEV: 0.5)
        let cgImage = try DisplayPreviewCGImageAdapter.makeCGImage(from: preview)

        let provider = try #require(cgImage.dataProvider)
        let data = try #require(provider.data) as Data
        #expect(data.count == preview.bytes.count)
        #expect(data == preview.bytes)

        // Spot-check through the coordinate accessors too, so a stride
        // mistake in the description would show.
        for (row, column) in [(0, 0), (1, 3), (3, 5)] {
            let pixel = try #require(preview.pixel(row: row, column: column))
            let base = (row * preview.width + column) * 3
            #expect(data[base] == pixel.red)
            #expect(data[base + 1] == pixel.green)
            #expect(data[base + 2] == pixel.blue)
        }
    }

    @Test("A single pixel is a legal image")
    func onePixelWorks() throws {
        let preview = try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.pixel(0.18, 0.5, 1.0),
            settings: DisplayPreviewTestData.settings(exposureEV: 0)
        )
        let cgImage = try DisplayPreviewCGImageAdapter.makeCGImage(from: preview)
        #expect(cgImage.width == 1)
        #expect(cgImage.height == 1)
        #expect(cgImage.bytesPerRow == 3)
    }

    // MARK: - Refusals

    /// `DisplayEncodedPreviewImage` is publicly constructible, so the adapter
    /// checks rather than trusts — and reports a typed failure rather than
    /// returning `nil`, so a preview that cannot be shown has a reason.
    @Test("An image whose buffer does not match its dimensions is refused")
    func inconsistentGeometryIsRefused() {
        let processing = DisplayPreviewProcessing(
            settings: DisplayPreviewTestData.settings(exposureEV: 0),
            orientationProcessing: DisplayPreviewTestData.orientationProcessing(),
            clippedLowSampleCount: 0,
            clippedHighSampleCount: 0
        )
        let malformed = [
            // Declares 4×4 (48 bytes) and holds 10.
            DisplayEncodedPreviewImage(
                width: 4, height: 4, bytes: Data(count: 10), processing: processing
            ),
            DisplayEncodedPreviewImage(
                width: 0, height: 4, bytes: Data(), processing: processing
            ),
            DisplayEncodedPreviewImage(
                width: Int.max, height: 4, bytes: Data(count: 12), processing: processing
            ),
        ]
        for image in malformed {
            #expect {
                _ = try DisplayPreviewCGImageAdapter.makeCGImage(from: image)
            } throws: { error in
                guard case .invalidGeometry = error as? DisplayRenderingError else {
                    return false
                }
                return true
            }
        }
    }
}
