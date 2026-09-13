import Foundation

/// The sRGB opto-electronic transfer function, and the one place it is
/// written.
///
/// ```text
/// if x <= 0.0031308:  12.92 × x
/// else:               1.055 × x^(1 / 2.4) − 0.055
/// ```
///
/// `pow(x, 1 / 2.2)` is **not** this curve, differs most in the shadows, and
/// would make encoded samples disagree with the sRGB profile they are about to
/// be tagged with. The linear segment near black is part of what sRGB
/// specifies.
///
/// The comparison is `<=`, so the threshold itself takes the linear branch.
/// The published constants are slightly inconsistent — the two branches differ
/// by about `3e-8` there — and choosing a branch by fiat is the only way to
/// make the boundary deterministic.
///
/// ## Why it is shared
///
/// Two encoders apply it: `DisplayPreviewRenderer`, to 8-bit preview pixels,
/// and `ExportImageEncoder`, to 16-bit export samples. A second copy of a
/// transfer function is a second curve that can drift, and the drift would be
/// invisible — an export a shade lighter than its preview looks like an
/// export, not like a defect. Evaluated in `Double` on both paths, so the two
/// differ only in the quantisation step each applies afterwards.
///
/// See `docs/decisions/0008-display-preview-rendering.md` and
/// `docs/decisions/0018-full-resolution-tiff-export.md`.
public enum SRGBTransferFunction {

    /// The threshold between the linear segment and the power segment.
    public static let linearSegmentThreshold = 0.003_130_8

    /// Encodes one display-linear value.
    ///
    /// - Parameter displayLinear: a value in `0...1`, already exposed and
    ///   already clipped by whichever range policy owns clipping. Values
    ///   outside that range are not this function's business and it does not
    ///   check for them: `pow` of a negative base is NaN, which is why every
    ///   caller clips first.
    public static func encode(_ displayLinear: Double) -> Double {
        if displayLinear <= linearSegmentThreshold {
            return 12.92 * displayLinear
        }
        return 1.055 * pow(displayLinear, 1.0 / 2.4) - 0.055
    }
}
