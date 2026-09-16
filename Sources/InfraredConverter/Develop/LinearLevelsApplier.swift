import Foundation

/// A stage failing to apply levels to a linear-light image.
///
/// Deliberately distinct from `SceneLinearExposureError` and
/// `DisplayRenderingError`: this stage produces linear-light values, not
/// display pixels, and a caller that cannot expose an image, cannot level one,
/// and cannot encode a preview have three different problems.
public enum LinearLevelsError: Error, Equatable {
    /// The input's declared dimensions and its buffer disagree.
    case invalidGeometry(reason: String)
    /// The requested levels cannot be applied at all: an endpoint is not
    /// finite, the black point is not below the white point, or the interval's
    /// span or scale is not representable.
    ///
    /// One case for four causes, because all four are the same fact — these
    /// two numbers do not describe a usable interval — and reporting the
    /// endpoints together with the span and the scale they produced diagnoses
    /// every one of them.
    case nonApplicableLevels(
        blackPoint: Double, whitePoint: Double, span: Double, scale: Double
    )
    /// The image contains a value that is not a finite number.
    case nonFiniteLinearInput(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        value: Float
    )
    /// A finite input became non-finite once levelled: a finite coordinate
    /// offset and scaled by finite numbers, overflowing on the single
    /// narrowing back to `Float`.
    ///
    /// Refused rather than left to the clip. A sample that overflowed to
    /// infinity would clip to `1` and reach a screen or a file as an ordinary
    /// white pixel, indistinguishable from a legitimately bright one.
    case nonFiniteLeveledValue(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        blackPoint: Double,
        whitePoint: Double
    )
}

extension LinearLevelsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The image's dimensions are inconsistent and cannot be levelled."
        case .nonApplicableLevels:
            return "The requested black and white points cannot be applied."
        case .nonFiniteLinearInput:
            return "The image data contains a value that is not a finite number."
        case .nonFiniteLeveledValue:
            return "These black and white points produce values that are not finite numbers."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .nonApplicableLevels(let blackPoint, let whitePoint, let span, let scale):
            return """
                A black point of \(blackPoint) and a white point of \(whitePoint) give an \
                interval of \(span) and a scale of \(scale). The black point must be finite \
                and strictly below the finite white point, and both the interval and its \
                reciprocal must be representable.
                """
        case .nonFiniteLinearInput(let row, let column, let channel, let value):
            return """
                Linear \(channel) coordinate \(value) at row \(row), column \(column) is not \
                finite.
                """
        case .nonFiniteLeveledValue(
            let row, let column, let channel, let blackPoint, let whitePoint
        ):
            return """
                The \(channel) coordinate at row \(row), column \(column) is not a finite \
                Float32 after a black point of \(blackPoint) and a white point of \
                \(whitePoint).
                """
        }
    }
}

/// Applies the user's black and white points to an exposed image, in the
/// linear domain, producing linear-light values.
///
/// ```text
/// ExposedSceneLinearRGBImage    extended linear sRGB, scene-linear, unclamped
///       │
///       │  explicit LinearLevels
///       ↓
/// LinearLevelsApplier           ← this stage
///       │
///       │  levelled = (exposed − black) × 1/(white − black)
///       │             the shared primitive, per component
///       ↓
/// LeveledLinearRGBImage         linear-light, still unclamped, and no longer
///                               proportional to scene radiance
/// ```
///
/// ## Where it sits, and why exactly there
///
/// After exposure and before every destination's range policy, on **both**
/// paths:
///
/// ```text
/// working RGB → channel mix → orientation → exposure → LEVELS
///             → range policy → transfer function → quantisation
/// ```
///
/// After exposure, because the two are different decisions and the order is
/// what makes each of them mean what its control says. Exposure asks "how much
/// light was there"; levels ask "where are black and white in the result".
/// Folding them together — a single gain-and-offset — would make each slider
/// change what the other one did.
///
/// Before the range policy, because levels routinely produce values outside
/// `0…1` and the whole point of a black point above `0` is that something goes
/// below it. Clipping first would destroy exactly the values the adjustment
/// exists to move.
///
/// ## What it does not do
///
/// It does not clip, clamp, compress, roll off, normalise, stretch to a
/// histogram, recover a highlight or a shadow, read the image, or derive
/// anything from it. It is not tone mapping, not a curve, not contrast, not a
/// gamma slider and not automatic levels. If a value here changed the
/// rendering, a person chose it.
///
/// There is no per-channel form: the same two numbers are applied to R, G and
/// B, and the stage has no way to be told otherwise.
///
/// ## Cancellation
///
/// One synchronous pass, so a caller that has superseded it needs a way to
/// stop it rather than merely discard it. `apply` polls `cancellation` once
/// before any work and once more before each row, and a cancelled call throws
/// `CancellationError` and returns no image at all — never a buffer with some
/// rows levelled and the rest not, which would look like an ordinary band.
///
/// ## Cost
///
/// `O(component count)`: one read pass, one owned output buffer of the same
/// size, one reciprocal outside the loop, one subtract and one multiply per
/// component.
///
/// The identity — black `0`, white `1` — hands the input's immutable buffer
/// back rather than copying it, so neutral levels cost a finiteness sweep and
/// no allocation at all. At full export resolution that is the difference
/// between one 148 MB buffer and two.
///
/// See `docs/decisions/0026-linear-levels.md`.
public struct LinearLevelsApplier: Sendable {
    public init() {}

    /// Applies levels to an exposed scene-linear image.
    ///
    /// - Parameters:
    ///   - image: extended-linear-sRGB coordinates with the mix, the
    ///     orientation and the exposure already applied. Not mutated and not
    ///     clamped.
    ///   - levels: the levels to apply. Required — there is deliberately no
    ///     default, for the same reason no stage in this project has one.
    ///   - cancellation: polled once here and once per row. Defaults to never
    ///     cancelling.
    /// - Throws: `LinearLevelsError`, or `CancellationError` when the work was
    ///   superseded. The two are deliberately distinct: one says the image
    ///   could not be levelled, the other says nobody wants it.
    public func apply(
        to image: ExposedSceneLinearRGBImage,
        levels: LinearLevels,
        cancellation: ProcessingCancellation = .none
    ) throws -> LeveledLinearRGBImage {
        guard image.isGeometryConsistent else {
            throw LinearLevelsError.invalidGeometry(
                reason: """
                    Exposed scene-linear RGB geometry \(image.width)x\(image.height) needs \
                    \(image.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(image.values.count).
                    """
            )
        }

        // Before anything is allocated: a caller that has already superseded
        // this call gets nothing built for it at all.
        try cancellation.check()

        guard levels.isApplicable else {
            throw LinearLevelsError.nonApplicableLevels(
                blackPoint: levels.blackPoint,
                whitePoint: levels.whitePoint,
                span: levels.span,
                scale: levels.scale
            )
        }

        return LeveledLinearRGBImage(
            width: image.width,
            height: image.height,
            values: try Self.leveledValues(
                image.values,
                width: image.width,
                height: image.height,
                levels: levels,
                cancellation: cancellation
            ),
            processing: LinearLevelsProcessing(
                levels: levels, exposureProcessing: image.processing
            )
        )
    }

    /// Levels an exposed result, keeping that whole exposed state reachable on
    /// the returned value's `source`.
    ///
    /// Use this rather than the bare-image overload whenever the caller may
    /// want different levels later: the result carries everything needed to
    /// restart from the exposed image, without exposing, orienting, mixing,
    /// converting, demosaicing or decoding again.
    public func apply(
        to processed: ExposedProcessedRAWImage,
        levels: LinearLevels,
        cancellation: ProcessingCancellation = .none
    ) throws -> LeveledProcessedRAWImage {
        let image = try apply(
            to: processed.image, levels: levels, cancellation: cancellation
        )
        return LeveledProcessedRAWImage(source: processed, image: image)
    }

    /// Replaces the levels on a previous result, starting again from the
    /// exposed image it was produced from.
    ///
    /// Levels never compose: replacing `L1` with `L2` yields `L2(exposed)`,
    /// not `L2(L1(exposed))`. That is structural — this reaches through
    /// `previous.source` and never touches `previous.image`.
    ///
    /// The failure mode it prevents is quiet. Two affine maps compose into a
    /// third affine map, so a chained result is always *some* valid levels
    /// setting of the photograph and never looks malformed; it is simply not
    /// the one that was asked for, while provenance records the one that was.
    ///
    /// Nothing upstream reruns: no exposure, no orientation, no channel mix,
    /// no camera conversion, no demosaic, no white balance, no decode.
    public func apply(
        levels newLevels: LinearLevels,
        replacing previous: LeveledProcessedRAWImage,
        cancellation: ProcessingCancellation = .none
    ) throws -> LeveledProcessedRAWImage {
        try apply(to: previous.source, levels: newLevels, cancellation: cancellation)
    }

    // MARK: - The arithmetic

    /// The identity path hands the same immutable array back.
    ///
    /// Black `0` and white `1` give a scale of exactly `1`, and
    /// `(x − 0) × 1` is the identity for every finite `Float` including signed
    /// zeros and subnormals — so copying the buffer would allocate a
    /// full-resolution image's worth of memory to reproduce it bit for bit.
    /// The finiteness sweep still runs, so the stage's output contract holds
    /// on both paths: an image containing a NaN is refused at neutral levels
    /// exactly as it is at any other.
    private static func leveledValues(
        _ values: [Float],
        width: Int,
        height: Int,
        levels: LinearLevels,
        cancellation: ProcessingCancellation
    ) throws -> [Float] {
        let channels = LeveledLinearRGBImage.channelCount

        if levels.isIdentity {
            try validateFinite(
                values, width: width, height: height, cancellation: cancellation
            )
            return values
        }

        return try [Float](unsafeUninitializedCapacity: values.count) { buffer, initialized in
            try values.withUnsafeBufferPointer { input in
                // One component: validate, level, validate. Written once and
                // called three times per pixel rather than looped over
                // `RAWLinearRGBChannel.allCases`, which would allocate an
                // array per pixel — the same reason the exposer, the channel
                // mixer and the display renderer write their three calls out.
                func leveled(
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
                        throw LinearLevelsError.nonFiniteLinearInput(
                            row: row, column: column, channel: channel, value: linear
                        )
                    }
                    let result = levels.applied(to: linear)
                    guard result.isFinite else {
                        throw LinearLevelsError.nonFiniteLeveledValue(
                            row: row, column: column, channel: channel,
                            blackPoint: levels.blackPoint, whitePoint: levels.whitePoint
                        )
                    }
                    return result
                }

                var index = 0
                do {
                    for row in 0..<height {
                        // One poll per row. Throwing here abandons the whole
                        // array — the caller gets `CancellationError`, never
                        // an image with some rows levelled and the rest not.
                        if cancellation.isCancelled {
                            initialized = index
                            throw CancellationError()
                        }
                        for column in 0..<width {
                            buffer[index] = try leveled(index, row, column, .red)
                            buffer[index + 1] = try leveled(index + 1, row, column, .green)
                            buffer[index + 2] = try leveled(index + 2, row, column, .blue)
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

    /// The sweep the identity path runs instead of the subtract and multiply.
    private static func validateFinite(
        _ values: [Float],
        width: Int,
        height: Int,
        cancellation: ProcessingCancellation
    ) throws {
        let channels = LeveledLinearRGBImage.channelCount
        try values.withUnsafeBufferPointer { input in
            func check(
                _ index: Int, _ row: Int, _ column: Int, _ channel: RAWLinearRGBChannel
            ) throws {
                guard input[index].isFinite else {
                    throw LinearLevelsError.nonFiniteLinearInput(
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
