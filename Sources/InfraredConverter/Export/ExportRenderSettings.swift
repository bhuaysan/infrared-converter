import Foundation

/// What an export encoder does with scene-linear coordinates that lie outside
/// the range its file format can represent.
///
/// ## Exactly one case
///
/// The same rule as the display path's, for the same reason: a case here is a
/// claim that the pipeline can produce that behaviour, and a case that exists
/// but is unimplemented is worse than one that does not exist at all. Tone
/// mapping, highlight recovery and automatic rescaling arrive when they are
/// implemented, each with its own decision record.
///
/// See `docs/decisions/0018-full-resolution-tiff-export.md`, Decision 5.
public enum ExportRangePolicy: Equatable, Sendable {
    /// Each component is clipped to the unit range, independently of the
    /// other two:
    ///
    /// ```text
    /// x < 0   → 0
    /// x > 1   → 1
    /// else    → x unchanged
    /// ```
    ///
    /// ## Why a 16-bit file still needs this
    ///
    /// Bit depth and range are different things. A 16-bit **unsigned integer**
    /// TIFF is a normalised format: its samples run `0…65535` and mean `0…1`.
    /// More bits buy finer steps inside that range, not a larger one. So the
    /// scene-linear values this pipeline produces — which are deliberately
    /// unbounded, and routinely negative after black subtraction or a creative
    /// mix with negative coefficients — still have to be brought into a finite
    /// encodable range, and the choice of how is a decision rather than a
    /// technicality.
    ///
    /// ## This is not tone mapping
    ///
    /// Nothing is compressed, rolled off, shouldered, toed or adapted, and no
    /// highlight is recovered. Detail above `1` is **destroyed** and detail
    /// below `0` is **destroyed**. The encoder counts both, so an export whose
    /// whites are white because the range ran out is distinguishable from one
    /// whose scene was bright.
    ///
    /// ## It is also this path's gamut handling
    ///
    /// Clipping extended linear sRGB to the unit cube is a primitive gamut
    /// operation as well as a range one. Clipping each component independently
    /// moves an out-of-gamut coordinate to a *different colour*, not to the
    /// nearest in-gamut one.
    case hardClipToExportRange

    public var diagnosticDescription: String {
        switch self {
        case .hardClipToExportRange:
            return "hard export-range clipping to 0...1 (per component; not tone mapping)"
        }
    }
}

/// How an export encoder turns clipped, display-linear values into samples.
///
/// One case, for the same reason `ExportRangePolicy` has one.
public enum ExportEncoding: Equatable, Sendable {
    /// The piecewise sRGB transfer function, over sRGB primaries and D65 —
    /// which is also what the working space uses, so the primaries and white
    /// point are carried across unchanged and only the transfer function
    /// changes.
    ///
    /// Shared with the display path through `SRGBTransferFunction`. Applied
    /// exactly **once**, here; the file is then tagged sRGB so that no reader
    /// applies it again.
    case sRGB

    public var diagnosticDescription: String {
        switch self {
        case .sRGB:
            return "standard sRGB (sRGB primaries, D65, piecewise sRGB transfer function)"
        }
    }
}

/// Everything an export encoder needs, and nothing it does not.
///
/// ## Why there is no exposure here
///
/// The display path's settings carry `exposureEV` because its renderer applies
/// exposure in the same pass that it clips and encodes. The export path
/// applies exposure **upstream**, as `SceneLinearExposer`, so that the
/// adjusted scene-linear image exists as an inspectable value before anything
/// is clipped or quantised.
///
/// The absence is therefore structural rather than tidy: an
/// `ExposedSceneLinearRGBImage` has already been exposed, and settings
/// carrying an exposure would offer a second, silent application of it. The
/// encoder cannot double-expose because it is not given an exposure.
public struct ExportRenderSettings: Equatable, Sendable {
    /// What to do with values outside `0...1`.
    public let rangePolicy: ExportRangePolicy
    /// How to encode the values that remain.
    public let encoding: ExportEncoding

    public init(rangePolicy: ExportRangePolicy, encoding: ExportEncoding) {
        self.rangePolicy = rangePolicy
        self.encoding = encoding
    }

    /// The settings every export in this version uses.
    ///
    /// An application choice, spelled out in one place rather than defaulted
    /// inside the encoder: the encoder has no default settings, deliberately,
    /// for the same reason no processing stage in this project has one.
    public static let standard = ExportRenderSettings(
        rangePolicy: .hardClipToExportRange, encoding: .sRGB
    )

    public var diagnosticDescription: String {
        "\(rangePolicy.diagnosticDescription), \(encoding.diagnosticDescription)"
    }
}
