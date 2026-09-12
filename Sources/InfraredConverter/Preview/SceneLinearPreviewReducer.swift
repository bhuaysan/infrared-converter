import Foundation

/// `WorkingColorRGBImage` → `SceneLinearPreviewImage`: the one stage that
/// makes the interactive workspace cheap.
///
/// ```text
/// WorkingColorRGBImage        extended linear sRGB, sensor resolution
///       │
///       │  PreviewResolutionPolicy decides the size
///       │  area-weighted mean decides the values
///       ↓
/// SceneLinearPreviewImage     extended linear sRGB, preview resolution
/// ```
///
/// ## Why here, and not one stage earlier
///
/// One stage earlier is the mosaic domain, and a CFA mosaic is not an image.
/// Its neighbouring samples are different colours — red, green and blue sit at
/// different positions of the same 2x2 cell, and a non-Bayer layout such as
/// X-Trans has a larger and less regular period still. Averaging neighbouring
/// mosaic samples averages *across colour filters*, which produces a smaller
/// buffer whose pattern semantics have been destroyed, and then demosaicing it
/// as though the pattern survived produces colours that came from nowhere.
///
/// ```text
/// FORBIDDEN
/// CFA mosaic → generic 2x2 or bilinear resize → demosaic as if still a CFA
/// ```
///
/// A CFA-aware reduction is a real technique and is not ruled out forever; it
/// would need its own invariant, its own per-layout handling and its own
/// tests. It is not needed here, because a correct point exists downstream:
/// once demosaicing has run, every pixel carries all three channels and an
/// ordinary image filter means what it says.
///
/// ## Why here, and not one stage later
///
/// One stage later is the creative channel mix, and mixing is the next thing
/// the workspace will let a user change. Reducing after it would bake one mix
/// into the retained buffer, so changing the mix would have to re-decode,
/// re-normalise, re-balance, re-demosaic and re-convert the whole file — the
/// exact full-resolution work this milestone removes.
///
/// Reducing *before* the mix costs nothing to do and keeps that door open: the
/// reduced image is the pre-creative working representation, and the mix runs
/// on 3.1 megapixels instead of 12.3.
///
/// ## Why the point does not change the pixels
///
/// Every transformation between demosaicing and orientation is a per-pixel
/// linear map with no offset — a 3x3 matrix for the camera-to-working
/// transform, another for the channel mix — and an area-weighted mean is a
/// weighted sum. Matrix multiplication distributes over weighted sums, so
///
/// ```text
/// reduce(M · image)  ==  M · reduce(image)
/// ```
///
/// exactly, in real arithmetic, and to within floating-point rounding here.
/// The choice of point is therefore an engineering decision about cost and
/// future flexibility, not a colour decision — and the claim is tested rather
/// than asserted, in `SceneLinearPreviewEquivalenceTests`.
///
/// ## The filter
///
/// **Area-weighted averaging.** Each destination pixel's footprint is the
/// exact rectangle of source pixels it maps to; each source pixel contributes
/// in proportion to how much of that rectangle it covers, and the sum is
/// divided by the total weight.
///
/// ```text
/// destination column d covers source x in [d·sw/dw, (d+1)·sw/dw)
/// ```
///
/// Nearest-neighbour is deliberately not used. Point sampling a photograph
/// throws away every sample it does not land on, so fine detail aliases into
/// coarse artefacts — foliage in particular, which is exactly what infrared
/// photography is full of. Area averaging is the reduction that answers "what
/// was the average light over this patch", which is the only question a
/// smaller rendition of a photograph can honestly answer.
///
/// It is computed **in the scene-linear domain, on Float32 values, with Double
/// accumulators**. Averaging light-proportional values is the physically
/// meaningful operation; averaging display-encoded ones darkens every texture
/// it touches. There is no 8-bit round trip anywhere in this stage, no
/// `CGImage`, no ColorSync, no implicit colour management: `Float` in,
/// `Double` accumulate, `Float` out.
///
/// Apple's `vImage` was considered and not used here. Its scaling entry points
/// want a planar or four-channel layout and their own buffer ownership, and
/// this project's storage is three interleaved Float32 per pixel; the
/// conversions needed to hand data over and back would cost more than the
/// arithmetic they replace, and would put an unauditable resampling kernel in
/// the middle of the one stage whose exactness this milestone has to
/// demonstrate. A correct, measured reference implementation comes first.
///
/// ## Cost
///
/// `O(source pixel count)`: every source pixel is read once per destination
/// pixel it overlaps, which for a reduction is a small constant. One owned
/// output allocation of `destination pixel count * 3` floats, plus two span
/// tables whose combined size is `O(sourceWidth + sourceHeight)`. No
/// full-frame intermediate and no `Double` image buffer.
///
/// ## Cancellation
///
/// Polled once before anything is allocated and once per destination row, the
/// same contract `ImageOrienter` and `DisplayPreviewRenderer` follow. A
/// cancelled reduction throws `CancellationError` and abandons its buffer; it
/// never returns a partially written image.
public struct SceneLinearPreviewReducer: Sendable {
    public init() {}

    /// Reduces a working-colour image to preview resolution.
    ///
    /// - Parameters:
    ///   - image: extended-linear-sRGB coordinates at full resolution, as
    ///     `RAWWorkingColorConverter` produces. Not mutated and not clamped.
    ///   - policy: the size rule. Required — there is deliberately no default,
    ///     for the same reason no other stage here has one.
    ///   - cancellation: polled once before allocation and once per
    ///     destination row.
    /// - Returns: the reduced image, carrying the full-resolution dimensions,
    ///   the policy and the method it was made by.
    /// - Throws: `PreviewReductionError`, or `CancellationError`.
    public func reduce(
        _ image: WorkingColorRGBImage,
        policy: PreviewResolutionPolicy,
        cancellation: ProcessingCancellation = .none
    ) throws -> SceneLinearPreviewImage {
        guard image.isGeometryConsistent else {
            throw PreviewReductionError.invalidGeometry(
                reason: """
                    Working-colour RGB geometry \(image.width)x\(image.height) needs \
                    \(image.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(image.values.count).
                    """
            )
        }

        guard let size = policy.reducedSize(width: image.width, height: image.height) else {
            throw PreviewReductionError.unusablePreviewSize(
                sourceWidth: image.width,
                sourceHeight: image.height,
                maximumLongestEdge: policy.maximumLongestEdge
            )
        }

        // Before anything is allocated: a caller that has already superseded
        // this call gets nothing built for it at all.
        try cancellation.check()

        let isReduced = size.width != image.width || size.height != image.height
        let resolution = PreviewResolution(
            sourceWidth: image.width,
            sourceHeight: image.height,
            width: size.width,
            height: size.height,
            policy: policy,
            method: isReduced ? .areaAverage : .unreduced
        )

        let values: [Float]
        if isReduced {
            values = try Self.areaAveraged(
                image.values,
                sourceWidth: image.width,
                sourceHeight: image.height,
                destinationWidth: size.width,
                destinationHeight: size.height,
                cancellation: cancellation
            )
        } else {
            // Already within the limit. The preview *is* the full-resolution
            // image: the values are handed straight over, which `Array`'s
            // copy-on-write makes free and which keeps every bit pattern —
            // signed zeros included — exactly as it was. The sweep for
            // non-finite values still runs, so the stage's output contract
            // holds on both paths.
            try Self.validateFinite(
                image.values, width: image.width, height: image.height
            )
            values = image.values
        }

        return SceneLinearPreviewImage(
            width: size.width,
            height: size.height,
            values: values,
            processing: SceneLinearPreviewProcessing(
                resolution: resolution,
                workingColorProcessing: image.processing
            )
        )
    }

    // MARK: - The filter

    /// One source pixel's contribution to one destination pixel.
    private struct Span {
        let first: Int
        let count: Int
        /// Weights for `first ..< first + count`, in order.
        let weights: [Double]
    }

    /// The exact overlap of each destination index with the source indices it
    /// covers.
    ///
    /// For destination `d` of `destination`, the covered source interval is
    /// `[d·scale, (d+1)·scale)` with `scale = source / destination >= 1`. Each
    /// whole source index in that interval contributes the length of the
    /// overlap, so the weights for one destination index sum to `scale` and
    /// the partial pixels at both ends are counted in proportion.
    ///
    /// Building the tables once, outside the pixel loop, is what keeps the
    /// inner loop free of division.
    private static func spans(source: Int, destination: Int) -> [Span] {
        let scale = Double(source) / Double(destination)
        var spans: [Span] = []
        spans.reserveCapacity(destination)

        for index in 0..<destination {
            let start = Double(index) * scale
            // The last destination index ends exactly at the source edge,
            // rather than at an accumulated-rounding approximation of it.
            let end = index == destination - 1
                ? Double(source)
                : min(Double(source), Double(index + 1) * scale)

            let first = min(source - 1, max(0, Int(start.rounded(.down))))
            // `end` is exclusive, so `ceil(end) - 1` is the last source
            // index that overlaps it — for a fractional end and for one that
            // lands exactly on a source boundary alike.
            let last = min(source - 1, max(first, Int(end.rounded(.up)) - 1))

            var weights: [Double] = []
            weights.reserveCapacity(last - first + 1)
            for sourceIndex in first...last {
                let overlap = min(end, Double(sourceIndex + 1)) - max(start, Double(sourceIndex))
                weights.append(max(0, overlap))
            }
            spans.append(Span(first: first, count: last - first + 1, weights: weights))
        }
        return spans
    }

    /// The area-weighted mean, per channel, over `Double` accumulators.
    private static func areaAveraged(
        _ values: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int,
        cancellation: ProcessingCancellation
    ) throws -> [Float] {
        let columnSpans = spans(source: sourceWidth, destination: destinationWidth)
        let rowSpans = spans(source: sourceHeight, destination: destinationHeight)
        let channels = SceneLinearPreviewImage.channelCount
        let outputCount = destinationWidth * destinationHeight * channels

        return try [Float](unsafeUninitializedCapacity: outputCount) { buffer, initializedCount in
            initializedCount = 0
            try values.withUnsafeBufferPointer { input in
                var destination = 0
                for destinationRow in 0..<destinationHeight {
                    // One poll per destination row. Throwing here abandons the
                    // whole array: the caller gets `CancellationError`, never
                    // an image with some rows written and the rest not.
                    if cancellation.isCancelled {
                        initializedCount = destination
                        throw CancellationError()
                    }

                    let rowSpan = rowSpans[destinationRow]
                    for destinationColumn in 0..<destinationWidth {
                        let columnSpan = columnSpans[destinationColumn]

                        var red = 0.0
                        var green = 0.0
                        var blue = 0.0
                        var totalWeight = 0.0

                        for rowOffset in 0..<rowSpan.count {
                            let sourceRow = rowSpan.first + rowOffset
                            let rowWeight = rowSpan.weights[rowOffset]
                            let rowBase = sourceRow * sourceWidth

                            for columnOffset in 0..<columnSpan.count {
                                let sourceColumn = columnSpan.first + columnOffset
                                let weight = rowWeight * columnSpan.weights[columnOffset]
                                let base = (rowBase + sourceColumn) * channels

                                let sampleRed = input[base]
                                let sampleGreen = input[base + 1]
                                let sampleBlue = input[base + 2]

                                // A hand-built image can carry anything, and a
                                // single NaN averaged into a neighbourhood
                                // would poison every destination pixel that
                                // overlaps it. Reported with the *source*
                                // coordinate, which is the one a reader can
                                // go and look at.
                                guard sampleRed.isFinite else {
                                    initializedCount = destination
                                    throw PreviewReductionError.nonFiniteInput(
                                        row: sourceRow, column: sourceColumn,
                                        channel: .red, value: sampleRed
                                    )
                                }
                                guard sampleGreen.isFinite else {
                                    initializedCount = destination
                                    throw PreviewReductionError.nonFiniteInput(
                                        row: sourceRow, column: sourceColumn,
                                        channel: .green, value: sampleGreen
                                    )
                                }
                                guard sampleBlue.isFinite else {
                                    initializedCount = destination
                                    throw PreviewReductionError.nonFiniteInput(
                                        row: sourceRow, column: sourceColumn,
                                        channel: .blue, value: sampleBlue
                                    )
                                }

                                red += weight * Double(sampleRed)
                                green += weight * Double(sampleGreen)
                                blue += weight * Double(sampleBlue)
                                totalWeight += weight
                            }
                        }

                        // Every destination pixel covers a positive area of a
                        // positive-sized source, so this cannot currently be
                        // zero. Checked rather than assumed, because the
                        // alternative to a check is a NaN in an image.
                        guard totalWeight > 0 else {
                            initializedCount = destination
                            throw PreviewReductionError.nonFiniteResult(
                                row: destinationRow, column: destinationColumn, channel: .red
                            )
                        }

                        // Narrowed to Float exactly once per channel, after
                        // the whole sum. Channels are accumulated separately
                        // and never read each other, so a reduction cannot
                        // exchange or blend them.
                        let meanRed = Float(red / totalWeight)
                        let meanGreen = Float(green / totalWeight)
                        let meanBlue = Float(blue / totalWeight)

                        guard meanRed.isFinite else {
                            initializedCount = destination
                            throw PreviewReductionError.nonFiniteResult(
                                row: destinationRow, column: destinationColumn, channel: .red
                            )
                        }
                        guard meanGreen.isFinite else {
                            initializedCount = destination
                            throw PreviewReductionError.nonFiniteResult(
                                row: destinationRow, column: destinationColumn, channel: .green
                            )
                        }
                        guard meanBlue.isFinite else {
                            initializedCount = destination
                            throw PreviewReductionError.nonFiniteResult(
                                row: destinationRow, column: destinationColumn, channel: .blue
                            )
                        }

                        buffer[destination] = meanRed
                        buffer[destination + 1] = meanGreen
                        buffer[destination + 2] = meanBlue
                        destination += channels
                    }
                }
                initializedCount = destination
            }
        }
    }

    /// Sweeps a buffer for non-finite values, reporting the first with its
    /// coordinate and channel. Reads only; allocates nothing.
    private static func validateFinite(
        _ values: [Float], width: Int, height: Int
    ) throws {
        try values.withUnsafeBufferPointer { input in
            var base = 0
            for row in 0..<height {
                for column in 0..<width {
                    let red = input[base]
                    let green = input[base + 1]
                    let blue = input[base + 2]
                    guard red.isFinite else {
                        throw PreviewReductionError.nonFiniteInput(
                            row: row, column: column, channel: .red, value: red
                        )
                    }
                    guard green.isFinite else {
                        throw PreviewReductionError.nonFiniteInput(
                            row: row, column: column, channel: .green, value: green
                        )
                    }
                    guard blue.isFinite else {
                        throw PreviewReductionError.nonFiniteInput(
                            row: row, column: column, channel: .blue, value: blue
                        )
                    }
                    base += SceneLinearPreviewImage.channelCount
                }
            }
        }
    }
}

extension SceneLinearPreviewReducer {
    /// The bare-values entry point, for callers that already know the
    /// destination size and hold no image type — principally the equivalence
    /// tests, which have to reduce a channel-mixed buffer and a working-colour
    /// buffer through the identical filter to compare them.
    ///
    /// Module-internal on purpose. A public API taking loose arrays would make
    /// it possible to reduce anything at all, including display-encoded bytes,
    /// which is precisely the mistake the typed entry point exists to prevent.
    static func reducedValues(
        _ values: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int,
        cancellation: ProcessingCancellation = .none
    ) throws -> [Float] {
        guard sourceWidth > 0, sourceHeight > 0,
              destinationWidth > 0, destinationHeight > 0,
              destinationWidth <= sourceWidth, destinationHeight <= sourceHeight,
              values.count == sourceWidth * sourceHeight * SceneLinearPreviewImage.channelCount
        else {
            throw PreviewReductionError.invalidGeometry(
                reason: """
                    Cannot reduce \(sourceWidth)x\(sourceHeight) to \
                    \(destinationWidth)x\(destinationHeight) from \(values.count) values.
                    """
            )
        }
        guard destinationWidth != sourceWidth || destinationHeight != sourceHeight else {
            try validateFinite(values, width: sourceWidth, height: sourceHeight)
            return values
        }
        return try areaAveraged(
            values,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            destinationWidth: destinationWidth,
            destinationHeight: destinationHeight,
            cancellation: cancellation
        )
    }
}
