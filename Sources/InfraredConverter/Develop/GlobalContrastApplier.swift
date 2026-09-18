import Foundation

/// A stage failing to apply a global contrast curve.
///
/// Deliberately distinct from `SceneLinearExposureError`, `LinearLevelsError`
/// and the two destination errors: this stage produces unclamped working-space
/// values, not display pixels, and a caller that cannot expose an image,
/// cannot level one, cannot curve one and cannot encode a preview has four
/// different problems.
public enum GlobalContrastError: Error, Equatable {
    /// The input's declared dimensions and its buffer disagree.
    case invalidGeometry(reason: String)
    /// The requested curve cannot be evaluated at all: the amount is not
    /// finite, or the exponent it produces is not a finite positive number.
    ///
    /// One case for both causes, because they are the same fact — this number
    /// does not describe a usable curve — and reporting the amount together
    /// with the exponent it produced diagnoses either.
    ///
    /// Note what this is *not*: it is not "outside `−1 … +1`". That range
    /// belongs to `UserContrastAdjustment` and is refused there, at the
    /// boundary where a person's decision is validated. A curve built directly
    /// from a raw amount is checked here against what the arithmetic needs.
    case nonApplicableContrast(amount: Double, exponent: Double)
    /// The image contains a value that is not a finite number.
    case nonFiniteLinearInput(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        value: Float
    )
    /// A finite input became non-finite once curved.
    ///
    /// Refused rather than left to the clip, and never replaced with black or
    /// white. A sample that became a NaN and was silently substituted would
    /// reach a screen or a file as an ordinary pixel, indistinguishable from a
    /// legitimate one.
    case nonFiniteToneCurvedValue(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        contrastAmount: Double,
        contrastExponent: Double
    )
}

extension GlobalContrastError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The image's dimensions do not match its contents."
        case .nonApplicableContrast:
            return "The requested contrast cannot be applied."
        case .nonFiniteLinearInput:
            return "The image contains a value that is not a finite number."
        case .nonFiniteToneCurvedValue:
            return "A value became unusable when the contrast curve was applied."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .nonApplicableContrast(let amount, let exponent):
            return """
                A contrast amount of \(amount) gives an exponent of \(exponent). The amount \
                must be finite and the exponent it produces must be a finite number greater \
                than zero.
                """
        case .nonFiniteLinearInput(let row, let column, let channel, let value):
            return """
                The \(channel) coordinate \(value) at row \(row), column \(column) is not \
                finite.
                """
        case .nonFiniteToneCurvedValue(
            let row, let column, let channel, let amount, let exponent
        ):
            return """
                The \(channel) coordinate at row \(row), column \(column) is not a finite \
                Float32 after a contrast amount of \(amount) (exponent \(exponent)).
                """
        }
    }
}

/// Applies the user's global contrast to a levelled image, per RGB component,
/// producing working-space values that are no longer linear-light encoded.
///
/// ```text
/// LeveledLinearRGBImage         linear-light, unclamped
///       │
///       │  explicit GlobalContrastCurve
///       ↓
/// GlobalContrastApplier         ← this stage
///       │
///       │  y = x^k / (x^k + (1−x)^k) inside 0…1, x unchanged outside it
///       │      the shared primitive, per component
///       ↓
/// ToneCurvedRGBImage            still unclamped, still working-space RGB,
///                               no longer linear-light encoded
/// ```
///
/// ## Where it sits, and why exactly there
///
/// After levels and before every destination's range policy, on **both**
/// paths:
///
/// ```text
/// working RGB → channel mix → orientation → exposure → levels → CONTRAST
///             → range policy → transfer function → quantisation
/// ```
///
/// After levels, because the curve's three fixed points — `0`, `0.5` and `1` —
/// are only meaningful once something has decided where black and white are.
/// Contrast asks "how steeply does the image move between the black point and
/// the white point"; that question has no answer before the black and white
/// points exist. Running the curve first would make the levels reinterpret a
/// tone distribution the user had already shaped, and each control would
/// change what the other one did.
///
/// Before the range policy, because the curve leaves extended values alone
/// deliberately: a value at `1.7` is still `1.7` here, and it is the
/// destination that decides what a display or a file can hold. Clipping first
/// would destroy the headroom the pipeline has carried since the mosaic.
///
/// ## What it does not do
///
/// It does not clip, clamp, extrapolate, normalise, read the image, build a
/// histogram, or derive anything from anything. It is not tone mapping, not
/// local contrast, not clarity, not a gamma slider, not automatic contrast and
/// not per-channel. There is no per-channel form: the same curve is applied to
/// R, G and B, and the stage has no way to be told otherwise.
///
/// It **does** change colour appearance. A nonlinear function applied
/// independently to three components does not preserve the ratios between
/// them. Nothing here compensates for that, because a saturation correction
/// would be a second operation nobody asked for. See
/// `docs/decisions/0027-global-contrast-tone-curve.md`.
///
/// ## Cancellation
///
/// One synchronous pass, so a caller that has superseded it needs a way to
/// stop it rather than merely discard it. `apply` polls `cancellation` once
/// before any work and once more before each row, and a cancelled call throws
/// `CancellationError` and returns no image at all — never a buffer with some
/// rows curved and the rest not, which would look like an ordinary band.
///
/// ## Cost
///
/// `O(component count)`: one read pass, one owned output buffer of the same
/// size, one `exp2` outside the loop, two `pow`s and one divide per component.
/// Evaluated in `Double` and narrowed once per component — there is no
/// `Double` frame buffer.
///
/// The identity — amount `0` — hands the input's immutable buffer back rather
/// than copying it, so neutral contrast costs a finiteness sweep and no
/// allocation at all.
public struct GlobalContrastApplier: Sendable {
    public init() {}

    /// Applies a global contrast curve to a levelled image.
    ///
    /// - Parameters:
    ///   - image: working-space coordinates with the mix, the orientation, the
    ///     exposure and the levels already applied. Not mutated and not
    ///     clamped.
    ///   - curve: the curve to apply. Required — there is deliberately no
    ///     default, for the same reason no stage in this project has one.
    ///   - cancellation: polled once here and once per row. Defaults to never
    ///     cancelling.
    /// - Throws: `GlobalContrastError`, or `CancellationError` when the work
    ///   was superseded. The two are deliberately distinct: one says the image
    ///   could not be curved, the other says nobody wants it.
    public func apply(
        to image: LeveledLinearRGBImage,
        curve: GlobalContrastCurve,
        cancellation: ProcessingCancellation = .none
    ) throws -> ToneCurvedRGBImage {
        guard image.isGeometryConsistent else {
            throw GlobalContrastError.invalidGeometry(
                reason: """
                    Levelled linear RGB geometry \(image.width)x\(image.height) needs \
                    \(image.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(image.values.count).
                    """
            )
        }

        // Before anything is allocated: a caller that has already superseded
        // this call gets nothing built for it at all.
        try cancellation.check()

        guard curve.isApplicable else {
            throw GlobalContrastError.nonApplicableContrast(
                amount: curve.amount, exponent: curve.exponent
            )
        }

        return ToneCurvedRGBImage(
            width: image.width,
            height: image.height,
            values: try Self.curvedValues(
                image.values,
                width: image.width,
                height: image.height,
                curve: curve,
                cancellation: cancellation
            ),
            processing: GlobalContrastProcessing(
                curve: curve, levelsProcessing: image.processing
            )
        )
    }

    /// Curves a levelled result, keeping that whole levelled state reachable
    /// on the returned value's `source`.
    ///
    /// Use this rather than the bare-image overload whenever the caller may
    /// want a different contrast later: the result carries everything needed
    /// to restart from the levelled image, without levelling, exposing,
    /// orienting, mixing, converting, demosaicing or decoding again.
    public func apply(
        to processed: LeveledProcessedRAWImage,
        curve: GlobalContrastCurve,
        cancellation: ProcessingCancellation = .none
    ) throws -> ToneCurvedProcessedRAWImage {
        let image = try apply(
            to: processed.image, curve: curve, cancellation: cancellation
        )
        return ToneCurvedProcessedRAWImage(source: processed, image: image)
    }

    /// Replaces the curve on a previous result, starting again from the
    /// levelled image it was produced from.
    ///
    /// Contrast never composes: replacing `C1` with `C2` yields
    /// `C2(levelled)`, not `C2(C1(levelled))`. That is structural — this
    /// reaches through `previous.source` and never touches `previous.image`.
    ///
    /// The failure mode it prevents is worse here than it was for levels. Two
    /// affine maps compose into a third affine map, so a chained levels result
    /// was at least *some* valid levels setting of the photograph. Two of
    /// these curves do **not** compose into a curve of this family at all:
    /// `C1` then `C2` is not `C1 + C2`, and the result is a shape no contrast
    /// amount could have produced, while provenance records a single amount
    /// that did not produce it.
    ///
    /// Nothing upstream reruns: no levels, no exposure, no orientation, no
    /// channel mix, no camera conversion, no demosaic, no white balance, no
    /// decode.
    public func apply(
        curve newCurve: GlobalContrastCurve,
        replacing previous: ToneCurvedProcessedRAWImage,
        cancellation: ProcessingCancellation = .none
    ) throws -> ToneCurvedProcessedRAWImage {
        try apply(to: previous.source, curve: newCurve, cancellation: cancellation)
    }

    // MARK: - The arithmetic

    /// The identity path hands the same immutable array back.
    ///
    /// An amount of `0` gives an exponent of exactly `1`, and the curve
    /// branches on `isIdentity` rather than evaluating `pow(x, 1)` — so the
    /// identity is the identity for every `Float` including signed zeros and
    /// subnormals, and copying the buffer would allocate a full-resolution
    /// image's worth of memory to reproduce it bit for bit.
    ///
    /// The finiteness sweep still runs, so the stage's output contract holds
    /// on both paths: an image containing a NaN is refused at neutral contrast
    /// exactly as it is at any other.
    private static func curvedValues(
        _ values: [Float],
        width: Int,
        height: Int,
        curve: GlobalContrastCurve,
        cancellation: ProcessingCancellation
    ) throws -> [Float] {
        let channels = ToneCurvedRGBImage.channelCount

        if curve.isIdentity {
            try validateFinite(
                values, width: width, height: height, cancellation: cancellation
            )
            return values
        }

        return try [Float](unsafeUninitializedCapacity: values.count) { buffer, initialized in
            try values.withUnsafeBufferPointer { input in
                // One component: validate, curve, validate. Written once and
                // called three times per pixel rather than looped over
                // `RAWLinearRGBChannel.allCases`, which would allocate an
                // array per pixel — the same reason the levels applier, the
                // exposer and the channel mixer write their three calls out.
                func curved(
                    _ index: Int,
                    _ row: Int,
                    _ column: Int,
                    _ channel: RAWLinearRGBChannel
                ) throws -> Float {
                    let linear = input[index]
                    // A hand-built image can carry anything, and the stages
                    // upstream refuse non-finite values, so this is a real
                    // boundary rather than an assertion.
                    guard linear.isFinite else {
                        throw GlobalContrastError.nonFiniteLinearInput(
                            row: row, column: column, channel: channel, value: linear
                        )
                    }
                    let result = curve.applied(to: linear)
                    guard result.isFinite else {
                        throw GlobalContrastError.nonFiniteToneCurvedValue(
                            row: row, column: column, channel: channel,
                            contrastAmount: curve.amount,
                            contrastExponent: curve.exponent
                        )
                    }
                    return result
                }

                var index = 0
                do {
                    for row in 0..<height {
                        // One poll per row. Throwing here abandons the whole
                        // array — the caller gets `CancellationError`, never
                        // an image with some rows curved and the rest not.
                        if cancellation.isCancelled {
                            initialized = index
                            throw CancellationError()
                        }
                        for column in 0..<width {
                            buffer[index] = try curved(index, row, column, .red)
                            buffer[index + 1] = try curved(index + 1, row, column, .green)
                            buffer[index + 2] = try curved(index + 2, row, column, .blue)
                            index += channels
                        }
                    }
                } catch {
                    // `Float` is trivial, so nothing needs destroying; the
                    // count is kept honest anyway rather than left stale for a
                    // future element type to trip over.
                    initialized = index
                    throw error
                }
                initialized = index
            }
        }
    }

    /// The sweep the identity path runs instead of the curve.
    private static func validateFinite(
        _ values: [Float],
        width: Int,
        height: Int,
        cancellation: ProcessingCancellation
    ) throws {
        let channels = ToneCurvedRGBImage.channelCount
        try values.withUnsafeBufferPointer { input in
            func check(
                _ index: Int, _ row: Int, _ column: Int, _ channel: RAWLinearRGBChannel
            ) throws {
                guard input[index].isFinite else {
                    throw GlobalContrastError.nonFiniteLinearInput(
                        row: row, column: column, channel: channel, value: input[index]
                    )
                }
            }
            var index = 0
            for row in 0..<height {
                try cancellation.check()
                for column in 0..<width {
                    try check(index, row, column, .red)
                    try check(index + 1, row, column, .green)
                    try check(index + 2, row, column, .blue)
                    index += channels
                }
            }
        }
    }
}
