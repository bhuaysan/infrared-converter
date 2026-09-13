import Foundation

/// The infrared white balance the **user** asked for, as intent rather than as
/// numbers.
///
/// ```text
/// RAWWhiteBalanceGains            four literal multipliers, measured from
///         ▲                       these pixels, by this estimator
///         │  estimated, never stored
///         │
/// RAWActiveAreaRegion             the sensor rectangle that was measured
///         ▲
///         │  resolved, never stored
///         │
/// UserWhiteBalanceAdjustment      ← this type: "balance from *there*",
///                                 persisted, and meaningful without the file
/// ```
///
/// ## Why the intent is persisted and the gains are not
///
/// Because a gain is an answer and the patch is the question. `[3.81, 1.0,
/// 2.07, 1.0]` cannot be reviewed, reproduced or reconsidered; "the grey card
/// just left of centre" can. Persisting the four multipliers would also freeze
/// today's estimator into every sidecar ever written: a better scale policy, a
/// wider or narrower patch convention, or a fix to the measurement would leave
/// every saved photograph rendering by the old arithmetic with nothing saying
/// so.
///
/// So the sidecar records **where the user pointed**, and the gains are
/// derived from the RAW file every time — by the preview and by the export,
/// through the same resolver and the same
/// `RAWWhiteBalanceEstimator`. See
/// `docs/decisions/0019-interactive-white-balance.md`.
///
/// Explicit multipliers are a legitimate future case and this enum can gain
/// one. It deliberately has not: there is no manual-gain editor, no
/// temperature and no tint in this version, and adding a case the UI cannot
/// produce would put a wire format into the world ahead of the decision it
/// describes.
///
/// ## It is a state, not a history
///
/// Like every other adjustment. Picking a patch replaces whatever was picked
/// before; nothing composes, and there is no "balance again".
///
/// ## The default is a real operation, not the absence of one
///
/// `.defaultNeutralPatch` is **not** "no white balance" and its gains are not
/// the identity. It is the application's deterministic placeholder — estimate
/// from an even-sided square in the middle of the frame — and it is exactly
/// what every build of this project did before the white balance became a user
/// decision. That is why it is its own case rather than a centred
/// `.neutralPatch`: the rule is expressed in sensor pixels
/// (`defaultRegion(width:height:)`) and only a case that resolves through that
/// rule can promise a version 1, 2 or 3 sidecar the rendering it was saved
/// with.
public enum UserWhiteBalanceAdjustment: Equatable, Sendable {

    /// Estimate from the application's deterministic centred patch — the
    /// behaviour every build had before white balance became adjustable.
    ///
    /// Not an automatic white balance, and deliberately not called one.
    /// Nothing examines the photograph to decide where its neutral part is;
    /// the middle of the frame is a placeholder a person can replace.
    case defaultNeutralPatch

    /// Estimate from a rectangle the user selected, in normalised active-area
    /// coordinates.
    case neutralPatch(NormalizedActiveAreaRegion)

    /// Which of the two shapes this is — and the token it persists as.
    ///
    /// One value serves both, as `UserChannelMixAdjustment.Kind` does, because
    /// two lists of the same names eventually disagree.
    public enum Kind: String, CaseIterable, Sendable {
        case defaultNeutralPatch
        case neutralPatch
    }

    public var kind: Kind {
        switch self {
        case .defaultNeutralPatch: return .defaultNeutralPatch
        case .neutralPatch: return .neutralPatch
        }
    }

    /// The white balance a file with no saved decision gets.
    ///
    /// Named so that the application layer can state the choice rather than
    /// spell the case out, and so that "what does a fresh file do" has one
    /// answer in one place.
    public static let initial = UserWhiteBalanceAdjustment.defaultNeutralPatch

    /// Whether this is the application's own default rather than a decision a
    /// person made.
    ///
    /// Note what it is not: a claim that the white balance has no effect. The
    /// default estimates real gains from real samples and changes the image.
    /// See `ImageAdjustments.isDefault`.
    public var isDefault: Bool { self == .defaultNeutralPatch }

    /// The region a person chose, or `nil` for the default.
    public var selectedRegion: NormalizedActiveAreaRegion? {
        switch self {
        case .defaultNeutralPatch: return nil
        case .neutralPatch(let region): return region
        }
    }

    // MARK: - The default patch rule

    /// The fraction of the shorter active-area dimension the default patch
    /// spans. A sixteenth is large enough to average thousands of samples of
    /// every CFA plane and small enough to stay well inside the frame.
    ///
    /// This constant used to live on `RAWWorkingImagePipeline`, where it was a
    /// hidden default inside the shared RAW front half. It belongs here, with
    /// the case whose meaning it is.
    public static let defaultPatchDivisor = 16

    /// The smallest extent, in samples, a resolved patch may have on either
    /// axis.
    ///
    /// Two, and even, because a region of even width and height contains whole
    /// 2×2 CFA cells whatever its origin's parity, so every colour plane of a
    /// Bayer layout is measured. It is a Bayer-shaped minimum and is honest
    /// about being one: a layout with a larger repeating cell — X-Trans, at
    /// 6×6 — is not guaranteed complete coverage by this rule, and is
    /// protected instead by `RAWWhiteBalanceEstimator`'s own refusal to invent
    /// a gain for a plane it did not measure.
    public static let minimumPatchExtent = 2

    /// The side, in samples, of the default centred square for an active area
    /// of the given size.
    ///
    /// `max(2, (shorter / 16) rounded down to even)`.
    public static func defaultPatchSide(width: Int, height: Int) -> Int {
        let shorter = min(width, height)
        return max(minimumPatchExtent, (shorter / defaultPatchDivisor) & ~1)
    }

    /// A centred, even-sided square in active-image coordinates.
    ///
    /// The rule this project has always used, moved here unchanged, and the
    /// single authority for what `.defaultNeutralPatch` means. A version 1, 2
    /// or 3 sidecar migrates to `.defaultNeutralPatch` precisely so that it
    /// resolves through this function and reproduces the photograph it was
    /// saved with.
    public static func defaultRegion(width: Int, height: Int) -> RAWActiveAreaRegion {
        let side = defaultPatchSide(width: width, height: height)
        return RAWActiveAreaRegion(
            originRow: max(0, (height - side) / 2),
            originColumn: max(0, (width - side) / 2),
            width: min(side, width),
            height: min(side, height)
        )
    }

    /// The normalised region a click at `(x, y)` selects, sized like the
    /// default patch.
    ///
    /// The picker's size rule, stated once. A picked patch is the **same
    /// square, in sensor samples**, that the default patch is — so picking the
    /// exact centre of a frame measures the same samples the default does, and
    /// a click near an edge measures just as much of the photograph as one in
    /// the middle (the region is shifted, never trimmed).
    ///
    /// Sizing in sensor samples and then normalising is what keeps the patch
    /// square: the two normalised extents differ, because the active area is
    /// not.
    ///
    /// - Parameters:
    ///   - x: horizontal position in the active area, `0...1`, in **sensor**
    ///     axes — the picker has already undone the displayed orientation.
    ///   - y: vertical position, likewise.
    /// - Throws: `ImageAdjustmentError` when the point is not finite, or
    ///   `RAWProcessingError.invalidActiveAreaRegion` when the active area is
    ///   not a usable size.
    public static func pickedRegion(
        atX x: Double, y: Double, activeAreaWidth: Int, activeAreaHeight: Int
    ) throws -> NormalizedActiveAreaRegion {
        guard activeAreaWidth > 0, activeAreaHeight > 0 else {
            throw RAWProcessingError.invalidActiveAreaRegion(
                reason: """
                    Active area \(activeAreaWidth)x\(activeAreaHeight) cannot contain a \
                    neutral patch.
                    """
            )
        }
        let side = defaultPatchSide(width: activeAreaWidth, height: activeAreaHeight)
        return try NormalizedActiveAreaRegion.centered(
            atX: x,
            y: y,
            width: min(1, Double(side) / Double(activeAreaWidth)),
            height: min(1, Double(side) / Double(activeAreaHeight))
        )
    }

    // MARK: - Resolving intent into samples

    /// The active-image rectangle this decision names, for an active area of
    /// the given size.
    ///
    /// **The one canonical conversion.** The interactive preview and the
    /// full-resolution export both call it, with the same adjustment and the
    /// same sensor dimensions, so the two cannot resolve a saved patch
    /// differently. No processing stage has a default patch of its own; the
    /// estimator is handed an explicit region and nothing else.
    ///
    /// ## The arithmetic, stated so it can be reproduced
    ///
    /// ```text
    /// left   = floor(originX × width)
    /// top    = floor(originY × height)
    /// extent = round(fraction × dimension), then rounded DOWN to even,
    ///          and at least minimumPatchExtent
    /// origin = shifted back inside the area if the even extent pushed it out
    /// ```
    ///
    /// Sizes round to nearest and then down to even; origins floor. The even
    /// extent is the CFA-alignment rule `minimumPatchExtent` documents, and it
    /// is applied here — in the conversion — rather than in the persisted
    /// value, because it is a fact about a sensor layout and the persisted
    /// value is a fact about a photograph. A record written on one camera is
    /// therefore still meaningful on another.
    ///
    /// The final shift is the only adjustment made to a valid region, it moves
    /// the origin by at most one sample, and it exists so that a patch
    /// touching the right or bottom edge keeps its size instead of being
    /// trimmed to an odd one.
    ///
    /// ## The default case keeps the historical clamp, and does not refuse
    ///
    /// `.defaultNeutralPatch` goes through `defaultRegion(width:height:)`,
    /// which clamps its side to the image rather than refusing — so an active
    /// area one sample across yields a one-sample region rather than an error.
    /// That is the rule this project has always had, and preserving it exactly
    /// is the whole reason the default is its own case; the estimator's own
    /// refusal to invent a gain for an unmeasured plane is what catches such a
    /// frame. A **picked** region is refused here instead, because there is no
    /// historical behaviour to preserve for one.
    ///
    /// - Throws: `RAWProcessingError.invalidActiveAreaRegion` when the active
    ///   area is not a usable size, or when the region resolves to something
    ///   larger than the area — which a normalised region can do only when the
    ///   area is smaller than `minimumPatchExtent` on an axis.
    public func resolvedRegion(
        activeAreaWidth: Int, activeAreaHeight: Int
    ) throws -> RAWActiveAreaRegion {
        guard activeAreaWidth > 0, activeAreaHeight > 0 else {
            throw RAWProcessingError.invalidActiveAreaRegion(
                reason: """
                    Active area \(activeAreaWidth)x\(activeAreaHeight) cannot contain a \
                    neutral patch.
                    """
            )
        }

        switch self {
        case .defaultNeutralPatch:
            return Self.defaultRegion(width: activeAreaWidth, height: activeAreaHeight)

        case .neutralPatch(let region):
            let width = try Self.evenExtent(
                region.width, of: activeAreaWidth, axis: "width"
            )
            let height = try Self.evenExtent(
                region.height, of: activeAreaHeight, axis: "height"
            )
            return RAWActiveAreaRegion(
                originRow: Self.origin(region.originY, of: activeAreaHeight, extent: height),
                originColumn: Self.origin(region.originX, of: activeAreaWidth, extent: width),
                width: width,
                height: height
            )
        }
    }

    /// A fraction of a dimension, as an even sample count of at least
    /// `minimumPatchExtent`.
    private static func evenExtent(
        _ fraction: Double, of dimension: Int, axis: String
    ) throws -> Int {
        let exact = (fraction * Double(dimension)).rounded()
        let bounded = Int(min(Double(dimension), max(0, exact)))
        let extent = max(minimumPatchExtent, bounded & ~1)
        guard extent <= dimension else {
            throw RAWProcessingError.invalidActiveAreaRegion(
                reason: """
                    A neutral patch needs at least \(minimumPatchExtent) samples of \
                    \(axis) to contain whole CFA cells, and the active area has \
                    \(dimension).
                    """
            )
        }
        return extent
    }

    /// A fraction of a dimension as a sample origin, shifted back so that
    /// `origin + extent` stays inside the dimension.
    private static func origin(
        _ fraction: Double, of dimension: Int, extent: Int
    ) -> Int {
        let exact = (fraction * Double(dimension)).rounded(.down)
        let bounded = Int(min(Double(dimension), max(0, exact)))
        return min(max(0, bounded), dimension - extent)
    }

    /// The same rectangle as `resolvedRegion(activeAreaWidth:activeAreaHeight:)`,
    /// expressed back in normalised coordinates.
    ///
    /// What an overlay draws. It deliberately goes **through** the resolver
    /// rather than returning the persisted region directly, so that what is
    /// drawn is the region that will actually be measured — origins floored,
    /// extents rounded down to even — rather than the request that produced
    /// it. The two differ by less than a sample, and showing the request would
    /// make the resolver's rounding invisible exactly where a reader is
    /// looking for it.
    ///
    /// It is also the only description of the default patch a view can draw:
    /// `.defaultNeutralPatch` has no persisted rectangle, and this is where its
    /// rule produces one.
    ///
    /// - Throws: `RAWProcessingError.invalidActiveAreaRegion`, or
    ///   `ImageAdjustmentError` if the resolved rectangle is not inside the
    ///   active area — which it always is, so the refusal is structural rather
    ///   than expected.
    public func normalizedRegion(
        activeAreaWidth: Int, activeAreaHeight: Int
    ) throws -> NormalizedActiveAreaRegion {
        let region = try resolvedRegion(
            activeAreaWidth: activeAreaWidth, activeAreaHeight: activeAreaHeight
        )
        return try NormalizedActiveAreaRegion(
            originX: Double(region.originColumn) / Double(activeAreaWidth),
            originY: Double(region.originRow) / Double(activeAreaHeight),
            width: Double(region.width) / Double(activeAreaWidth),
            height: Double(region.height) / Double(activeAreaHeight)
        )
    }

    // MARK: - Description

    /// A short label for a control.
    public var shortDescription: String {
        switch self {
        case .defaultNeutralPatch: return "Default Patch"
        case .neutralPatch: return "Picked Patch"
        }
    }

    /// A longer label for diagnostics, provenance and the inspector.
    public var diagnosticDescription: String {
        switch self {
        case .defaultNeutralPatch:
            return "default centred neutral patch (not an automatic white balance)"
        case .neutralPatch(let region):
            return "neutral patch you picked at \(region.diagnosticDescription)"
        }
    }
}

// MARK: - Persistence

/// ## The wire format
///
/// ```json
/// { "kind" : "defaultNeutralPatch" }
/// { "kind" : "neutralPatch",
///   "region" : { "originX" : 0.4, "originY" : 0.4, "width" : 0.05, "height" : 0.07 } }
/// ```
///
/// A keyed object rather than a bare string, for the reason
/// `UserChannelMixAdjustment` uses one: one of the cases carries data, and a
/// format that changes shape between cases is worse than one that always has a
/// `kind`. The tokens are `Kind.rawValue`, so there is one list of them.
///
/// The shape is exact per kind:
///
/// ```text
/// defaultNeutralPatch   token only        a "region" key is refused
/// neutralPatch          token + region
/// ```
///
/// A default carrying a region is refused rather than read with the rectangle
/// ignored — the same rule, for the same reason, that refuses a `redBlueSwap`
/// carrying a matrix. The record would say two different things about which
/// samples were measured, and neither reading of it is anything but a guess.
///
/// **The gains are deliberately not written.** Not as the truth, and not
/// beside the region as a cache: a second copy of a derived number is a second
/// thing that can be stale, and a reader that trusted it would render by an
/// estimator that no longer exists.
extension UserWhiteBalanceAdjustment: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case region
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let token = try container.decodeIfPresent(String.self, forKey: .kind) else {
            throw ImageAdjustmentError.missingWhiteBalanceField(field: "kind")
        }
        guard let kind = Kind(rawValue: token) else {
            // Never the default: a token we cannot read and a deliberate
            // decision to use the application's placeholder are different
            // facts, and rendering the second in place of the first would
            // silently discard the patch the user chose.
            throw ImageAdjustmentError.unknownWhiteBalanceKind(token: token)
        }

        switch kind {
        case .defaultNeutralPatch:
            guard !container.contains(.region) else {
                throw ImageAdjustmentError.unexpectedWhiteBalanceField(
                    field: CodingKeys.region.stringValue, kind: token
                )
            }
            self = .defaultNeutralPatch

        case .neutralPatch:
            guard let region = try container.decodeIfPresent(
                NormalizedActiveAreaRegion.self, forKey: .region
            ) else {
                throw ImageAdjustmentError.missingWhiteBalanceField(field: "region")
            }
            self = .neutralPatch(region)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        // Written only for the case that has one.
        if let region = selectedRegion {
            try container.encode(region, forKey: .region)
        }
    }
}
