import Foundation

/// The first explicitly creative stage: `WorkingColorRGBImage` →
/// `IRChannelMixedRGBImage`, by one linear 3×3 RGB channel mix applied inside
/// the working colour space.
///
/// ```text
/// DemosaicedRAWRGBImage             linear camera-native sensor RGB
///       ↓
/// RAWWorkingColorConverter          explicit camera → working transform
///       ↓
/// WorkingColorRGBImage              extended linear sRGB, unclamped Float32
///       │
///       │  explicit IRChannelMix
///       ↓
/// IRChannelMixer                    ← this stage
///       ↓
/// IRChannelMixedRGBImage            the SAME space, creatively remixed
///       ↓
/// [FUTURE: exposure / tone]
///       ↓
/// [FUTURE: display encoding / preview]
/// ```
///
/// ## A different question from the camera transform
///
/// ```text
/// RAWCameraToWorkingColorTransform
///     How do camera-native sensor responses enter our working colour space?
///
/// IRChannelMix
///     Once we are already in that space, how do we creatively remix RGB
///     for infrared rendering?
/// ```
///
/// Both are 3×3 matrices; they are not the same operation, and this stage is
/// never merged with the one before it. What happens here is **creative
/// intent** and is recorded as such — never as camera calibration, camera
/// colour conversion, white balance, working-space establishment or filter
/// calibration.
///
/// ## What this stage does not do
///
/// The colour space does not change: no new primaries, no chromatic
/// adaptation, no conversion. White balance does not run again — it happened
/// per CFA plane in the mosaic domain, and there are no CFA planes here.
/// `RAWMetadata` is not consulted at all: the core entry point takes an image
/// and a mix, and there is no parameter metadata could arrive through, so
/// `rgbFromCamera`, `cameraFromXYZ`, `cameraMultipliers`,
/// `daylightMultipliers` and the camera's make and model cannot change a
/// single output value. No gamma, tone mapping, exposure, display encoding or
/// orientation happens either.
///
/// ## One primitive, no policy
///
/// This stage decides nothing. It takes a mix the caller chose and applies it,
/// as `RAWWhiteBalancer` takes gains someone else estimated. There is **no
/// default mix argument** on any entry point: which rendering an infrared
/// capture deserves is a creative decision, made at the call site in one of
/// three visible ways —
///
/// ```text
/// .identity                  traverse the stage, remap nothing
/// .redBlueSwap               the canonical first IR creative operation
/// .explicit(matrix:)         a matrix the caller decided on
/// ```
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
/// Nothing is clamped, in either direction, and nothing is normalised or
/// rescaled. Negative coordinates and coordinates above `1` are exactly what a
/// creative mix with negative or amplifying coefficients is for.
///
/// ## Two exact paths, chosen by the matrix
///
/// - **Identity** performs no arithmetic at all: every accepted value's
///   `Float` bit pattern survives, `-0.0` included.
/// - **The red/blue permutation** copies channels rather than computing three
///   dot products, which is both cheaper and *more exact*: `0*R + 0*G + 1*B`
///   is mathematically right but can change a signed zero's sign, and a
///   permutation should not alter a single bit.
///
/// "Accepted" is the operative word on both. The stage's input contract is
/// **finite** `Float32`, and both paths enforce it before they preserve
/// anything: a NaN or an infinity is refused with its coordinate and channel,
/// on every path, not copied through. So the guarantee is that no finite value
/// this stage accepts is altered by an identity or a permutation — not that
/// every `Float32` bit pattern reaches the output.
///
/// The execution path is decided by the **matrix value**; the provenance is
/// decided by how the `IRChannelMix` was constructed. An
/// `.explicit(matrix:)` mix whose matrix equals a built-in takes the fast path
/// and keeps `.explicit` provenance. The two facts are never allowed to
/// contaminate each other.
///
/// ## Cost
///
/// `O(pixel count)`. A general matrix does nine multiplications and six
/// additions per pixel, with one owned output allocation, one read pass over
/// the input, and the nine coefficients loaded once outside the loop. The
/// permutation path reads and writes one owned buffer with no arithmetic. The
/// identity path allocates nothing at all — it validates and hands the same
/// immutable array back, which `Array`'s copy-on-write makes free. No
/// full-frame intermediate, no planar copies, no `Double` image, no per-pixel
/// array or dictionary.
///
/// This is a reference CPU implementation. Metal, Accelerate, vDSP and Core
/// Image are deliberately absent: correctness and testability first,
/// optimisation after profiling.
public struct IRChannelMixer: Sendable {
    public init() {}

    /// Applies a creative channel mix to a working-colour image.
    ///
    /// - Parameters:
    ///   - image: extended-linear-sRGB coordinates, as
    ///     `RAWWorkingColorConverter` produces.
    ///   - mix: which matrix, authored for which working space, obtained how.
    ///     Required — there is deliberately no default.
    /// - Throws: `IRProcessingError`.
    public func apply(
        to image: WorkingColorRGBImage,
        mix: IRChannelMix
    ) throws -> IRChannelMixedRGBImage {
        guard image.isGeometryConsistent else {
            throw IRProcessingError.invalidGeometry(
                reason: """
                    Working-colour RGB geometry \(image.width)x\(image.height) needs \
                    \(image.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(image.values.count).
                    """
            )
        }
        // Coefficients are defined relative to the RGB axes they were authored
        // for, so a mix made for one working space must not run in another.
        // Exactly one space exists today, which makes this unreachable in
        // practice and worth keeping anyway: the invariant is about the first
        // day a second one exists, not about today.
        guard image.processing.workingColorSpace == mix.workingColorSpace else {
            throw IRProcessingError.channelMixWorkingColorSpaceMismatch(
                image: image.processing.workingColorSpace,
                mix: mix.workingColorSpace
            )
        }

        let processing = IRChannelMixProcessing(
            mix: mix,
            workingColorProcessing: image.processing
        )

        let values: [Float]
        if mix.matrix.isIdentity {
            values = try Self.identityValues(image)
        } else if mix.matrix == IRChannelMix.redBlueSwap.matrix {
            values = try Self.redBlueSwappedValues(image)
        } else {
            values = try Self.mixedValues(image, matrix: mix.matrix)
        }

        return IRChannelMixedRGBImage(
            width: image.width,
            height: image.height,
            values: values,
            processing: processing
        )
    }

    /// Applies a mix to a working-colour result, keeping that whole pre-mix
    /// state reachable on the returned value's `source`.
    ///
    /// Use this rather than the bare-image overload whenever the caller may
    /// want a different mix later: the result carries everything needed to
    /// restart from the pre-mix working image, without converting, demosaicing
    /// or decoding again.
    public func apply(
        to processed: WorkingColorProcessedRAWImage,
        mix: IRChannelMix
    ) throws -> IRChannelMixedProcessedRAWImage {
        let image = try apply(to: processed.image, mix: mix)
        return IRChannelMixedProcessedRAWImage(source: processed, image: image)
    }

    /// Replaces the mix on a previous result, starting again from the
    /// working-colour image it was produced from.
    ///
    /// Mixes never compose: replacing `M1` with `M2` yields
    /// `M2 × workingRGB`, not `M2 × (M1 × workingRGB)`. That is structural —
    /// this reaches through `previous.source` and never touches
    /// `previous.image`.
    public func apply(
        mix newMix: IRChannelMix,
        replacing previous: IRChannelMixedProcessedRAWImage
    ) throws -> IRChannelMixedProcessedRAWImage {
        try apply(to: previous.source, mix: newMix)
    }

    // MARK: - Identity

    /// The identity path: the same numbers, in a different processing state.
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
    /// defended by the other paths is defended here too: an
    /// `IRChannelMixedRGBImage` this stage produced holds finite values
    /// whichever path made it. That sweep reads, and allocates nothing.
    private static func identityValues(_ image: WorkingColorRGBImage) throws -> [Float] {
        try validateFinite(image)
        return image.values
    }

    // MARK: - Red/blue permutation

    /// The exact channel permutation:
    ///
    /// ```text
    /// outputR = inputB
    /// outputG = inputG
    /// outputB = inputR
    /// ```
    ///
    /// Written as copies rather than three dot products. `0*R + 0*G + 1*B` is
    /// mathematically the same number but not necessarily the same *bits*: it
    /// turns a `-0.0` blue into `+0.0`. A permutation moves values, so this
    /// moves them, and every accepted source value's bit pattern survives —
    /// signed zeros, negatives, values above `1`, and the largest and smallest
    /// finite magnitudes alike. Non-finite samples are refused below rather
    /// than moved, so the surviving set is exactly the finite one.
    ///
    /// One owned output buffer is allocated, because the values genuinely have
    /// to be reordered; copy-on-write cannot help when the contents change.
    private static func redBlueSwappedValues(_ image: WorkingColorRGBImage) throws -> [Float] {
        let outputCount = image.values.count
        let width = image.width
        let height = image.height

        return try [Float](unsafeUninitializedCapacity: outputCount) { buffer, initializedCount in
            initializedCount = 0
            try image.values.withUnsafeBufferPointer { input in
                var base = 0
                for row in 0..<height {
                    for column in 0..<width {
                        let red = input[base]
                        let green = input[base + 1]
                        let blue = input[base + 2]

                        // A hand-built image can carry anything; a value that
                        // is not finite is reported with its coordinate and
                        // channel rather than copied through. The three checks
                        // are written out rather than looped over `allCases`,
                        // which would allocate an array per pixel.
                        guard red.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixInput(
                                row: row, column: column, channel: .red, value: red
                            )
                        }
                        guard green.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixInput(
                                row: row, column: column, channel: .green, value: green
                            )
                        }
                        guard blue.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixInput(
                                row: row, column: column, channel: .blue, value: blue
                            )
                        }

                        // Copies, not arithmetic: bit patterns survive.
                        buffer[base] = blue
                        buffer[base + 1] = green
                        buffer[base + 2] = red
                        base += IRChannelMixedRGBImage.channelCount
                    }
                }
                initializedCount = base
            }
        }
    }

    // MARK: - General 3×3

    /// The general path: one dot product per output channel, per pixel.
    ///
    /// One owned `[Float]` allocation, written once, from a borrowed read of
    /// the source. The nine coefficients are loaded into locals before the loop
    /// so the hot path is nine multiplications and six additions with no
    /// property access, and the row and column are tracked by the loop rather
    /// than recomputed by division.
    private static func mixedValues(
        _ image: WorkingColorRGBImage,
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
                        let inputRed = input[base]
                        let inputGreen = input[base + 1]
                        let inputBlue = input[base + 2]

                        guard inputRed.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixInput(
                                row: row, column: column, channel: .red, value: inputRed
                            )
                        }
                        guard inputGreen.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixInput(
                                row: row, column: column, channel: .green, value: inputGreen
                            )
                        }
                        guard inputBlue.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixInput(
                                row: row, column: column, channel: .blue, value: inputBlue
                            )
                        }

                        let red = Double(inputRed)
                        let green = Double(inputGreen)
                        let blue = Double(inputBlue)

                        // Rows are output channels, columns input channels —
                        // the convention RAWColorMatrix3x3 fixes. Accumulated
                        // in Double: a Float32 intermediate can overflow where
                        // the mathematical result cannot.
                        let mixedRed = Float(m00 * red + m01 * green + m02 * blue)
                        let mixedGreen = Float(m10 * red + m11 * green + m12 * blue)
                        let mixedBlue = Float(m20 * red + m21 * green + m22 * blue)

                        // Narrowed exactly once per channel, above. A Double
                        // result that is not finite, and a finite Double that
                        // overflows Float32 on narrowing, both fail here
                        // rather than being clamped to a plausible number.
                        guard mixedRed.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixResult(
                                row: row, column: column, channel: .red
                            )
                        }
                        guard mixedGreen.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixResult(
                                row: row, column: column, channel: .green
                            )
                        }
                        guard mixedBlue.isFinite else {
                            initializedCount = base
                            throw IRProcessingError.nonFiniteChannelMixResult(
                                row: row, column: column, channel: .blue
                            )
                        }

                        buffer[base] = mixedRed
                        buffer[base + 1] = mixedGreen
                        buffer[base + 2] = mixedBlue
                        base += IRChannelMixedRGBImage.channelCount
                    }
                }
                initializedCount = base
            }
        }
    }

    // MARK: - Shared validation

    /// Sweeps the input for non-finite values, reporting the first with its
    /// coordinate and channel. Reads only; allocates nothing.
    private static func validateFinite(_ image: WorkingColorRGBImage) throws {
        try image.values.withUnsafeBufferPointer { input in
            var base = 0
            for row in 0..<image.height {
                for column in 0..<image.width {
                    let red = input[base]
                    let green = input[base + 1]
                    let blue = input[base + 2]
                    guard red.isFinite else {
                        throw IRProcessingError.nonFiniteChannelMixInput(
                            row: row, column: column, channel: .red, value: red
                        )
                    }
                    guard green.isFinite else {
                        throw IRProcessingError.nonFiniteChannelMixInput(
                            row: row, column: column, channel: .green, value: green
                        )
                    }
                    guard blue.isFinite else {
                        throw IRProcessingError.nonFiniteChannelMixInput(
                            row: row, column: column, channel: .blue, value: blue
                        )
                    }
                    base += WorkingColorRGBImage.channelCount
                }
            }
        }
    }
}
