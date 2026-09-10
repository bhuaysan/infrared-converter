import Foundation
@testable import InfraredConverter

/// Per-channel statistics over a `DemosaicedRAWRGBImage`, computed over the
/// whole interleaved buffer rather than sampled.
///
/// Diagnostic only. Nothing here says anything about whether the image is
/// *colour-correct* — no camera matrix has been applied at this stage, so
/// there is no colour to be correct about yet.
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
        var minimum = [Float](repeating: .greatestFiniteMagnitude, count: 3)
        var maximum = [Float](repeating: -.greatestFiniteMagnitude, count: 3)
        var total = [Double](repeating: 0, count: 3)
        var counted = [Int](repeating: 0, count: 3)
        var belowZero = [Int](repeating: 0, count: 3)
        var aboveOne = [Int](repeating: 0, count: 3)
        var nonFinite = 0

        image.values.withUnsafeBufferPointer { buffer in
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
        self.valueCount = image.values.count
    }

    subscript(channel: RAWLinearRGBChannel) -> Channel {
        // Every case is populated above.
        channels[channel]!
    }
}
