import Foundation

/// A black point and a white point as arithmetic on linear-light RGB, and the
/// one place in the project that arithmetic is written.
///
/// ```text
/// span   = whitePoint − blackPoint
/// scale  = 1 / span
/// output = (input − blackPoint) × scale      per component, in Double,
///                                            narrowed once
/// ```
///
/// Applied independently and identically to every RGB component. There are no
/// per-channel levels, and the three output components of one pixel are
/// produced by the same two numbers.
///
/// ## Why this is its own type
///
/// For the reason `SceneLinearExposure` is: two consumers apply it — the
/// interactive preview at reduced resolution and the full-resolution export —
/// and two copies of a numeric rule drift invisibly. An export that subtracted
/// before scaling in `Float32` rather than `Double`, or that computed the
/// reciprocal per component rather than once, would look entirely plausible
/// and would not match the preview.
///
/// ```text
/// UserLevelsAdjustment       the person's intent, validated and persisted
/// LinearLevels               the mathematics, shared by every consumer
/// LinearLevelsApplier        the stage that runs it over an image
/// ```
///
/// ## It is not exposure, and the difference is not cosmetic
///
/// ```text
/// exposure   x × 2^EV               a pure gain. Proportionality to scene
///                                   radiance survives it: double the light,
///                                   double the number, at every level.
///
/// levels     (x − b) / (w − b)      an affine map. The subtraction moves the
///                                   origin, so the result is no longer
///                                   proportional to scene radiance unless
///                                   b is exactly 0.
/// ```
///
/// That is why the stage downstream of this produces `LeveledLinearRGBImage`
/// rather than another scene-linear type: the values are still **linear-light
/// encoded** — no transfer function has been applied, nothing is compressed —
/// but the claim "proportional to the light that reached the sensor" is gone
/// the moment a non-zero black point is subtracted.
/// `preservesProportionalityToSceneRadiance` says which case a given value is.
///
/// ## What it is not
///
/// It is not tone mapping, a curve, contrast, a gamma slider, highlight or
/// shadow recovery, automatic levels, a histogram stretch, white balance, or
/// RAW normalisation. Every one of those has been declined by name, because
/// each is something an affine rescale is routinely mistaken for.
///
/// Nothing here clips. A value this type pushes below `0` or above `1` reaches
/// whichever range policy owns clipping with its magnitude intact — which is
/// exactly what lets a person open the shadows and then pull them back. See
/// `docs/decisions/0026-linear-levels.md`.
public struct LinearLevels: Equatable, Sendable {

    /// The input value that becomes `0`.
    public let blackPoint: Double

    /// The input value that becomes `1`.
    public let whitePoint: Double

    /// `whitePoint − blackPoint`, computed once.
    ///
    /// Stored rather than derived at each call so that the subtraction that
    /// decides applicability is the same subtraction that produces the result.
    public let span: Double

    /// The reciprocal of the span, `1 / (whitePoint − blackPoint)`, computed
    /// once per value rather than once per component.
    ///
    /// A reciprocal and a multiply rather than a divide per component: one
    /// rounding of the reciprocal, shared by every pixel, is deterministic and
    /// is what makes preview and export agree bit for bit at the same input.
    public let scale: Double

    public init(blackPoint: Double, whitePoint: Double) {
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
        let span = whitePoint - blackPoint
        self.span = span
        self.scale = 1 / span
    }

    /// The neutral levels: black `0`, white `1`, scale exactly `1`.
    ///
    /// Mathematically the identity. `(x − 0) × 1` returns every finite `Float`
    /// unchanged, signed zeros and subnormals included.
    public static let neutral = LinearLevels(blackPoint: 0, whitePoint: 1)

    /// The adjustment a user asked for, as arithmetic.
    public init(_ adjustment: UserLevelsAdjustment) {
        self.init(
            blackPoint: adjustment.blackPoint, whitePoint: adjustment.whitePoint
        )
    }

    /// Whether these levels can be applied at all.
    ///
    /// Four conditions, and each rules out a distinct way the arithmetic stops
    /// meaning anything:
    ///
    /// ```text
    /// both endpoints finite      NaN or an infinity describes no interval
    /// blackPoint < whitePoint    equal endpoints divide by zero; reversed
    ///                            endpoints invert the image, which is a
    ///                            different decision nobody asked for
    /// span finite                endpoints ~1e308 apart overflow the
    ///                            subtraction, giving a scale of exactly 0 —
    ///                            every pixel would render as black and the
    ///                            arithmetic would look healthy
    /// scale finite               endpoints closer than about 1e-308 make the
    ///                            reciprocal overflow, and every finite input
    ///                            would become an infinity
    /// ```
    ///
    /// This is the **whole** validity rule, and it is derived from what IEEE
    /// 754 doubles can represent rather than from photography. No magnitude
    /// limit is imposed on either endpoint: `black = −1e300, white = 1e300` is
    /// perfectly representable, maps `1.0` to `0.5`, and is allowed. A
    /// photographic bound such as `−1…2` would be a slider's opinion wearing a
    /// validity rule's clothes.
    public var isApplicable: Bool {
        blackPoint.isFinite
            && whitePoint.isFinite
            && blackPoint < whitePoint
            && span.isFinite
            && scale.isFinite
    }

    /// Whether these levels leave every value exactly as it was: black `0`,
    /// white `1`.
    public var isIdentity: Bool { blackPoint == 0 && whitePoint == 1 }

    /// Whether the result of applying these levels is still proportional to
    /// the light that reached the sensor.
    ///
    /// True exactly when the black point is `0`, which makes the map a pure
    /// gain `x / whitePoint` — the same kind of operation exposure is. Any
    /// other black point subtracts an offset, and an offset destroys
    /// proportionality at every level.
    ///
    /// Derived, never asserted: it is a property of the two numbers, so it
    /// cannot disagree with what was applied.
    public var preservesProportionalityToSceneRadiance: Bool { blackPoint == 0 }

    /// One component, levelled.
    ///
    /// Subtracted and scaled in `Double` and narrowed exactly once: the
    /// subtraction of a large black point from a small `Float32` coordinate
    /// can lose every significant bit in `Float32` while being exact in
    /// `Double`, and narrowing twice would round twice.
    ///
    /// The result is **not** checked for finiteness here — the caller knows
    /// the pixel's coordinates and can say which one failed, which this
    /// cannot. It is also **not clipped**: `−0.2` and `1.4` are ordinary
    /// results and are returned as they are.
    @inline(__always)
    public func applied(to linear: Float) -> Float {
        Float((Double(linear) - blackPoint) * scale)
    }

    public var diagnosticDescription: String {
        "black \(blackPoint), white \(whitePoint) (×\(scale)), affine, not tone mapping"
    }
}
