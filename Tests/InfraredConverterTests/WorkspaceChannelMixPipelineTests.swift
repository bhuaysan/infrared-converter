import Testing
import Foundation
@testable import InfraredConverter

/// Where the creative mix now runs, and what the workspace keeps.
///
/// The claim this milestone exists for is a boundary claim, so it is tested as
/// one:
///
/// ```text
/// prepare   … → reduce → RETAIN the pre-mix preview
/// render    retained pre-mix preview → mix → orientation → display
/// ```
///
/// The arithmetic of the mix itself belongs to `IRChannelMixerTests`; these
/// tests are about which stage runs in which half, how many times, and on
/// which buffer.
@Suite("Workspace channel-mix pipeline")
struct WorkspaceChannelMixPipelineTests {

    static let url = URL(fileURLWithPath: "/tmp/mix-pipeline.orf")

    /// A deliberately non-square mosaic whose samples all differ, so an
    /// orientation is identifiable from the pixels and a dimension swap cannot
    /// hide.
    static func decoder() -> WorkspaceStubDecoder {
        WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url, width: 8, height: 6))
        )
    }

    static func prepared() throws -> WorkspacePreviewPipeline.Source {
        try WorkspacePreviewPipeline().prepare(decoding: url, using: decoder())
    }

    // MARK: - The retained source is pre-mix

    /// The central claim. `prepare` stops at the reduction: the buffer it
    /// hands back has not been through the creative stage, so a mix asked for
    /// later is applied to the working-colour values themselves.
    @Test("prepare retains a source with no channel mix applied")
    func prepareRetainsAPreMixSource() throws {
        let source = try Self.prepared()

        // The type is the statement, and the record agrees with it: there is
        // no field on a pre-mix preview a mix could be recorded in.
        #expect(!source.preview.processing.channelMixApplied)
        #expect(source.preview.processing.reducedForPreview)
        #expect(source.preview.processing.sceneLinear)
        #expect(!source.preview.processing.gammaApplied)
        #expect(!source.preview.processing.orientationApplied)
        #expect(source.preview.isGeometryConsistent)
    }

    /// The negative form of the same claim, stated about the values rather
    /// than the provenance: the retained buffer is what the reducer produced,
    /// not what a mixer produced from it.
    @Test("The retained values are the reducer's output, unmixed")
    func theRetainedValuesAreUnmixed() throws {
        let source = try Self.prepared()

        let decoded = try Self.decoder().decodeMosaic(at: Self.url)
        let normalized = try RAWMosaicNormalizer().process(decoded)
        let region = WorkspacePreviewPipeline.centredNeutralPatch(
            width: normalized.mosaic.width, height: normalized.mosaic.height
        )
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: normalized.mosaic, region: region)
        let balanced = try RAWWhiteBalancer().apply(to: normalized, estimate: estimate)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)
        let working = try RAWWorkingColorConverter().convert(
            demosaiced.image, using: WorkspacePreviewPipeline.initialTransform
        )
        let reduced = try SceneLinearPreviewReducer().reduce(
            working, policy: WorkspacePreviewPipeline.previewPolicy
        )

        #expect(source.preview.values.count == reduced.values.count)
        #expect(
            zip(source.preview.values, reduced.values)
                .allSatisfy { $0.bitPattern == $1.bitPattern }
        )
    }

    // MARK: - render applies the mix exactly once

    @Test("render with the identity mix applies it once, and records it")
    func renderAppliesTheIdentityOnce() throws {
        let source = try Self.prepared()
        let preview = try WorkspacePreviewPipeline().render(
            source, adjustments: ImageAdjustments(channelMix: .identity)
        )

        #expect(preview.channelMixAdjustment == .identity)
        #expect(preview.channelMix == IRChannelMix.identity)
        #expect(preview.channelMix.source == .identity)
        #expect(preview.processing.channelMixApplied)
    }

    @Test("render with the red/blue swap applies it once, and records it")
    func renderAppliesTheSwapOnce() throws {
        let source = try Self.prepared()
        let preview = try WorkspacePreviewPipeline().render(
            source, adjustments: ImageAdjustments(channelMix: .redBlueSwap)
        )

        #expect(preview.channelMixAdjustment == .redBlueSwap)
        #expect(preview.channelMix == IRChannelMix.redBlueSwap)
        #expect(preview.channelMix.source == .redBlueSwap)
        #expect(preview.processing.channelMixApplied)
    }

    /// "Exactly once" as a statement about the pixels: the swap the pipeline
    /// performed is the swap a single mixer pass performs on the retained
    /// buffer. A second, composed application would give back the identity,
    /// and this is the assertion that would catch it.
    @Test("The rendered pixels are one mixer pass over the retained source")
    func theRenderedPixelsAreOnePass() throws {
        let source = try Self.prepared()
        let pipeline = WorkspacePreviewPipeline()

        for mix in [UserChannelMixAdjustment.identity, .redBlueSwap] {
            let rendered = try pipeline.render(
                source, adjustments: ImageAdjustments(channelMix: mix)
            )
            let byHand = try DisplayPreviewRenderer().render(
                try ImageOrienter().apply(
                    to: try IRChannelMixer().apply(to: source.preview, mix: mix.mix),
                    orientation: .upright
                ),
                settings: WorkspacePreviewPipeline.displaySettings(for: ImageAdjustments(channelMix: mix))
            )
            #expect(
                WorkspaceStubs.pixelBytes(rendered.image)
                    == WorkspaceStubs.pixelBytes(
                        try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand)
                    )
            )
        }
    }

    /// And the two renderings differ, which is what makes the comparison above
    /// worth making: a pipeline that ignored the mix would pass both halves of
    /// it with identical bytes.
    @Test("The identity and the swap produce different pixels")
    func theTwoMixesDiffer() throws {
        let source = try Self.prepared()
        let pipeline = WorkspacePreviewPipeline()
        let identity = try pipeline.render(
            source, adjustments: ImageAdjustments(channelMix: .identity)
        )
        let swapped = try pipeline.render(
            source, adjustments: ImageAdjustments(channelMix: .redBlueSwap)
        )
        #expect(
            WorkspaceStubs.pixelBytes(identity.image)
                != WorkspaceStubs.pixelBytes(swapped.image)
        )
    }

    /// Rendering reads the source; it never writes to it. Two renders with
    /// different mixes leave the retained buffer bit-identical, which is the
    /// property that makes the next mix an ordinary re-render.
    @Test("The retained source is bit-identical after both renders")
    func theRetainedSourceSurvivesBothRenders() throws {
        let source = try Self.prepared()
        let before = source.preview.values
        let pipeline = WorkspacePreviewPipeline()

        _ = try pipeline.render(source, adjustments: ImageAdjustments(channelMix: .identity))
        _ = try pipeline.render(source, adjustments: ImageAdjustments(channelMix: .redBlueSwap))
        _ = try pipeline.render(
            source,
            adjustments: ImageAdjustments(
                orientation: .quarterTurnRight, channelMix: .redBlueSwap
            )
        )

        #expect(source.preview.values.count == before.count)
        #expect(
            zip(source.preview.values, before).allSatisfy { $0.bitPattern == $1.bitPattern }
        )
        #expect(!source.preview.processing.channelMixApplied)
    }

    // MARK: - Pixel correctness, on a field a reader can check by hand

    /// Three clearly distinguishable channels, so "the mix moved the channels"
    /// is a statement about named numbers rather than about a difference.
    ///
    /// ```text
    /// R = 0.1   G = 0.4   B = 0.8
    /// ```
    ///
    /// Exactly representable? No — none of the three is a binary fraction. It
    /// does not need to be: the identity and the permutation paths move bit
    /// patterns without arithmetic, so the assertion is on bit patterns.
    static let sampleRed: Float = 0.1
    static let sampleGreen: Float = 0.4
    static let sampleBlue: Float = 0.8

    static func flatPreview(width: Int = 4, height: Int = 3) -> SceneLinearPreviewImage {
        PreviewTestData.preview(width: width, height: height) { _, _, channel in
            switch channel {
            case 0: return sampleRed
            case 1: return sampleGreen
            default: return sampleBlue
            }
        }
    }

    @Test("Identity leaves the three channels where they were")
    func identityKeepsTheChannels() throws {
        let mixed = try IRChannelMixer().apply(
            to: Self.flatPreview(), mix: UserChannelMixAdjustment.identity.mix
        )
        for row in 0..<mixed.height {
            for column in 0..<mixed.width {
                let pixel = try #require(mixed.pixel(row: row, column: column))
                #expect(pixel.red.bitPattern == Self.sampleRed.bitPattern)
                #expect(pixel.green.bitPattern == Self.sampleGreen.bitPattern)
                #expect(pixel.blue.bitPattern == Self.sampleBlue.bitPattern)
            }
        }
    }

    @Test("The red/blue swap exchanges red and blue and leaves green alone")
    func theSwapExchangesRedAndBlue() throws {
        let mixed = try IRChannelMixer().apply(
            to: Self.flatPreview(), mix: UserChannelMixAdjustment.redBlueSwap.mix
        )
        for row in 0..<mixed.height {
            for column in 0..<mixed.width {
                let pixel = try #require(mixed.pixel(row: row, column: column))
                #expect(pixel.red.bitPattern == Self.sampleBlue.bitPattern)
                #expect(pixel.green.bitPattern == Self.sampleGreen.bitPattern)
                #expect(pixel.blue.bitPattern == Self.sampleRed.bitPattern)
            }
        }
    }

    // MARK: - Mix and orientation are different kinds of change

    /// The mix changes **which channel** a value is in; the orientation
    /// changes **where** a pixel is. Combining them has to do both, and each
    /// has to do only its own.
    ///
    /// The field is a gradient, unique per pixel and per channel, so a moved
    /// pixel and an exchanged channel are both identifiable.
    @Test("A mix changes channels, an orientation changes positions")
    func theTwoAdjustmentsDoDifferentThings() throws {
        let width = 4
        let height = 3
        let preview = PreviewTestData.preview(width: width, height: height) {
            row, column, channel in
            Float(row * 100 + column * 10 + channel)
        }

        let mixed = try IRChannelMixer().apply(to: preview, mix: IRChannelMix.redBlueSwap)
        let oriented = try ImageOrienter().apply(
            to: mixed, orientation: .rotated90Clockwise
        )

        // Geometry: a quarter turn exchanges the dimensions.
        #expect(oriented.width == height)
        #expect(oriented.height == width)

        // For `.rotated90Clockwise` on a w x h source, destination (r, c)
        // comes from source (h - 1 - c, r).
        for row in 0..<oriented.height {
            for column in 0..<oriented.width {
                let sourceRow = height - 1 - column
                let sourceColumn = row
                let original = try #require(
                    preview.pixel(row: sourceRow, column: sourceColumn)
                )
                let moved = try #require(oriented.pixel(row: row, column: column))

                // The channels were exchanged by the mix...
                #expect(moved.red.bitPattern == original.blue.bitPattern)
                #expect(moved.green.bitPattern == original.green.bitPattern)
                #expect(moved.blue.bitPattern == original.red.bitPattern)
            }
        }
    }

    /// The order is mix, then orientation, and it is fixed. The two commute
    /// mathematically — a per-pixel colour map and a whole-pixel permutation
    /// cannot interfere — so the check is that both were applied and that the
    /// result is the one the documented order gives, not that reversing them
    /// would have been visibly wrong.
    @Test("Mixing then orienting agrees with orienting then mixing")
    func theTwoStagesCommute() throws {
        let preview = PreviewTestData.preview(width: 4, height: 3) { row, column, channel in
            Float(row * 100 + column * 10 + channel)
        }

        let mixedThenOriented = try ImageOrienter().apply(
            to: try IRChannelMixer().apply(to: preview, mix: .redBlueSwap),
            orientation: .rotated270Clockwise
        )

        // The other order, built by hand from the same values: orient the
        // pre-mix buffer, then exchange the channels of the result.
        let orientedFirst = try ImageOrienter().apply(
            to: try IRChannelMixer().apply(to: preview, mix: .identity),
            orientation: .rotated270Clockwise
        )
        var swappedAfterwards: [Float] = []
        swappedAfterwards.reserveCapacity(orientedFirst.values.count)
        for index in stride(from: 0, to: orientedFirst.values.count, by: 3) {
            swappedAfterwards.append(orientedFirst.values[index + 2])
            swappedAfterwards.append(orientedFirst.values[index + 1])
            swappedAfterwards.append(orientedFirst.values[index])
        }

        #expect(
            zip(mixedThenOriented.values, swappedAfterwards)
                .allSatisfy { $0.bitPattern == $1.bitPattern }
        )
    }

    // MARK: - Provenance

    /// A rendering says which mix it applied, and says it is creative. The
    /// camera transform's provenance is a separate fact and is unaffected.
    @Test("The rendered preview's provenance names the mix and keeps it creative")
    func theProvenanceNamesTheMix() throws {
        let source = PreviewTestData.source(Self.flatPreview())
        let pipeline = WorkspacePreviewPipeline()

        let swapped = try pipeline.render(
            source, adjustments: ImageAdjustments(channelMix: .redBlueSwap)
        )
        #expect(swapped.processing.mixSource == .redBlueSwap)
        #expect(swapped.processing.channelMixApplied)
        // The mix never turns the camera transform into a calibration.
        #expect(!swapped.processing.isValidatedInfraredCalibration)
        #expect(swapped.processing.cameraToWorkingTransformSource
            == .sensorRGBIdentityFalseColor)

        // An explicit matrix keeps `.explicit` even when it equals a built-in:
        // the execution path is decided by the value, the provenance by how the
        // decision was made.
        let explicitSwap = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0, 0, 1, 0, 1, 0, 1, 0, 0]
        )
        let explicit = try pipeline.render(
            source, adjustments: ImageAdjustments(channelMix: explicitSwap)
        )
        #expect(explicit.processing.mixSource == .explicit)
        #expect(explicit.channelMixAdjustment == explicitSwap)
        #expect(
            WorkspaceStubs.pixelBytes(explicit.image)
                == WorkspaceStubs.pixelBytes(swapped.image)
        )
    }

    /// The reduction record survives the mix untouched. A mix is not a
    /// reduction, and the finished preview still says what it was reduced
    /// from.
    @Test("The reduction record survives the mix")
    func theReductionRecordSurvives() throws {
        let source = try Self.prepared()
        let preview = try WorkspacePreviewPipeline().render(
            source, adjustments: ImageAdjustments(channelMix: .redBlueSwap)
        )
        #expect(preview.resolution == source.resolution)
        #expect(preview.resolution.sourceWidth == 8)
        #expect(preview.resolution.sourceHeight == 6)
    }

    // MARK: - Cancellation

    /// The mix is now on the interactive path, so a superseded one has to stop
    /// inside its pass. The contract is ADR 0011's, unchanged: one poll before
    /// anything is allocated, one per row, `CancellationError`, and never a
    /// partially written buffer.
    @Test(
        "A cancelled mix throws rather than returning a partial image",
        arguments: [
            UserChannelMixAdjustment.identity,
            .redBlueSwap,
        ]
    )
    func aCancelledMixThrows(mix: UserChannelMixAdjustment) throws {
        let preview = Self.flatPreview(width: 8, height: 8)
        let probe = CancellationProbe(cancelAfterPolls: 1)

        #expect(throws: CancellationError.self) {
            _ = try IRChannelMixer().apply(
                to: preview, mix: mix.mix, cancellation: probe.cancellation
            )
        }
        // Refused before anything was allocated: the first poll is the one
        // that fired.
        #expect(probe.pollCount == 1)
    }

    @Test("A general matrix is cancelled at a row boundary too")
    func aCancelledGeneralMixThrows() throws {
        let preview = Self.flatPreview(width: 8, height: 8)
        let mix = IRChannelMix.explicit(matrix: try PreviewTestData.asymmetricMatrix())
        let probe = CancellationProbe(cancelAfterPolls: 4)

        #expect(throws: CancellationError.self) {
            _ = try IRChannelMixer().apply(
                to: preview, mix: mix, cancellation: probe.cancellation
            )
        }
        // One poll before allocation, then one per row: it stopped after
        // three of the eight rows rather than finishing the frame.
        #expect(probe.pollCount == 4)
    }

    @Test(
        "An uncancelled mix polls once plus once per row, on every path",
        arguments: [
            UserChannelMixAdjustment.identity,
            .redBlueSwap,
        ]
    )
    func anUncancelledMixPollsPerRow(mix: UserChannelMixAdjustment) throws {
        let preview = Self.flatPreview(width: 4, height: 5)
        let probe = CancellationProbe()

        _ = try IRChannelMixer().apply(
            to: preview, mix: mix.mix, cancellation: probe.cancellation
        )
        #expect(probe.pollCount == 1 + preview.height)
    }

    @Test("The general path polls once plus once per row too")
    func theGeneralPathPollsPerRow() throws {
        let preview = Self.flatPreview(width: 4, height: 5)
        let probe = CancellationProbe()

        _ = try IRChannelMixer().apply(
            to: preview,
            mix: IRChannelMix.explicit(matrix: try PreviewTestData.asymmetricMatrix()),
            cancellation: probe.cancellation
        )
        #expect(probe.pollCount == 1 + preview.height)
    }
}
