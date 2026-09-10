import Foundation

/// Where a creative infrared channel mix came from, and therefore what it is
/// entitled to claim.
///
/// ## Creative intent, never calibration
///
/// Every case here describes an **aesthetic decision taken inside an already
/// defined working colour space**. None of them is, or can become, a camera
/// calibration, a colour conversion, a white balance, a working-space
/// establishment or a filter calibration — those are earlier stages with their
/// own provenance types. Keeping the two kinds of provenance apart is what
/// lets a rendering be audited later for what it actually claimed.
///
/// ## Exactly three origins
///
/// Camera-profile, filter-profile, preset and recipe cases are absent because
/// none of those subsystems exists. A provenance case naming a subsystem the
/// project has not built would be a claim about nothing. When a profile system
/// arrives it either produces an `.explicit` mix or gains a case of its own.
public enum IRChannelMixSource: Equatable, Sendable {
    /// No creative remapping was requested. The stage was still traversed
    /// deliberately; see `IRChannelMix.identity`.
    case identity
    /// The canonical first infrared creative operation: output red takes input
    /// blue and output blue takes input red. See `IRChannelMix.redBlueSwap`.
    case redBlueSwap
    /// A matrix supplied deliberately by application logic, a caller, or — in
    /// future — a profile system. The project makes no claim about it beyond
    /// that its coefficients are finite.
    ///
    /// A matrix that happens to equal a built-in's stays `.explicit`: how a
    /// mix was constructed is a different fact from what its numbers do, and
    /// the mixer's choice of execution path never rewrites it.
    case explicit

    /// A label for diagnostics and provenance reports, worded so a reader
    /// cannot mistake it for a colour claim.
    public var diagnosticDescription: String {
        switch self {
        case .identity:
            return "identity channel mix (creative no-op; the stage was traversed)"
        case .redBlueSwap:
            return "built-in red/blue channel swap (creative infrared rendering)"
        case .explicit:
            return "explicit caller-supplied channel mix (creative; no calibration claim)"
        }
    }
}

/// A complete instruction for creatively remixing RGB channels **inside** the
/// working colour space: which space the coefficients were authored for, which
/// matrix, obtained how.
///
/// ```text
/// WorkingColorRGBImage           extended linear sRGB coordinates
///         ↓
/// IRChannelMix                   ← this type: space + matrix + source
///         ↓
/// IRChannelMixer
///         ↓
/// IRChannelMixedRGBImage         the same extended linear sRGB coordinates
/// ```
///
/// ## Not the same question as the camera transform
///
/// ```text
/// RAWCameraToWorkingColorTransform
///     How do camera-native sensor responses enter our working colour space?
///
/// IRChannelMix
///     Once we are already in that space, how do we creatively remix RGB
///     for infrared rendering?
/// ```
///
/// Both can be written as a 3×3 matrix, and both use the same
/// `RAWColorMatrix3x3` primitive. They are still different operations, and are
/// deliberately different types: one is a placement into a coordinate system,
/// the other is an aesthetic decision taken within it. A future profile may
/// well carry both — it will carry them as two values with two provenances,
/// not as one composed matrix.
///
/// ## Why a mix carries a working colour space
///
/// Coefficients mean something only relative to the RGB axes they were
/// authored for. "Take output red from input blue" is a different rendering
/// when *blue* is a different primary. Exactly one working space exists today,
/// so every factory here produces `.extendedLinearSRGB` mixes — but the space
/// is recorded rather than assumed, and `IRChannelMixer` refuses a mismatch
/// instead of silently reinterpreting the coefficients.
///
/// ## Why the matrix is never handed round on its own
///
/// A bare matrix plus a separately supplied provenance label can be
/// mismatched: an arbitrary matrix described as the built-in red/blue swap, or
/// a swap described as an identity no-op. The pairing is therefore enforced by
/// the type, exactly as `RAWWhiteBalanceEstimate` and
/// `RAWCameraToWorkingColorTransform` enforce theirs:
///
/// - all three properties are `let`, so no half can be replaced afterwards;
/// - the memberwise initialiser is module-internal, so no caller outside the
///   module can mint a mix whose matrix and source never met;
/// - the only ways in are the three factories below, each of which sets the
///   source that genuinely describes what it did.
///
/// ## There is no default
///
/// This type has no `.default` and no zero-argument factory, and
/// `IRChannelMixer` has no defaulted mix parameter. Which rendering an
/// infrared capture deserves is a creative decision the project will not make
/// on a caller's behalf, so it is made at the call site, visibly:
/// `.identity`, `.redBlueSwap` or `.explicit(matrix:)`.
///
/// ## Linear, with no constant term
///
/// The operation is `output = M × input`, never `M × input + offset`. A
/// Photoshop-style channel-mixer constant shifts black, which is a different
/// operation on a scene-linear representation; if it is ever wanted it is a
/// separate decision, not a parameter quietly added here.
public struct IRChannelMix: Equatable, Sendable {
    /// The coordinate system `matrix` was authored for, and the only one it
    /// may be applied in.
    public let workingColorSpace: RAWWorkingColorSpace
    /// The 3×3 matrix, in the column-vector convention `RAWColorMatrix3x3`
    /// documents: rows are output channels, columns are input channels. Both
    /// sides are working-space RGB.
    public let matrix: RAWColorMatrix3x3
    /// How `matrix` was obtained, and therefore what it may be said to be.
    public let source: IRChannelMixSource

    /// Module-internal, deliberately: see the type's note above. Only the
    /// factories below pair a matrix with the source that describes it.
    init(
        workingColorSpace: RAWWorkingColorSpace,
        matrix: RAWColorMatrix3x3,
        source: IRChannelMixSource
    ) {
        self.workingColorSpace = workingColorSpace
        self.matrix = matrix
        self.source = source
    }

    // MARK: - Identity

    /// The creative no-op:
    ///
    /// ```text
    /// 1 0 0
    /// 0 1 0
    /// 0 0 1
    /// ```
    ///
    /// It means **no creative channel remapping was requested, and the
    /// channel-mix stage was explicitly traversed anyway**. That is a
    /// statement worth being able to make: a rendering that went through the
    /// creative stage and asked for nothing is a different fact from one that
    /// never reached it, and the provenance chain records which.
    ///
    /// It is not a camera transform and not a colour conversion; nothing about
    /// the coordinates changes. `IRChannelMixer` gives it a path that performs
    /// no arithmetic at all, so every `Float` bit pattern survives.
    public static let identity = IRChannelMix(
        workingColorSpace: .extendedLinearSRGB,
        matrix: .identity,
        source: .identity
    )

    // MARK: - Red/blue swap

    /// The canonical first infrared creative operation: exchange the red and
    /// blue channels.
    ///
    /// ```text
    /// 0 0 1        outputR = inputB
    /// 0 1 0        outputG = inputG
    /// 1 0 0        outputB = inputR
    /// ```
    ///
    /// ## What it is
    ///
    /// A **creative rendering choice**, and the one infrared photographers
    /// reach for first: on a typical infrared capture it is what turns the
    /// characteristic red-dominant frame into the familiar blue-sky rendering.
    ///
    /// ## What it is not
    ///
    /// Not a camera calibration, not a white balance, not a working-space
    /// transform, and not a physical model of any filter. It rearranges
    /// coordinates inside a space that has already been established; no
    /// primaries change, no chromatic adaptation happens, and nothing is
    /// measured.
    ///
    /// ## Bit-exact
    ///
    /// Because it is a permutation rather than arithmetic, `IRChannelMixer`
    /// copies the channels directly, preserving every `Float` bit pattern
    /// including `-0.0`.
    public static let redBlueSwap = IRChannelMix(
        workingColorSpace: .extendedLinearSRGB,
        matrix: redBlueSwapMatrix,
        source: .redBlueSwap
    )

    /// The exact permutation matrix behind `redBlueSwap`.
    ///
    /// `try!` is sound here and nowhere else in the project: the nine
    /// coefficients are literal zeros and ones written on the page, so the
    /// only failure `RAWColorMatrix3x3` can report — a non-finite coefficient
    /// — cannot arise.
    private static let redBlueSwapMatrix = try! RAWColorMatrix3x3(
        m00: 0, m01: 0, m02: 1,
        m10: 0, m11: 1, m12: 0,
        m20: 1, m21: 0, m22: 0
    )

    // MARK: - Explicit

    /// A channel mix supplied deliberately by the caller.
    ///
    /// This is the route for application logic, experiments, and — later — a
    /// profile or recipe system that has decided which rendering an infrared
    /// capture configuration deserves. Provenance records `.explicit`, and it
    /// stays `.explicit` even when the matrix happens to equal a built-in's:
    /// the execution path the mixer picks is decided by the matrix's value,
    /// the provenance by how the mix was constructed, and the two are not
    /// allowed to contaminate each other.
    ///
    /// The working space is not a parameter because exactly one exists. When a
    /// second is implemented, this gains one.
    ///
    /// ### What is not done to the matrix
    ///
    /// Nothing. Rows are not normalised, coefficients are not turned into
    /// percentages, row sums need not be `1`, coefficients need not lie in
    /// `0...1`, and the matrix need not be invertible. Negative coefficients,
    /// coefficients above `1`, channel swaps and singular monochrome-collapse
    /// matrices are all legitimate infrared creative operations. The only
    /// contract is the one `RAWColorMatrix3x3` already enforced at
    /// construction: every coefficient is finite. This factory therefore
    /// cannot fail.
    public static func explicit(matrix: RAWColorMatrix3x3) -> IRChannelMix {
        IRChannelMix(
            workingColorSpace: .extendedLinearSRGB,
            matrix: matrix,
            source: .explicit
        )
    }
}
