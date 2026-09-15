import Testing
import Foundation
@testable import InfraredConverter

/// The gate that decides whether the expensive real-RAW suites run, and the
/// one test that makes a misconfigured request impossible to mistake for
/// coverage.
///
/// This suite is deliberately **not** gated on anything. It is cheap, it
/// reads no RAW file, and it must run in the ordinary fast suite — the
/// misconfiguration it reports is one that only shows up there.
@Suite("Real-RAW fixture mode")
struct RAWFixtureModeTests {

    // MARK: - The parse

    @Test(
        "The variable's value is read as a closed set of intents",
        arguments: [
            (nil, RAWFixtureMode.Request.absent),
            ("", .absent),
            ("   ", .absent),
            ("1", .enabled),
            (" 1 ", .enabled),
            ("0", .disabled),
            ("true", .unrecognised("true")),
            ("yes", .unrecognised("yes")),
            ("2", .unrecognised("2")),
            ("Y", .unrecognised("Y")),
        ] as [(String?, RAWFixtureMode.Request)]
    )
    func theValueIsReadAsAClosedSet(value: String?, expected: RAWFixtureMode.Request) {
        #expect(RAWFixtureMode.parse(value) == expected)
    }

    /// The point of `unrecognised`: a value nobody defined is not silently
    /// "off". `INFRARED_RUN_RAW_FIXTURES=true` is a plausible thing to type,
    /// and a developer who typed it would otherwise see a fast green run and
    /// conclude the real-RAW suites had passed.
    @Test("An unrecognised value is not folded into off")
    func anUnrecognisedValueIsNotOff() {
        #expect(RAWFixtureMode.parse("true") != .disabled)
        #expect(RAWFixtureMode.parse("true") != .absent)
        #expect(RAWFixtureMode.parse("true") != .enabled)
    }

    // MARK: - Location and execution are separate questions

    /// `RAWFixtures` says where a file is; `RAWFixtureMode` says whether the
    /// suites that use one are wanted. Neither implies the other, and this is
    /// the property the whole milestone rests on: a developer with
    /// `RAW/OLYMPUS.ORF` on disk still gets the fast suite.
    @Test("Having a fixture is not consent to run the expensive suites")
    func havingAFixtureIsNotConsent() {
        if RAWFixtures.isAvailable && !RAWFixtureMode.isRequested {
            #expect(!RAWFixtureMode.isEnabled)
        }
        // And the converse: asking without a file does not enable them either.
        if RAWFixtureMode.isRequested && !RAWFixtures.isAvailable {
            #expect(!RAWFixtureMode.isEnabled)
        }
        #expect(RAWFixtureMode.isEnabled == (RAWFixtureMode.isRequested && RAWFixtures.isAvailable))
    }

    // MARK: - The misconfiguration

    /// Asking for the extended suite without a fixture is a configuration
    /// error, and it is reported as a **failure** rather than a skip.
    ///
    /// ## Why not a skip
    ///
    /// A skip is what an absent optional fixture deserves, and that is what
    /// the gated suites do when nobody asked for them. But a developer who
    /// typed `INFRARED_RUN_RAW_FIXTURES=1` has stated an intent, and the
    /// honest answer to "run the real-RAW suites" when there is nothing to run
    /// is not a green tick. Every gated suite would skip, the run would pass,
    /// and the report would say the extended validation succeeded.
    ///
    /// So this one test fails, loudly, naming both environment variables.
    @Test("Requesting the fixture suites without a fixture is a failure, not a skip")
    func requestingWithoutAFixtureFails() {
        guard RAWFixtureMode.isRequested else { return }

        #expect(
            RAWFixtures.isAvailable,
            """
            \(RAWFixtureMode.variableName)=1 asked for the expensive real-RAW \
            fixture suites, but no usable RAW fixture was found, so every one \
            of them skipped. This run proves nothing about real-camera \
            integration.

            \(RAWFixtures.unavailableReason)

            The two settings are separate: \
            \(RAWFixtureMode.variableName) decides whether the suites run, \
            INFRARED_TEST_ORF decides where the file is.
            """
        )
    }

    /// The other half of the same guard. `isRequested` is false for an
    /// unrecognised value, so every gated suite skips — which would look
    /// exactly like "nobody asked". The person who set the variable did ask,
    /// and misspelled it, so the run says so.
    @Test("A value nobody defined is reported rather than silently ignored")
    func anUnrecognisedValueIsReported() {
        guard case let .unrecognised(value) = RAWFixtureMode.request else { return }

        let name = RAWFixtureMode.variableName
        Issue.record(
            """
            \(name) is set to "\(value)", which this reader has no meaning
            for, so every real-RAW fixture suite skipped. If you meant to run
            them, set it to exactly 1. If you meant to skip them, unset it or
            set it to 0.
            """
        )
    }

    // MARK: - The skip reason says which condition failed

    @Test("The skip reason distinguishes not-asked-for from no-fixture")
    func theSkipReasonNamesTheCondition() {
        let reason = RAWFixtureMode.disabledReason
        if RAWFixtureMode.isRequested {
            #expect(reason.contains("no RAW fixture was found"))
        } else {
            #expect(reason.contains("Set \(RAWFixtureMode.variableName)=1"))
        }
    }
}
