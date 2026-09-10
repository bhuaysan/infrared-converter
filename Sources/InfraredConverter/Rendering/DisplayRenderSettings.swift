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
/// IRChannelMixedRGBImage        extended linear sRGB, scene-linear, unclamped
///         ↓
/// DisplayRenderSettings         ← this type: exposure + range policy + encoding
///         ↓
/// DisplayPreviewRenderer
///         ↓
/// DisplayEncodedPreviewImage    display-referred sRGB, 8 bits per component
/// ```
///
/// ## There is no default
///
/// No `.standard`, no `.neutral`, no zero-argument initialiser, and no
/// defaulted parameter on any renderer entry point that could supply one. A
/// caller that wants neutral exposure writes `0 EV`, and that choice is then
/// visible at the call site to anyone reading the code — which is the whole
/// point, and the same reason `IRChannelMixer` requires a mix to be named.
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
/// matrix came from somewhere it did not. This type pairs three independent
/// choices, none of which is a claim about anything's origin. There is nothing
/// here to forge, so the memberwise initialiser stays open and the value is
/// validated once, where it is used.
public struct DisplayRenderSettings: Equatable, Sendable {
    /// Exposure in photographic stops, applied in the **linear** domain as
    /// `linearInput × 2^EV`.
    ///
    /// ```text
    /// +1 EV   ×2
    ///  0 EV   ×1        the mathematically neutral value
    /// −1 EV   ×0.5
    /// +2 EV   ×4
    /// ```
    ///
    /// Fractional values are supported and mean what they say: `+0.5 EV` is
    /// `×2^0.5`, half a stop.
    ///
    /// Not clamped to a "sensible" range. It must, however, be finite, and
    /// `2^EV` must be finite too — `DisplayPreviewRenderer` refuses both
    /// failures rather than substituting a plausible number.
    public let exposureEV: Double
    /// What happens to coordinates outside `0...1`, after exposure.
    public let rangePolicy: DisplayRangePolicy
    /// The transfer function and colour space the output bytes are in.
    public let encoding: DisplayEncoding

    public init(
        exposureEV: Double,
        rangePolicy: DisplayRangePolicy,
        encoding: DisplayEncoding
    ) {
        self.exposureEV = exposureEV
        self.rangePolicy = rangePolicy
        self.encoding = encoding
    }

    /// The linear multiplier `2^exposureEV`.
    ///
    /// Exact for integer stops: `exp2(0) == 1`, `exp2(1) == 2`,
    /// `exp2(-1) == 0.5`, `exp2(2) == 4`, with no rounding in any of them.
    ///
    /// Not guaranteed finite — a finite but enormous EV produces an infinite
    /// scale, which the renderer refuses. This property reports what the
    /// arithmetic gives; it does not sanitise it.
    public var exposureScale: Double { exp2(exposureEV) }

    /// A one-line summary for diagnostics and reports.
    public var diagnosticDescription: String {
        "\(exposureEV) EV (×\(exposureScale)), \(rangePolicy.diagnosticDescription), "
            + encoding.diagnosticDescription
    }
}
