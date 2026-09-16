import Foundation
import Testing

/// Whether the expensive real-RAW fixture suites should run at all.
///
/// ## Two separate questions
///
/// `RAWFixtures` answers **where** a real RAW file is. This type answers
/// **whether** the suites that consume one are wanted. They are deliberately
/// not the same question, and neither one implies the other.
///
/// Before this existed, the presence of `RAW/OLYMPUS.ORF` on a developer's
/// machine was taken as consent to run every fixture-backed suite. That made
/// one command mean two very different things:
///
/// ```text
/// swift test    on CI, with no fixture      seconds
/// swift test    on a machine with one       many minutes
/// ```
///
/// The cost was not the only problem. The real-RAW suites decode, normalise,
/// demosaic and reduce a twelve-megapixel frame repeatedly, and the CPU and
/// memory contention that produced made unrelated asynchronous `Workspace`
/// tests appear flaky — a failure in one subsystem caused by the scheduling
/// of another.
///
/// So the mere existence of a file is no longer consent. Running the
/// expensive suites is something a developer asks for:
///
/// ```bash
/// INFRARED_RUN_RAW_FIXTURES=1 swift test
/// ```
///
/// ## Why one authority rather than a check per suite
///
/// A policy spread across seventeen `ProcessInfo` lookups is seventeen
/// chances to spell the variable differently, to forget one suite, or to let
/// a new suite default to the old behaviour. The rule is stated once here and
/// every suite carries the one trait `.requiresRAWFixture`, which is the only
/// place the decision is made.
///
/// ## Why the gate throws rather than merely returning `false`
///
/// A misconfiguration used to be reported by one ungated test in
/// `RAWFixtureModeTests`, which is enough for a whole `swift test` run and
/// not enough for the documented Tier 2 command:
///
/// ```bash
/// INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3OrientationCorrectionTests
/// ```
///
/// `--filter` excludes the suite that would have complained. The targeted
/// suite, finding `isRequested` true and no fixture, disabled itself — and the
/// run reported success having executed no real-RAW test at all.
///
/// So the refusal lives in the gate every fixture suite already touches.
/// `gate()` returns `false` for the ordinary "nobody asked" case, so an
/// ordinary `swift test` still skips quietly, and *throws* when the
/// configuration is one nobody can act on: an explicit request with no
/// fixture, or a value this reader has no meaning for. A condition trait whose
/// condition throws is a recorded error rather than a skip, so whichever
/// fixture suite `--filter` selected fails the process and says why.
enum RAWFixtureMode {

    /// The environment variable that opts in.
    static let variableName = "INFRARED_RUN_RAW_FIXTURES"

    /// What the environment says, as a closed set rather than a `Bool`.
    ///
    /// `unrecognised` exists so that a value the reader did not understand is
    /// *reported* rather than quietly folded into "off". `=true` is a
    /// plausible thing for a person to type, and a developer who typed it and
    /// saw a fast green run would reasonably conclude the fixture suites had
    /// passed.
    enum Request: Equatable {
        /// Unset, or set to the empty string.
        case absent
        /// Explicitly on: `1`.
        case enabled
        /// Explicitly off: `0`.
        case disabled
        /// Set to something this reader has no meaning for.
        case unrecognised(String)
    }

    /// The parse, as a pure function of the variable's value, so that it can
    /// be tested without mutating the process environment.
    static func parse(_ value: String?) -> Request {
        guard let value else { return .absent }
        switch value.trimmingCharacters(in: .whitespaces) {
        case "": return .absent
        case "1": return .enabled
        case "0": return .disabled
        case let other: return .unrecognised(other)
        }
    }

    static var request: Request {
        parse(ProcessInfo.processInfo.environment[variableName])
    }

    /// Whether the developer asked for the expensive suites.
    ///
    /// This is about intent alone. It is `true` when the flag is set even if
    /// no fixture exists — which is precisely the misconfiguration
    /// `RAWFixtureModeTests` reports.
    static var isRequested: Bool { request == .enabled }

    /// Whether a fixture-backed suite should run: asked for, **and** with a
    /// file to run against.
    static var isEnabled: Bool { isRequested && RAWFixtures.isAvailable }

    /// Why a gated suite is skipped, naming which of the two conditions
    /// failed so that a skip reason is never ambiguous.
    static var disabledReason: String {
        if !isRequested {
            return """
                Expensive real-RAW fixture suite. Set \(variableName)=1 to run it.
                """
        }
        return """
            \(variableName)=1 was set, but no RAW fixture was found. \
            \(RAWFixtures.unavailableReason)
            """
    }

    /// A fixture request that cannot be honoured, and that nothing downstream
    /// can sensibly interpret as "off".
    enum Misconfiguration: Error, Equatable, CustomStringConvertible {
        /// `=1`, but there is no file to run against.
        case requestedWithoutFixture
        /// Set to a value this reader has no meaning for.
        case unrecognisedValue(String)

        var description: String {
            switch self {
            case .requestedWithoutFixture:
                return """
                    \(RAWFixtureMode.variableName)=1 asked for the expensive \
                    real-RAW fixture suites, but no usable RAW fixture was \
                    found, so this suite could only have skipped. A run that \
                    skipped it proves nothing about real-camera integration, \
                    so it is a failure rather than a skip.

                    \(RAWFixtures.unavailableReason)

                    The two settings are separate: \
                    \(RAWFixtureMode.variableName) decides whether the suites \
                    run, INFRARED_TEST_ORF decides where the file is.
                    """
            case let .unrecognisedValue(value):
                return """
                    \(RAWFixtureMode.variableName) is set to "\(value)", which \
                    this reader has no meaning for, so this suite could only \
                    have skipped. Set it to exactly 1 to run the real-RAW \
                    fixture suites, or to 0 — or unset it — to skip them.
                    """
            }
        }
    }

    /// The single decision every fixture-backed suite makes.
    ///
    /// - Returns: `true` when the suites were asked for and a fixture exists,
    ///   `false` when nobody asked.
    /// - Throws: `Misconfiguration` when somebody asked and the request cannot
    ///   be honoured. Returning `false` there would be the false green this
    ///   gate exists to prevent.
    static func gate() throws -> Bool {
        switch request {
        case .absent, .disabled:
            return false
        case let .unrecognised(value):
            throw Misconfiguration.unrecognisedValue(value)
        case .enabled:
            guard RAWFixtures.isAvailable else {
                throw Misconfiguration.requestedWithoutFixture
            }
            return true
        }
    }
}

extension Trait where Self == ConditionTrait {

    /// The gate carried by every expensive real-RAW fixture suite.
    ///
    /// One trait rather than seventeen copies of the same `.enabled(if:)`
    /// expression, so that what a misconfigured request does is decided in
    /// `RAWFixtureMode.gate()` and nowhere else. Skips quietly when nobody
    /// asked; fails the run — under `--filter` as much as under a whole
    /// `swift test` — when somebody asked for something impossible.
    static var requiresRAWFixture: Self {
        .enabled(if: try RAWFixtureMode.gate(), "\(RAWFixtureMode.disabledReason)")
    }
}
