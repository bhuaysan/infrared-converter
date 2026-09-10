import Foundation
@testable import InfraredConverter

/// Synthetic sensor colour layouts for demosaicing tests, built by packing
/// colour-plane indices the way LibRaw's `filters` code does.
///
/// The packing is written out here rather than as hex constants so a reader
/// can see which phase a test uses without decoding a magic number, and so a
/// layout with a deliberately non-repeating cell can be built at all.
enum BayerTestLayouts {

    /// Packs an 8-row × 2-column cell of colour-plane indices into the code
    /// `RAWMetadata.SensorColorLayout.filters` carries: two bits per
    /// position, at bit `((row << 1) | column) << 1`.
    ///
    /// `cell` supplies as many rows as the pattern genuinely repeats over —
    /// two for an ordinary Bayer mosaic — and is tiled to fill all eight.
    static func filters(cell: [[Int]]) -> UInt32 {
        precondition(!cell.isEmpty, "a CFA cell needs at least one row")
        var code: UInt32 = 0
        for row in 0..<8 {
            let planes = cell[row % cell.count]
            precondition(planes.count == 2, "the packed cell is two columns wide")
            for column in 0..<2 {
                let shift = UInt32(((row << 1) | column) << 1)
                code |= UInt32(planes[column] & 3) << shift
            }
        }
        return code
    }

    static func layout(
        cell: [[Int]],
        colorDescription: String = "RGBG",
        colorCount: Int = 3
    ) -> RAWMetadata.SensorColorLayout {
        RAWMetadata.SensorColorLayout(
            pattern: .bayer,
            filters: filters(cell: cell),
            colorDescription: colorDescription,
            colorCount: colorCount,
            sourceRawBitDepth: 12
        )
    }

    // MARK: - The four ordinary phases, as four reachable planes

    /// `RGBG` colour description, so the two greens are planes 1 and 3 — the
    /// reference camera's arrangement, and identical to
    /// `RAWTestData.bayerLayout()`.
    ///
    /// ```text
    /// R  G1        planes 0 1
    /// G2 B                3 2
    /// ```
    static let rggb = layout(cell: [[0, 1], [3, 2]])

    /// ```text
    /// B  G1        planes 2 1
    /// G2 R                3 0
    /// ```
    static let bggr = layout(cell: [[2, 1], [3, 0]])

    /// ```text
    /// G1 R         planes 1 0
    /// B  G2               2 3
    /// ```
    static let grbg = layout(cell: [[1, 0], [2, 3]])

    /// ```text
    /// G1 B         planes 1 2
    /// R  G2               0 3
    /// ```
    static let gbrg = layout(cell: [[1, 2], [0, 3]])

    /// A genuine three-plane Bayer layout: both greens are plane `1`, so
    /// plane `3` is never produced anywhere in the CFA.
    ///
    /// ```text
    /// R G          planes 0 1
    /// G B                 1 2
    /// ```
    static let rggbThreePlane = layout(cell: [[0, 1], [1, 2]])

    /// The semantic 2×2 channel letters a phase must resolve to, for readable
    /// expectations. Independent of the production resolver: it reads the
    /// cell the test itself declared.
    static func phase(_ cell: [[Int]], colorDescription: String = "RGBG") -> String {
        let letters = Array(colorDescription)
        return String((0..<2).flatMap { row in
            (0..<2).map { column in letters[cell[row][column]] }
        })
    }
}
