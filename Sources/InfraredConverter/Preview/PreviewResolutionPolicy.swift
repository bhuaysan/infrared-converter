import Foundation

/// How large the interactive preview is allowed to be.
///
/// The workspace does not re-render a photograph at sensor resolution in order
/// to show it in a window. It re-renders a **reduced** scene-linear rendition
/// of it, and this type is the one place that decides how reduced.
///
/// ## One rule, stated once
///
/// ```text
/// longest edge <= maximumLongestEdge
/// aspect ratio preserved
/// never enlarged
/// never zero
/// ```
///
/// Everything else follows from those four lines. There is no separate
/// landscape rule and no separate portrait rule: the constraint is on the
/// longest edge, whichever edge that is.
///
/// ## Where the decision is made, and in which coordinates
///
/// On the **unoriented** image, in sensor/active-area coordinates, before
/// `ImageOrienter` runs. That is not an accident of ordering and it is not
/// something orientation can invalidate: the eight orientations are exact
/// permutations of whole pixels, so they may exchange width and height but can
/// never change which number is the larger of the two. A limit imposed on the
/// longest edge before orientation is therefore still exactly satisfied after
/// it.
///
/// ```text
/// source 4056 x 3040   →  reduced 2048 x 1535  →  quarter turn  →  1535 x 2048
/// ```
///
/// So a rotation costs one permutation of the reduced buffer. It does not
/// re-decide the size, does not resample, and does not reach back to any
/// full-resolution buffer.
///
/// ## Not a SwiftUI concept
///
/// Nothing here reads a window size, a screen, a scale factor or a view. It is
/// a plain value with plain arithmetic, testable without a running
/// application, and injectable so a test can ask for a limit smaller than any
/// production default.
public struct PreviewResolutionPolicy: Equatable, Sendable {

    /// The largest the longer of the two preview edges may be, in pixels.
    public let maximumLongestEdge: Int

    public init(maximumLongestEdge: Int) {
        self.maximumLongestEdge = maximumLongestEdge
    }

    /// The limit the workspace uses: **2048 pixels on the longest edge.**
    ///
    /// Chosen, not inherited from anywhere, and the reasoning is short enough
    /// to state in full.
    ///
    /// - **The window it has to fill.** `ContentView` has a 720 x 520 point
    ///   floor and an inspector that takes 280–420 points of that, so the
    ///   smallest image area is a few hundred points across. A comfortably
    ///   large workspace on a laptop display is on the order of 1000–1400
    ///   points wide. At a 2x backing scale that is 2000–2800 device pixels,
    ///   so 2048 is a 1:1 match for the common case and a mild upscale for a
    ///   window maximised on a large display.
    /// - **What it retains.** On the E-PL3's 4056 x 3040 active area a 2048
    ///   limit gives 2048 x 1535: 3.14 megapixels instead of 12.33, which is
    ///   36 MB of Float32 instead of 141 MB — and roughly 11x less than the
    ///   whole chain the workspace used to hold open.
    /// - **What an interaction costs.** Every orientation change permutes and
    ///   display-encodes exactly that buffer, so the per-press work falls by
    ///   the same 3.9x factor.
    /// - **Retina later.** A larger limit — 2560 would cover a maximised
    ///   window on a 16-inch display exactly — buys sharpness in one window
    ///   size at the cost of 56 MB retained and 2.5x rather than 3.9x less
    ///   work per press. The preview is a *preview*: a future zoom or
    ///   1:1-inspection path is the right answer to "I need more pixels here",
    ///   not a permanently larger interactive buffer.
    ///
    /// It is a power of two, which costs nothing and is a convenient size for
    /// a future GPU path that has texture limits to respect.
    public static let workspace = PreviewResolutionPolicy(maximumLongestEdge: 2048)

    /// The preview dimensions for a source of the given size, or `nil` when
    /// the question does not have an answer.
    ///
    /// `nil` means the input is unusable rather than that no reduction is
    /// needed: a non-positive dimension, or a non-positive limit. An image
    /// already within the limit comes back **unchanged**, which is a real
    /// answer and not a refusal.
    ///
    /// ## The arithmetic, and why it is written this way
    ///
    /// The longer edge is set to the limit exactly, and the shorter edge is
    /// the source's shorter edge scaled by the same factor and rounded to
    /// nearest. Deriving the shorter edge from the longer one — rather than
    /// scaling both and hoping — is what makes `longest edge == limit` an
    /// exact equality rather than an approximate one, for every input.
    ///
    /// The shorter edge is floored at `1`. A 5000 x 1 strip reduces to
    /// 2048 x 1, not to 2048 x 0: a zero-sized image is not a smaller image,
    /// it is no image.
    ///
    /// A square source gets both edges set to the limit, because either edge
    /// is the longest one and both branches agree.
    public func reducedSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, maximumLongestEdge > 0 else { return nil }

        let longest = max(width, height)
        // Never enlarge. A photograph smaller than the limit is already its
        // own best preview, and inventing pixels for it would be worse than
        // useless.
        guard longest > maximumLongestEdge else { return (width: width, height: height) }

        let scale = Double(maximumLongestEdge) / Double(longest)

        if width >= height {
            let reducedHeight = max(1, Int((Double(height) * scale).rounded()))
            return (width: maximumLongestEdge, height: min(height, reducedHeight))
        } else {
            let reducedWidth = max(1, Int((Double(width) * scale).rounded()))
            return (width: min(width, reducedWidth), height: maximumLongestEdge)
        }
    }
}

/// How a reduced preview's pixels were produced from the full-resolution ones.
///
/// Two cases, and the second is not a degenerate first: an image already
/// within the policy's limit is **copied**, not filtered, and saying
/// "area-averaged" about it would be false.
public enum PreviewReductionMethod: String, Equatable, Sendable, CaseIterable {
    /// Each destination pixel is the area-weighted mean of the source pixels
    /// its footprint covers, computed per channel in `Double` over
    /// scene-linear values. See `SceneLinearPreviewReducer`.
    case areaAverage
    /// No resampling happened. The source was already within the limit, so the
    /// preview *is* the full-resolution image and every sample survives
    /// bit-for-bit.
    case unreduced

    public var diagnosticDescription: String {
        switch self {
        case .areaAverage: return "area-weighted average of scene-linear samples"
        case .unreduced: return "no resampling; already within the preview limit"
        }
    }
}

/// What resolution a preview is, what resolution it was made from, and by what
/// rule.
///
/// This is the answer to "what am I holding?" for an interactive preview
/// buffer, and it exists so that the answer never has to be guessed from
/// `width < sensorWidth`. It travels with the reduced image, reaches the
/// workspace's `WorkspacePreview`, and is what the inspector reads.
///
/// It deliberately records the **policy** as well as the outcome. Two previews
/// of the same photograph at 2048 and at 512 pixels are not distinguishable by
/// their dimensions alone once you no longer remember which limit was in
/// force; with the policy attached, they are.
public struct PreviewResolution: Equatable, Sendable {
    /// Width of the full-resolution, unoriented image this was reduced from,
    /// in pixels — the active image area, in sensor coordinates.
    public let sourceWidth: Int
    /// Height of that same full-resolution image.
    public let sourceHeight: Int
    /// Width of the reduced, unoriented preview, in pixels.
    public let width: Int
    /// Height of the reduced, unoriented preview, in pixels.
    public let height: Int
    /// The rule that produced those dimensions.
    public let policy: PreviewResolutionPolicy
    /// How the pixels themselves were produced.
    public let method: PreviewReductionMethod

    public init(
        sourceWidth: Int,
        sourceHeight: Int,
        width: Int,
        height: Int,
        policy: PreviewResolutionPolicy,
        method: PreviewReductionMethod
    ) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.width = width
        self.height = height
        self.policy = policy
        self.method = method
    }

    /// Whether any pixels were actually dropped. `false` for a photograph that
    /// was already within the limit.
    public var isReduced: Bool { width != sourceWidth || height != sourceHeight }

    /// Preview width as a fraction of source width. `1` when unreduced.
    public var horizontalScale: Double {
        sourceWidth > 0 ? Double(width) / Double(sourceWidth) : 0
    }
    /// Preview height as a fraction of source height. `1` when unreduced.
    public var verticalScale: Double {
        sourceHeight > 0 ? Double(height) / Double(sourceHeight) : 0
    }

    /// Pixels in the full-resolution image, or `nil` on overflow.
    public var sourcePixelCount: Int? {
        let (count, overflow) = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
        return overflow ? nil : count
    }
    /// Pixels in the reduced preview, or `nil` on overflow.
    public var pixelCount: Int? {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : count
    }

    /// How many times fewer pixels the preview has, or `nil` when that cannot
    /// be computed. `1` when unreduced.
    public var pixelReductionFactor: Double? {
        guard let source = sourcePixelCount, let preview = pixelCount, preview > 0 else {
            return nil
        }
        return Double(source) / Double(preview)
    }

    public var diagnosticDescription: String {
        isReduced
            ? "\(width)x\(height), reduced from \(sourceWidth)x\(sourceHeight)"
            : "\(width)x\(height), not reduced"
    }
}
