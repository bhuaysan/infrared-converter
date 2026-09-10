import Foundation

/// The RGB coordinate system the application's working representation is
/// defined in.
///
/// ## A coordinate system, not a rendering intent
///
/// Choosing a working colour space answers exactly one question: **what do the
/// numbers in a working-representation buffer mean as coordinates?** It says
/// nothing about how sensor responses got there. That second question — how
/// camera-native RGB is mapped into these coordinates — is a separate decision
/// carried by `RAWCameraToWorkingColorTransform`, and for an infrared-modified
/// camera it is the harder of the two.
///
/// Keeping them apart is deliberate. Conflating them is how a project ends up
/// believing that "the working space is sRGB" implies "the colours are
/// correct". See `docs/decisions/0006-working-color-space.md`.
///
/// ## Exactly one case
///
/// Display P3, ProPhoto RGB, Adobe RGB, ACES, XYZ and Rec.2020 are absent on
/// purpose. A case here is a claim that the pipeline can produce and interpret
/// that space; none of them can be produced today, and a case that exists but
/// is unimplemented is worse than one that does not exist at all. They arrive
/// when they are implemented.
public enum RAWWorkingColorSpace: Equatable, Sendable {
    /// sRGB primaries and the sRGB D65 white point, with a **linear** transfer
    /// function and floating-point values that are not clipped to `0...1`.
    ///
    /// Concretely, a value in this space is:
    ///
    /// ```text
    /// primaries      sRGB / IEC 61966-2-1
    /// white point    D65
    /// transfer       linear — light is proportional to the number
    /// storage        Float32
    /// range          any finite Float: < 0, 0...1 and > 1 are all legal
    /// ```
    ///
    /// ### What "extended" means here
    ///
    /// Only that the range is not clipped. Values below `0` occur because
    /// black-subtracted sensor noise straddles the black point and because a
    /// matrix with negative coefficients — which infrared work legitimately
    /// uses — produces them. Values above `1` occur because highlights above
    /// the normalisation white level are preserved rather than clipped. Both
    /// are retained; a later display or export stage decides what to do with
    /// them.
    ///
    /// ### What is deliberately NOT applied
    ///
    /// - the nonlinear sRGB transfer function (the "sRGB gamma" curve)
    /// - any other gamma or tone curve
    /// - clamping, in either direction
    /// - tone mapping or gamut mapping
    /// - auto exposure
    /// - display encoding
    ///
    /// A buffer in this space is therefore **not** ready to write to a file
    /// tagged sRGB and not ready to hand to a display. Encoding it for a
    /// monitor is a later, separate stage.
    ///
    /// ### Why this space first
    ///
    /// It is the smallest well-defined choice that later stages can build on:
    /// its primaries and white point are unambiguous, its linearity keeps
    /// channel mixing and exposure arithmetic meaningful, and macOS already
    /// understands extended-range linear sRGB, so a future Core Image or
    /// Metal preview bridge is a labelling exercise rather than a conversion
    /// design.
    case extendedLinearSRGB

    /// A short label for diagnostics and provenance reports.
    public var diagnosticDescription: String {
        switch self {
        case .extendedLinearSRGB:
            return "extended linear sRGB (sRGB primaries, D65, linear transfer, unclamped Float32)"
        }
    }
}
