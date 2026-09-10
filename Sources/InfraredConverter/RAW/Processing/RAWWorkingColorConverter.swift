import Foundation

/// The application-owned working-colour stage: `DemosaicedRAWRGBImage` →
/// `WorkingColorRGBImage`, by one explicit 3×3 camera-to-working transform.
///
/// ```text
/// WhiteBalancedRAWMosaic
///       ↓
/// RAWDemosaicer
///       ↓
/// DemosaicedRAWRGBImage             ← linear camera-native sensor RGB
///       │
///       │  explicit RAWCameraToWorkingColorTransform
///       ↓
/// RAWWorkingColorConverter          ← this stage
///       ↓
/// WorkingColorRGBImage              ← extended linear sRGB, unclamped Float32
///       ↓
/// [FUTURE: IR channel mixer / false-colour creative transform]
///       ↓
/// [FUTURE: exposure / tone]
///       ↓
/// [FUTURE: display encoding / preview]
/// ```
///
/// ## One primitive, no policy
///
/// This stage decides nothing. It takes a transform the caller chose and
/// applies it, exactly as `RAWWhiteBalancer` takes gains someone else
/// estimated. There is **no default transform argument** on any entry point,
/// on purpose: which mapping suits an infrared capture is not a question the
/// project can answer on the caller's behalf today, so the caller answers it
/// visibly, in one of three ways —
///
/// ```text
/// .sensorRGBIdentityFalseColor          IR-safe, assumption-minimal
/// .explicit(matrix:)                    a matrix the caller decided on
/// .visibleLightMetadata(from:)          opt-in, diagnostic, visible-light
/// ```
///
/// ## No metadata reaches this stage
///
/// The core entry point takes an image and a transform, and there is no
/// parameter a `RAWMetadata` could arrive through. Nothing here discovers
/// `rgbFromCamera`, and there is no fallback order that reaches for it when
/// something else is missing — that policy does not exist. The visible-light
/// adapter may read `RAWMetadata.ColorMetadata` while *constructing* a
/// transform; once the transform exists this stage cannot tell where it came
/// from, and does not ask.
///
/// White balance is likewise not reconsidered here. It already happened in the
/// mosaic domain, per CFA plane, and `cameraMultipliers` and
/// `daylightMultipliers` are never read by this stage — applying them would be
/// a second white balance. `cameraFromXYZ` is not read and nothing is
/// inverted.
///
/// ## Arithmetic
///
/// Storage is `Float32` in and `Float32` out; the matrix is `Double`. Each
/// output channel is one dot product accumulated in `Double` and narrowed to
/// `Float` exactly once, because `Float32` intermediates can overflow where
/// the mathematical result cannot: with `2 × greatestFiniteMagnitude −
/// greatestFiniteMagnitude`, `Float` arithmetic reaches infinity on the first
/// multiplication and never comes back, while `Double` finishes at a value
/// `Float` represents perfectly. There is no `Double` image buffer — the
/// widening lives in three local accumulators, not in memory.
///
/// Nothing is clamped, in either direction. Negative coordinates are expected
/// from matrices with negative coefficients, coordinates above `1` from
/// highlights, and both are what an extended linear space is for.
///
/// ## Identity is bit-preserving
///
/// A transform whose matrix is exactly the identity takes a dedicated path
/// that never multiplies: every `Float` bit pattern survives, `-0.0` included.
/// See `convert(_:using:)`.
///
/// ## Cost
///
/// `O(pixel count)`, with nine multiplications and six additions per pixel for
/// a general matrix, one owned output allocation, one read pass over the
/// input, and the nine coefficients loaded once outside the loop. No full-frame
/// intermediate, no planar R/G/B copies, no `Double` image, no per-pixel array
/// or dictionary.
///
/// This is a reference CPU implementation. Metal, Accelerate, vDSP and Core
/// Image are deliberately absent: correctness and testability first,
/// optimisation after profiling. Extended linear sRGB was chosen partly
/// because it makes that later bridging straightforward.
public struct RAWWorkingColorConverter: Sendable {
    public init() {}

    /// Applies a camera-to-working transform to a linear camera-native RGB
    /// image.
    ///
    /// - Parameters:
    ///   - image: linear camera-native RGB, as `RAWDemosaicer` produces.
    ///   - transform: which working space, by which matrix, obtained how.
    ///     Required — there is deliberately no default.
    /// - Throws: `RAWProcessingError`.
    public func convert(
        _ image: DemosaicedRAWRGBImage,
        using transform: RAWCameraToWorkingColorTransform
    ) throws -> WorkingColorRGBImage {
        guard image.isGeometryConsistent else {
            throw RAWProcessingError.invalidGeometry(
                reason: """
                    Camera-native RGB geometry \(image.width)x\(image.height) needs \
                    \(image.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(image.values.count).
                    """
            )
        }

        let processing = RAWWorkingColorProcessing(
            transform: transform,
            demosaicProcessing: image.processing
        )

        let values: [Float]
        if transform.matrix.isIdentity {
            values = try Self.identityValues(image)
        } else {
            values = try Self.transformedValues(image, matrix: transform.matrix)
        }

        return WorkingColorRGBImage(
            width: image.width,
            height: image.height,
            values: values,
            processing: processing
        )
    }

    /// Applies a transform to a demosaiced result, keeping that whole
    /// camera-native state reachable on the returned value's `source`.
    ///
    /// Use this rather than the bare-image overload whenever the caller may
    /// want a different transform later: the result carries everything needed
    /// to restart from camera-native RGB, without demosaicing or decoding
    /// again.
    public func convert(
        _ processed: DemosaicedProcessedRAWImage,
        using transform: RAWCameraToWorkingColorTransform
    ) throws -> WorkingColorProcessedRAWImage {
        let image = try convert(processed.image, using: transform)
        return WorkingColorProcessedRAWImage(source: processed, image: image)
    }

    /// Replaces the transform on a previous result, starting again from the
    /// camera-native image it was produced from.
    ///
    /// Transforms never compose: replacing `M1` with `M2` yields
    /// `M2 × cameraRGB`, not `M2 × (M1 × cameraRGB)`. That is structural — this
    /// reaches through `previous.source` and never touches `previous.image`.
    public func convert(
        using newTransform: RAWCameraToWorkingColorTransform,
        replacing previous: WorkingColorProcessedRAWImage
    ) throws -> WorkingColorProcessedRAWImage {
        try convert(previous.source, using: newTransform)
    }

    // MARK: - Identity

    /// The identity path: the same numbers, in a different semantic state.
    ///
    /// The values are handed straight to the result. `Array`'s value semantics
    /// make that a copy-on-write reference to the same immutable backing
    /// storage — both sides expose `let` values, so neither can observe the
    /// other change — which means the E-PL3's 148 MB is not duplicated merely
    /// so the stage can claim to have allocated something. Bit identity is the
    /// contract; a `memcpy` would satisfy it more expensively and no more
    /// truly.
    ///
    /// The input is still swept for non-finite values, so the boundary
    /// defended by the general path is defended here too: a
    /// `WorkingColorRGBImage` this converter produced holds finite values
    /// whichever path made it. That sweep reads, and allocates nothing.
    private static func identityValues(_ image: DemosaicedRAWRGBImage) throws -> [Float] {
        try image.values.withUnsafeBufferPointer { input in
            var base = 0
            for row in 0..<image.height {
                for column in 0..<image.width {
                    let red = input[base]
                    let green = input[base + 1]
                    let blue = input[base + 2]
                    guard red.isFinite else {
                        throw RAWProcessingError.nonFiniteWorkingColorInput(
                            row: row, column: column, channel: .red, value: red
                        )
                    }
                    guard green.isFinite else {
                        throw RAWProcessingError.nonFiniteWorkingColorInput(
                            row: row, column: column, channel: .green, value: green
                        )
                    }
                    guard blue.isFinite else {
                        throw RAWProcessingError.nonFiniteWorkingColorInput(
                            row: row, column: column, channel: .blue, value: blue
                        )
                    }
                    base += DemosaicedRAWRGBImage.channelCount
                }
            }
        }
        return image.values
    }

    // MARK: - General 3×3

    /// The general path: one dot product per output channel, per pixel.
    ///
    /// One owned `[Float]` allocation, written once, from a borrowed read of
    /// the source. The nine coefficients are loaded into locals before the loop
    /// so the hot path is nine multiplications and six additions with no
    /// property access, and the row and column are tracked by the loop rather
    /// than recomputed by division.
    private static func transformedValues(
        _ image: DemosaicedRAWRGBImage,
        matrix: RAWColorMatrix3x3
    ) throws -> [Float] {
        // Loaded once, outside the per-pixel loop.
        let m00 = matrix.m00, m01 = matrix.m01, m02 = matrix.m02
        let m10 = matrix.m10, m11 = matrix.m11, m12 = matrix.m12
        let m20 = matrix.m20, m21 = matrix.m21, m22 = matrix.m22

        let outputCount = image.values.count
        let width = image.width
        let height = image.height

        return try [Float](unsafeUninitializedCapacity: outputCount) { buffer, initializedCount in
            initializedCount = 0
            try image.values.withUnsafeBufferPointer { input in
                var base = 0
                for row in 0..<height {
                    for column in 0..<width {
                        let cameraRed = input[base]
                        let cameraGreen = input[base + 1]
                        let cameraBlue = input[base + 2]

                        // A hand-built image can carry anything; a value that
                        // is not finite is reported with its coordinate and
                        // channel rather than multiplied and propagated. The
                        // three checks are written out rather than looped over
                        // `allCases`, which would allocate an array per pixel.
                        guard cameraRed.isFinite else {
                            initializedCount = base
                            throw RAWProcessingError.nonFiniteWorkingColorInput(
                                row: row, column: column, channel: .red, value: cameraRed
                            )
                        }
                        guard cameraGreen.isFinite else {
                            initializedCount = base
                            throw RAWProcessingError.nonFiniteWorkingColorInput(
                                row: row, column: column, channel: .green, value: cameraGreen
                            )
                        }
                        guard cameraBlue.isFinite else {
                            initializedCount = base
                            throw RAWProcessingError.nonFiniteWorkingColorInput(
                                row: row, column: column, channel: .blue, value: cameraBlue
                            )
                        }

                        let red = Double(cameraRed)
                        let green = Double(cameraGreen)
                        let blue = Double(cameraBlue)

                        // Rows are output channels, columns input camera
                        // channels — the convention RAWColorMatrix3x3 fixes.
                        // Accumulated in Double: a Float32 intermediate can
                        // overflow where the mathematical result cannot.
                        let workingRed = Float(m00 * red + m01 * green + m02 * blue)
                        let workingGreen = Float(m10 * red + m11 * green + m12 * blue)
                        let workingBlue = Float(m20 * red + m21 * green + m22 * blue)

                        // Narrowed exactly once per channel, above. A Double
                        // result that is not finite, and a finite Double that
                        // overflows Float32 on narrowing, both fail here
                        // rather than being clamped to a plausible number.
                        guard workingRed.isFinite else {
                            initializedCount = base
                            throw RAWProcessingError.nonFiniteWorkingColorResult(
                                row: row, column: column, channel: .red
                            )
                        }
                        guard workingGreen.isFinite else {
                            initializedCount = base
                            throw RAWProcessingError.nonFiniteWorkingColorResult(
                                row: row, column: column, channel: .green
                            )
                        }
                        guard workingBlue.isFinite else {
                            initializedCount = base
                            throw RAWProcessingError.nonFiniteWorkingColorResult(
                                row: row, column: column, channel: .blue
                            )
                        }

                        buffer[base] = workingRed
                        buffer[base + 1] = workingGreen
                        buffer[base + 2] = workingBlue
                        base += WorkingColorRGBImage.channelCount
                    }
                }
                initializedCount = base
            }
        }
    }
}
