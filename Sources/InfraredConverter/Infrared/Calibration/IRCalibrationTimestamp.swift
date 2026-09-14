import Foundation

/// When a calibration artefact's timestamps are recorded, and why they carry no
/// more precision than that.
///
/// ## The problem this solves
///
/// A calibration is persisted with its timestamps as ISO-8601 strings with
/// fractional seconds, because a person reading the file should be able to see
/// when the chart was photographed without converting an epoch offset in their
/// head. That format carries **milliseconds**.
///
/// `Date()` carries considerably more. So an artefact built from the real clock
/// and then written and read back would not equal itself:
///
/// ```text
/// in memory   1789379303.087666
/// written     2026-09-14T09:48:23.088Z
/// read back   1789379303.088
/// ```
///
/// A persisted record whose publicly constructible values do not round-trip is
/// a defect in this project, and this is exactly that defect: an artefact whose
/// whole purpose is to be checked by recomputation would fail an equality check
/// against its own file, for a reason that has nothing to do with anything
/// measured.
///
/// ## The fix, and why it is at this end
///
/// The timestamp is truncated **where the value is constructed**, not where it
/// is written. Rounding at the wire boundary would leave the in-memory value
/// carrying precision the format silently discards, which is the same defect
/// one layer further down. Truncating on the way in means the value a
/// calibration holds is always one its file can express exactly, and equality
/// means what it appears to mean.
///
/// Milliseconds are far finer than anything a calibration measures. The
/// timestamp records which session a measurement belongs to and in what order
/// two fits were made; nothing depends on it to sub-second accuracy, and
/// nothing should.
enum IRCalibrationTimestamp {

    /// The precision the wire format carries.
    static let ticksPerSecond = 1000.0

    /// `date`, truncated to the precision a calibration file can express.
    ///
    /// Rounds to nearest rather than truncating towards zero, so that the
    /// result is the same value `ISO8601DateFormatter` would produce and read
    /// back — its own conversion rounds.
    static func recorded(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return date }
        return Date(timeIntervalSince1970: (seconds * ticksPerSecond).rounded() / ticksPerSecond)
    }
}
