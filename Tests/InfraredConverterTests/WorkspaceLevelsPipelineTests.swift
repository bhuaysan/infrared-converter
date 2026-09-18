import Testing
import Foundation
@testable import InfraredConverter

/// Levels in the interactive half of the pipeline.
///
/// ```text
/// retained pre-mix preview → mix → orientation → exposure → LEVELS → display
/// ```
///
/// `LinearLevelsApplierTests` owns the arithmetic. What these tests establish
/// is that the **workspace** passes the user's pair to that stage unchanged,
/// in the right place — after exposure, before the range policy — and that the
/// preview's provenance says so.
///
/// The pixels are compared two ways: against the same stages called by hand,
/// and against `DisplayPreviewTestData`'s reference arithmetic, which is
/// written from the specification rather than by calling production code.
@Suite("Workspace levels pipeline")
struct WorkspaceLevelsPipelineTests {

    static func levels(_ black: Double, _ white: Double) throws -> UserLevelsAdjustment {
        try UserLevelsAdjustment(blackPoint: black, whitePoint: white)
    }

    static func exposure(_ ev: Double) throws -> UserExposureAdjustment {
        try UserExposureAdjustment(ev: ev)
    }

    /// Three pixels, with values below zero, inside the display range and
    /// above one. Every value is a binary fraction, so `× 2^n` is exact in
    /// `Float32`.
    static let values: [Float] = [
        0.125, 0.25, 0.375,
        0.0625, 0.75, 1.5,
        -0.25, 0.5, 0.03125,
    ]

    static func source(
        _ values: [Float], width: Int = 3, height: Int = 1
    ) -> WorkspacePreviewPipeline.Source {
        PreviewTestData.source(PreviewTestData.preview(width: width, height: height, values: values))
    }

    /// The workspace's render stages, called one by one with the values the
    /// pipeline would derive for `adjustments`.
    static func byHand(
        _ source: WorkspacePreviewPipeline.Source,
        mix: IRChannelMix = .identity,
        orientation: RAWImageOrientation = .upright,
        adjustments: ImageAdjustments
    ) throws -> DisplayEncodedPreviewImage {
        try DisplayPreviewRenderer().render(
            try GlobalContrastApplier().apply(
              to: try LinearLevelsApplier().apply(
                to: try SceneLinearExposer().apply(
                    to: try ImageOrienter().apply(
                        to: try IRChannelMixer().apply(to: source.preview, mix: mix),
                        orientation: orientation
                    ),
                    exposure: SceneLinearExposure(adjustments.exposure)
                ),
                levels: LinearLevels(adjustments.levels)
              ),
              curve: GlobalContrastCurve(adjustments.contrast)
            ),
            settings: WorkspacePreviewPipeline.displaySettings
        )
    }

    /// The reference encoding, per component, computed from the
    /// specification: expose, level, clip, encode, quantise, in that order.
    static func reference(
        _ values: [Float], exposureEV: Double = 0, black: Double = 0, white: Double = 1
    ) -> [UInt8] {
        values.map {
            DisplayPreviewTestData.referenceSample(
                sceneLinear: $0, exposureEV: exposureEV, blackPoint: black, whitePoint: white
            )
        }
    }

    static func bytes(_ image: DisplayEncodedPreviewImage) -> [UInt8] { [UInt8](image.bytes) }

    // MARK: - The workspace applies the user's pair

    @Test("The pipeline applies the user's levels, and nothing else does")
    func thePipelineAppliesTheUsersLevels() throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)
        let adjustments = ImageAdjustments(levels: try Self.levels(0.1, 0.9))

        let rendered = try pipeline.render(source, adjustments: adjustments)
        let byHand = try Self.byHand(source, adjustments: adjustments)

        #expect(
            WorkspaceStubs.pixelBytes(rendered.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand)
                )
        )
        // And the bytes are the specification's, not merely self-consistent.
        #expect(Self.bytes(byHand) == Self.reference(Self.values, black: 0.1, white: 0.9))

        // The stage was asked for exactly the user's pair, and it recorded it.
        #expect(rendered.renderedLevels.blackPoint == 0.1)
        #expect(rendered.renderedLevels.whitePoint == 0.9)
        #expect(rendered.processing.levelsApplied)
        // The requested decision and the rendered one are two facts, kept
        // separately readable, and here they agree.
        #expect(rendered.levelsAdjustment == adjustments.levels)
        #expect(rendered.renderedLevels == LinearLevels(rendered.levelsAdjustment))
    }

    @Test("Neutral levels render exactly what no levels decision would have rendered")
    func neutralLevelsAreTheIdentity() throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)

        let neutral = try pipeline.render(source, adjustments: .none)
        let explicitlyNeutral = try pipeline.render(
            source, adjustments: ImageAdjustments(levels: .neutral)
        )

        #expect(
            WorkspaceStubs.pixelBytes(neutral.image)
                == WorkspaceStubs.pixelBytes(explicitlyNeutral.image)
        )
        // Which is also the pre-milestone rendering: exposure, then the clip,
        // then the encoding, with nothing between them.
        #expect(
            Self.bytes(try Self.byHand(source, adjustments: .none))
                == Self.reference(Self.values)
        )
        // Recorded as applied even so. Traversing the stage and asking for the
        // identity is a different fact from never running it.
        #expect(neutral.processing.levelsApplied)
        #expect(neutral.renderedLevels.isIdentity)
    }

    // MARK: - Order: after exposure

    /// Shown as an equivalence that only holds in this order. Rendering the
    /// source at `+1 EV` with a given pair is byte-identical to rendering the
    /// source pre-multiplied by two at `0 EV` with the **same** pair — which
    /// is true precisely because the exposure happens first and the levels
    /// then see the exposed value.
    ///
    /// Reversing the two stages would break it:
    /// `(2x − b)/(w − b) ≠ 2·((x − b)/(w − b))` for any `b ≠ 0`.
    @Test(
        "Levels are applied to the exposed value, not to the unexposed one",
        arguments: [(1.0, Float(2)), (-1.0, Float(0.5)), (2.0, Float(4))]
    )
    func levelsFollowExposure(ev: Double, factor: Float) throws {
        let pipeline = WorkspacePreviewPipeline()
        let pair = try Self.levels(0.125, 0.875)

        let exposedThenLevelled = try pipeline.render(
            Self.source(Self.values),
            adjustments: ImageAdjustments(exposure: try Self.exposure(ev), levels: pair)
        )
        let preScaled = try pipeline.render(
            Self.source(Self.values.map { $0 * factor }),
            adjustments: ImageAdjustments(levels: pair)
        )

        #expect(
            WorkspaceStubs.pixelBytes(exposedThenLevelled.image)
                == WorkspaceStubs.pixelBytes(preScaled.image)
        )
        #expect(exposedThenLevelled.renderedExposureEV == ev)
        #expect(exposedThenLevelled.renderedLevels.blackPoint == 0.125)
    }

    /// The other direction, stated numerically: the two orders genuinely
    /// differ, so the equivalence above is evidence rather than a tautology.
    @Test("Levelling before exposing would give different pixels")
    func theTwoOrdersDiffer() throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)
        let pair = try Self.levels(0.125, 0.875)

        let asShipped = try pipeline.render(
            source,
            adjustments: ImageAdjustments(exposure: try Self.exposure(1), levels: pair)
        )

        // The reversed order, computed here by hand: level the oriented image
        // first, then double it.
        let mixed = try IRChannelMixer().apply(to: source.preview, mix: .identity)
        let oriented = try ImageOrienter().apply(to: mixed, orientation: .upright)
        let levelledFirst = try LinearLevelsApplier().apply(
            to: try SceneLinearExposer().apply(to: oriented, exposure: .neutral),
            levels: LinearLevels(pair)
        )
        let reversed = try DisplayPreviewRenderer().render(
            DisplayPreviewTestData.toneCurvedImage(
                width: levelledFirst.width,
                height: levelledFirst.height,
                values: levelledFirst.values.map { Float(Double($0) * 2) }
            ),
            settings: WorkspacePreviewPipeline.displaySettings
        )

        #expect(
            WorkspaceStubs.pixelBytes(asShipped.image)
                != WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: reversed)
                )
        )
    }

    // MARK: - Order: before the range policy

    /// Levels decide what clips, because they happen before the clip and do
    /// not clip themselves. The counts are the evidence: the same source, two
    /// pairs, and the number of destroyed components moves.
    @Test("Levels decide what clips, and the clipping is counted downstream")
    func levelsDecideWhatClips() throws {
        let pipeline = WorkspacePreviewPipeline()
        // Three components at 0.5, nothing out of range on its own.
        let source = Self.source([0.5, 0.5, 0.5], width: 1, height: 1)

        let neutral = try pipeline.render(source, adjustments: .none)
        #expect(neutral.processing.clippedHighSampleCount == 0)
        #expect(neutral.processing.clippedLowSampleCount == 0)

        // A white point of 0.25 puts every component above 1.
        let blown = try pipeline.render(
            source, adjustments: ImageAdjustments(levels: try Self.levels(0, 0.25))
        )
        #expect(blown.processing.clippedHighSampleCount == 3)
        #expect(blown.processing.clippedLowSampleCount == 0)
        #expect(Self.bytes(try Self.byHand(
            source, adjustments: ImageAdjustments(levels: try Self.levels(0, 0.25))
        )) == [255, 255, 255])

        // A black point of 0.75 puts every component below 0.
        let crushed = try pipeline.render(
            source, adjustments: ImageAdjustments(levels: try Self.levels(0.75, 1))
        )
        #expect(crushed.processing.clippedLowSampleCount == 3)
        #expect(crushed.processing.clippedHighSampleCount == 0)
    }

    /// The stage itself does not clip; the destination does. Proven by asking
    /// for two different out-of-range results and seeing them arrive at the
    /// encoder as different numbers, which a clip inside the stage would have
    /// made equal.
    @Test("The levels stage hands out-of-range values on rather than clipping them")
    func theStageDoesNotClip() throws {
        let source = Self.source([0.0, 0.25, 0.5], width: 1, height: 1)
        let mixed = try IRChannelMixer().apply(to: source.preview, mix: .identity)
        let oriented = try ImageOrienter().apply(to: mixed, orientation: .upright)
        let exposed = try SceneLinearExposer().apply(to: oriented, exposure: .neutral)
        let levelled = try LinearLevelsApplier().apply(
            to: exposed, levels: LinearLevels(blackPoint: 0.5, whitePoint: 1)
        )

        // −1, −0.5 and 0 — three distinct values, two of them out of range.
        #expect(levelled.values[0] == -1)
        #expect(levelled.values[1] == -0.5)
        #expect(levelled.values[2] == 0)
        #expect(!levelled.processing.clamped)

        // And the clip that follows makes the first two indistinguishable,
        // which is exactly why it must not happen upstream.
        let encoded = try DisplayPreviewRenderer().render(
            try GlobalContrastApplier().apply(to: levelled, curve: .neutral),
            settings: WorkspacePreviewPipeline.displaySettings
        )
        #expect(Array(encoded.bytes) == [0, 0, 0])
        #expect(encoded.processing.clippedLowSampleCount == 2)
    }

    // MARK: - No composition

    /// A second pair is applied to the retained pre-mix preview, never to the
    /// result of the first. Two affine maps compose into a third perfectly
    /// valid affine map, which is why this would never look malformed.
    @Test("A second levels setting restarts from the retained preview")
    func levelsNeverCompose() throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)
        let first = try Self.levels(0.1, 0.9)
        let second = try Self.levels(0.2, 1.5)

        let afterFirst = try pipeline.render(
            source, adjustments: ImageAdjustments(levels: first)
        )
        let afterSecond = try pipeline.render(
            source, adjustments: ImageAdjustments(levels: second)
        )
        let directly = try pipeline.render(
            Self.source(Self.values), adjustments: ImageAdjustments(levels: second)
        )

        #expect(
            WorkspaceStubs.pixelBytes(afterSecond.image)
                == WorkspaceStubs.pixelBytes(directly.image)
        )
        #expect(
            WorkspaceStubs.pixelBytes(afterSecond.image)
                != WorkspaceStubs.pixelBytes(afterFirst.image)
        )
        // The composition of the two is itself a valid single pair, which is
        // exactly why chaining would never look malformed. Applying L1 then
        // L2 is the same as applying this — and it is *not* what the pipeline
        // produced.
        //
        //   L2(L1(x)) = (x − b1 − b2(w1 − b1)) / ((w1 − b1)(w2 − b2))
        //             = levels(b1 + b2(w1 − b1), b1 + w2(w1 − b1))(x)
        let span = first.whitePoint - first.blackPoint
        let composedBlack = first.blackPoint + second.blackPoint * span
        let composedWhite = first.blackPoint + second.whitePoint * span
        #expect(
            Self.bytes(try Self.byHand(source, adjustments: ImageAdjustments(levels: second)))
                != Self.reference(Self.values, black: composedBlack, white: composedWhite)
        )
        // …and that composed pair is a perfectly ordinary one, so nothing
        // about the wrong answer would have looked broken.
        #expect(composedBlack < composedWhite)
        #expect(LinearLevels(blackPoint: composedBlack, whitePoint: composedWhite).isApplicable)

        // Returning to neutral reproduces the untouched rendering exactly.
        #expect(Self.bytes(try Self.byHand(source, adjustments: .none))
            == Self.reference(Self.values))
    }

    // MARK: - Alongside every other adjustment

    /// Levels are applied identically whatever the creative mix is: there is
    /// no infrared path, no monochrome path and no per-mix behaviour.
    @Test(
        "Levels behave identically after every kind of channel mix",
        arguments: [
            UserChannelMixAdjustment.identity,
            .redBlueSwap,
        ]
    )
    func levelsAreIndependentOfTheMix(mix: UserChannelMixAdjustment) throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)
        let adjustments = ImageAdjustments(
            channelMix: mix, levels: try Self.levels(0.1, 0.9)
        )

        let rendered = try pipeline.render(source, adjustments: adjustments)
        let byHand = try Self.byHand(source, mix: mix.mix, adjustments: adjustments)
        #expect(
            WorkspaceStubs.pixelBytes(rendered.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand)
                )
        )
    }

    /// The same for an authored matrix and for a monochrome one, which is an
    /// authored matrix whose three rows are identical. Neither has a path of
    /// its own.
    @Test("Levels behave identically after an authored and a monochrome matrix")
    func levelsAreIndependentOfAnAuthoredMatrix() throws {
        let pipeline = WorkspacePreviewPipeline()
        let authored = UserChannelMixAdjustment.explicit(
            try RAWColorMatrix3x3(
                m00: 1.5, m01: -0.25, m02: 0.125,
                m10: 0.25, m11: 0.75, m12: 0.5,
                m20: -0.5, m21: 0.25, m22: 1.25
            )
        )
        let monochrome = UserChannelMixAdjustment.explicit(
            try RAWColorMatrix3x3(
                m00: 0.5, m01: 0.25, m02: 0.25,
                m10: 0.5, m11: 0.25, m12: 0.25,
                m20: 0.5, m21: 0.25, m22: 0.25
            )
        )

        for mix in [authored, monochrome] {
            let source = Self.source(Self.values)
            let adjustments = ImageAdjustments(
                channelMix: mix, exposure: try Self.exposure(0.5), levels: try Self.levels(-0.1, 1.2)
            )
            let rendered = try pipeline.render(source, adjustments: adjustments)
            let byHand = try Self.byHand(source, mix: mix.mix, adjustments: adjustments)
            #expect(
                WorkspaceStubs.pixelBytes(rendered.image)
                    == WorkspaceStubs.pixelBytes(
                        try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand)
                    )
            )
            #expect(rendered.renderedLevels.blackPoint == -0.1)
        }
    }

    @Test("Levels are applied after the orientation, and change no geometry")
    func levelsChangeNoGeometry() throws {
        let pipeline = WorkspacePreviewPipeline()
        let source = Self.source(Self.values)
        let adjustments = ImageAdjustments(
            orientation: .quarterTurnRight, levels: try Self.levels(0.1, 0.9)
        )

        let rendered = try pipeline.render(source, adjustments: adjustments)
        #expect(rendered.pixelWidth == 1)
        #expect(rendered.pixelHeight == 3)
        #expect(rendered.processing.orientationApplied)
        #expect(!rendered.processing.levelsProcessing.scaled)
        #expect(!rendered.processing.levelsProcessing.cropped)
        #expect(!rendered.processing.levelsProcessing.interpolated)

        let byHand = try Self.byHand(
            source, orientation: .rotated90Clockwise, adjustments: adjustments
        )
        #expect(
            WorkspaceStubs.pixelBytes(rendered.image)
                == WorkspaceStubs.pixelBytes(
                    try DisplayPreviewCGImageAdapter.makeCGImage(from: byHand)
                )
        )
    }

    // MARK: - The application's own choices

    /// The display settings are now a constant: nothing a user chooses reaches
    /// them. That is the visible trace of exposure and levels having become
    /// stages of their own.
    @Test("The display settings carry no adjustment at all")
    func displaySettingsCarryNoAdjustment() {
        #expect(WorkspacePreviewPipeline.displaySettings.rangePolicy == .hardClipToDisplayRange)
        #expect(WorkspacePreviewPipeline.displaySettings.encoding == .sRGB)
        #expect(WorkspacePreviewPipeline.displaySettings == DisplayRenderSettings.standard)
    }
}
