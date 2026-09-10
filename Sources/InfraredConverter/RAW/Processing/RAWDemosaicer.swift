import Foundation

/// The application-owned demosaicing stage: `WhiteBalancedRAWMosaic` →
/// `DemosaicedRAWRGBImage`, by bilinear interpolation over a repeating 2×2
/// Bayer RGB mosaic.
///
/// ```text
/// LinearRAWMosaic
///       ↓
/// RAWWhiteBalancer
///       ↓
/// WhiteBalancedRAWMosaic          ← mosaic domain ends here
///       ↓
/// RAWDemosaicer                   ← this stage
///       ↓
/// DemosaicedRAWRGBImage           ← linear camera-native RGB
///       ↓
/// [FUTURE: camera-native RGB → working colour space]
/// ```
///
/// ## LibRaw is not involved
///
/// This file does not import `CLibRaw`, receives no LibRaw context, and calls
/// nothing in LibRaw. In particular it does **not** route the mosaic back
/// through `dcraw_process`, does not convert Float data back into LibRaw
/// structures, and shares nothing with `RAWDecodeOptions.Demosaic`, which
/// selects LibRaw's own algorithms on the separate legacy processed-RGB path.
/// The interpolation below is this project's, so its exact behaviour at
/// borders, its arithmetic precision and its refusal to clamp are properties
/// this project defines and tests rather than inherits.
///
/// ## White balance structurally precedes this stage
///
/// The input type is `WhiteBalancedRAWMosaic`, not `LinearRAWMosaic`. That is
/// the enforcement, not a convention: there is no overload that demosaics an
/// unbalanced mosaic. Interpolating first and balancing after would mix
/// samples of different colour planes — and, on the reference camera, of two
/// green planes that received different gains — before their relative scaling
/// was correct, so every reconstructed value would be a mean of mismatched
/// numbers.
///
/// A caller who genuinely wants no white balance applies
/// `RAWWhiteBalanceGains.identity`, which leaves every finite value
/// bit-identical and says so in provenance.
///
/// ## No colour science happens here
///
/// This stage receives no `RAWMetadata`, no camera matrices and no decoder
/// colour information, and there is no parameter for them to arrive through.
/// `cam_mul`, `pre_mul`, `rgb_cam` and `cam_xyz` are untouched. Nothing here
/// converts a colour space, applies gamma, clamps a range, adjusts exposure or
/// reconstructs a highlight. The output is linear camera-native RGB; see
/// `DemosaicedRAWRGBImage`.
///
/// ## The algorithm
///
/// The 2×2 Bayer phase is discovered from the mosaic's own sensor colour
/// layout — `RGGB`, `BGGR`, `GRBG` and `GBRG` are all supported and none is
/// hardcoded — and resolved once into a `RAWBayerCellPattern` before any pixel
/// is touched. Then, for every location:
///
/// ```text
/// at a red location:      R = the native sample, copied exactly
///                         G = mean of the in-bounds AXIAL   green neighbours (N S W E)
///                         B = mean of the in-bounds DIAGONAL blue  neighbours (NW NE SW SE)
///
/// at a blue location:     B = the native sample, copied exactly
///                         G = mean of the in-bounds AXIAL   green neighbours
///                         R = mean of the in-bounds DIAGONAL red   neighbours
///
/// at a green location:    G = the native sample, copied exactly
///                         R = mean of the in-bounds AXIAL   red   neighbours
///                         B = mean of the in-bounds AXIAL   blue  neighbours
/// ```
///
/// A contributor counts only if it is in bounds **and** its own CFA location
/// carries the colour being reconstructed. For a green location that resolves
/// to one horizontal pair and one vertical pair, but which is which follows
/// from the discovered phase rather than from an assumption: the two green
/// positions in a Bayer cell have opposite orientations, and both are handled
/// by the same rule.
///
/// ## G1 and G2 stay independent
///
/// Both green CFA positions map to the single output green channel, but they
/// are never merged, averaged or reconciled as *planes*. A G1 location's green
/// output is its own G1 white-balanced sample; a G2 location's is its own G2
/// sample; and a red or blue location's interpolated green is the spatial mean
/// of whichever green neighbours surround it, which will normally include both
/// kinds. There is no global green normalisation stage, and adding one would
/// undo the per-plane gains the white-balance stage deliberately kept
/// separate.
///
/// ## Borders
///
/// One policy, stated once: **average only the valid in-bounds contributors
/// that actually carry the wanted colour.** A corner red location has two
/// axial green neighbours rather than four, and one diagonal blue neighbour
/// rather than four, and its means are over two and over one accordingly.
/// Coordinates are never reflected, wrapped or duplicated, no out-of-bounds
/// sample is pretended into existence, and the output is never cropped: every
/// input CFA location produces exactly one output pixel.
///
/// If a channel has *no* valid contributor — reachable only for pathological
/// geometry such as a 1×1 mosaic — the stage fails with
/// `RAWProcessingError.missingDemosaicNeighbors`, carrying the coordinate and
/// the missing channel. It does not invent a zero.
///
/// ## Arithmetic
///
/// Storage is `Float32` in and `Float32` out. Interpolated means accumulate
/// their at most four contributors in `Double` and narrow once, because
/// `Float.greatestFiniteMagnitude + Float.greatestFiniteMagnitude` overflows
/// in `Float32` even though the average is perfectly representable — an
/// artificial failure created by the summation, not by the data.
///
/// Native samples take the other path: they are copied straight across, never
/// through `Double`, so their bit patterns — `-0.0` included — survive
/// exactly.
///
/// Nothing is clamped, in either direction, at any point.
public struct RAWDemosaicer: Sendable {
    public init() {}

    /// Demosaics a white-balanced mosaic into linear camera-native RGB.
    ///
    /// The sensor colour layout is validated in full before any pixel is
    /// touched, so an unsupported layout fails immediately rather than
    /// partway through a 12-megapixel buffer.
    ///
    /// - Parameters:
    ///   - mosaic: the white-balanced CFA mosaic. Identity gains are a valid
    ///     way to reach this state without changing any value.
    ///   - algorithm: which algorithm to use. One exists.
    /// - Throws: `RAWProcessingError`.
    public func demosaic(
        _ mosaic: WhiteBalancedRAWMosaic,
        algorithm: RAWDemosaicAlgorithm = .bilinearBayer
    ) throws -> DemosaicedRAWRGBImage {
        let pattern = try RAWBayerCellPattern.resolve(
            from: mosaic.sensorColorLayout, algorithm: algorithm
        )

        guard mosaic.isGeometryConsistent else {
            throw RAWProcessingError.invalidGeometry(
                reason: """
                    White-balanced mosaic geometry \(mosaic.width)x\(mosaic.height) needs \
                    \(mosaic.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(mosaic.values.count).
                    """
            )
        }
        // Recomputed rather than inferred from `isGeometryConsistent`, so the
        // allocation size below stands on its own arithmetic. The second
        // multiplication is checked separately: three channels reach Int.max
        // at a third of the geometry one channel does.
        let (sampleCount, sampleOverflow) =
            mosaic.width.multipliedReportingOverflow(by: mosaic.height)
        guard !sampleOverflow else {
            throw RAWProcessingError.invalidGeometry(
                reason: "Pixel count \(mosaic.width) x \(mosaic.height) overflows."
            )
        }
        let (outputCount, outputOverflow) =
            sampleCount.multipliedReportingOverflow(by: DemosaicedRAWRGBImage.channelCount)
        guard !outputOverflow else {
            throw RAWProcessingError.invalidGeometry(
                reason: """
                    Output element count \(sampleCount) x \
                    \(DemosaicedRAWRGBImage.channelCount) overflows.
                    """
            )
        }

        let width = mosaic.width
        let height = mosaic.height

        switch algorithm {
        case .bilinearBayer:
            let values = try Self.bilinearBayerValues(
                mosaic: mosaic,
                pattern: pattern,
                width: width,
                height: height,
                sampleCount: sampleCount,
                outputCount: outputCount
            )
            return DemosaicedRAWRGBImage(
                width: width,
                height: height,
                values: values,
                processing: RAWDemosaicProcessing(
                    algorithm: algorithm,
                    sourcePattern: pattern,
                    whiteBalanceProcessing: mosaic.processing
                )
            )
        }
    }

    /// Demosaics a white-balanced result, keeping that whole pre-demosaic
    /// state reachable on the returned value's `source`.
    ///
    /// Use this rather than the bare-mosaic overload whenever the caller may
    /// want to change the gains or the algorithm later: the result carries
    /// everything needed to restart from the correct earlier representation,
    /// without decoding the file again.
    public func demosaic(
        _ processed: WhiteBalancedProcessedRAWMosaic,
        algorithm: RAWDemosaicAlgorithm = .bilinearBayer
    ) throws -> DemosaicedProcessedRAWImage {
        let image = try demosaic(processed.mosaic, algorithm: algorithm)
        return DemosaicedProcessedRAWImage(source: processed, image: image)
    }

    // MARK: - Bilinear Bayer

    /// The four axial (edge-sharing) neighbour offsets, as `(rowDelta,
    /// columnDelta)`: north, south, west, east.
    private static let axialOffsets: [(Int, Int)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    /// The four diagonal (corner-sharing) neighbour offsets: northwest,
    /// northeast, southwest, southeast.
    private static let diagonalOffsets: [(Int, Int)] = [(-1, -1), (-1, 1), (1, -1), (1, 1)]

    /// The interpolation itself.
    ///
    /// One owned `[Float]` allocation, written once, from a borrowed read of
    /// the source. No full-frame intermediates: no per-channel R/G/B planes,
    /// no `Double` staging buffer, no copy of the input, no second output
    /// buffer. Per pixel there is no dictionary, no array of colour letters
    /// and no string handling — the CFA colour of any position is two `& 1`
    /// operations and a switch over the pre-resolved pattern.
    ///
    /// `O(width × height)` with a bounded neighbourhood per pixel: at most
    /// eight neighbour lookups, each of which is a parity check and one load.
    private static func bilinearBayerValues(
        mosaic: WhiteBalancedRAWMosaic,
        pattern: RAWBayerCellPattern,
        width: Int,
        height: Int,
        sampleCount: Int,
        outputCount: Int
    ) throws -> [Float] {
        try [Float](unsafeUninitializedCapacity: outputCount) { buffer, initializedCount in
            initializedCount = 0
            try mosaic.values.withUnsafeBufferPointer { input in
                guard input.count >= sampleCount else {
                    throw RAWProcessingError.invalidGeometry(
                        reason: "Value buffer is smaller than the declared geometry requires."
                    )
                }

                /// The mean of the in-bounds neighbours at `offsets` whose own
                /// CFA location carries `wanted`.
                ///
                /// Accumulated in `Double` and narrowed once: at most four
                /// finite `Float32` values, whose sum can overflow `Float32`
                /// while their mean cannot. A non-finite contributor is
                /// reported with **its own** coordinate rather than skipped —
                /// skipping would quietly change the denominator.
                func interpolate(
                    _ wanted: RAWLinearRGBChannel,
                    from offsets: [(Int, Int)],
                    row: Int,
                    column: Int
                ) throws -> Float {
                    var sum = 0.0
                    var count = 0
                    for (rowDelta, columnDelta) in offsets {
                        let neighbourRow = row + rowDelta
                        let neighbourColumn = column + columnDelta
                        guard neighbourRow >= 0, neighbourRow < height,
                              neighbourColumn >= 0, neighbourColumn < width
                        else { continue }
                        guard pattern.channel(
                            rowParity: neighbourRow & 1, columnParity: neighbourColumn & 1
                        ) == wanted else { continue }

                        let value = input[neighbourRow * width + neighbourColumn]
                        guard value.isFinite else {
                            throw RAWProcessingError.nonFiniteInputValue(
                                row: neighbourRow, column: neighbourColumn, value: value
                            )
                        }
                        sum += Double(value)
                        count += 1
                    }
                    guard count > 0 else {
                        throw RAWProcessingError.missingDemosaicNeighbors(
                            row: row, column: column, channel: wanted
                        )
                    }
                    let result = Float(sum / Double(count))
                    guard result.isFinite else {
                        throw RAWProcessingError.nonFiniteDemosaicResult(
                            row: row, column: column, channel: wanted
                        )
                    }
                    return result
                }

                var base = 0
                var index = 0
                for row in 0..<height {
                    let rowParity = row & 1
                    for column in 0..<width {
                        let centre = pattern.channel(
                            rowParity: rowParity, columnParity: column & 1
                        )

                        // The native sample is copied, never averaged and
                        // never routed through Double, so its Float32 bit
                        // pattern survives exactly.
                        let native = input[index]
                        guard native.isFinite else {
                            initializedCount = base
                            throw RAWProcessingError.nonFiniteInputValue(
                                row: row, column: column, value: native
                            )
                        }

                        // All three channels are computed before any is
                        // written, so a throw mid-pixel leaves exactly the
                        // pixels before this one initialised.
                        let red: Float
                        let green: Float
                        let blue: Float
                        do {
                            switch centre {
                            case .red:
                                red = native
                                green = try interpolate(
                                    .green, from: axialOffsets, row: row, column: column
                                )
                                blue = try interpolate(
                                    .blue, from: diagonalOffsets, row: row, column: column
                                )
                            case .blue:
                                blue = native
                                green = try interpolate(
                                    .green, from: axialOffsets, row: row, column: column
                                )
                                red = try interpolate(
                                    .red, from: diagonalOffsets, row: row, column: column
                                )
                            case .green:
                                green = native
                                red = try interpolate(
                                    .red, from: axialOffsets, row: row, column: column
                                )
                                blue = try interpolate(
                                    .blue, from: axialOffsets, row: row, column: column
                                )
                            }
                        } catch {
                            initializedCount = base
                            throw error
                        }

                        buffer[base] = red
                        buffer[base + 1] = green
                        buffer[base + 2] = blue
                        base += DemosaicedRAWRGBImage.channelCount
                        index += 1
                    }
                }
                initializedCount = base
            }
        }
    }
}
