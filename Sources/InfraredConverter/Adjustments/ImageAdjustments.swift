import Foundation

/// Everything the user has decided about one image, as data.
///
/// ```text
/// ImageDocument (does not exist yet)
///  ├── source        the RAW file — never modified
///  ├── metadata      immutable facts the decoder read
///  └── adjustments   ← this type: the editing decisions
/// ```
///
/// ## Why a record rather than a property
///
/// There are four adjustments today — the orientation correction, the creative
/// channel mix, the exposure compensation and the infrared white balance — and
/// this is why the model was a record from the first one. Every adjustment that
/// follows, tone settings and crop among them, belongs beside them rather than
/// as another unrelated field, and the set has to be serialisable **as a set**:
/// a recipe is "all of these together", not one of them at a time.
///
/// The white balance is the first adjustment that is not applied to the
/// retained reduced preview — it is upstream of demosaicing, so changing it
/// re-prepares that preview from the retained normalised mosaic. That changes
/// what the workspace *schedules*, and deliberately nothing about this model:
/// it is a field like the other three, one request is still one complete
/// state, and the export still takes the whole record and nothing else. See
/// `docs/decisions/0019-interactive-white-balance.md`.
///
/// It is also what makes one render request mean one complete state. The
/// workspace never asks for "the new orientation", "the new mix", "the new
/// exposure" or "the new patch"; it asks for the whole record, so a burst of
/// changes to any of them — a slider drag included — collapses to one newest
/// state and nothing in between is ever rendered or written. See
/// `docs/decisions/0016-interactive-channel-mixer.md`,
/// `docs/decisions/0017-interactive-exposure.md` and
/// `docs/decisions/0019-interactive-white-balance.md`.
///
/// This is the first step toward the versioned `InfraredRecipe` the project
/// will need. It is deliberately not that format: a recipe also references
/// camera, capture-configuration and filter profiles by stable identity, and
/// none of those exist yet. Defining the whole format now would mean
/// versioning guesses. See
/// `docs/decisions/0010-user-owned-orientation-adjustment.md`.
///
/// ## Where it lives, and how long
///
/// In memory, on `DocumentState`, for as long as a file is open — as **one
/// half** of `PhotographProcessingState`, whose other half is the capture
/// profile the photograph is processed under. That pair is what a JSON sidecar
/// beside the RAW file holds between sessions, through
/// `PhotographProcessingStore`.
///
/// ## It carries no persistence metadata, and that is new
///
/// This type used to own the sidecar's schema version and its migrations,
/// because adjustments were the only thing a sidecar held. They are not any
/// more. A schema version belongs to the record it describes, and a version
/// number on the adjustments would have claimed to describe a file it only
/// half covered — so `PersistedSchemaVersion`, `currentSchemaVersion` and the
/// version-aware `Codable` conformance moved to
/// `PhotographProcessingState`, and this went back to being editing data.
///
/// What that buys is concrete: a test that wants to check an exposure builds
/// `ImageAdjustments(exposure: …)` and nothing else — no record, no version, no
/// profile. See `docs/decisions/0020-ir-capture-profile-foundation.md`,
/// Decision 7.
///
/// It is still not a recipe. A sidecar is the state of one photograph; a recipe
/// is a reusable set of choices that references capture profiles by stable
/// identity and is shared between photographs. The first half of that now
/// exists — `IRCaptureProfile` — and the reusable-recipe format deliberately
/// does not.
public struct ImageAdjustments: Equatable, Sendable {

    /// The user's orientation correction, on top of whatever the file
    /// recorded. `.identity` means they asked for none.
    public var orientation: UserOrientationAdjustment

    /// The creative infrared channel mix the user chose. `.identity` means
    /// they asked for no remapping.
    ///
    /// A **creative** decision, and never a calibration: it says how RGB is
    /// remixed inside a working colour space that has already been
    /// established, and it is recorded as intent rather than as anything
    /// measured. See `docs/decisions/0007-infrared-channel-mixing.md`.
    ///
    /// It is deliberately not defaulted anywhere in the processing API. The
    /// default here is the **application layer's** choice for a file with no
    /// saved decision, stated in one place, and it is `.identity` because
    /// nothing in this project knows whether a given RAW file is an infrared
    /// capture.
    public var channelMix: UserChannelMixAdjustment

    /// The exposure compensation the user chose. `.neutral` is `0 EV`.
    ///
    /// Applied in the linear domain as `× 2^EV` by the display renderer, after
    /// the mix and the orientation and before the display range policy. It is
    /// not tone mapping, not highlight recovery and not automatic: nothing
    /// derives it from the image. See
    /// `docs/decisions/0017-interactive-exposure.md`.
    public var exposure: UserExposureAdjustment

    /// The infrared white balance the user chose, as **intent**:
    /// `.defaultNeutralPatch`, or a neutral rectangle they picked.
    ///
    /// Resolved into an active-area region and then into gains by the RAW
    /// front half, every time, for the preview and for the export alike. The
    /// gains are never stored here and never persisted. See
    /// `docs/decisions/0019-interactive-white-balance.md`.
    ///
    /// It is the one adjustment that is **upstream of demosaicing**: changing
    /// it cannot be applied to the retained reduced preview and re-prepares
    /// that preview from the retained normalised mosaic instead. That is a
    /// scheduling fact, not a modelling one — it is a field of this record like
    /// the other three, and one request still means one complete state.
    ///
    /// Its default is not the identity. `.defaultNeutralPatch` measures real
    /// samples and produces real multipliers; see `isDefault`.
    public var whiteBalance: UserWhiteBalanceAdjustment

    /// Builds a record of the user's decisions at this build's schema version.
    ///
    /// There is deliberately no version parameter. See `schemaVersion`.
    public init(
        orientation: UserOrientationAdjustment = .identity,
        channelMix: UserChannelMixAdjustment = .identity,
        exposure: UserExposureAdjustment = .neutral,
        whiteBalance: UserWhiteBalanceAdjustment = .defaultNeutralPatch
    ) {
        self.orientation = orientation
        self.channelMix = channelMix
        self.exposure = exposure
        self.whiteBalance = whiteBalance
    }

    /// A freshly opened file's adjustments: the user has decided nothing.
    ///
    /// Not "the image is upright" — the file's own orientation still applies —
    /// and not "this is a visible-light photograph": the channel mix is
    /// identity because nothing here can know that a file is an infrared
    /// capture, not because anything decided it is not one.
    public static let none = ImageAdjustments()

    /// Whether every adjustment in this record is the value a freshly opened
    /// file with no sidecar gets.
    ///
    /// ```text
    /// orientation    no correction on top of what the file records
    /// channelMix     no creative remapping
    /// exposure       exactly 0 EV
    /// whiteBalance   the application's default centred neutral patch
    /// ```
    ///
    /// ## It replaced `isIdentity`, and the difference matters
    ///
    /// This property used to be called `isIdentity` and meant **no net effect
    /// on the image**. That reading survived three adjustments and died on the
    /// fourth: the default white balance estimates real multipliers from real
    /// samples, so `ImageAdjustments.none` visibly changes the photograph, and
    /// a property claiming otherwise would have been false for every record in
    /// the application.
    ///
    /// The honest split is between two different questions, and only one of
    /// them can be answered from a record:
    ///
    /// ```text
    /// isDefault        "has the user departed from the defaults?"
    ///                  a fact about this record. Answerable here.
    ///
    /// has no effect    "would rendering with these adjustments change the
    ///                  pixels?" Not answerable here at all: the white balance
    ///                  is intent, and whether its gains come out as 1,1,1,1
    ///                  depends on the photograph. Pretending otherwise would
    ///                  be exactly the kind of plausible-looking claim this
    ///                  project refuses to make.
    /// ```
    ///
    /// So this is a question about **decisions**, not about pixels.
    ///
    /// Two things it does *not* mean, each of which `isIdentity` was read as:
    ///
    /// ```text
    /// "the user decided nothing"      the defaults are states a person can
    ///                                 deliberately reach and save — Reset
    ///                                 Orientation, Identity, Reset Exposure,
    ///                                 Reset White Balance
    /// "nothing is on disk"            a default record is written like any
    ///                                 other; see ADR 0013, Decision 6
    /// ```
    /// It compares each field against **its default value**, not against its
    /// net effect. An `.explicit` matrix that happens to be the identity
    /// leaves the channels alone and is still not `.identity`: it carries
    /// different provenance and persists differently, so a record holding one
    /// is not a record of the defaults. That is the same distinction
    /// `UserChannelMixAdjustment.isIdentity` deliberately does not make.
    ///
    /// Equivalent to `self == .none`, and written out so that adding a field
    /// without deciding what its default is fails to compile here.
    public var isDefault: Bool {
        orientation == .identity
            && channelMix == .identity
            && exposure == .neutral
            && whiteBalance == .defaultNeutralPatch
    }
}
