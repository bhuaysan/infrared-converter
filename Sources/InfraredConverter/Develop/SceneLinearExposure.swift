import Foundation

/// Exposure compensation as arithmetic on scene-linear light, and the one
/// place in the project that arithmetic is written.
///
/// ```text
/// scale    = 2^EV
/// exposed  = sceneLinear × scale        per component, in Double, narrowed once
/// ```
///
/// ## Why this is its own type
///
/// `DisplayPreviewRenderer` performed this multiplication inline, which made
/// the *display* stage the mathematical authority on a *scene-linear*
/// adjustment. That was accurate while the display was the only consumer. It
/// stopped being accurate when a full-resolution export — which must apply the
/// same user decision and must not go anywhere near an 8-bit display renderer
/// — needed the same semantics. See
/// `docs/decisions/0018-full-resolution-tiff-export.md` and the amendment to
/// `docs/decisions/0017-interactive-exposure.md`.
///
/// The alternative was to copy four lines into the export path. Two copies of
/// a numeric rule drift, and the drift would be invisible: an export that is
/// one rounding step, one narrowing order or one `pow`-versus-`exp2` away from
/// the preview looks entirely plausible.
///
/// ```text
/// UserExposureAdjustment     the person's intent, validated and persisted
/// SceneLinearExposure        the mathematics, shared by every consumer
/// DisplayPreviewRenderer     display clipping and 8-bit sRGB encoding
/// ExportImageEncoder         export clipping and 16-bit sRGB encoding
/// ```
///
/// ## What it is not
///
/// It is not tone mapping, automatic exposure, a curve, a gain estimated from
/// the image, or highlight recovery. It multiplies. Nothing here clips: a
/// value this type lifts above `1` stays above `1` and reaches whichever range
/// policy owns clipping, which is what lets a later negative exposure bring it
/// back. Clamping here would destroy that and would be invisible.
public struct SceneLinearExposure: Equatable, Sendable {

    /// Exposure compensation in stops, exactly as the user asked for it.
    public let ev: Double

    /// The linear multiplier, `2^EV`.
    ///
    /// `exp2` rather than `pow(2, ev)`: exact for integral stops, which is
    /// what makes `+1 EV` precisely a doubling rather than a doubling to
    /// within a rounding error.
    public let scale: Double

    public init(ev: Double) {
        self.ev = ev
        self.scale = exp2(ev)
    }

    /// The neutral exposure: `0 EV`, scale `1`.
    public static let neutral = SceneLinearExposure(ev: 0)

    /// The adjustment a user asked for, as arithmetic.
    public init(_ adjustment: UserExposureAdjustment) {
        self.init(ev: adjustment.ev)
    }

    /// Whether this exposure can be applied at all.
    ///
    /// Both halves are checked. `2^EV` is not finite for a NaN EV, but it *is*
    /// finite for `−infinity`: `exp2(−infinity)` is `0`, a perfectly
    /// usable-looking scale that would silently render a black frame from a
    /// nonsense exposure. So the EV itself has to be finite too, which is why
    /// this is not a check on the scale alone.
    public var isApplicable: Bool { ev.isFinite && scale.isFinite }

    /// Whether this exposure leaves every value exactly as it was.
    public var isIdentity: Bool { ev == 0 }

    /// One component, exposed.
    ///
    /// Multiplied in `Double` and narrowed exactly once: a `Float32` product
    /// can overflow where the mathematical result cannot, and narrowing twice
    /// would round twice. The result is **not** checked for finiteness here —
    /// the caller knows the pixel's coordinates and can say which one failed,
    /// which this cannot.
    @inline(__always)
    public func applied(to sceneLinear: Float) -> Float {
        Float(Double(sceneLinear) * scale)
    }

    public var diagnosticDescription: String {
        "\(ev) EV (×\(scale)), scene-linear, not tone mapping"
    }
}
