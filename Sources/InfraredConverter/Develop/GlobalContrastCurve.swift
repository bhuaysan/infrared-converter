import Foundation

/// A global contrast amount as arithmetic on one RGB component, and the one
/// place in the project that arithmetic is written.
///
/// ```text
/// k = 2^amount
///
/// f(x) = x                                   x ≤ 0  or  x ≥ 1
/// f(x) = x^k / (x^k + (1 − x)^k)             0 < x < 1
/// ```
///
/// Evaluated in `Double` and narrowed to `Float` exactly once. Applied
/// independently and identically to every RGB component: there are no
/// per-channel curves, and the three output components of one pixel are
/// produced by the same single number.
///
/// ## Why this curve rather than a gain about the midpoint
///
/// Because of what it guarantees, not because of how it looks. Four properties
/// hold for **every** amount in the supported range, and each of them is a
/// failure mode of the obvious alternatives:
///
/// ```text
/// identity at 0          k = 1 makes f the identity on the whole extended
///                        domain — not merely "close to" it
///
/// three fixed points     f(0) = 0, f(0.5) = 0.5, f(1) = 1, exactly. Black
///                        stays black, white stays white, and mid-grey does
///                        not drift as the slider moves
///
/// strictly monotone      inside 0…1 the curve never flattens and never turns
///                        over, so no tone inverts and no two distinct values
///                        become one
///
/// symmetric              f(1 − x) = 1 − f(x): what the curve takes from the
///                        shadows it gives to the highlights, so +c and −c are
///                        mirror images rather than two unrelated shapes
/// ```
///
/// A linear slope about `0.5` — `0.5 + s(x − 0.5)` — fails three of the four:
/// it pushes values out of `0…1` at every positive setting, so it needs a
/// clamp, and the clamp destroys exactly the highlight and shadow detail the
/// pipeline has been carrying unclipped since the mosaic. This curve needs no
/// clamp, because `x^k / (x^k + (1−x)^k)` is *in* `0…1` whenever `x` is.
///
/// The form is standard: it is the logistic map applied to the log-odds of
/// `x`, with `k` scaling the odds. Nothing about it is tuned, fitted or
/// measured, and no constant in it was chosen to taste — `k = 2^amount` is the
/// whole parameterisation.
///
/// ## Why this is its own type
///
/// For the reason `SceneLinearExposure` and `LinearLevels` are: two consumers
/// apply it — the interactive preview at reduced resolution and the
/// full-resolution export — and two copies of a numeric rule drift invisibly.
/// An export that evaluated `pow` in `Float32`, or that computed `2^amount`
/// per component rather than once, would look entirely plausible and would not
/// match the preview.
///
/// ```text
/// UserContrastAdjustment      the person's intent, validated and persisted
/// GlobalContrastCurve         the mathematics, shared by every consumer
/// GlobalContrastApplier       the stage that runs it over an image
/// ```
///
/// ## What it is not
///
/// It is a **global RGB tone curve**, applied per component. That is worth
/// saying plainly because a per-component curve is routinely mistaken for
/// things it is not:
///
/// ```text
/// not luminance contrast     no luminance is computed, and none could be —
///                            infrared false-colour channels do not carry the
///                            visible-light meanings a luminance weighting is
///                            defined against
/// not Lab or HSL lightness   no conversion out of the working RGB space happens
/// not perceptual             nothing here models vision
/// not local contrast         every pixel is evaluated from its own value and
///                            from nothing else; no neighbourhood is read
/// not a calibration          it is creative intent, like the channel mix
/// ```
///
/// And it **changes channel ratios**. A nonlinear function applied
/// independently to R, G and B does not preserve the ratios between them, so
/// colour appearance changes — saturation typically rises with positive
/// contrast. That is a property of the operation, stated rather than
/// compensated for: a hidden saturation correction would be a second
/// operation, unasked for and unnamed. See
/// `docs/decisions/0027-global-contrast-tone-curve.md`.
///
/// ## Nothing here clips
///
/// Values outside the unit interval are returned **unchanged**, not
/// extrapolated and not clamped. That is a deliberate contract and not an
/// omission; see `applied(to:)`.
public struct GlobalContrastCurve: Equatable, Sendable {

    /// The normalised contrast amount the curve was built from.
    public let amount: Double

    /// `2^amount`, computed once per value rather than once per component.
    ///
    /// Stored rather than derived at each call for the reason `LinearLevels`
    /// stores its reciprocal: one rounding of the exponent, shared by every
    /// pixel, is deterministic and is what makes preview and export agree bit
    /// for bit at the same input.
    public let exponent: Double

    public init(amount: Double) {
        self.amount = amount
        self.exponent = Foundation.exp2(amount)
    }

    /// The adjustment a user asked for, as arithmetic.
    public init(_ adjustment: UserContrastAdjustment) {
        self.init(amount: adjustment.amount)
    }

    /// The neutral curve: amount `0`, exponent exactly `1`.
    ///
    /// `exp2(0)` is exactly `1`, and `isIdentity` is what the evaluation
    /// actually branches on — so the neutral curve returns every `Float`
    /// unchanged, bit for bit, signed zeros and subnormals included.
    public static let neutral = GlobalContrastCurve(amount: 0)

    /// Whether this curve can be evaluated at all.
    ///
    /// Two conditions, and each rules out a distinct way the arithmetic stops
    /// meaning anything:
    ///
    /// ```text
    /// amount finite      NaN or an infinity describes no curve
    /// exponent finite    and strictly positive: a non-positive or infinite k
    ///                    makes x^k diverge at an endpoint, and the fixed
    ///                    points stop holding
    /// ```
    ///
    /// Deliberately **not** a restatement of `UserContrastAdjustment`'s
    /// `−1 … +1`. That range is the control's definition; this is the
    /// arithmetic's own floor, and a curve built directly from a raw amount —
    /// as a test or a future recipe may do — is checked against it rather than
    /// against a slider's opinion.
    public var isApplicable: Bool {
        amount.isFinite && exponent.isFinite && exponent > 0
    }

    /// Whether this curve leaves every value exactly as it was: amount `0`.
    public var isIdentity: Bool { amount == 0 }

    /// One component, contrasted.
    ///
    /// ## The extended domain passes through untouched
    ///
    /// ```text
    /// x ≤ 0     returned unchanged, bit for bit, −0.0 included
    /// x ≥ 1     returned unchanged, bit for bit
    /// ```
    ///
    /// This is the contract, not a shortcut. By this point in the pipeline a
    /// component may legitimately be `−0.25` or `1.7`: the white balance, a
    /// creative mix with negative coefficients, exposure and a black point
    /// above zero all produce working coordinates outside the unit interval,
    /// and every stage so far has carried them with their magnitude intact.
    ///
    /// Three things this stage therefore refuses to be:
    ///
    /// ```text
    /// not an extrapolation   the S-curve is not continued past the endpoints.
    ///                        x^k for negative x is not a real number, and any
    ///                        rule that made one up — abs, sign-preserving
    ///                        power, reflection — would be an invention this
    ///                        project has no basis for
    /// not a clamp            −0.25 stays −0.25. Clipping belongs to the
    ///                        destination, downstream, where it is counted
    /// not a range policy     which is the same point said from the other side:
    ///                        the contrast stage must not quietly become the
    ///                        thing that decides what a display can show
    /// ```
    ///
    /// A value the destination will later clip is still distinct here, which
    /// is what lets a subsequent exposure or levels change bring it back.
    ///
    /// ## Inside the interval
    ///
    /// ```text
    /// a = x^k
    /// b = (1 − x)^k
    /// y = a / (a + b)
    /// ```
    ///
    /// evaluated in `Double` and narrowed once. `y` is in `0…1` for every
    /// `x` in `0…1` and every positive finite `k`, so the curve cannot itself
    /// push a value out of range.
    ///
    /// The result is **not** checked for finiteness here — the caller knows
    /// the pixel's coordinates and can say which one failed, which this
    /// cannot.
    @inline(__always)
    public func applied(to linear: Float) -> Float {
        // The identity is branched on rather than computed. `pow(x, 1)` is
        // exact, but `a + b` is `x + (1 − x)`, which is not exactly `1` for
        // every double, so the computed path could return a value one ulp from
        // its input at a setting that means "do nothing".
        if isIdentity { return linear }
        guard linear > 0, linear < 1 else { return linear }

        let x = Double(linear)
        let a = Foundation.pow(x, exponent)
        let b = Foundation.pow(1 - x, exponent)
        return Float(a / (a + b))
    }

    public var diagnosticDescription: String {
        "contrast \(amount) (k = \(exponent)), global RGB tone curve, per component"
    }
}
