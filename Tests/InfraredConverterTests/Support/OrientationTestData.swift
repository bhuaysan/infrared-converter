import Foundation
@testable import InfraredConverter

/// Builders for the orientation suites.
///
/// The images here are deliberately **asymmetric** and every pixel is
/// uniquely identifiable, so that no rotation can be mistaken for a mirror and
/// no mirror for the identity. A symmetrical test image would pass for six of
/// the eight orientations while the code did the wrong one.
enum OrientationTestData {

    /// One uniquely identifiable pixel, named by a letter.
    ///
    /// The three components differ from each other by orders of magnitude, so
    /// a channel swap is as visible as a pixel move — this stage must do
    /// neither.
    ///
    /// ```text
    /// A → (1, 10, 100)    B → (2, 20, 200)    C → (3, 30, 300)
    /// D → (4, 40, 400)    E → (5, 50, 500)    F → (6, 60, 600)
    /// ```
    static func pixel(_ label: Character) -> (red: Float, green: Float, blue: Float) {
        let index = Float(Int(label.asciiValue ?? 0) - Int(Character("A").asciiValue ?? 0) + 1)
        return (red: index, green: index * 10, blue: index * 100)
    }

    /// Provenance for a channel-mixed image, with an upstream chain rich
    /// enough that a stage which overwrote it would be visible.
    static func channelMixProcessing(
        mix: IRChannelMix = .identity,
        transform: RAWCameraToWorkingColorTransform = .sensorRGBIdentityFalseColor,
        gains: RAWWhiteBalanceGains = RAWWhiteBalanceGains(
            plane0: 2, plane1: 1, plane2: 3, plane3: 1.5
        ),
        whiteLevel: UInt32 = 4095
    ) -> IRChannelMixProcessing {
        IRChannelMixProcessing(
            mix: mix,
            workingColorProcessing: RAWWorkingColorProcessing(
                transform: transform,
                demosaicProcessing: RAWDemosaicProcessing(
                    algorithm: .bilinearBayer,
                    sourcePattern: RAWBayerCellPattern(
                        topLeft: .red, topRight: .green, bottomLeft: .green, bottomRight: .blue
                    ),
                    whiteBalanceProcessing: RAWWhiteBalanceProcessing(
                        gains: gains,
                        gainSource: .explicit,
                        linearProcessing: RAWLinearProcessing(
                            whiteLevelPolicy: .metadataMaximum, whiteLevel: whiteLevel
                        )
                    )
                )
            )
        )
    }

    /// A channel-mixed image built from rows of labels.
    ///
    /// ```swift
    /// labelled(["ABC", "DEF"])   // 3 wide, 2 high
    /// ```
    static func labelled(
        _ rows: [String],
        processing: IRChannelMixProcessing? = nil
    ) -> IRChannelMixedRGBImage {
        let width = rows.first?.count ?? 0
        var values = [Float]()
        values.reserveCapacity(width * rows.count * 3)
        for row in rows {
            for label in row {
                let pixel = pixel(label)
                values.append(pixel.red)
                values.append(pixel.green)
                values.append(pixel.blue)
            }
        }
        return IRChannelMixedRGBImage(
            width: width,
            height: rows.count,
            values: values,
            processing: processing ?? channelMixProcessing()
        )
    }

    /// A channel-mixed image from explicit interleaved values, for the
    /// bit-pattern suites where the labels would get in the way.
    static func image(
        width: Int,
        height: Int,
        values: [Float],
        processing: IRChannelMixProcessing? = nil
    ) -> IRChannelMixedRGBImage {
        IRChannelMixedRGBImage(
            width: width,
            height: height,
            values: values,
            processing: processing ?? channelMixProcessing()
        )
    }

    /// Re-presents an oriented image as a channel-mixed one, so a **second**
    /// orientation can be applied to it.
    ///
    /// Test-only, and deliberately so: production code never chains
    /// orientations — `ImageOrienter.apply(orientation:replacing:)` exists to
    /// make chaining structurally impossible. Chaining is exactly what the
    /// composition suite needs as its oracle, though: "apply A, then B" has to
    /// be produced by genuinely applying A and then B, or the test would be
    /// checking the composition table against itself.
    static func reinterpretedAsChannelMixed(
        _ image: OrientedSceneLinearRGBImage
    ) -> IRChannelMixedRGBImage {
        IRChannelMixedRGBImage(
            width: image.width,
            height: image.height,
            values: image.values,
            processing: image.processing.channelMixProcessing
        )
    }

    /// Reads an oriented image back as rows of labels, so an expected layout
    /// can be written in the test source exactly as it looks.
    ///
    /// A pixel whose components do not match any label reads as `?`, which
    /// fails the comparison rather than silently matching something.
    static func labels(of image: OrientedSceneLinearRGBImage) -> [String] {
        (0..<image.height).map { row in
            String((0..<image.width).map { column -> Character in
                guard let pixel = image.pixel(row: row, column: column) else { return "!" }
                for label in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
                    let expected = OrientationTestData.pixel(label)
                    if pixel.red == expected.red,
                       pixel.green == expected.green,
                       pixel.blue == expected.blue {
                        return label
                    }
                }
                return "?"
            })
        }
    }
}
