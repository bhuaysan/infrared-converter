import Foundation

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
/// every suite gates on `isEnabled`.
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
}
