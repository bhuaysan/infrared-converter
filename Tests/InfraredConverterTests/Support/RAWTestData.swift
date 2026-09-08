import Foundation
@testable import InfraredConverter

/// Synthetic RAW values for tests that must not depend on a real file.
enum RAWTestData {
    /// A 4×4 RGGB Bayer description matching the reference camera's layout.
    static func bayerLayout(filters: UInt32 = 0xB4B4B4B4) -> RAWMetadata.SensorColorLayout {
        RAWMetadata.SensorColorLayout(
            pattern: .bayer,
            filters: filters,
            colorDescription: "RGBG",
            colorCount: 3,
            bitsPerRawSample: 12
        )
    }

    static func metadata(model: String = "E-PL3") -> RAWMetadata {
        RAWMetadata(
            identity: .init(
                make: "Olympus",
                model: model,
                normalizedMake: "Olympus",
                normalizedModel: model
            ),
            geometry: .init(
                rawWidth: 4080,
                rawHeight: 3040,
                visibleWidth: 4056,
                visibleHeight: 3040,
                topMargin: 0,
                leftMargin: 0,
                outputWidth: 4056,
                outputHeight: 3040,
                flip: 0,
                pixelAspect: 1
            ),
            sensor: bayerLayout(),
            levels: .init(
                black: 0,
                perPlaneBlack: [64, 64, 64, 64],
                blackPatternRows: 0,
                blackPatternColumns: 0,
                maximum: 4095
            ),
            color: .init(
                cameraMultipliers: [0.640625, 1.0, 5.5625, 0],
                daylightMultipliers: [2.2629104, 0.9284695, 1.2071348, 0]
            ),
            exposure: .init(iso: 200, shutterSeconds: 0.003125)
        )
    }

    /// A tiny 16-bit linear RGB buffer with a horizontal ramp.
    static func image(width: Int = 4, height: Int = 3) -> RAWImage {
        let channels = 3
        var samples = [UInt16]()
        samples.reserveCapacity(width * height * channels)
        for row in 0..<height {
            for column in 0..<width {
                let base = UInt16((row * width + column) * 1000)
                samples.append(base)
                samples.append(base / 2)
                samples.append(base / 4)
            }
        }
        return RAWImage(
            width: width,
            height: height,
            channelCount: channels,
            bitsPerChannel: 16,
            bytesPerRow: width * channels * 2,
            samples: samples.withUnsafeBufferPointer { Data(buffer: $0) },
            encoding: .linear,
            colorSpace: .cameraNative
        )
    }

    static func processing() -> RAWDecoderProcessing {
        RAWDecoderProcessing(
            decoderIdentifier: "Stub",
            blackLevelSubtracted: true,
            normalizedToFullRange: true,
            appliedWhiteBalanceMultipliers: [1, 1, 1, 1],
            demosaic: .ahd,
            cameraColorMatrixApplied: false,
            autoBrightnessApplied: false,
            highlightReconstructionApplied: false,
            noiseReductionApplied: false,
            cameraOrientationApplied: true
        )
    }

    static func decodedRAW(url: URL) -> DecodedRAW {
        DecodedRAW(
            url: url,
            metadata: metadata(),
            image: image(),
            processing: processing()
        )
    }
}
