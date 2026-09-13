import Foundation

/// A stage failing to apply exposure to a scene-linear image.
///
/// Deliberately distinct from `DisplayRenderingError`: this stage produces
/// scene-linear light, not display pixels, and a caller that cannot encode a
/// preview and a caller that cannot expose an image have different problems.
public enum SceneLinearExposureError: Error, Equatable {
    /// The input's declared dimensions and its buffer disagree.
    case invalidGeometry(reason: String)
    /// The requested exposure cannot be applied at all.
    case nonFiniteExposure(exposureEV: Double, scale: Double)
    /// The image contains a value that is not a finite number.
    case nonFiniteSceneLinearInput(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        value: Float
    )
    /// A finite input became non-finite once exposed.
    case nonFiniteExposedValue(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        exposureEV: Double
    )
}

extension SceneLinearExposureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The image's dimensions are inconsistent and cannot be exposed."
        case .nonFiniteExposure:
            return "The requested exposure cannot be applied."
        case .nonFiniteSceneLinearInput:
            return "The image data contains a value that is not a finite number."
        case .nonFiniteExposedValue:
            return "This exposure produces values that are not finite numbers."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .nonFiniteExposure(let exposureEV, let scale):
            return """
                Exposure \(exposureEV) EV gives a linear scale of \(scale), which is not a \
                finite number.
                """
        case .nonFiniteSceneLinearInput(let row, let column, let channel, let value):
            return """
                Scene-linear \(channel) coordinate \(value) at row \(row), column \(column) \
                is not finite.
                """
        case .nonFiniteExposedValue(let row, let column, let channel, let exposureEV):
            return """
                The \(channel) coordinate at row \(row), column \(column) is not a finite \
                Float32 after \(exposureEV) EV of exposure.
                """
        }
    }
}

/// Applies the user's exposure to an oriented scene-linear image, in the
/// scene-linear domain, producing scene-linear light.
///
/// ```text
/// OrientedSceneLinearRGBImage    extended linear sRGB, in viewing order
///       │
///       │  explicit SceneLinearExposure
///       ↓
/// SceneLinearExposer             ← this stage
///       │
///       │  exposed = sceneLinear × 2^EV        the shared primitive
///       ↓
/// ExposedSceneLinearRGBImage     extended linear sRGB, still unclamped
/// ```
///
/// ## Why this is a stage of its own on the export path
///
/// The interactive preview applies exposure inside `DisplayPreviewRenderer`,
/// where it has always lived, because that renderer's single pass reads each
/// component once and never needs the exposed value again. A full-resolution
/// export cannot do that: its encoder writes 16-bit integers and its result
/// has to be inspectable as **scene-linear light with every adjustment
/// applied** — that is precisely the state a test can check for a red/blue
/// swap, a quarter turn and a doubling, before any clipping or quantisation
/// has destroyed the evidence.
///
/// Both call the same `SceneLinearExposure`. The arithmetic is shared; only
/// where it sits in each pass differs. See
/// `docs/decisions/0018-full-resolution-tiff-export.md`.
///
/// ## What it is not
///
/// It is not tone mapping, automatic exposure, a curve, contrast, or highlight
/// recovery, and it does not clip. Values above `1` and below `0` pass through
/// unchanged — the range policy of whichever destination follows is what owns
/// clipping, and it owns it *after* this.
///
/// ## Cost
///
/// `O(component count)`: one read pass, one owned output buffer of the same
/// size, one `exp2` outside the loop, one multiply per component. At full
/// sensor resolution that output buffer is the size of the input, which is the
/// export path's largest single allocation after the working image.
public struct SceneLinearExposer: Sendable {
    public init() {}

    /// Exposes an oriented scene-linear image.
    ///
    /// - Parameters:
    ///   - image: extended-linear-sRGB coordinates in viewing order, as
    ///     `ImageOrienter` produces. Not mutated and not clamped.
    ///   - exposure: the exposure to apply. Required — there is deliberately
    ///     no default, for the same reason no stage in this project has one.
    ///   - cancellation: polled once here and once per row. Defaults to never
    ///     cancelling.
    /// - Throws: `SceneLinearExposureError`, or `CancellationError` when the
    ///   work was superseded. The two are deliberately distinct: one says the
    ///   image could not be exposed, the other says nobody wants it.
    public func apply(
        to image: OrientedSceneLinearRGBImage,
        exposure: SceneLinearExposure,
        cancellation: ProcessingCancellation = .none
    ) throws -> ExposedSceneLinearRGBImage {
        guard image.isGeometryConsistent else {
            throw SceneLinearExposureError.invalidGeometry(
                reason: """
                    Oriented scene-linear RGB geometry \(image.width)x\(image.height) needs \
                    \(image.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(image.values.count).
                    """
            )
        }

        // Before anything is allocated: a caller that has already superseded
        // this call gets nothing built for it at all.
        try cancellation.check()

        guard exposure.isApplicable else {
            throw SceneLinearExposureError.nonFiniteExposure(
                exposureEV: exposure.ev, scale: exposure.scale
            )
        }

        let processing = SceneLinearExposureProcessing(
            exposure: exposure,
            orientationProcessing: image.processing
        )

        return ExposedSceneLinearRGBImage(
            width: image.width,
            height: image.height,
            values: try Self.exposedValues(
                image.values,
                width: image.width,
                height: image.height,
                exposure: exposure,
                cancellation: cancellation
            ),
            processing: processing
        )
    }

    // MARK: - The arithmetic

    /// The identity path hands the same immutable array back.
    ///
    /// `0 EV` is a scale of exactly `1`, and multiplying a `Float` by `1` is
    /// the identity for every finite value including signed zeros and
    /// subnormals — so copying the buffer would allocate a full-resolution
    /// image's worth of memory to reproduce it bit for bit. The finiteness
    /// sweep still runs, so the stage's output contract holds on both paths:
    /// an image containing a NaN is refused at `0 EV` exactly as it is at
    /// `+1 EV`.
    private static func exposedValues(
        _ values: [Float],
        width: Int,
        height: Int,
        exposure: SceneLinearExposure,
        cancellation: ProcessingCancellation
    ) throws -> [Float] {
        let channels = ExposedSceneLinearRGBImage.channelCount

        if exposure.isIdentity {
            try validateFinite(
                values, width: width, height: height, cancellation: cancellation
            )
            return values
        }

        return try [Float](unsafeUninitializedCapacity: values.count) { buffer, initialized in
            try values.withUnsafeBufferPointer { input in
                // One component: validate, expose, validate. Written once and
                // called three times per pixel rather than looped over
                // `RAWLinearRGBChannel.allCases`, which would allocate an
                // array per pixel — the same reason the channel mixer and the
                // display renderer write their three calls out.
                func exposed(
                    _ index: Int,
                    _ row: Int,
                    _ column: Int,
                    _ channel: RAWLinearRGBChannel
                ) throws -> Float {
                    let sceneLinear = input[index]
                    // A hand-built image can carry anything, and the stages
                    // upstream refuse non-finite values, so this is a real
                    // boundary rather than an assertion.
                    guard sceneLinear.isFinite else {
                        throw SceneLinearExposureError.nonFiniteSceneLinearInput(
                            row: row, column: column, channel: channel, value: sceneLinear
                        )
                    }
                    let result = exposure.applied(to: sceneLinear)
                    guard result.isFinite else {
                        throw SceneLinearExposureError.nonFiniteExposedValue(
                            row: row, column: column, channel: channel,
                            exposureEV: exposure.ev
                        )
                    }
                    return result
                }

                var index = 0
                do {
                    for row in 0..<height {
                        // One poll per row. Throwing here abandons the whole
                        // array — the caller gets `CancellationError`, never
                        // an image with some rows exposed and the rest not,
                        // which would look like an ordinary bright band.
                        if cancellation.isCancelled {
                            initialized = index
                            throw CancellationError()
                        }
                        for column in 0..<width {
                            buffer[index] = try exposed(index, row, column, .red)
                            buffer[index + 1] = try exposed(index + 1, row, column, .green)
                            buffer[index + 2] = try exposed(index + 2, row, column, .blue)
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

    /// The sweep the identity path runs instead of the multiply.
    private static func validateFinite(
        _ values: [Float],
        width: Int,
        height: Int,
        cancellation: ProcessingCancellation
    ) throws {
        let channels = ExposedSceneLinearRGBImage.channelCount
        try values.withUnsafeBufferPointer { input in
            func check(
                _ index: Int, _ row: Int, _ column: Int, _ channel: RAWLinearRGBChannel
            ) throws {
                guard input[index].isFinite else {
                    throw SceneLinearExposureError.nonFiniteSceneLinearInput(
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
