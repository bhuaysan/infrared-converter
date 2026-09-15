import Foundation

/// A reusable creative starting point: one channel mix a person wants to use
/// again, under a name they will recognise.
///
/// ```text
/// "My 720 nm Blue Sky"
///     filter hint    720 nm nominal long-pass      context, not physics
///     channel mix    explicit 3×3                  the decision it applies
/// ```
///
/// ## What it is, in one sentence
///
/// A named `UserChannelMixAdjustment` a photograph can be given. Nothing more.
///
/// ## What it is not
///
/// ```text
/// a calibration               no measured evidence, no reference dataset, no residuals
/// a camera-to-working transform   that is IRCaptureProcessingBasis, and no preset carries one
/// a measured spectral profile no filter's transmission is modelled anywhere in this project
/// a capture profile           a profile describes how a photograph was MADE
/// a photograph sidecar        a preset belongs to no photograph
/// an automatic decision       applying one is always something a person did
/// ```
///
/// A preset is the **authoring and reuse** mechanism for a creative decision.
/// It is not a new mathematical origin of a matrix, which is why nothing here
/// touches `IRChannelMixSource`: a preset that resolves to `.redBlueSwap`
/// applies the red/blue swap and the photograph records the red/blue swap.
/// Where the person got the idea from is not a property of the pixels.
///
/// ## Why it does not become a capture profile
///
/// The two answer different questions, and the filter appears in both for
/// different reasons:
///
/// ```text
/// IRCaptureProfile    what camera, conversion and filter the photograph was captured with
/// IRCreativePreset    what look its author recommends this mix for
/// ```
///
/// One is a record of a physical configuration; the other is a creative
/// suggestion. Merging them would make a person's taste into a claim about
/// their equipment. See `docs/decisions/0024-reusable-creative-presets.md`.
///
/// ## The filter hint is a label, and nothing consults it
///
/// `filter` is `IRFilterDescriptor`, the project's one notion of "which
/// filter", and its rule is carried over unchanged: **a nominal wavelength
/// identifies a filter family; it is not a measured spectral response, and two
/// products sold as "720 nm" are not thereby interchangeable.**
///
/// So the hint takes part in no arithmetic, selects nothing, enables nothing
/// and disables nothing. A preset hinted `720 nm` is offered for every
/// photograph, including one shot at 590 nm, and a photograph whose capture
/// profile says `720 nm` has no preset applied to it on that account. Matching
/// presets to photographs by wavelength would be exactly the false filter
/// science this project refuses to invent.
///
/// ## Immutable
///
/// Every field is `let`. Editing a preset constructs a new value under the
/// same identity and replaces the stored definition whole, exactly as editing
/// a capture profile does.
public struct IRCreativePreset: Equatable, Sendable, Identifiable {

    /// The stable identity. Never derived from `name`.
    public let id: IRCreativePresetID

    /// What a person calls this preset. Free to change without affecting a
    /// single photograph — a photograph stores the resolved mix, never a
    /// reference to a preset.
    public let name: String

    /// The creative decision this preset applies.
    ///
    /// Deliberately the **existing** user adjustment type rather than a matrix
    /// of its own. A preset that carried nine raw coefficients would be a
    /// second persisted representation of a channel mix, and the two would
    /// eventually disagree about what `.redBlueSwap` means. Applying a preset
    /// is therefore a single assignment:
    ///
    /// ```text
    /// preset.channelMix → DocumentState.setChannelMix(_:)
    /// ```
    public let channelMix: UserChannelMixAdjustment

    /// The filter family the preset's author had in mind, if they recorded
    /// one.
    ///
    /// `.unknown` is an ordinary and complete state: a preset with no filter
    /// hint is a preset about a look rather than about equipment.
    public let filter: IRFilterDescriptor

    public init(
        id: IRCreativePresetID,
        name: String,
        channelMix: UserChannelMixAdjustment,
        filter: IRFilterDescriptor = .unknown
    ) {
        self.id = id
        self.name = name
        self.channelMix = channelMix
        self.filter = filter
    }

    // MARK: - What it says about itself

    /// Whether a filter family is recorded at all.
    public var hasFilterHint: Bool { filter.isKnown }

    /// The filter hint as a short label — `720 nm nominal long-pass`,
    /// `Hoya R72`, or `nil` when none is recorded.
    ///
    /// The wording is `IRFilterDescriptor`'s own, so that the nominal
    /// wavelength cannot be read here as a measurement of anything.
    public var filterLabel: String? {
        hasFilterHint ? filter.shortDescription : nil
    }

    /// Whether this preset is a validated infrared calibration.
    ///
    /// Always `false`, and a stored property would be a way for it not to be.
    /// It exists so that an interface asks rather than assumes, and so that
    /// the answer is written down in exactly one place: a creative mix is a
    /// look somebody liked, and no amount of naming a wavelength turns it into
    /// a measured transform.
    public var isValidatedInfraredCalibration: Bool { false }

    /// A longer label for the library list and for diagnostics.
    ///
    /// Worded so that a filter hint reads as context and never as a claim.
    public var diagnosticDescription: String {
        let mix = channelMix.diagnosticDescription
        guard hasFilterHint else {
            return "creative preset: \(mix); no filter recorded"
        }
        return """
            creative preset: \(mix); suggested for \(filter.diagnosticDescription) — \
            a context label, not a calibration for that filter
            """
    }
}
