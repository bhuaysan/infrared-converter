import Foundation
@testable import InfraredConverter

/// Per-channel statistics over an interleaved `R G B` Float32 buffer,
/// computed over the whole buffer rather than sampled.
///
/// Serves both RGB-domain representations: `DemosaicedRAWRGBImage`, whose
/// values are linear camera-native sensor responses, and
/// `WorkingColorRGBImage`, whose values are extended-linear-sRGB coordinates.
/// They share a storage layout and nothing else, so which one a table
/// describes has to be said by the caller.
///
/// Diagnostic only. Nothing here says anything about whether an image is
/// *colour-correct*. For the camera-native image there is no colour to be
/// correct about yet; for the working-colour image the coordinates are defined
/// but their meaning depends entirely on the transform's provenance, and no
/// transform in this project is a validated infrared calibration.
struct RGBImageStatistics {
    struct Channel {
        let minimum: Float
        let maximum: Float
        let mean: Double
        let belowZeroCount: Int
        let aboveOneCount: Int
    }

    let channels: [RAWLinearRGBChannel: Channel]
    let nonFiniteCount: Int
    let valueCount: Int

    init(image: DemosaicedRAWRGBImage) {
        self.init(values: image.values)
    }

    init(image: WorkingColorRGBImage) {
        self.init(values: image.values)
    }

    private init(values allValues: [Float]) {
        var minimum = [Float](repeating: .greatestFiniteMagnitude, count: 3)
        var maximum = [Float](repeating: -.greatestFiniteMagnitude, count: 3)
        var total = [Double](repeating: 0, count: 3)
        var counted = [Int](repeating: 0, count: 3)
        var belowZero = [Int](repeating: 0, count: 3)
        var aboveOne = [Int](repeating: 0, count: 3)
        var nonFinite = 0

        allValues.withUnsafeBufferPointer { buffer in
            for index in 0..<buffer.count {
                let channel = index % 3
                let value = buffer[index]
                guard value.isFinite else {
                    nonFinite += 1
                    continue
                }
                minimum[channel] = Swift.min(minimum[channel], value)
                maximum[channel] = Swift.max(maximum[channel], value)
                total[channel] += Double(value)
                counted[channel] += 1
                if value < 0 { belowZero[channel] += 1 }
                if value > 1 { aboveOne[channel] += 1 }
            }
        }

        var result = [RAWLinearRGBChannel: Channel]()
        for channel in RAWLinearRGBChannel.allCases {
            let index = channel.storageOffset
            result[channel] = Channel(
                minimum: minimum[index],
                maximum: maximum[index],
                mean: counted[index] > 0 ? total[index] / Double(counted[index]) : 0,
                belowZeroCount: belowZero[index],
                aboveOneCount: aboveOne[index]
            )
        }
        self.channels = result
        self.nonFiniteCount = nonFinite
        self.valueCount = allValues.count
    }

    subscript(channel: RAWLinearRGBChannel) -> Channel {
        // Every case is populated above.
        channels[channel]!
    }
}
