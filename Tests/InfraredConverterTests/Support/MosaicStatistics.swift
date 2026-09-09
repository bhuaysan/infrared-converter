import Foundation
@testable import InfraredConverter

/// Full-buffer statistics over a Float32 CFA mosaic, whatever stage produced
/// it.
///
/// Every figure is computed over the whole buffer, not sampled: the counts
/// below zero and above one are exactly the facts these milestones are about,
/// and a sparse estimate of them would be meaningless. The accumulators are
/// scalars and the buffer is read through a borrowed pointer, so no second
/// full-size allocation happens.
struct MosaicStatistics {
    let minimum: Float
    let maximum: Float
    let mean: Double
    let perPlaneMean: [Int: Double]
    let belowZeroCount: Int
    let zeroCount: Int
    let aboveOneCount: Int
    let nonFiniteCount: Int
    let valueCount: Int

    init(
        values: [Float],
        width: Int,
        height: Int,
        layout: RAWMetadata.SensorColorLayout
    ) {
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        var total = 0.0
        var perPlaneTotal: [Int: Double] = [:]
        var perPlaneCount: [Int: Int] = [:]
        var belowZero = 0
        var zero = 0
        var aboveOne = 0
        var nonFinite = 0

        var index = 0
        for row in 0..<height {
            for column in 0..<width {
                guard index < values.count else { break }
                let value = values[index]
                index += 1

                guard value.isFinite else {
                    nonFinite += 1
                    continue
                }
                minimum = Swift.min(minimum, value)
                maximum = Swift.max(maximum, value)
                total += Double(value)
                if value < 0 { belowZero += 1 }
                if value == 0 { zero += 1 }
                if value > 1 { aboveOne += 1 }

                if let plane = layout.colorPlaneIndex(row: row, column: column) {
                    perPlaneTotal[plane, default: 0] += Double(value)
                    perPlaneCount[plane, default: 0] += 1
                }
            }
        }

        self.minimum = minimum
        self.maximum = maximum
        self.mean = values.isEmpty ? 0 : total / Double(values.count)
        self.perPlaneMean = perPlaneTotal.reduce(into: [:]) { result, entry in
            let count = perPlaneCount[entry.key] ?? 0
            result[entry.key] = count > 0 ? entry.value / Double(count) : 0
        }
        self.belowZeroCount = belowZero
        self.zeroCount = zero
        self.aboveOneCount = aboveOne
        self.nonFiniteCount = nonFinite
        self.valueCount = values.count
    }

    init(mosaic: LinearRAWMosaic) {
        self.init(
            values: mosaic.values,
            width: mosaic.width,
            height: mosaic.height,
            layout: mosaic.sensorColorLayout
        )
    }

    init(mosaic: WhiteBalancedRAWMosaic) {
        self.init(
            values: mosaic.values,
            width: mosaic.width,
            height: mosaic.height,
            layout: mosaic.sensorColorLayout
        )
    }

    /// Per-plane means in colour-plane order, for reports.
    var perPlaneMeansInOrder: [(plane: Int, mean: Double)] {
        perPlaneMean.sorted { $0.key < $1.key }.map { (plane: $0.key, mean: $0.value) }
    }
}
