import Foundation

/// The four semantic colour channels of one repeating 2×2 Bayer cell, in
/// active-image coordinates.
///
/// ## What it is for
///
/// A CFA mosaic is described by a *colour-plane index* per position, and a
/// separate `colorDescription` string saying what each plane index means. A
/// demosaicer needs the second thing, per position, several times per pixel.
/// Resolving it per sample would mean a string index — or worse, an
/// `Array(colorDescription)` allocation — inside a loop that runs twelve
/// million times.
///
/// So the layout is validated and resolved **once**, into this value, and the
/// hot loop then uses row and column parity alone.
///
/// ## G1 and G2 collapse here, and only here
///
/// On the reference camera two distinct plane indices — `1` and `3` — both
/// map to the letter `G`, so both cell positions resolve to `.green`. That is
/// the *only* place the two greens are treated as one thing: they become the
/// same output channel, but they remain separate source samples with
/// separate white-balance gains, and nothing averages or reconciles them. See
/// `RAWDemosaicer`.
public struct RAWBayerCellPattern: Equatable, Sendable {
    /// The channel at even row, even column.
    public let topLeft: RAWLinearRGBChannel
    /// The channel at even row, odd column.
    public let topRight: RAWLinearRGBChannel
    /// The channel at odd row, even column.
    public let bottomLeft: RAWLinearRGBChannel
    /// The channel at odd row, odd column.
    public let bottomRight: RAWLinearRGBChannel

    public init(
        topLeft: RAWLinearRGBChannel,
        topRight: RAWLinearRGBChannel,
        bottomLeft: RAWLinearRGBChannel,
        bottomRight: RAWLinearRGBChannel
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// The channel at an active-image coordinate, by parity.
    ///
    /// Negative coordinates wrap onto the repeating cell rather than
    /// trapping, matching `SensorColorLayout.colorPlaneIndex(row:column:)`.
    /// Callers still have to bounds-check the image itself; this only
    /// answers "what colour is this position".
    public func channel(row: Int, column: Int) -> RAWLinearRGBChannel {
        channel(rowParity: ((row % 2) + 2) % 2, columnParity: ((column % 2) + 2) % 2)
    }

    /// The channel for already-reduced parities, `0` or `1` each. The hot
    /// path: two `& 1` operations at the call site and a switch here, with no
    /// modulo, no string and no allocation.
    ///
    /// Parities outside `0...1` are reduced the same way `channel(row:
    /// column:)` reduces coordinates, so this cannot trap either.
    public func channel(rowParity: Int, columnParity: Int) -> RAWLinearRGBChannel {
        let r = ((rowParity % 2) + 2) % 2
        let c = ((columnParity % 2) + 2) % 2
        switch (r, c) {
        case (0, 0): return topLeft
        case (0, 1): return topRight
        case (1, 0): return bottomLeft
        default: return bottomRight
        }
    }

    /// The four channels in `topLeft, topRight, bottomLeft, bottomRight`
    /// order, for diagnostics and provenance.
    public var channels: [RAWLinearRGBChannel] {
        [topLeft, topRight, bottomLeft, bottomRight]
    }

    /// A compact description of the discovered phase, e.g. `"RGGB"`.
    public var phaseDescription: String {
        String(channels.map(\.colorDescriptionLetter))
    }

    // MARK: - Resolving a layout

    /// Validates that a sensor colour layout really is a repeating 2×2 Bayer
    /// RGB mosaic, and resolves it into this value.
    ///
    /// This deliberately does **more** than check `pattern == .bayer`. That
    /// flag says the decoder packed a CFA code into `filters`; it does not
    /// say the code describes something a Bayer algorithm may run on. Every
    /// one of the following is established, in order:
    ///
    /// 1. the layout is `.bayer` at all — `.xTrans` is recognised and
    ///    refused by name, and `.foveon`, `.none` and `.unknown` have no
    ///    per-sample mosaic to read;
    /// 2. `filters != 1`, LibRaw's non-standard 16×16 layout, which this
    ///    project does not carry the table for;
    /// 3. every position of the **complete packed cell** — 8 rows × 2
    ///    columns, the extent the `filters` code addresses — names a colour
    ///    plane;
    /// 4. every named plane index is addressable in `colorDescription`;
    /// 5. every letter is `R`, `G` or `B`;
    /// 6. rows 2 through 7 repeat the first two rows exactly, so the mosaic
    ///    genuinely repeats every 2×2 and is not an 8-row pattern that merely
    ///    fits in a Bayer-shaped field;
    /// 7. the 2×2 cell holds exactly one red, exactly one blue and exactly
    ///    two greens.
    ///
    /// Step 6 is the one that is easy to skip and expensive to get wrong: a
    /// four- or eight-row CFA demosaiced as 2×2 would produce a plausible
    /// image with systematically wrong colour, rather than an obvious
    /// failure.
    ///
    /// Nothing here re-derives LibRaw's CFA decoding. The layout's own
    /// `colorPlaneIndex(row:column:)` is the single implementation of that,
    /// and this walks it — so a three-plane Bayer layout whose two greens
    /// share plane index `1`, and a four-plane `RGBG` layout whose greens are
    /// planes `1` and `3`, both resolve to the same `R/G/G/B` cell.
    ///
    /// - Parameters:
    ///   - layout: the sensor colour layout to validate.
    ///   - algorithm: recorded in the error, so an unsupported layout says
    ///     which algorithm refused it rather than implying no algorithm ever
    ///     could.
    /// - Throws: `RAWProcessingError.unsupportedSensorLayoutForDemosaicing`.
    public static func resolve(
        from layout: RAWMetadata.SensorColorLayout,
        algorithm: RAWDemosaicAlgorithm = .bilinearBayer
    ) throws -> RAWBayerCellPattern {
        func unsupported(_ reason: String) -> RAWProcessingError {
            .unsupportedSensorLayoutForDemosaicing(
                pattern: layout.pattern, algorithm: algorithm, reason: reason
            )
        }

        switch layout.pattern {
        case .bayer:
            break
        case .xTrans:
            throw unsupported("""
                This is a Fujifilm X-Trans layout: a recognised, fully described 6x6 \
                colour-filter array, not an unknown one. It is not a repeating 2x2 Bayer \
                mosaic, so \(algorithm) cannot demosaic it — not because the layout is \
                unsupported by the project, but because this algorithm is Bayer-only. An \
                X-Trans demosaicer would be a separate algorithm producing the same \
                DemosaicedRAWRGBImage representation.
                """)
        case .foveon:
            throw unsupported("""
                Foveon sensors stack photodiodes and have no colour-filter mosaic to \
                interpolate; every location already carries all three responses.
                """)
        case .none:
            throw unsupported("""
                This file is already full-colour per pixel, so there is nothing to \
                demosaic.
                """)
        case .unknown:
            throw unsupported("""
                The decoder did not describe this sensor's colour layout, so no \
                interpolation rule can be derived for it.
                """)
        }

        guard layout.filters != 1 else {
            throw unsupported("""
                filters == 1 denotes LibRaw's non-standard 16x16 colour-filter layout. \
                This project does not carry that table, and it is not a 2x2 Bayer cell.
                """)
        }

        // The packed dcraw/LibRaw code addresses 8 rows x 2 columns. Walking
        // all of it — rather than only the first 2x2 — is what proves the
        // mosaic really repeats every two rows.
        let cellRows = 8
        let cellColumns = 2
        let letters = Array(layout.colorDescription)

        var resolved = [RAWLinearRGBChannel?](repeating: nil, count: cellRows * cellColumns)
        for row in 0..<cellRows {
            for column in 0..<cellColumns {
                guard let plane = layout.colorPlaneIndex(row: row, column: column) else {
                    throw unsupported("""
                        The layout named no colour plane at row \(row), column \(column) of \
                        its packed \(cellRows)x\(cellColumns) cell.
                        """)
                }
                guard plane >= 0, plane < letters.count else {
                    throw unsupported("""
                        Colour plane \(plane) at row \(row), column \(column) is not \
                        addressable in colorDescription "\(layout.colorDescription)", so its \
                        colour is unknown.
                        """)
                }
                let letter = letters[plane]
                guard let channel = RAWLinearRGBChannel(colorDescriptionLetter: letter) else {
                    throw unsupported("""
                        Colour plane \(plane) at row \(row), column \(column) is described as \
                        "\(letter)", which is not one of R, G or B. \(algorithm) reconstructs \
                        red, green and blue only, and will not map another filter colour onto \
                        one of them.
                        """)
                }
                resolved[row * cellColumns + column] = channel
            }
        }

        // Every entry was written above or a throw already happened.
        let cell = resolved.compactMap { $0 }
        guard cell.count == cellRows * cellColumns else {
            throw unsupported("The packed CFA cell could not be fully resolved.")
        }

        // The 2x2 repeat. Rows 2...7 must restate rows 0...1 exactly.
        for row in 2..<cellRows {
            for column in 0..<cellColumns {
                let here = cell[row * cellColumns + column]
                let expected = cell[(row % 2) * cellColumns + column]
                guard here == expected else {
                    throw unsupported("""
                        The packed CFA cell does not repeat every 2 rows: row \(row), column \
                        \(column) is \(here) where row \(row % 2) is \(expected). This mosaic \
                        has a taller repeat than 2x2 and must not be demosaiced by a 2x2 \
                        Bayer algorithm.
                        """)
                }
            }
        }

        let topLeft = cell[0]
        let topRight = cell[1]
        let bottomLeft = cell[cellColumns]
        let bottomRight = cell[cellColumns + 1]
        let quad = [topLeft, topRight, bottomLeft, bottomRight]

        let redCount = quad.filter { $0 == .red }.count
        let greenCount = quad.filter { $0 == .green }.count
        let blueCount = quad.filter { $0 == .blue }.count
        guard redCount == 1, blueCount == 1, greenCount == 2 else {
            throw unsupported("""
                A Bayer cell must hold exactly one red, one blue and two green positions. \
                This one holds \(redCount) red, \(greenCount) green and \(blueCount) blue: \
                \(quad.map(\.colorDescriptionLetter).map(String.init).joined()).
                """)
        }

        return RAWBayerCellPattern(
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight
        )
    }
}
