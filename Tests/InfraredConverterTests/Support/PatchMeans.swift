import Foundation
@testable import InfraredConverter

/// Per-CFA-plane arithmetic means over a rectangular region of a Float32
/// mosaic buffer, computed independently of `RAWWhiteBalanceEstimator`.
///
/// Deliberately a separate, obvious implementation: using the estimator to
/// check the estimator's own output would make a shared bug invisible. This
/// walks the region, groups by the layout's colour-plane index, and divides.
enum PatchMeans {
    static func perPlane(
        values: [Float],
        width: Int,
        layout: RAWMetadata.SensorColorLayout,
        region: RAWActiveAreaRegion
    ) -> [Int: Double] {
        var sums: [Int: Double] = [:]
        var counts: [Int: Int] = [:]
        for row in region.originRow..<(region.originRow + region.height) {
            for column in region.originColumn..<(region.originColumn + region.width) {
                let index = row * width + column
                guard index >= 0, index < values.count else { continue }
                guard let plane = layout.colorPlaneIndex(row: row, column: column) else { continue }
                sums[plane, default: 0] += Double(values[index])
                counts[plane, default: 0] += 1
            }
        }
        return sums.reduce(into: [:]) { result, entry in
            let count = counts[entry.key] ?? 0
            if count > 0 { result[entry.key] = entry.value / Double(count) }
        }
    }

    static func perPlane(
        mosaic: LinearRAWMosaic,
        region: RAWActiveAreaRegion
    ) -> [Int: Double] {
        perPlane(
            values: mosaic.values,
            width: mosaic.width,
            layout: mosaic.sensorColorLayout,
            region: region
        )
    }

    static func perPlane(
        mosaic: WhiteBalancedRAWMosaic,
        region: RAWActiveAreaRegion
    ) -> [Int: Double] {
        perPlane(
            values: mosaic.values,
            width: mosaic.width,
            layout: mosaic.sensorColorLayout,
            region: region
        )
    }
}
