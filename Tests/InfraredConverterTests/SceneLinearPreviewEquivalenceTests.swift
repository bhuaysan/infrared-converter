import Testing
import Foundation
@testable import InfraredConverter

/// The architectural claim the choice of reduction point rests on:
///
/// ```text
/// reduce(M · image)  ==  M · reduce(image)
/// ```
///
/// for the per-pixel linear maps that sit between demosaicing and orientation —
/// the camera-to-working transform and the creative channel mix. Both are 3x3
/// matrices with no offset term, and an area-weighted mean is a weighted sum,
/// so matrix multiplication distributes over it.
///
/// That is why reducing *before* those stages is free of consequence for the
/// pixels: the point was chosen for cost and for what a future adjustment can
/// still change, not because it renders differently. A claim of that kind
/// written only in an ADR is a hope, so it is checked here on the exact matrix
/// and mix representations the code uses.
///
/// ## What is not claimed
///
/// That reduction commutes with *everything*. It does not commute with
/// demosaicing — which is why the reduction is downstream of it — and it would
/// not commute with a transfer function, a clip or any other non-linear
/// operation. It is checked here only for the stages whose commutation the
/// design actually relies on.
@Suite("Preview reduction and per-pixel linear stages commute")
struct SceneLinearPreviewEquivalenceTests {

    /// Accumulation order differs between the two sides — one averages then
    /// multiplies, the other multiplies then averages — so exact equality is
    /// not the claim. A few ULPs relative to the magnitudes involved is.
    static let tolerance: Float = 2e-5

    static let sourceWidth = 60
    static let sourceHeight = 44
    static let previewWidth = 15
    static let previewHeight = 11

    /// A deliberately structured field: every channel varies differently, so a
    /// mistake that treated the channels alike would not cancel out.
    static func sample(row: Int, column: Int, channel: Int) -> Float {
        switch channel {
        case 0: return Float(row) * 0.031 - Float(column) * 0.017 + 0.4
        case 1: return Float(column % 7) * 0.11 - 0.3
        default: return Float((row * 31 + column * 17) % 13) * 0.07 - 0.25
        }
    }

    static func workingImage() -> WorkingColorRGBImage {
        PreviewTestData.working(width: sourceWidth, height: sourceHeight, sample: sample)
    }

    static func demosaicedImage() -> DemosaicedRAWRGBImage {
        var values: [Float] = []
        values.reserveCapacity(sourceWidth * sourceHeight * 3)
        for row in 0..<sourceHeight {
            for column in 0..<sourceWidth {
                for channel in 0..<3 {
                    values.append(sample(row: row, column: column, channel: channel))
                }
            }
        }
        return DemosaicedRAWRGBImage(
            width: sourceWidth,
            height: sourceHeight,
            values: values,
            processing: PreviewTestData.workingColorProcessing().demosaicProcessing
        )
    }

    static var policy: PreviewResolutionPolicy {
        PreviewResolutionPolicy(maximumLongestEdge: previewWidth)
    }

    static func expectClose(_ left: [Float], _ right: [Float], _ label: String) {
        guard left.count == right.count else {
            Issue.record("\(label): \(left.count) values vs \(right.count)")
            return
        }
        var worst: Float = 0
        for index in 0..<left.count {
            worst = max(worst, abs(left[index] - right[index]))
        }
        #expect(worst < tolerance, "\(label): worst absolute difference \(worst)")
    }

    // MARK: - The channel mix

    /// The stage immediately downstream of the reduction point, and the one
    /// the workspace will make adjustable next. If this did not commute,
    /// reducing before the mix would render differently from reducing after
    /// it, and the choice of point would be a colour decision.
    @Test("Mixing a reduced image equals reducing a mixed one")
    func theChannelMixCommutesWithReduction() throws {
        let working = Self.workingImage()
        let mix = try IRChannelMix.explicit(matrix: PreviewTestData.asymmetricMatrix())

        // reduce, then mix
        let reducedThenMixed = try IRChannelMixer().apply(
            to: try SceneLinearPreviewReducer().reduce(working, policy: Self.policy),
            mix: mix
        )

        // mix, then reduce
        let mixedFull = try IRChannelMixer().apply(to: working, mix: mix)
        let mixedThenReduced = try SceneLinearPreviewReducer.reducedValues(
            mixedFull.values,
            sourceWidth: Self.sourceWidth,
            sourceHeight: Self.sourceHeight,
            destinationWidth: Self.previewWidth,
            destinationHeight: Self.previewHeight
        )

        #expect(reducedThenMixed.width == Self.previewWidth)
        #expect(reducedThenMixed.height == Self.previewHeight)
        Self.expectClose(reducedThenMixed.values, mixedThenReduced, "channel mix")
    }

    /// The exact paths commute too, and more strongly: a permutation moves
    /// values without arithmetic on either side, so the two orders agree
    /// bit for bit.
    @Test("The red/blue swap commutes with reduction, bit for bit")
    func theRedBlueSwapCommutesExactly() throws {
        let working = Self.workingImage()

        let reducedThenSwapped = try IRChannelMixer().apply(
            to: try SceneLinearPreviewReducer().reduce(working, policy: Self.policy),
            mix: .redBlueSwap
        )
        let swappedFull = try IRChannelMixer().apply(to: working, mix: .redBlueSwap)
        let swappedThenReduced = try SceneLinearPreviewReducer.reducedValues(
            swappedFull.values,
            sourceWidth: Self.sourceWidth,
            sourceHeight: Self.sourceHeight,
            destinationWidth: Self.previewWidth,
            destinationHeight: Self.previewHeight
        )

        #expect(
            zip(reducedThenSwapped.values, swappedThenReduced)
                .allSatisfy { $0.bitPattern == $1.bitPattern }
        )
    }

    // MARK: - The camera-to-working transform

    /// The stage immediately *upstream* of the reduction point. It commutes
    /// too, which is what makes reducing one stage earlier — in camera-native
    /// RGB — an equally valid choice numerically, and therefore a choice that
    /// had to be made on other grounds. See
    /// `docs/decisions/0015-reduced-resolution-preview.md`.
    @Test("Converting a reduced image equals reducing a converted one")
    func theCameraTransformCommutesWithReduction() throws {
        let demosaiced = Self.demosaicedImage()
        let transform = try RAWCameraToWorkingColorTransform.explicit(
            matrix: PreviewTestData.asymmetricMatrix()
        )
        let converter = RAWWorkingColorConverter()

        // convert, then reduce
        let convertedFull = try converter.convert(demosaiced, using: transform)
        let convertedThenReduced = try SceneLinearPreviewReducer.reducedValues(
            convertedFull.values,
            sourceWidth: Self.sourceWidth,
            sourceHeight: Self.sourceHeight,
            destinationWidth: Self.previewWidth,
            destinationHeight: Self.previewHeight
        )

        // reduce, then convert
        let reducedCameraNative = try SceneLinearPreviewReducer.reducedValues(
            demosaiced.values,
            sourceWidth: Self.sourceWidth,
            sourceHeight: Self.sourceHeight,
            destinationWidth: Self.previewWidth,
            destinationHeight: Self.previewHeight
        )
        let reducedThenConverted = try converter.convert(
            DemosaicedRAWRGBImage(
                width: Self.previewWidth,
                height: Self.previewHeight,
                values: reducedCameraNative,
                processing: demosaiced.processing
            ),
            using: transform
        )

        Self.expectClose(
            reducedThenConverted.values, convertedThenReduced, "camera transform"
        )
    }

    // MARK: - Both stages at once

    /// The whole per-pixel linear span between demosaicing and orientation:
    /// camera transform followed by channel mix. Reducing anywhere in it gives
    /// the same picture.
    @Test("The whole linear span commutes, reduced at either end")
    func theWholeLinearSpanCommutes() throws {
        let demosaiced = Self.demosaicedImage()
        let transform = try RAWCameraToWorkingColorTransform.explicit(
            matrix: PreviewTestData.asymmetricMatrix()
        )
        let mix = try IRChannelMix.explicit(
            matrix: RAWColorMatrix3x3(
                m00: 0, m01: 0.5, m02: 0.5,
                m10: 0.25, m11: 0.5, m12: 0.25,
                m20: 1.5, m21: -0.5, m22: 0
            )
        )
        let converter = RAWWorkingColorConverter()
        let mixer = IRChannelMixer()

        // Reduce first (camera-native), then run both stages.
        let reducedEarly = try SceneLinearPreviewReducer.reducedValues(
            demosaiced.values,
            sourceWidth: Self.sourceWidth,
            sourceHeight: Self.sourceHeight,
            destinationWidth: Self.previewWidth,
            destinationHeight: Self.previewHeight
        )
        let earlyResult = try mixer.apply(
            to: try converter.convert(
                DemosaicedRAWRGBImage(
                    width: Self.previewWidth,
                    height: Self.previewHeight,
                    values: reducedEarly,
                    processing: demosaiced.processing
                ),
                using: transform
            ),
            mix: mix
        )

        // Run both stages first, then reduce.
        let lateResult = try SceneLinearPreviewReducer.reducedValues(
            try mixer.apply(
                to: try converter.convert(demosaiced, using: transform), mix: mix
            ).values,
            sourceWidth: Self.sourceWidth,
            sourceHeight: Self.sourceHeight,
            destinationWidth: Self.previewWidth,
            destinationHeight: Self.previewHeight
        )

        Self.expectClose(earlyResult.values, lateResult, "camera transform then mix")
    }

    // MARK: - The negative control

    /// Reduction does **not** commute with a non-linear operation, and this
    /// says so out loud rather than leaving it implied. The display transfer
    /// function is the concrete case: encoding then averaging is not averaging
    /// then encoding, which is exactly why the interactive source stays
    /// scene-linear and the display encode stays the last stage.
    @Test("Reduction does not commute with the display transfer function")
    func reductionDoesNotCommuteWithANonLinearStage() throws {
        // A checkerboard of 0 and 1: the average is 0.5, whose encoded value
        // is far from the average of the encoded 0 and 1.
        let source: [Float] = [0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0]
        let reducedThen = try SceneLinearPreviewReducer.reducedValues(
            source, sourceWidth: 2, sourceHeight: 2,
            destinationWidth: 1, destinationHeight: 1
        )
        // Encode the mean: sRGB(0.5) is about 0.7354.
        let encodedMean = DisplayPreviewRenderer.encode(Double(reducedThen[0]), as: .sRGB)
        // Mean of the encoded values: sRGB(0) = 0 and sRGB(1) = 1, so 0.5.
        let meanOfEncoded = 0.5

        #expect(abs(encodedMean - meanOfEncoded) > 0.2)
    }
}
