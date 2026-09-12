import Foundation

/// The geometry stage: `IRChannelMixedRGBImage` →
/// `OrientedSceneLinearRGBImage`, by one of eight discrete rearrangements of
/// whole pixels.
///
/// ```text
/// WorkingColorRGBImage              extended linear sRGB, unclamped Float32
///       ↓
/// IRChannelMixer                    creative 3×3 mix — ADR 0007
///       ↓
/// IRChannelMixedRGBImage            the same space, in SENSOR order
///       │
///       │  explicit RAWImageOrientation
///       ↓
/// ImageOrienter                     ← this stage
///       ↓
/// OrientedSceneLinearRGBImage       the same values, in VIEWING order
///       ↓
/// DisplayPreviewRenderer            exposure, clip, encode — ADR 0008
///       ↓
/// DisplayEncodedPreviewImage
/// ```
///
/// See `docs/decisions/0009-application-owned-orientation.md`.
///
/// ## Why this is its own stage
///
/// It is the only stage in the pipeline that changes **where** a pixel is, and
/// the only one that can change the image's width and height. Folding it into
/// a neighbour would hide a geometry operation inside something else:
///
/// - Inside the **demosaicer** it would be wrong as well as hidden. A CFA
///   layout is defined in sensor coordinates; rotating before or during
///   interpolation would invalidate the very pattern the interpolation reads.
/// - Inside the **display encoder** it would be invisible. That stage's whole
///   claim is that it is per-component and geometry-preserving, and a rotation
///   smuggled into it would make the one record meant to describe the pipeline
///   describe it wrongly.
///
/// So it sits between them, after every colour decision and before the display
/// boundary, where it changes nothing but arrangement.
///
/// ## It decides nothing
///
/// There is **no default orientation** on any entry point, and this stage
/// never reads `RAWMetadata`. It applies the `RAWImageOrientation` a caller
/// passed in — as `IRChannelMixer` applies a mix someone else chose, and
/// `RAWWhiteBalancer` applies gains someone else estimated. Where that
/// orientation came from, and what to do when a file's own value cannot be
/// mapped, are decisions for the layer that holds the metadata.
///
/// ## Values are moved, never computed
///
/// Each destination pixel's three `Float` components are copied from exactly
/// one source pixel. No arithmetic touches them, so **bit patterns survive
/// exactly** — signed zeros, subnormals, and non-finite values included. The
/// stage reads no component as a number and therefore refuses none; a NaN is
/// `DisplayPreviewRenderer`'s problem, at the boundary that genuinely cannot
/// proceed with one.
///
/// There is no interpolation because none is possible to need: the eight
/// orientations are exact permutations of the sample grid. Arbitrary-angle
/// rotation, which *would* need resampling, is deliberately not here.
///
/// ## A gather, not a scatter
///
/// The loop runs over **destination** coordinates and asks each one where its
/// pixel comes from. Every output element is therefore written exactly once,
/// by construction rather than by argument — no output can be left
/// uninitialised and none can be written twice. The mapping itself is
/// `RAWImageOrientation.sourceCoordinate(row:column:sourceWidth:sourceHeight:)`,
/// one explicit switch over eight written-out formulas, deliberately not a
/// matrix: a reader has to be able to audit the `w − 1` and `h − 1` terms and
/// which axis each attaches to, and a 2×3 affine abstraction makes that
/// harder, not easier.
///
/// ## Cancellation
///
/// The permutation is one synchronous pass over every pixel, so a caller that
/// has superseded it needs a way to stop it rather than merely discard it.
/// `apply` takes a `ProcessingCancellation` and polls it **once before any
/// work, and once more before each destination row**. A stated granularity is
/// the point: a test can predict the poll count exactly, which is how
/// abandoning the work early is proven rather than assumed.
///
/// A cancelled call throws `CancellationError` and returns no image at all.
/// It is not an `OrientationError`: nothing about the image was wrong.
///
/// ## Cost
///
/// `O(pixel count)`: one owned output buffer the same size as the input, one
/// read pass, three `Float` copies per pixel and no arithmetic on values. The
/// `.upright` path allocates nothing at all — it validates and hands the same
/// immutable array back, which `Array`'s copy-on-write makes free.
///
/// Memory locality is honest about itself: the four transposing orientations
/// read the source down columns while writing the destination along rows, so
/// they are cache-hostile on a large frame. That is a known property of a
/// straightforward implementation, not a measured problem — no tiled or
/// blocked variant is written until measurement asks for one.
///
/// This is a reference CPU implementation. Metal, Accelerate, vDSP and Core
/// Image are deliberately absent.
public struct ImageOrienter: Sendable {
    public init() {}

    /// Applies an orientation to a channel-mixed image.
    ///
    /// - Parameters:
    ///   - image: extended-linear-sRGB coordinates in sensor order, as
    ///     `IRChannelMixer` produces. Not mutated, not clamped, not modified
    ///     in any way.
    ///   - orientation: which of the eight arrangements to apply. Required —
    ///     there is deliberately no default.
    ///   - cancellation: polled once here and once per destination row.
    ///     Defaults to never cancelling.
    /// - Throws: `OrientationError`, or `CancellationError` when the work was
    ///   superseded. The two are deliberately distinct types: one says the
    ///   image could not be oriented, the other says nobody wants it.
    public func apply(
        to image: IRChannelMixedRGBImage,
        orientation: RAWImageOrientation,
        cancellation: ProcessingCancellation = .none
    ) throws -> OrientedSceneLinearRGBImage {
        guard image.isGeometryConsistent else {
            throw OrientationError.invalidGeometry(
                reason: """
                    Channel-mixed RGB geometry \(image.width)x\(image.height) needs \
                    \(image.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(image.values.count).
                    """
            )
        }

        // Before anything is allocated: a caller that has already superseded
        // this call gets nothing built for it at all.
        try cancellation.check()

        let output = orientation.outputDimensions(
            sourceWidth: image.width, sourceHeight: image.height
        )

        // A consistent input already proves this product is representable —
        // orientation only exchanges the two factors, and the element count is
        // exactly the one the input's buffer already has — so this cannot
        // currently fail. Checked rather than assumed, because the alternative
        // to a check here is a trap in an allocation.
        guard let outputCount = OrientedSceneLinearRGBImage.expectedValueCount(
            width: output.width, height: output.height
        ), outputCount == image.values.count else {
            throw OrientationError.unrepresentableOrientedGeometry(
                reason: """
                    Orienting \(image.width)x\(image.height) as \
                    \(orientation.diagnosticDescription) gives \(output.width)x\
                    \(output.height), which does not yield the source's \
                    \(image.values.count) values.
                    """
            )
        }

        let processing = ImageOrientationProcessing(
            orientation: orientation,
            channelMixProcessing: image.processing
        )

        return OrientedSceneLinearRGBImage(
            width: output.width,
            height: output.height,
            values: orientation.isIdentity
                ? image.values
                : try Self.permutedValues(
                    image.values,
                    sourceWidth: image.width,
                    sourceHeight: image.height,
                    orientation: orientation,
                    output: output,
                    cancellation: cancellation
                ),
            processing: processing
        )
    }

    /// Applies an orientation to a **reduced, channel-mixed** scene-linear
    /// preview.
    ///
    /// The only entry point the interactive workspace uses. It permutes the
    /// preview-resolution buffer — 3.1 megapixels on the E-PL3 rather than
    /// 12.3 — and nothing upstream of the creative mix runs: no camera
    /// conversion, no demosaic, no white balance, no decode, and no
    /// resampling. The size was decided once, on the unoriented image, and an
    /// orientation can only exchange the two dimensions, never re-open the
    /// question.
    ///
    /// The reduction is recorded on the result's provenance, so a finished
    /// preview says that its pixels are a smaller rendition rather than the
    /// sensor's own.
    ///
    /// The input type is the **post-mix** one, and that is what makes the
    /// provenance chain complete by construction: the orientation record
    /// carries the whole history through `channelMixProcessing`, and a preview
    /// the creative stage had not run on has no such history to carry. There
    /// used to be a runtime refusal for that case; now there is no overload
    /// for it. See `docs/decisions/0016-interactive-channel-mixer.md`.
    public func apply(
        to preview: IRChannelMixedPreviewImage,
        orientation: RAWImageOrientation,
        cancellation: ProcessingCancellation = .none
    ) throws -> OrientedSceneLinearRGBImage {
        guard preview.isGeometryConsistent else {
            throw OrientationError.invalidGeometry(
                reason: """
                    Preview scene-linear RGB geometry \(preview.width)x\(preview.height) needs \
                    \(preview.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(preview.values.count).
                    """
            )
        }

        try cancellation.check()

        let output = orientation.outputDimensions(
            sourceWidth: preview.width, sourceHeight: preview.height
        )
        guard let outputCount = OrientedSceneLinearRGBImage.expectedValueCount(
            width: output.width, height: output.height
        ), outputCount == preview.values.count else {
            throw OrientationError.unrepresentableOrientedGeometry(
                reason: """
                    Orienting \(preview.width)x\(preview.height) as \
                    \(orientation.diagnosticDescription) gives \(output.width)x\
                    \(output.height), which does not yield the source's \
                    \(preview.values.count) values.
                    """
            )
        }

        return OrientedSceneLinearRGBImage(
            width: output.width,
            height: output.height,
            values: orientation.isIdentity
                ? preview.values
                : try Self.permutedValues(
                    preview.values,
                    sourceWidth: preview.width,
                    sourceHeight: preview.height,
                    orientation: orientation,
                    output: output,
                    cancellation: cancellation
                ),
            processing: ImageOrientationProcessing(
                orientation: orientation,
                channelMixProcessing: preview.processing.channelMixProcessing,
                previewResolution: preview.processing.resolution
            )
        )
    }

    /// Applies an orientation to a channel-mixed result, keeping that whole
    /// unoriented state reachable on the returned value's `source`.
    ///
    /// Use this rather than the bare-image overload whenever the caller may
    /// want a different orientation later: the result carries everything
    /// needed to restart from the unoriented image, without mixing,
    /// converting, demosaicing or decoding again.
    public func apply(
        to processed: IRChannelMixedProcessedRAWImage,
        orientation: RAWImageOrientation,
        cancellation: ProcessingCancellation = .none
    ) throws -> OrientedProcessedRAWImage {
        let image = try apply(
            to: processed.image, orientation: orientation, cancellation: cancellation
        )
        return OrientedProcessedRAWImage(source: processed, image: image)
    }

    /// Replaces the orientation on a previous result, starting again from the
    /// channel-mixed image it was produced from.
    ///
    /// Orientations never compose: replacing `O1` with `O2` yields
    /// `orient(mixed, O2)`, not `orient(orient(mixed, O1), O2)`. That is
    /// structural — this reaches through `previous.source` and never touches
    /// `previous.image`.
    ///
    /// The failure mode it prevents is unusually quiet. The eight orientations
    /// are closed under composition, so a chained result is always *a* valid
    /// orientation of the photograph and never looks malformed; it is simply
    /// not the one that was asked for, while provenance records the one that
    /// was.
    ///
    /// Nothing upstream reruns: no channel mix, no camera conversion, no
    /// demosaic, no white balance, no decode.
    public func apply(
        orientation newOrientation: RAWImageOrientation,
        replacing previous: OrientedProcessedRAWImage,
        cancellation: ProcessingCancellation = .none
    ) throws -> OrientedProcessedRAWImage {
        try apply(
            to: previous.source, orientation: newOrientation, cancellation: cancellation
        )
    }

    // MARK: - The permutation

    /// Gathers every destination pixel from its one source pixel.
    ///
    /// Called only for the seven non-identity orientations; `.upright` hands
    /// the input array back instead, which is both free and exactly as
    /// faithful.
    ///
    /// The source index is computed from the source coordinate with plain
    /// `Int` arithmetic and no overflow checks, which is sound here for a
    /// reason worth stating: the caller has already established that the
    /// source buffer's element count — `sourceWidth * sourceHeight * 3` — is a
    /// representable `Int`, and every index computed below is bounded by it.
    private static func permutedValues(
        _ values: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        orientation: RAWImageOrientation,
        output: (width: Int, height: Int),
        cancellation: ProcessingCancellation
    ) throws -> [Float] {
        let channels = OrientedSceneLinearRGBImage.channelCount
        let outputCount = values.count

        return try [Float](unsafeUninitializedCapacity: outputCount) { buffer, initializedCount in
            try values.withUnsafeBufferPointer { input in
                var destination = 0
                for row in 0..<output.height {
                    // One poll per destination row. Throwing here abandons the
                    // whole array — the caller gets `CancellationError`, never
                    // an image with some rows written and the rest not.
                    if cancellation.isCancelled {
                        // `Float` is trivial, so nothing needs destroying;
                        // the count is kept honest anyway rather than left
                        // stale for a future element type to trip over.
                        initializedCount = destination
                        throw CancellationError()
                    }
                    for column in 0..<output.width {
                        let source = orientation.sourceCoordinate(
                            row: row,
                            column: column,
                            sourceWidth: sourceWidth,
                            sourceHeight: sourceHeight
                        )
                        let base = (source.row * sourceWidth + source.column) * channels

                        // Copies, not arithmetic: every bit survives, and the
                        // three are written out rather than looped over
                        // `RAWLinearRGBChannel.allCases`, which would allocate
                        // an array per pixel.
                        buffer[destination] = input[base]
                        buffer[destination + 1] = input[base + 1]
                        buffer[destination + 2] = input[base + 2]
                        destination += channels
                    }
                }
                initializedCount = destination
            }
        }
    }
}
