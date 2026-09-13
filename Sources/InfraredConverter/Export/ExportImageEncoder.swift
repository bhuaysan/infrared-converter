import Foundation

/// An export encoder refusing an image.
///
/// Deliberately separate from `DisplayRenderingError`: a preview that cannot
/// be shown and a file that cannot be written are different problems, and a
/// user is told different things about them.
public enum ExportEncodingError: Error, Equatable {
    /// The input's declared dimensions and its buffer disagree.
    case invalidGeometry(reason: String)
    /// The image contains a value that is not a finite number.
    case nonFiniteSceneLinearInput(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        value: Float
    )
    /// The image is a reduced **preview** rendition, and a preview is never
    /// export truth.
    case previewReducedSource(resolution: PreviewResolution)
}

extension ExportEncodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The image's dimensions are inconsistent and cannot be exported."
        case .nonFiniteSceneLinearInput:
            return "The image data contains a value that is not a finite number."
        case .previewReducedSource:
            return "This image is a reduced preview and cannot be exported."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .nonFiniteSceneLinearInput(let row, let column, let channel, let value):
            return """
                Scene-linear \(channel) coordinate \(value) at row \(row), column \(column) \
                is not finite.
                """
        case .previewReducedSource(let resolution):
            return """
                These pixels are \(resolution.diagnosticDescription) — an interactive \
                preview, which is a disposable cache rather than the photograph. An export \
                is rendered from the RAW file at its own resolution, never from preview \
                pixels.
                """
        }
    }
}

/// The export boundary: `ExposedSceneLinearRGBImage` →
/// `ExportEncodedImage`, by hard export-range clipping, the sRGB transfer
/// function and deterministic 16-bit quantisation.
///
/// ```text
/// ExposedSceneLinearRGBImage    extended linear sRGB, mixed, oriented, exposed
///       │
///       │  explicit ExportRenderSettings
///       ↓
/// ExportImageEncoder            ← this stage
///       │
///       │  clipped = min(max(x, 0), 1)          hard, named, counted
///       │  encoded = sRGB OETF(clipped)         piecewise, shared, not 1/2.2
///       │  sample  = round(encoded × 65535)     half away from zero
///       ↓
/// ExportEncodedImage            display-referred sRGB, 16 bits per component
///       ↓
/// TIFFExporter                  tagged sRGB, written to a file
/// ```
///
/// See `docs/decisions/0018-full-resolution-tiff-export.md`.
///
/// ## What this stage is and is not
///
/// It is the export path's counterpart of `DisplayPreviewRenderer`, and the
/// resemblance is the point: both take the same scene-linear coordinates,
/// clip by an explicitly named policy, apply the **same**
/// `SRGBTransferFunction`, and quantise by the same rounding rule. They differ
/// in exactly two places, both deliberate:
///
/// ```text
///                    preview                     export
/// resolution         reduced, PreviewResolution  the sensor's own
/// bit depth          8 bits per component        16 bits per component
/// ```
///
/// It is **not** a photographic tone pipeline. No tone mapping, no highlight
/// reconstruction, no automatic exposure, no contrast, no saturation, no
/// curve, no LUT, no sharpening and no resizing. A 16-bit file is a more
/// precise record of the same rendering, not a better-looking one.
///
/// ## Exposure is already applied
///
/// This stage takes an image that has been exposed and does not expose it
/// again — it is not given an exposure to apply. See `ExportRenderSettings`.
///
/// ## The preview refusal
///
/// The one thing this stage checks that its display counterpart does not: an
/// image whose provenance says it was reduced for preview is refused. The
/// export pipeline cannot produce one — it never reduces — so this guards the
/// case where someone later hands the encoder an image that came from the
/// interactive path. Upscaling a preview into a final file is the single
/// worst failure this milestone can have, and it would look entirely
/// plausible in every way except sharpness.
///
/// ## Cost
///
/// `O(component count)`: one read pass over the input, one owned `UInt16`
/// buffer half its size, one `pow` per component that takes the nonlinear
/// branch. No full-frame intermediate and no per-pixel allocation.
public struct ExportImageEncoder: Sendable {
    public init() {}

    /// Encodes an exposed scene-linear image into 16-bit export samples.
    ///
    /// - Parameters:
    ///   - image: extended-linear-sRGB coordinates with every canonical
    ///     adjustment already applied. Not mutated and not clamped.
    ///   - settings: range policy and encoding. Required — there is
    ///     deliberately no default.
    ///   - cancellation: polled once here and once per row.
    /// - Throws: `ExportEncodingError`, or `CancellationError` when the work
    ///   was superseded.
    public func encode(
        _ image: ExposedSceneLinearRGBImage,
        settings: ExportRenderSettings,
        cancellation: ProcessingCancellation = .none
    ) throws -> ExportEncodedImage {
        guard image.isGeometryConsistent else {
            throw ExportEncodingError.invalidGeometry(
                reason: """
                    Exposed scene-linear RGB geometry \(image.width)x\(image.height) needs \
                    \(image.expectedValueCount.map(String.init) ?? "an unrepresentable number of") \
                    values, buffer holds \(image.values.count).
                    """
            )
        }

        if let resolution = image.processing.previewResolution,
           image.processing.reducedForPreview {
            throw ExportEncodingError.previewReducedSource(resolution: resolution)
        }

        // Before anything is allocated: a caller that has already superseded
        // this call gets nothing built for it at all.
        try cancellation.check()

        guard let sampleCount = ExportEncodedImage.expectedSampleCount(
            width: image.width, height: image.height
        ) else {
            throw ExportEncodingError.invalidGeometry(
                reason: """
                    Export geometry \(image.width)x\(image.height) needs an unrepresentable \
                    number of samples.
                    """
            )
        }

        var clippedLow = 0
        var clippedHigh = 0
        let encoding = settings.encoding

        let samples = try [UInt16](unsafeUninitializedCapacity: sampleCount) {
            buffer, initialized in
            try image.values.withUnsafeBufferPointer { input in
                // One component: validate, clip, encode, quantise. Written
                // once and called three times per pixel rather than looped
                // over `RAWLinearRGBChannel.allCases`, which would allocate an
                // array per pixel.
                func sample(
                    _ index: Int,
                    _ row: Int,
                    _ column: Int,
                    _ channel: RAWLinearRGBChannel
                ) throws -> UInt16 {
                    let sceneLinear = input[index]

                    // A hand-built image can carry anything, and no upstream
                    // stage here can produce a non-finite value, so this is a
                    // real boundary rather than an assertion. It also matters
                    // more here than on a preview: a NaN that clipped to a
                    // plausible sample would be written to a file and kept.
                    guard sceneLinear.isFinite else {
                        throw ExportEncodingError.nonFiniteSceneLinearInput(
                            row: row, column: column, channel: channel, value: sceneLinear
                        )
                    }

                    // Hard export-range clipping, counted. Both branches
                    // destroy detail; that is what the counts are for.
                    let clipped: Float
                    switch settings.rangePolicy {
                    case .hardClipToExportRange:
                        if sceneLinear < 0 {
                            clipped = 0
                            clippedLow += 1
                        } else if sceneLinear > 1 {
                            clipped = 1
                            clippedHigh += 1
                        } else {
                            clipped = sceneLinear
                        }
                    }

                    return Self.quantize(Self.encode(Double(clipped), as: encoding))
                }

                var index = 0
                do {
                    for row in 0..<image.height {
                        // One poll per row. Throwing here abandons the whole
                        // buffer — the caller gets `CancellationError`, never
                        // a file with some rows encoded and the rest zero,
                        // which would look like an ordinary black band.
                        if cancellation.isCancelled {
                            initialized = index
                            throw CancellationError()
                        }
                        for column in 0..<image.width {
                            buffer[index] = try sample(index, row, column, .red)
                            buffer[index + 1] = try sample(index + 1, row, column, .green)
                            buffer[index + 2] = try sample(index + 2, row, column, .blue)
                            index += ExportEncodedImage.channelCount
                        }
                    }
                } catch {
                    // `UInt16` is trivial, so nothing needs destroying; the
                    // count is kept honest anyway.
                    initialized = index
                    throw error
                }
                initialized = index
            }
        }

        return ExportEncodedImage(
            width: image.width,
            height: image.height,
            samples: samples,
            processing: ExportImageProcessing(
                settings: settings,
                exposureProcessing: image.processing,
                clippedLowSampleCount: clippedLow,
                clippedHighSampleCount: clippedHigh
            )
        )
    }

    // MARK: - The transfer function

    /// The encoding, by the shared `SRGBTransferFunction`.
    ///
    /// Internal rather than private so the reference points can be pinned
    /// directly, and rather than public because the stage's surface is the
    /// encoder, not its arithmetic.
    static func encode(_ displayLinear: Double, as encoding: ExportEncoding) -> Double {
        switch encoding {
        case .sRGB:
            return SRGBTransferFunction.encode(displayLinear)
        }
    }

    // MARK: - Quantisation

    /// Rounds an encoded value in `0...1` to a 16-bit sample.
    ///
    /// ```text
    /// sample = round(encoded × 65535)        half away from zero
    /// ```
    ///
    /// The same rule the display path uses, with `65535` where it has `255`.
    /// Every input here is non-negative, so "half away from zero" is plainly
    /// "half up". Truncation was rejected for the same reason it was rejected
    /// there: it biases every sample downward by up to one level and maps `1`
    /// to `65534`. Two quantisers with two different rules would also make a
    /// preview and an export disagree in a way that looks like a colour
    /// difference rather than a rounding one.
    ///
    /// The endpoints are exact:
    ///
    /// ```text
    /// 0   → 0 × 65535 = 0                        → 0
    /// 0.5 → 32767.5   → rounded half up          → 32768
    /// 1   → 65534.999999999998…  → rounded       → 65535
    /// ```
    ///
    /// The last is worth stating carefully. `1.055 × 1^(1/2.4) − 0.055`
    /// evaluates in `Double` to one ULP below `1`, so rounding to nearest is
    /// exactly what recovers `65535`. The mapping is exact *because* of the
    /// rounding step.
    ///
    /// The bounds on the conversion are the ones already proven by the clip
    /// immediately upstream — the encoding is monotonic with `f(0) = 0` and
    /// `f(1) ≈ 1` — not invented limits. They are written out because a
    /// trapping integer conversion is not an acceptable failure mode on a
    /// publicly reachable path.
    static func quantize(_ encoded: Double) -> UInt16 {
        let scaled = (encoded * Double(ExportEncodedImage.maximumSample)).rounded()
        return UInt16(
            Swift.min(Swift.max(scaled, 0), Double(ExportEncodedImage.maximumSample))
        )
    }
}
