import Testing
import CoreGraphics
import Foundation
import ImageIO
@testable import InfraredConverter

/// What actually lands on disk: dimensions, bit depth, channel order, row
/// order, byte order, colour tagging — and what happens when the write fails.
@Suite("TIFF exporter")
struct TIFFExporterTests {

    private static let metadata: RAWMetadata = {
        var metadata = RAWTestData.metadata()
        metadata.identity.make = "OLYMPUS IMAGING CORP."
        metadata.identity.model = "E-PL3"
        return metadata
    }()

    private static let sourceURL = URL(fileURLWithPath: "/tmp/synthetic-source.orf")

    private static func encoded(
        width: Int,
        height: Int,
        values: [Float]
    ) throws -> ExportEncodedImage {
        try ExportImageEncoder().encode(
            try ExportTestData.exposed(width: width, height: height, values: values),
            settings: .standard
        )
    }

    @discardableResult
    private static func write(
        _ image: ExportEncodedImage,
        to destination: URL,
        adjustments: ImageAdjustments = .none
    ) throws -> TIFFExportResult {
        try TIFFExporter().write(
            image,
            to: destination,
            metadata: metadata,
            sourceURL: sourceURL,
            adjustments: adjustments
        )
    }

    // MARK: - Exact pixels

    @Test("A 3×2 image of known values round-trips through the file exactly")
    func knownValuesRoundTripExactly() throws {
        // One row of 0, 0.25, 0.5 and one of 0.75, 1 and a grey; every
        // component of every pixel distinct, so a transposed row, a swapped
        // channel or a byte-swapped sample would all show.
        let inputs: [Float] = [
            0.00, 0.25, 0.50,
            0.75, 1.00, 0.10,
            0.20, 0.30, 0.40,

            0.60, 0.70, 0.80,
            0.90, 0.05, 0.15,
            0.35, 0.45, 0.55
        ]
        let image = try Self.encoded(width: 3, height: 2, values: inputs)

        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("exact.tif")
            let result = try Self.write(image, to: destination)

            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(result.pixelWidth == 3)
            #expect(result.pixelHeight == 2)
            #expect(result.bitsPerComponent == 16)
            #expect(result.channelCount == 3)
            #expect((result.fileSizeBytes ?? 0) > 0)

            let read = try TIFFPixelReader(contentsOf: destination)
            #expect(read.width == 3)
            #expect(read.height == 2)
            #expect(read.bitsPerComponent == 16)
            #expect(read.bitsPerPixel == 48)
            #expect(read.alphaInfo == .none)

            // Every sample, in reading order, against the reference.
            #expect(read.samples.count == inputs.count)
            for (index, value) in inputs.enumerated() {
                #expect(read.samples[index] == ExportTestData.referenceSample(sceneLinear: value))
            }
            // And against what the encoder produced, so the file and the
            // in-memory image agree sample for sample.
            #expect(read.samples == image.samples)

            // Spelled out at the corners: row order and channel order.
            #expect(read.pixel(row: 0, column: 0).red == 0)
            #expect(read.pixel(row: 0, column: 1).green == 65535)
            #expect(read.pixel(row: 1, column: 2).blue
                == ExportTestData.referenceSample(sceneLinear: 0.55))
        }
    }

    @Test("Black and white survive as 0 and 65535, not 0 and 65534")
    func theEndpointsSurviveTheFile() throws {
        let image = try Self.encoded(
            width: 2, height: 1, values: [0, 0, 0, 1, 1, 1]
        )
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("endpoints.tif")
            try Self.write(image, to: destination)
            let read = try TIFFPixelReader(contentsOf: destination)
            #expect(read.pixel(row: 0, column: 0) == (0, 0, 0))
            #expect(read.pixel(row: 0, column: 1) == (65535, 65535, 65535))
        }
    }

    @Test("No sample is byte-swapped, at values where a swap would be obvious")
    func noSampleIsByteSwapped() throws {
        // 0x0102 byte-swapped is 0x0201 — a hundredfold difference. Values are
        // chosen so the encoded samples land far from any palindrome.
        let values: [Float] = [0.001, 0.01, 0.02, 0.98, 0.99, 0.999]
        let image = try Self.encoded(width: 2, height: 1, values: values)
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("byteorder.tif")
            try Self.write(image, to: destination)
            let read = try TIFFPixelReader(contentsOf: destination)
            for (index, value) in values.enumerated() {
                let expected = ExportTestData.referenceSample(sceneLinear: value)
                #expect(read.samples[index] == expected)
                #expect(read.samples[index] != expected.byteSwapped)
            }
        }
    }

    // MARK: - What the file declares

    @Test("The file's own tags say 16-bit, three channels, upright")
    func theFileTagsSayWhatItIs() throws {
        let image = try Self.encoded(
            width: 3, height: 2, values: Array(repeating: 0.5, count: 18)
        )
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("tags.tif")
            try Self.write(image, to: destination)

            let directoryEntries = try TIFFTagReader.readIFD0(at: destination)
            let entries = Dictionary(
                uniqueKeysWithValues: directoryEntries.entries.map { ($0.tag, $0) }
            )

            // ImageWidth (256) and ImageLength (257).
            #expect(entries[256]?.firstValue == 3)
            #expect(entries[257]?.firstValue == 2)
            // SamplesPerPixel (277) — three, so no alpha channel was written.
            #expect(entries[277]?.firstValue == 3)
            // BitsPerSample (258) is a count-3 SHORT, so it is stored out of
            // line; the count alone proves three components were declared.
            #expect(entries[258]?.count == 3)
            // Orientation (274), if present at all, must be 1: the pixels are
            // already in viewing order, and a reader that rotated them again
            // would show the photograph sideways.
            if let orientation = entries[274] {
                #expect(orientation.firstValue == 1)
            }
            // An ICC profile (34675) is embedded, so the file is not left for
            // a reader to guess at.
            #expect(entries[34675] != nil)
        }
    }

    @Test("ImageIO reads the file back as sRGB, 16-bit, orientation 1")
    func imageIOReadsItAsSRGB() throws {
        let image = try Self.encoded(
            width: 2, height: 2, values: Array(repeating: 0.4, count: 12)
        )
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("srgb.tif")
            try Self.write(image, to: destination)

            let read = try TIFFPixelReader(contentsOf: destination)
            #expect(read.colorSpaceModel == .rgb)
            // CoreGraphics resolved the embedded profile to its own sRGB, and
            // the file names that profile. Both matter: the first says the
            // tagging is recognised, the second that a profile is actually in
            // the file rather than assumed by the reader.
            #expect(read.colorSpaceName == CGColorSpace.sRGB as String)
            #expect(read.profileName?.contains("sRGB") == true)
            #expect(read.declaredOrientation == 1)
            #expect(
                read.tiffProperties[kCGImagePropertyTIFFMake] as? String
                    == "OLYMPUS IMAGING CORP."
            )
            #expect(read.tiffProperties[kCGImagePropertyTIFFModel] as? String == "E-PL3")
        }
    }

    @Test("Orientation metadata is upright even when the pixels were rotated")
    func orientationMetadataIsAlwaysUpright() throws {
        // The pixels here came through a quarter turn. The file must not also
        // ask its reader to turn them.
        let exposed = try ExportTestData.exposed(
            width: 2, height: 3,
            values: Array(repeating: 0.5, count: 18),
            orientation: .rotated90Clockwise
        )
        let image = try ExportImageEncoder().encode(exposed, settings: .standard)
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("rotated.tif")
            try Self.write(image, to: destination)
            let read = try TIFFPixelReader(contentsOf: destination)
            #expect(read.declaredOrientation == 1)
            #expect(read.width == 2)
            #expect(read.height == 3)
        }
    }

    @Test("Nothing about the adjustments is embedded in the file")
    func noAdjustmentMetadataIsEmbedded() throws {
        let image = try Self.encoded(
            width: 2, height: 1, values: Array(repeating: 0.5, count: 6)
        )
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("clean.tif")
            try Self.write(
                image,
                to: destination,
                adjustments: ImageAdjustments(
                    orientation: .quarterTurnRight, channelMix: .redBlueSwap
                )
            )
            let contents = try Data(contentsOf: destination)
            // No sidecar JSON, no XMP, no recipe. Searching the bytes is
            // crude and exactly right: it would catch any of them.
            for marker in ["schemaVersion", "channelMix", "iradjustments", "xmpmeta"] {
                #expect(contents.range(of: Data(marker.utf8)) == nil)
            }
        }
    }

    // MARK: - The receipt

    @Test("The result reports what was written and what it was written from")
    func theResultIsAReceipt() throws {
        let image = try Self.encoded(width: 1, height: 1, values: [-0.5, 0.5, 1.5])
        let adjustments = ImageAdjustments(
            orientation: .halfTurn,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1.25)
        )
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("receipt.tif")
            let result = try Self.write(image, to: destination, adjustments: adjustments)

            #expect(result.destination == destination)
            #expect(result.sourceURL == Self.sourceURL)
            #expect(result.adjustments == adjustments)
            #expect(result.pixelWidth == 1)
            #expect(result.pixelHeight == 1)
            #expect(result.bitsPerComponent == 16)
            #expect(result.channelCount == 3)
            #expect(result.clippedLowSampleCount == 1)
            #expect(result.clippedHighSampleCount == 1)
            #expect(result.clippedSampleCount == 2)
        }
    }

    // MARK: - File safety

    @Test("An existing file is replaced, not appended to or corrupted")
    func anExistingFileIsReplaced() throws {
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("replaced.tif")
            try Data("not a tiff at all".utf8).write(to: destination)

            let image = try Self.encoded(
                width: 2, height: 1, values: Array(repeating: 0.5, count: 6)
            )
            try Self.write(image, to: destination)

            let read = try TIFFPixelReader(contentsOf: destination)
            #expect(read.width == 2)
            #expect(read.samples == image.samples)
        }
    }

    @Test("A failed write leaves the destination exactly as it was")
    func aFailedWriteLeavesTheDestinationAlone() throws {
        try ExportTestData.withTemporaryDirectory { directory in
            // A destination inside a directory that does not exist: the
            // temporary file is written successfully, and the move fails.
            let missing = directory
                .appendingPathComponent("no-such-directory", isDirectory: true)
                .appendingPathComponent("out.tif")
            let image = try Self.encoded(
                width: 2, height: 1, values: Array(repeating: 0.5, count: 6)
            )
            #expect(throws: TIFFExportError.self) {
                try Self.write(image, to: missing)
            }
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }
    }

    @Test("An inconsistent image is refused before any file is touched")
    func anInconsistentImageIsRefusedFirst() throws {
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("never-written.tif")
            let broken = ExportEncodedImage(
                width: 4,
                height: 4,
                samples: [1, 2, 3],
                processing: ExportImageProcessing(
                    settings: .standard,
                    exposureProcessing: SceneLinearExposureProcessing(
                        exposure: .neutral,
                        orientationProcessing: DisplayPreviewTestData.orientationProcessing()
                    ),
                    clippedLowSampleCount: 0,
                    clippedHighSampleCount: 0
                )
            )
            #expect(throws: TIFFExportError.self) {
                try Self.write(broken, to: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("No temporary files are left behind")
    func noTemporaryFilesAreLeftBehind() throws {
        try ExportTestData.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("tidy.tif")
            let image = try Self.encoded(
                width: 2, height: 1, values: Array(repeating: 0.5, count: 6)
            )
            try Self.write(image, to: destination)
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
            #expect(contents.map(\.lastPathComponent) == ["tidy.tif"])
        }
    }

    // MARK: - The filename rule

    @Test("The suggested filename replaces the RAW extension")
    func theSuggestedFilenameReplacesTheExtension() {
        #expect(
            ExportDestinationPolicy.suggestedFilename(
                for: URL(fileURLWithPath: "/photos/OLYMPUS.ORF")
            ) == "OLYMPUS.tif"
        )
        #expect(
            ExportDestinationPolicy.suggestedFilename(
                for: URL(fileURLWithPath: "/photos/P1010101.orf")
            ) == "P1010101.tif"
        )
        // Never appended to the RAW name.
        #expect(
            ExportDestinationPolicy.suggestedFilename(
                for: URL(fileURLWithPath: "/photos/OLYMPUS.ORF")
            ) != "OLYMPUS.ORF.tif"
        )
        // A name with no extension keeps its name.
        #expect(
            ExportDestinationPolicy.suggestedFilename(
                for: URL(fileURLWithPath: "/photos/scan")
            ) == "scan.tif"
        )
        // And a dotted name loses only its last component.
        #expect(
            ExportDestinationPolicy.suggestedFilename(
                for: URL(fileURLWithPath: "/photos/2011.06.12-forest.ORF")
            ) == "2011.06.12-forest.tif"
        )
    }
}
