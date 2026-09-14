import Foundation

/// Where measured calibration artefacts are kept between sessions.
///
/// ```text
/// IRCaptureProfileStore    reusable capture-profile definitions
/// IRCalibrationStore       measured calibration artefacts (evidence + fit)
/// ```
///
/// The same shape as `IRCaptureProfileStore`, for the same reason: a
/// calibration has its own lifetime, its own schema and its own identity
/// namespace, and none of that belongs folded into the profile library or a
/// photograph's sidecar. Nothing in this project attaches a calibration to a
/// capture profile yet — no calibration this project can produce is
/// validated — so this store exists ahead of that attachment, not because of
/// it: measuring has to be possible, and reproducible, before applying is.
///
/// ## Three operations, deliberately
///
/// Load everything, save one, delete one — the same minimalism
/// `IRCaptureProfileStore` states and for the same reason: there are as many
/// calibrations as a photographer has camera/filter combinations they have
/// bothered to measure, and every question worth asking is answered by
/// loading them all.
///
/// ## Loading does not fail as a whole
///
/// `loadAll()` returns both halves — what loaded and what refused — rather
/// than throwing. One corrupt file must not make every valid calibration
/// disappear, and it must not be silently skipped either. See
/// `IRCalibrationLibraryLoad`.
public protocol IRCalibrationStore: Sendable {

    /// Every stored calibration, and every stored thing that would not load.
    func loadAll() -> IRCalibrationLibraryLoad

    /// Writes one calibration, replacing whatever record was stored under its
    /// identity.
    ///
    /// The replacement must be atomic **at the calibration's own path**: a
    /// reader must never observe a half-written record there, and a write
    /// that fails partway must leave the previous record in place. That is a
    /// statement about the replacement, not about durability — no store is
    /// asked to promise what survives a power loss.
    ///
    /// A calibration's own evidence is immutable
    /// (`IRCalibrationMeasurementSet` is never revised), but re-fitting the
    /// same evidence produces a **new** `IRCalibration` with a new identity —
    /// see `IRCalibrationID`. Saving the same identity twice therefore only
    /// happens for genuine metadata edits, such as a renamed `name`; there is
    /// no route by which saving mutates a fit's numbers.
    ///
    /// - Throws: `IRCalibrationPersistenceError.cannotWrite` or
    ///   `.cannotCreateDirectory` for a file that could not be put where it
    ///   belongs.
    func save(_ calibration: IRCalibration) throws(IRCalibrationPersistenceError)

    /// Removes the stored record with this identity.
    ///
    /// Deleting an identity that is not stored is **not** an error: the
    /// requested end state — no calibration with that identity — already
    /// holds.
    ///
    /// - Throws: `IRCalibrationPersistenceError.cannotDelete`.
    func delete(_ id: IRCalibrationID) throws(IRCalibrationPersistenceError)
}

/// What one pass over the calibration storage found: the calibrations, and
/// the refusals.
///
/// ```text
/// calibrations   records that loaded, and may be inspected
/// failures       per-file typed refusals, each naming what it is about
/// ```
///
/// Both halves, always. The two alternatives are each worse in their own way:
/// throwing on the first bad file would make one corrupt calibration hide an
/// entire library, and ignoring bad files would let a calibration somebody
/// spent an afternoon measuring vanish without a word.
public struct IRCalibrationLibraryLoad: Sendable {

    /// The records that loaded, in the order the store produced them.
    public let calibrations: [IRCalibration]

    /// Everything that did not, each as its own typed refusal.
    public let failures: [IRCalibrationPersistenceError]

    public init(
        calibrations: [IRCalibration] = [],
        failures: [IRCalibrationPersistenceError] = []
    ) {
        self.calibrations = calibrations
        self.failures = failures
    }

    /// Whether anything refused. The interface reports this without having to
    /// decide what a failure means.
    public var hasFailures: Bool { !failures.isEmpty }

    /// One line for a banner: "1 calibration could not be loaded."
    ///
    /// Deliberately a count and not a decoder's description. The detail is
    /// available per failure, and belongs behind a disclosure rather than in
    /// the first sentence a person reads.
    public var failureSummary: String? {
        guard hasFailures else { return nil }
        return failures.count == 1
            ? "1 calibration could not be loaded."
            : "\(failures.count) calibrations could not be loaded."
    }
}
