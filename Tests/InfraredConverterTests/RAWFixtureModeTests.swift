import Testing
import Foundation
@testable import InfraredConverter

/// The gate that decides whether the expensive real-RAW suites run, and the
/// tests that make a misconfigured request impossible to mistake for coverage.
///
/// This suite is deliberately **not** gated on anything. It is cheap and it
/// reads no RAW file, so it runs in the ordinary fast suite.
///
/// It is no longer the *only* thing that reports a misconfiguration, and it
/// could never have been enough on its own: `--filter` excludes it, so a
/// targeted Tier 2 run against a missing fixture passed while executing
/// nothing. The refusal now lives in `RAWFixtureMode.gate()`, behind the
/// `.requiresRAWFixture` trait every fixture suite carries. What is left here
/// is the pure policy — the parse, the two questions being separate, and the
/// shape of the refusals — plus the whole-run guards, which still catch a
/// misconfigured `swift test` that selects no fixture suite at all.
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

    // MARK: - The gate every suite carries

    /// What `--filter` broke, and where the repair had to live.
    ///
    /// The two tests above fail a whole `swift test` run, and they cannot
    /// fail the documented Tier 2 command, because `--filter` excludes this
    /// suite from it. So the refusal moved into `gate()` — the one function
    /// behind `.requiresRAWFixture`, which every real-RAW suite carries.
    ///
    /// This is the pure-policy half. The half that matters, that a throwing
    /// condition trait fails a *filtered* run rather than skipping it, is a
    /// property of the command line and is verified there.
    @Test("The gate skips when nobody asked")
    func theGateSkipsWhenNobodyAsked() throws {
        // Whatever this machine's environment says, the two off cases are the
        // quiet ones: an ordinary `swift test` must not fail for want of a
        // fixture nobody asked for.
        #expect(RAWFixtureMode.parse(nil) == .absent)
        #expect(RAWFixtureMode.parse("0") == .disabled)

        switch RAWFixtureMode.request {
        case .absent, .disabled:
            #expect(try RAWFixtureMode.gate() == false)
        case .enabled:
            #expect(try RAWFixtureMode.gate() == RAWFixtures.isAvailable)
        case .unrecognised:
            break
        }
    }

    /// An impossible request is an error out of the gate, not a `false`.
    ///
    /// `false` is what "nobody asked" means. Reusing it for "somebody asked
    /// and it cannot be done" is exactly how a targeted run came to report
    /// success having executed nothing.
    @Test("An impossible request throws out of the gate rather than returning false")
    func anImpossibleRequestThrows() {
        guard case let .unrecognised(value) = RAWFixtureMode.request else {
            if RAWFixtureMode.isRequested && !RAWFixtures.isAvailable {
                #expect(throws: RAWFixtureMode.Misconfiguration.requestedWithoutFixture) {
                    try RAWFixtureMode.gate()
                }
            }
            return
        }
        #expect(throws: RAWFixtureMode.Misconfiguration.unrecognisedValue(value)) {
            try RAWFixtureMode.gate()
        }
    }

    /// The diagnostics are what a developer actually reads when a filtered run
    /// fails, so they must name the variable, the other variable, and the
    /// value that was rejected.
    @Test("The refusals say which setting to change")
    func theRefusalsSayWhichSettingToChange() {
        let missing = String(describing: RAWFixtureMode.Misconfiguration.requestedWithoutFixture)
        #expect(missing.contains(RAWFixtureMode.variableName))
        #expect(missing.contains("INFRARED_TEST_ORF"))
        #expect(missing.contains("no usable RAW fixture was found"))

        let unrecognised = String(
            describing: RAWFixtureMode.Misconfiguration.unrecognisedValue("true")
        )
        #expect(unrecognised.contains(RAWFixtureMode.variableName))
        #expect(unrecognised.contains("\"true\""))
        #expect(unrecognised.contains("exactly 1"))
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
