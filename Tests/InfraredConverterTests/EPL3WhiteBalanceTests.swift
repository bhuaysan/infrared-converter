import Testing
import CryptoKit
import Foundation
@testable import InfraredConverter

/// The interactive white balance on a real photograph.
///
/// > A user-selected neutral region must become canonical image state, must
/// > drive both preview and full-resolution export through the same
/// > mosaic-domain estimator, and changing that region must not require
/// > re-decoding the RAW file.
///
/// Every test works on an **isolated copy** of the fixture in a temporary
/// directory, so whatever a developer has saved beside their own
/// `RAW/OLYMPUS.ORF` cannot change what these tests see, and nothing is ever
/// written into `RAW/`.
///
/// Deliberately not pinned: exact photographic values. The gains depend on
/// what is in the middle of one particular frame, and asserting `3.81` would
/// be a test of that photograph rather than of this code. What is asserted is
/// what the architecture promises — the same region, the same gains, finite
/// results, one decode.
@Suite(
    "E-PL3 interactive white balance",
    .requiresRAWFixture,
    .serialized
)
struct EPL3WhiteBalanceTests {

    static let fullWidth = 4056
    static let fullHeight = 3040
    static let previewWidth = 2048
    static let previewHeight = 1535

    /// A patch well away from the centre, so it measures genuinely different
    /// samples from the default — and safely inside the frame, so it is a
    /// selection rather than an edge case.
    static func customPatch() throws -> UserWhiteBalanceAdjustment {
        .neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.15, originY: 0.2, width: 0.05, height: 0.0625
            )
        )
    }

    static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func withIsolatedFixture<T>(_ body: (URL) throws -> T) throws -> T {
        try RAWFixtures.withIsolatedCopy(body)
    }

    // MARK: - The default still does what it always did

    /// The backward-compatibility claim, on the real geometry: a file with no
    /// saved decision measures the same 190-sample square this project has
    /// always measured.
    @Test("The default patch is the historical centred square, on the real sensor")
    func theDefaultIsUnchanged() throws {
        try Self.withIsolatedFixture { url in
            let source = try WorkspacePreviewPipeline().prepare(
                decoding: url, using: LibRawDecoder()
            )

            #expect(source.whiteBalance == .defaultNeutralPatch)
            #expect(source.neutralPatch.width == 190)
            #expect(source.neutralPatch.height == 190)
            #expect(source.neutralPatch.originRow == 1425)
            #expect(source.neutralPatch.originColumn == 1933)
            #expect(
                source.neutralPatch
                    == UserWhiteBalanceAdjustment.defaultRegion(
                        width: Self.fullWidth, height: Self.fullHeight
                    )
            )
            try source.estimate.gains.validate()
        }
    }

    // MARK: - A custom patch

    @Test("A custom patch measures where it says and produces usable gains")
    func aCustomPatchIsMeasuredWhereItSays() throws {
        try Self.withIsolatedFixture { url in
            let patch = try Self.customPatch()
            let source = try WorkspacePreviewPipeline().prepare(
                decoding: url, using: LibRawDecoder(), whiteBalance: patch
            )

            #expect(source.whiteBalance == patch)
            #expect(
                source.neutralPatch
                    == (try patch.resolvedRegion(
                        activeAreaWidth: Self.fullWidth, activeAreaHeight: Self.fullHeight
                    ))
            )
            // Every gain is finite, positive and usable — the estimator's own
            // contract, on real samples.
            try source.estimate.gains.validate()
            for gain in source.estimate.gains.gainsByColorPlane {
                #expect(gain.isFinite)
                #expect(gain > 0)
            }
            // Every plane the RGBG layout produces was measured, including the
            // second green.
            #expect(source.estimate.statistics.measuredColorPlanes == [0, 1, 2, 3])

            // The preview still renders, at the size the policy says.
            let preview = try WorkspacePreviewPipeline().render(
                source, adjustments: ImageAdjustments(whiteBalance: patch)
            )
            #expect(preview.pixelWidth == Self.previewWidth)
            #expect(preview.pixelHeight == Self.previewHeight)
            #expect(preview.whiteBalanceAdjustment == patch)
        }
    }

    @Test("A custom patch renders a different photograph from the default one")
    func aCustomPatchChangesThePicture() throws {
        try Self.withIsolatedFixture { url in
            let decoder = LibRawDecoder()
            let patch = try Self.customPatch()

            let base = try RAWBasePreparationPipeline().prepare(
                decoding: url, using: decoder
            )
            let pipeline = WorkspacePreviewPipeline()
            let profile = IRCaptureProfile.builtinUncalibrated
            let withDefault = try pipeline.prepareSource(
                base, whiteBalance: .defaultNeutralPatch, captureProfile: profile
            )
            let withPatch = try pipeline.prepareSource(
                base, whiteBalance: patch, captureProfile: profile
            )

            #expect(withDefault.estimate.gains != withPatch.estimate.gains)
            #expect(withDefault.preview.values != withPatch.preview.values)

            // And picking the same patch twice from the same mosaic is
            // deterministic: gains never compound, because the second estimate
            // reads the same unbalanced samples as the first.
            let again = try pipeline.prepareSource(
                base, whiteBalance: patch, captureProfile: profile
            )
            #expect(again.estimate.gains == withPatch.estimate.gains)
            #expect(again.preview.values == withPatch.preview.values)
        }
    }

    // MARK: - The export

    @Test("The export resolves and measures the same patch as the preview")
    func theExportAgreesWithThePreview() throws {
        try Self.withIsolatedFixture { url in
            let decoder = LibRawDecoder()
            let patch = try Self.customPatch()
            let adjustments = ImageAdjustments(
                orientation: .quarterTurnRight,
                channelMix: .redBlueSwap,
                exposure: try UserExposureAdjustment(ev: 0.5),
                whiteBalance: patch
            )

            let preview = try WorkspacePreviewPipeline().render(
                decoding: url, using: decoder, adjustments: adjustments
            )
            let export = try FullResolutionExportPipeline().render(
                ExportRequest(rawURL: url, adjustments: adjustments), using: decoder
            )

            // The same region and the same multipliers, bit for bit: one
            // resolver, one estimator, two paths.
            #expect(export.neutralPatch == preview.neutralPatch)
            #expect(export.whiteBalanceGains == preview.whiteBalanceGains)
            #expect(export.estimate.targetMean == preview.estimate.targetMean)
            #expect(export.estimate.statistics == preview.estimate.statistics)

            // And the export really is full resolution, oriented as asked.
            #expect(export.pixelWidth == Self.fullHeight)
            #expect(export.pixelHeight == Self.fullWidth)
            #expect(export.mix == preview.channelMix)
            #expect(export.exposureEV == preview.renderedExposureEV)
        }
    }

    @Test("A full export with a custom patch writes a 16-bit file")
    func aCustomPatchExportWritesAFile() throws {
        try Self.withIsolatedFixture { url in
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("custom-patch.tiff")
            let before = try Self.digest(of: url)

            let result = try FullResolutionExportPipeline().export(
                ExportRequest(
                    rawURL: url,
                    adjustments: ImageAdjustments(whiteBalance: try Self.customPatch())
                ),
                to: destination,
                using: LibRawDecoder()
            )

            #expect(result.pixelWidth == Self.fullWidth)
            #expect(result.pixelHeight == Self.fullHeight)
            #expect(result.bitsPerComponent == 16)
            #expect(FileManager.default.fileExists(atPath: destination.path))

            // The RAW file is an immutable input, and an export is not an
            // edit: the bytes are unchanged and no sidecar appeared.
            #expect(try Self.digest(of: url) == before)
            let contents = try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path
            ).sorted()
            #expect(contents == [destination.lastPathComponent, url.lastPathComponent].sorted())
        }
    }

    // MARK: - The performance claim, on the real file

    /// One decode for the open, and none for either patch — on a twelve
    /// megapixel file, where a re-decode would be seconds rather than
    /// milliseconds.
    @Test("Two patches and a reset decode the real RAW file exactly once")
    func changingThePatchNeverRedecodes() throws {
        try Self.withIsolatedFixture { url in
            let decoder = CountingLibRawDecoder()
            let pipeline = WorkspacePreviewPipeline()

            let base = try pipeline.prepareBase(decoding: url, using: decoder)
            #expect(decoder.mosaicDecodeCount == 1)

            let profile = IRCaptureProfile.builtinUncalibrated
            _ = try pipeline.prepareSource(
                base, whiteBalance: .defaultNeutralPatch, captureProfile: profile
            )
            _ = try pipeline.prepareSource(
                base, whiteBalance: try Self.customPatch(), captureProfile: profile
            )
            _ = try pipeline.prepareSource(
                base, whiteBalance: .defaultNeutralPatch, captureProfile: profile
            )

            #expect(decoder.mosaicDecodeCount == 1)
        }
    }

    /// What the workspace holds after an open: one normalised mosaic and one
    /// reduced preview, and nothing that reaches a full-resolution RGB chain.
    @Test("The retained state is one mosaic and one reduced preview")
    func theRetainedStateIsTwoBuffers() throws {
        try Self.withIsolatedFixture { url in
            let base = try RAWBasePreparationPipeline().prepare(
                decoding: url, using: LibRawDecoder()
            )
            let source = try WorkspacePreviewPipeline().prepareSource(
                base,
                whiteBalance: .defaultNeutralPatch,
                captureProfile: .builtinUncalibrated
            )

            // The mosaic: one Float32 per sample, and no decoded UInt16 buffer
            // reachable from it.
            #expect(
                Mirror(reflecting: base).children.compactMap(\.label)
                    == ["mosaic", "metadata", "url"]
            )
            #expect(base.mosaic.values.count == Self.fullWidth * Self.fullHeight)
            #expect(base.activeAreaWidth == Self.fullWidth)
            #expect(base.activeAreaHeight == Self.fullHeight)

            // The preview: one reduced RGB buffer, and no upstream chain.
            //
            // `captureProfile` joined the list in the capture-profile milestone
            // and is a description rather than a buffer: the profile these
            // pixels were prepared under, which the workspace compares against
            // a newly selected one to decide whether they are still valid. See
            // `docs/decisions/0020-ir-capture-profile-foundation.md`,
            // Decision 10. Nothing here reaches a full-resolution image.
            #expect(
                Mirror(reflecting: source).children.compactMap(\.label)
                    == ["preview", "metadata", "url", "captureProfile", "whiteBalance",
                        "estimate"]
            )
            #expect(
                source.preview.values.count
                    == Self.previewWidth * Self.previewHeight * 3
            )

            // Roughly 49 MB and roughly 36 MB, which is the trade ADR 0019
            // states. Asserted as element counts rather than as bytes, because
            // the element counts are what the code controls.
            let mosaicBytes = base.mosaic.values.count * MemoryLayout<Float>.size
            let previewBytes = source.preview.values.count * MemoryLayout<Float>.size
            #expect(mosaicBytes > 48_000_000 && mosaicBytes < 51_000_000)
            #expect(previewBytes > 35_000_000 && previewBytes < 38_000_000)
        }
    }

    // MARK: - Persistence, through a real sidecar

    /// A saved patch is read before anything is decoded, so the **first**
    /// preview is the one the user saved — not a default one that is replaced.
    @Test("A saved patch reopens as itself, with no default-balanced first pass")
    func aSavedPatchReopensAsItself() throws {
        try Self.withIsolatedFixture { url in
            let store = JSONSidecarPhotographProcessingStore()
            let patch = try Self.customPatch()
            let saved = ImageAdjustments(
                orientation: .halfTurn,
                channelMix: .redBlueSwap,
                exposure: try UserExposureAdjustment(ev: -0.25),
                whiteBalance: patch
            )
            try store.save(PhotographProcessingState(adjustments: saved), for: url)

            let loaded = try #require(try store.load(for: url))
            #expect(loaded.adjustments == saved)
            // The profile half travels with them, and is the built-in
            // uncalibrated one: the only processing this project has ever done.
            #expect(loaded.captureProfile == .builtinUncalibrated)
            #expect(loaded.adjustments.whiteBalance == patch)

            // The first preparation there is uses that patch.
            let source = try WorkspacePreviewPipeline().prepare(
                decoding: url,
                using: LibRawDecoder(),
                whiteBalance: loaded.adjustments.whiteBalance
            )
            #expect(source.whiteBalance == patch)
            #expect(
                source.neutralPatch
                    == (try patch.resolvedRegion(
                        activeAreaWidth: Self.fullWidth, activeAreaHeight: Self.fullHeight
                    ))
            )
        }
    }

    /// A version 3 sidecar — written before the white balance was adjustable —
    /// reopens with the same centred patch it was saved against.
    @Test("A version 3 sidecar reopens with the historical centred patch")
    func aVersionThreeSidecarMigrates() throws {
        try Self.withIsolatedFixture { url in
            let sidecar = JSONSidecarPhotographProcessingStore.sidecarURL(for: url)
            try Data(
                #"""
                {
                  "schemaVersion": 3,
                  "orientation": "rotate90Clockwise",
                  "channelMix": { "kind": "redBlueSwap" },
                  "exposureEV": 1.0
                }
                """#.utf8
            ).write(to: sidecar)

            let loaded = try #require(
                try JSONSidecarPhotographProcessingStore().load(for: url)
            )
            #expect(loaded.adjustments.whiteBalance == .defaultNeutralPatch)

            let source = try WorkspacePreviewPipeline().prepare(
                decoding: url,
                using: LibRawDecoder(),
                whiteBalance: loaded.adjustments.whiteBalance
            )
            // The same 190-sample square version 3 was rendered with.
            #expect(source.neutralPatch.width == 190)
            #expect(source.neutralPatch.originRow == 1425)
            #expect(source.neutralPatch.originColumn == 1933)

            // Reading changed nothing on disk: the record is still version 3
            // until a decision renders and is saved.
            let text = try String(contentsOf: sidecar, encoding: .utf8)
            #expect(text.contains("\"schemaVersion\": 3"))
            #expect(!text.contains("whiteBalance"))
        }
    }
}

/// A `LibRawDecoder` that counts what it was asked to do.
///
/// The fixture counterpart of `CountingStubDecoder`: the decode is the real
/// one, so the count is a count of real work.
final class CountingLibRawDecoder: RAWDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var mosaicDecodes = 0
    private let wrapped = LibRawDecoder()

    var mosaicDecodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mosaicDecodes
    }

    func readMetadata(at url: URL) throws -> RAWMetadata {
        try wrapped.readMetadata(at: url)
    }

    func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
        try wrapped.decode(at: url, options: options)
    }

    func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
        lock.lock()
        mosaicDecodes += 1
        lock.unlock()
        return try wrapped.decodeMosaic(at: url)
    }
}
