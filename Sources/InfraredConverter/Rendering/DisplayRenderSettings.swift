import Foundation

/// What a display renderer does with coordinates that lie outside `0...1`.
///
/// ## Exactly one case
///
/// `.reinhard`, `.filmic`, `.aces`, a shoulder/toe curve and a local operator
/// are all absent on purpose, as are real gamut-mapping strategies. A case
/// here is a claim that the pipeline can produce that behaviour; none of them
/// can, and a case that exists but is unimplemented is worse than one that
/// does not exist at all. They arrive when they are implemented.
///
/// See `docs/decisions/0008-display-preview-rendering.md`, Decision 6.
public enum DisplayRangePolicy: Equatable, Sendable {
    /// Each component is clipped to the unit range, independently of the
    /// other two:
    ///
    /// ```text
    /// x < 0   → 0
    /// x > 1   → 1
    /// else    → x unchanged
    /// ```
    ///
    /// ## This is not tone mapping
    ///
    /// Nothing is compressed, rolled off, shouldered, toed or adapted, and no
    /// highlight is recovered. Detail above `1` is **destroyed** and detail
    /// below `0` is **destroyed**. Describing it any more gently would
    /// misdescribe what the code does.
    ///
    /// ## It is also this path's gamut handling
    ///
    /// Clipping extended linear sRGB to the unit cube is a primitive gamut
    /// operation as well as a range one. A coordinate outside the cube may be
    /// outside sRGB's gamut, and clipping each component independently moves
    /// it to a *different colour*, not to the nearest in-gamut one. Values
    /// below zero are ordinary in this pipeline — black-subtracted noise
    /// straddles the black point, and creative mixes with negative
    /// coefficients produce them deliberately — so this acts on real data, not
    /// on a theoretical edge case.
    ///
    /// ## Where it happens
    ///
    /// Only in the display representation, and only after exposure. The
    /// scene-linear image it was rendered from is never mutated, replaced or
    /// clamped.
    case hardClipToDisplayRange

    /// A short label for diagnostics and provenance reports, worded so it
    /// cannot be read as tone mapping.
    public var diagnosticDescription: String {
        switch self {
        case .hardClipToDisplayRange:
            return "hard display-range clipping to 0...1 (per component; not tone mapping)"
        }
    }
}

/// The encoding a display renderer produces, and the colour space its output
/// bytes are in.
///
/// ## Exactly one case
///
/// Display P3, Rec.709, Rec.2020, any HDR transfer function and any linear
/// output are absent for the reason `RAWWorkingColorSpace` gives for its own
/// single case: this pipeline can produce and correctly tag exactly one thing
/// today.
public enum DisplayEncoding: Equatable, Sendable {
    /// Standard sRGB: sRGB primaries, the sRGB D65 white point, and the
    /// **piecewise sRGB opto-electronic transfer function**.
    ///
    /// ```text
    /// if x <= 0.0031308:  encoded = 12.92 × x
    /// else:               encoded = 1.055 × x^(1 / 2.4) − 0.055
    /// ```
    ///
    /// ### Not a gamma-2.2 approximation
    ///
    /// `pow(x, 1/2.2)` is a different curve. It differs most in the shadows —
    /// where infrared work most often lives — and it would make the bytes
    /// disagree with the sRGB profile they are tagged with. The linear segment
    /// near black is part of what sRGB specifies, not a refinement.
    ///
    /// ### The relationship to the working space
    ///
    /// ```text
    /// extended linear sRGB   same primaries, same white point, LINEAR transfer,
    ///                        unclamped Float32, scene-referred
    ///
    /// this                   same primaries, same white point, sRGB transfer,
    ///                        0...1, display-referred
    /// ```
    ///
    /// The primaries do not change here. What changes is the transfer function
    /// and the range — which is exactly why values encoded this way must never
    /// be tagged linear, and values in the working space must never be tagged
    /// as this.
    case sRGB

    /// A short label for diagnostics and provenance reports.
    public var diagnosticDescription: String {
        switch self {
        case .sRGB:
            return "standard sRGB (sRGB primaries, D65, piecewise sRGB transfer function)"
        }
    }
}

/// Every choice the display rendering stage requires, and nothing else.
///
/// ```text
/// LeveledLinearRGBImage         linear-light, unclamped, every adjustment applied
///         ↓
/// DisplayRenderSettings         ← this type: range policy + encoding
///         ↓
/// DisplayPreviewRenderer
///         ↓
/// DisplayEncodedPreviewImage    display-referred sRGB, 8 bits per component
/// ```
///
/// ## Why there is no exposure here any more
///
/// There used to be. `exposureEV` lived on these settings because the display
/// renderer applied exposure in the same pass that it clipped and encoded,
/// which made the *display* stage the authority on a *scene-linear*
/// adjustment. That was already uncomfortable when the export path had to
/// apply the same decision without going near an 8-bit renderer, and it became
/// untenable when Levels arrived: Levels must sit **after** exposure and
/// **before** clipping, and there is no way to put a stage between two halves
/// of one fused pass.
///
/// So exposure moved out, to `SceneLinearExposer`, where the export path had
/// already been calling it, and Levels follows it as `LinearLevelsApplier`.
/// The preview and the export now run the identical three-stage sequence and
/// hand the identical type to their respective encoders:
///
/// ```text
/// OrientedSceneLinearRGBImage
///   → SceneLinearExposer        adjustments.exposure
///   → LinearLevelsApplier       adjustments.levels
///   → LeveledLinearRGBImage     ─┬─ DisplayPreviewRenderer  (this type)
///                                └─ ExportImageEncoder      (ExportRenderSettings)
/// ```
///
/// The absence is therefore structural rather than tidy, exactly as it is for
/// `ExportRenderSettings`: the image these settings describe has already been
/// exposed and levelled, and settings carrying an exposure would offer a
/// second, silent application of it. The renderer cannot double-expose because
/// it is not given an exposure. See
/// `docs/decisions/0026-linear-levels.md`.
///
/// ## No automatic behaviour
///
/// Nothing here is derived from the image. No histogram is read, no mean or
/// percentile is computed, and nothing is normalised to a maximum. If a value
/// in this struct changed the rendering, a person chose it.
///
/// ## Why this initialiser is public, when `IRChannelMix`'s is not
///
/// `IRChannelMix` and `RAWCameraToWorkingColorTransform` pair a matrix with a
/// **provenance claim**, so a caller-assembled pairing could assert that a
/// matrix came from somewhere it did not. This type pairs two independent
/// choices, neither of which is a claim about anything's origin. There is
/// nothing here to forge, so the memberwise initialiser stays open and the
/// value is validated once, where it is used.
public struct DisplayRenderSettings: Equatable, Sendable {
    /// What happens to coordinates outside `0...1`.
    public let rangePolicy: DisplayRangePolicy
    /// The transfer function and colour space the output bytes are in.
    public let encoding: DisplayEncoding

    public init(rangePolicy: DisplayRangePolicy, encoding: DisplayEncoding) {
        self.rangePolicy = rangePolicy
        self.encoding = encoding
    }

    /// The settings every interactive preview in this version uses.
    ///
    /// An application choice, spelled out in one place rather than defaulted
    /// inside the renderer — the renderer has no default settings,
    /// deliberately, for the same reason no processing stage in this project
    /// has one. The mirror of `ExportRenderSettings.standard`.
    public static let standard = DisplayRenderSettings(
        rangePolicy: .hardClipToDisplayRange, encoding: .sRGB
    )

    /// A one-line summary for diagnostics and reports.
    public var diagnosticDescription: String {
        "\(rangePolicy.diagnosticDescription), \(encoding.diagnosticDescription)"
    }
}
