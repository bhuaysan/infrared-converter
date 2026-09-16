import Foundation

/// The display boundary: `LeveledLinearRGBImage` →
/// `DisplayEncodedPreviewImage`, by hard display-range clipping, the sRGB
/// transfer function and deterministic quantisation.
///
/// ```text
/// IRChannelMixedRGBImage         extended linear sRGB, in sensor order
///       │
///       │  explicit RAWImageOrientation
///       ↓
/// ImageOrienter                  discrete geometry — ADR 0009
///       ↓
/// OrientedSceneLinearRGBImage    the same values, in viewing order
///       │
///       │  explicit SceneLinearExposure
///       ↓
/// SceneLinearExposer             × 2^EV, in the linear domain — ADR 0017
///       ↓
/// ExposedSceneLinearRGBImage     still scene-linear, still unclamped
///       │
///       │  explicit LinearLevels
///       ↓
/// LinearLevelsApplier            (x − black) / (white − black) — ADR 0026
///       ↓
/// LeveledLinearRGBImage          linear-light, no longer scene-linear
///       │
///       │  explicit DisplayRenderSettings
///       ↓
/// DisplayPreviewRenderer         ← this stage
///       │
///       │  clipped = min(max(x, 0), 1)         hard, named, counted
///       │  encoded = sRGB OETF(clipped)        piecewise, not 1/2.2
///       │  sample  = round(encoded × 255)      half away from zero
///       ↓
/// DisplayEncodedPreviewImage     display-referred sRGB, 8 bits per component
///       ↓
/// DisplayPreviewCGImageAdapter   tagged sRGB, handed to SwiftUI
/// ```
///
/// See `docs/decisions/0008-display-preview-rendering.md` and
/// `docs/decisions/0026-linear-levels.md`.
///
/// ## Why it no longer applies exposure
///
/// It used to, in the same pass that it clipped and encoded, which made the
/// display stage the arithmetic authority on a scene-linear adjustment. Levels
/// ended that: they must sit **after** exposure and **before** clipping, and
/// nothing can be inserted between two halves of one fused pass. Exposure
/// therefore moved to `SceneLinearExposer` — where the export path had already
/// been calling it — and Levels follows it as `LinearLevelsApplier`.
///
/// What remains here is exactly what belongs to a destination: a range policy,
/// a transfer function and a bit depth. The export encoder now receives the
/// **same type** from the **same stages**, so preview and export differ in
/// resolution, range policy, bit depth and destination, and in nothing else.
///
/// ## What this stage is not
///
/// It is **not** a photographic tone pipeline. There is no tone mapping, no
/// highlight reconstruction, no automatic exposure, no histogram, no contrast,
/// no saturation, no curve and no LUT. It is a defined, auditable clip and
/// encode, and calling it anything more would misdescribe it.
///
/// The clipping destroys information in both directions, so the stage counts
/// what it destroyed and records the counts in provenance. A preview whose
/// whites are white because the display range ran out is a different thing
/// from one whose scene was bright, and the numbers say which.
///
/// ## The input is taken at its word, and only at its word
///
/// The input must be linear-light working-space coordinates: `Float32`,
/// interleaved, finite, and legitimately outside `0...1` in both directions.
/// They are never treated as though they were already sRGB-encoded — the
/// mistake that is invisible in code and obvious on screen.
///
/// They are **not** scene-linear, and the type says so: Levels have already
/// subtracted an offset. That changes nothing about this stage's arithmetic —
/// clipping and a transfer function care about the range, not about
/// proportionality to radiance — but it is why the parameter is a
/// `LeveledLinearRGBImage` and not an `OrientedSceneLinearRGBImage`.
///
/// What the stage does **not** assume is that the values are good. Whether
/// they mean anything colourimetrically for an infrared capture is the
/// camera-to-working transform's business, and no transform in this project is
/// a validated infrared calibration. Displayable is a weaker claim than
/// correct.
///
/// ## No defaults, anywhere
///
/// Every entry point requires a `DisplayRenderSettings`. There is no defaulted
/// parameter that could supply one — the same rule `IRChannelMixer` applies to
/// mixes, for the same reason.
///
/// ## Arithmetic
///
/// Storage is `Float32` in and `UInt8` out. Clipping operates on the `Float32`
/// value; the transfer function is evaluated in `Double` on the clipped value;
/// quantisation rounds to nearest, half away from zero.
///
/// ## Geometry
///
/// Strictly per-pixel and geometry-preserving: same width, same height, same
/// pixel order. No crop, no resize, no resampling — and **no orientation**.
/// This stage does not read `RAWMetadata.geometry.flip` and never will.
///
/// Its input arrives already arranged for viewing because `ImageOrienter` did
/// that three stages upstream, as its own auditable operation. Provenance
/// forwards the fact — `orientationApplied` and `appliedOrientation` are
/// readable from a preview — while the work itself stays where it can be seen.
///
/// ## Cancellation
///
/// The encode is one synchronous pass over every component, so a caller that
/// has superseded it needs a way to stop it rather than merely discard it.
/// `render` takes a `ProcessingCancellation` and polls it **once before any
/// work, and once more before each row**. A stated granularity is the point: a
/// test can predict the poll count exactly, which is how abandoning the work
/// early is proven rather than assumed.
///
/// A cancelled call throws `CancellationError` and returns no image at all. It
/// is not a `DisplayRenderingError`: nothing about the image was wrong.
///
/// ## Cost
///
/// `O(component count)`: one read pass over the input, one owned output buffer
/// a quarter of its size, and one `pow` per component that takes the nonlinear
/// branch. No full-frame intermediate, no `Double` image buffer, no per-pixel
/// allocation.
///
/// This is a reference CPU implementation. Metal, Accelerate, vDSP and Core
/// Image are deliberately absent — Core Image especially, since a `CIFilter`
/// chain behind a display call would be an undocumented tone and colour
/// pipeline, which is the opposite of the point.
public struct DisplayPreviewRenderer: Sendable {
    public init() {}

    /// Renders adjusted linear-light working coordinates into display-encoded
    /// preview pixels.
    ///
    /// - Parameters:
    ///   - image: linear-light working-space coordinates in viewing order,
    ///     with the mix, the orientation, the exposure and the levels already
    ///     applied, as `LinearLevelsApplier` produces. Not mutated, not
    ///     clamped, not modified in any way.
    ///   - settings: range policy and encoding. Required — there is
    ///     deliberately no default.
    ///   - cancellation: polled once here and once per row. Defaults to never
    ///     cancelling.
    /// - Throws: `DisplayRenderingError`, or `CancellationError` when the work
    ///   was superseded. The two are deliberately distinct types: one says the
    ///   image could not be encoded, the other says nobody wants it.
    public func render(
        _ image: LeveledLinearRGBImage,
        settings: DisplayRenderSettings,
        cancellation: ProcessingCancellation = .none
    ) throws -> DisplayEncodedPreviewImage {
        guard image.isGeometryConsistent else {
            throw DisplayRenderingError.invalidGeometry(
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

        // A consistent input already proves this product is representable —
        // the output needs exactly the count the input's `Float` buffer
        // already has — so this cannot currently fail. Checked rather than
        // assumed, and reported as the one geometry case rather than a second
        // one that would mean the same thing.
        guard let byteCount = DisplayEncodedPreviewImage.expectedByteCount(
            width: image.width, height: image.height
        ) else {
            throw DisplayRenderingError.invalidGeometry(
                reason: """
                    Preview geometry \(image.width)x\(image.height) needs an unrepresentable \
                    number of bytes.
                    """
            )
        }

        var clippedLow = 0
        var clippedHigh = 0
        var bytes = Data(count: byteCount)

        try bytes.withUnsafeMutableBytes { rawOutput in
            // `Data(count:)` of a positive count always has a base address;
            // a zero count cannot occur here, since a consistent geometry has
            // positive dimensions.
            guard let output = rawOutput.bindMemory(to: UInt8.self).baseAddress else {
                throw DisplayRenderingError.invalidGeometry(
                    reason: "Preview buffer of \(byteCount) bytes has no storage."
                )
            }
            let encoding = settings.encoding

            try image.values.withUnsafeBufferPointer { input in
                // One component: validate, clip, encode, quantise. Written
                // once and called three times per pixel rather than looped
                // over `RAWLinearRGBChannel.allCases`, which would allocate an
                // array per pixel — the same reason the channel mixer writes
                // its three checks out.
                func sample(
                    _ index: Int,
                    _ row: Int,
                    _ column: Int,
                    _ channel: RAWLinearRGBChannel
                ) throws -> UInt8 {
                    let linear = input[index]

                    // A hand-built image can carry anything, and no upstream
                    // stage here can produce a non-finite value, so this is a
                    // real boundary rather than an assertion.
                    guard linear.isFinite else {
                        throw DisplayRenderingError.nonFiniteLinearInput(
                            row: row, column: column, channel: channel, value: linear
                        )
                    }

                    // Hard display-range clipping, counted, per
                    // `settings.rangePolicy`. Both branches destroy detail;
                    // that is what the counts are for. It is the first thing
                    // this stage does, because everything an adjustment is
                    // allowed to do to these values has already been done.
                    let clipped: Float
                    switch settings.rangePolicy {
                    case .hardClipToDisplayRange:
                        if linear < 0 {
                            clipped = 0
                            clippedLow += 1
                        } else if linear > 1 {
                            clipped = 1
                            clippedHigh += 1
                        } else {
                            clipped = linear
                        }
                    }

                    return Self.quantize(Self.encode(Double(clipped), as: encoding))
                }

                var base = 0
                for row in 0..<image.height {
                    // One poll per row. Throwing here abandons the whole
                    // buffer — the caller gets `CancellationError`, never an
                    // image with some rows encoded and the rest still zero,
                    // which would look like a perfectly ordinary black band.
                    try cancellation.check()
                    for column in 0..<image.width {
                        output[base] = try sample(base, row, column, .red)
                        output[base + 1] = try sample(base + 1, row, column, .green)
                        output[base + 2] = try sample(base + 2, row, column, .blue)
                        base += DisplayEncodedPreviewImage.bytesPerPixel
                    }
                }
            }
        }

        return DisplayEncodedPreviewImage(
            width: image.width,
            height: image.height,
            bytes: bytes,
            processing: DisplayPreviewProcessing(
                settings: settings,
                levelsProcessing: image.processing,
                clippedLowSampleCount: clippedLow,
                clippedHighSampleCount: clippedHigh
            )
        )
    }

    /// Renders a levelled result, keeping that whole adjusted state reachable
    /// on the returned value's `source`.
    ///
    /// Use this rather than the bare-image overload whenever the caller may
    /// want different settings — or different adjustments — later: the result
    /// carries everything needed to restart from any upstream stage, without
    /// converting, demosaicing or decoding again.
    public func render(
        _ processed: LeveledProcessedRAWImage,
        settings: DisplayRenderSettings,
        cancellation: ProcessingCancellation = .none
    ) throws -> DisplayPreviewProcessedRAWImage {
        let image = try render(
            processed.image, settings: settings, cancellation: cancellation
        )
        return DisplayPreviewProcessedRAWImage(source: processed, image: image)
    }

    /// Replaces the settings on a previous preview, re-rendering from the
    /// scene-linear image it was produced from.
    ///
    /// Previews never compound: new settings are applied to the
    /// `LeveledLinearRGBImage`, never to the already-encoded bytes. That is
    /// structural — this reaches through `previous.source` and never touches
    /// `previous.image`. Re-rendering an encoded preview would apply the
    /// transfer function twice, compound quantisation, and be unable to
    /// recover a single clipped highlight, while looking entirely plausible.
    ///
    /// Nothing upstream reruns: no levels, no exposure, no orientation, no
    /// channel mix, no camera conversion, no demosaic, no white balance, no
    /// decode.
    public func render(
        settings newSettings: DisplayRenderSettings,
        replacing previous: DisplayPreviewProcessedRAWImage,
        cancellation: ProcessingCancellation = .none
    ) throws -> DisplayPreviewProcessedRAWImage {
        try render(previous.source, settings: newSettings, cancellation: cancellation)
    }

    // MARK: - The transfer function

    /// The sRGB opto-electronic transfer function, evaluated in `Double`.
    ///
    /// ```text
    /// if x <= 0.0031308:  12.92 × x
    /// else:               1.055 × x^(1 / 2.4) − 0.055
    /// ```
    ///
    /// `pow(x, 1 / 2.2)` is **not** this curve, differs most in the shadows,
    /// and would make the bytes disagree with the sRGB profile they are about
    /// to be tagged with. The linear segment near black is part of what sRGB
    /// specifies.
    ///
    /// The comparison is `<=`, so the threshold itself takes the linear
    /// branch. The published constants are slightly inconsistent — the two
    /// branches differ by about `3e-8` there — and choosing a branch by fiat
    /// is the only way to make the boundary deterministic.
    ///
    /// Internal rather than private so the reference points can be pinned
    /// directly, and rather than public because the stage's surface is the
    /// renderer, not its arithmetic.
    ///
    /// - Parameter displayLinear: a value in `0...1`, already exposed and
    ///   already clipped.
    static func encode(_ displayLinear: Double, as encoding: DisplayEncoding) -> Double {
        switch encoding {
        case .sRGB:
            return SRGBTransferFunction.encode(displayLinear)
        }
    }

    // MARK: - Quantisation

    /// Rounds an encoded value in `0...1` to an 8-bit sample.
    ///
    /// ```text
    /// sample = round(encoded × 255)          half away from zero
    /// ```
    ///
    /// Every input here is non-negative, so "half away from zero" is plainly
    /// "half up". Truncation was rejected: it biases every sample downward by
    /// up to one level and maps `1` to `254`.
    ///
    /// The endpoints are exact:
    ///
    /// ```text
    /// 0 → 0 × 255 = 0                        → 0
    /// 1 → 254.999999999999971… → rounded     → 255
    /// ```
    ///
    /// The second is worth stating carefully. `1.055 × 1^(1/2.4) − 0.055`
    /// evaluates in `Double` to one ULP below `1`, so rounding to nearest is
    /// exactly what recovers `255`. The mapping is exact *because* of the
    /// rounding step.
    ///
    /// The bounds on the conversion are the ones already proven by the clip
    /// immediately upstream — the encoding is monotonic with `f(0) = 0` and
    /// `f(1) ≈ 1` — not invented limits. They are written out because a
    /// trapping integer conversion is not an acceptable failure mode on a
    /// publicly reachable path.
    static func quantize(_ encoded: Double) -> UInt8 {
        let scaled = (encoded * 255).rounded()
        return UInt8(Swift.min(Swift.max(scaled, 0), 255))
    }
}
