# Testing

This project has two very different kinds of test, and the difference is cost.

Most of the suite is synthetic: hand-built mosaics, named coefficients, small
images whose every value is written out in the test. It proves arithmetic, and
it runs in seconds.

A much smaller part decodes a real twelve-megapixel Olympus E-PL3 ORF and
carries it through the whole pipeline. It proves *integration* — that LibRaw
reads a fifteen-year-old file, that its CFA layout is usable, that a real frame
reaches a displayable image and an exported TIFF — and it costs minutes.

Both are worth having. They are not worth running at the same frequency.

---

## The two environment variables

They answer two separate questions, and neither implies the other.

```text
INFRARED_TEST_ORF            where the fixture is
INFRARED_RUN_RAW_FIXTURES    whether the expensive suites run
```

### Why they are separate

They used not to be. A fixture-backed suite enabled itself whenever a file
could be found, so `RAW/OLYMPUS.ORF` sitting on a developer's disk was taken as
standing consent to decode it on every `swift test`. One command meant two
different things:

```text
swift test    on CI, with no fixture      seconds
swift test    on a developer's machine    many minutes
```

The runtime was the smaller problem. The real-RAW suites saturate CPU and
memory, and that contention starved unrelated asynchronous `Workspace` tests
until they appeared flaky — a failure in one subsystem manufactured by the
scheduling of another. Timeouts were raised to absorb it, which treated the
symptom.

Having a file is no longer consent. Running the expensive suites is something
you ask for, and asking is one flag.

### The rule, exactly

| `INFRARED_RUN_RAW_FIXTURES` | fixture present | fixture suites |
| --- | --- | --- |
| unset or empty | either | **skipped** |
| `0` | either | **skipped** |
| `1` | yes | **run** |
| `1` | no | **skipped, and the run fails** |
| anything else | either | **skipped, and the run fails** |

The last two rows are the point of the table. A developer who typed
`INFRARED_RUN_RAW_FIXTURES=1` has stated an intent, and a fast green run is not
an honest answer to "run the real-RAW suites" when there was nothing to run
them against. The run therefore fails, naming both variables, rather than
letting seventeen silent skips add up to a passing extended run.

The same holds for a value nobody defined. `INFRARED_RUN_RAW_FIXTURES=true` is
a plausible thing to type; folding it into "off" would produce exactly the
false confidence the flag exists to prevent, so it is reported instead.

**Those two rows hold under `--filter` as well**, which is the whole reason the
refusal lives where it does. See the next section.

### Where the rule lives

One type, `Tests/InfraredConverterTests/Support/RAWFixtureMode.swift`. Every
gated suite carries one trait, and that trait is the only caller of the
decision:

```swift
@Suite("…", .requiresRAWFixture)
```

A policy spread across seventeen `ProcessInfo` lookups is seventeen chances to
spell the variable differently, to miss a suite, or to let a new suite default
to the old behaviour.

#### Why the gate throws

`.requiresRAWFixture` is `.enabled(if: try RAWFixtureMode.gate(), …)`, and
`gate()` has three outcomes rather than two:

```text
nobody asked                    false     → the suite skips, quietly
asked, and a fixture exists     true      → the suite runs
asked, and it cannot be done    throws    → the run fails
```

The third outcome is the fix for a real false green. The refusal used to live
only in `RAWFixtureModeTests`, an ungated suite that fails a whole `swift test`
run. That cannot reach the documented Tier 2 command:

```bash
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3OrientationCorrectionTests
```

`--filter` excludes the suite that would have complained. The targeted suite —
asked for, with no fixture — disabled itself, and the run reported success
having executed no real-RAW test at all. Every honest signal was outside the
filter.

A condition trait whose condition *throws* is a recorded error, not a skip, so
whichever fixture suite the filter selected now fails the process itself and
prints which of the two settings to change. Nothing has to remember to append
`RAWFixtureModeTests` to a filter, and no suite restates the policy: the
returned `false` still produces the ordinary quiet skip, so plain `swift test`
is unaffected, and a filter that selects no fixture suite at all — `swift test
--filter ChannelMix` — never evaluates the gate.

`RAWFixtures` still answers the other question — it resolves
`INFRARED_TEST_ORF`, then `RAW/OLYMPUS.ORF`, then any other `.orf` in `RAW/` —
and it is the only thing that does.

---

## Three tiers

### Tier 1 — the fast suite

```bash
swift test
```

Synthetic and unit tests, workspace tests, channel-mix, persistence, profile,
preset, calibration and UI-domain tests. No real RAW file is opened, whether or
not one is on disk.

**This is the standard verification command.** Run it after ordinary feature
work.

### Tier 2 — targeted real-RAW smoke

Run when the change touched a RAW-sensitive subsystem — and run only the suite
that covers it, not all of them.

```bash
# decode, metadata, CFA layout
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter LibRawDecoderFixtureTests
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter LibRawDecoderMosaicFixtureTests

# black level, white level, normalisation
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter RAWMosaicNormalizerFixtureTests

# white balance: gains, estimation, the picked patch end to end
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter RAWWhiteBalancerFixtureTests
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter RAWWhiteBalanceEstimatorFixtureTests
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3WhiteBalanceTests

# demosaicing and the camera-to-working transform
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter RAWDemosaicerFixtureTests
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter RAWWorkingColorConverterFixtureTests

# creative mix, orientation, display encoding
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter IRChannelMixerFixtureTests
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter ImageOrienterFixtureTests
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter DisplayPreviewRendererFixtureTests

# preview preparation, reduction, orientation through the workspace
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3PreviewResolutionTests
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3OrientationCorrectionTests

# full-resolution export
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3FullResolutionExportTests

# capture profiles against a real camera identity
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3CaptureProfileTests
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3UserCaptureProfileTests
```

`swift test --filter` is the mechanism. There is no custom runner and there
should not be one.

### Tier 3 — the extended suite

```bash
INFRARED_RUN_RAW_FIXTURES=1 swift test
```

Everything. Run it before a release, after substantial RAW pipeline work, or
when deliberately validating all real-camera coverage. It is allowed to take
much longer than Tier 1; what matters is that it is **intentional**.

---

## Which tier for which change

```text
1. swift build
2. focused tests for the components you changed
3. swift test
4. if RAW-sensitive code changed — decoding, normalisation, white balance,
   demosaicing, working colour, mixing, orientation, display, export —
   the relevant Tier 2 suite(s)
5. Tier 3 only for major pipeline work or release validation
```

A milestone that added a preset library has no business spending fifteen
minutes decoding an ORF.

---

## What real RAW is for

Real RAW earns its cost on claims a synthetic fixture cannot make:

- LibRaw can decode this particular old Olympus E-PL3 ORF at all
- the camera's real metadata and CFA layout are usable as the pipeline assumes
- the file's actual black and white levels normalise to finite, valid data
- white-balance estimation works on a real sensor's four colour planes
- one real frame reaches a displayable image through the whole chain
- one real frame exports as a correct full-resolution 16-bit TIFF
- **the RAW input file is never modified**

It is not for arithmetic. Exhaustive permutations and combinatorics stay
synthetic, where they are faster, deterministic, and easier to localise:

- all eight orientation permutations
- matrix replacement and composition properties
- arbitrary coefficient combinations
- resolution-policy mathematics
- adjustment state-machine combinations

The division is not about coverage percentage. A synthetic test that fails
tells you which stage is wrong; a real-RAW test that fails tells you the
integration is wrong. Both answers are useful and they are different answers.

---

## Repeated preparation

A fixture suite prepares the frame once and shares it:

```swift
private static let sharedFixture: Result<T, any Error> = Result { … }

private static func fixture() throws -> T { try sharedFixture.get() }
```

The intermediate pipeline types are `Sendable` structs over immutable buffers,
so one shared instance is exactly the value a per-test preparation produced.
A `static let` is initialised once under `swift_once` even with Swift Testing
running tests concurrently, and `Result` is what lets a throwing preparation
live in one — the error is stored and rethrown to every caller rather than
retried per test.

This is deliberately a per-suite value, not a shared fixture cache. Suites that
assert filesystem facts — that no sidecar was written, that the RAW file's
digest is unchanged — keep their own isolated copy per test, because their
claim *is* about the directory.

---

## Continuous integration

`.github/workflows/ci.yml` runs `swift build` and `swift test`, with no
fixture and no flag. That is Tier 1, and it is deliberate: CI must stay fast
and deterministic, and must not depend on private local data. The ORF is not
committed and should not be.
