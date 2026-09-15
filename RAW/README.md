# Local RAW test fixtures

RAW files are large and generally not redistributable, so none is committed.

## Two separate settings

```text
INFRARED_TEST_ORF            where the fixture is
INFRARED_RUN_RAW_FIXTURES    whether the expensive suites run
```

Neither implies the other. **Having a fixture on disk is not consent to decode
it on every `swift test`** — that used to be the rule, and it made one command
mean "seconds" on CI and "many minutes" locally.

## Providing a fixture

Drop an Olympus `.ORF` here:

```text
RAW/OLYMPUS.ORF
```

The reference camera is the **Olympus PEN E-PL3**.

Alternatively, point the tests at a file anywhere on disk:

```bash
INFRARED_TEST_ORF=/path/to/your.ORF
```

Resolution order is: `INFRARED_TEST_ORF`, then `RAW/OLYMPUS.ORF`, then any
other `.orf` file in this directory.

Everything in this directory except this README is git-ignored.

## Running the tests

```bash
# Tier 1 — the normal fast suite. No real RAW file is opened, whether or not
# one is sitting in this directory.
swift test

# Tier 2 — one real-RAW suite, when you touched a RAW-sensitive subsystem.
INFRARED_RUN_RAW_FIXTURES=1 swift test --filter EPL3WhiteBalanceTests

# Tier 3 — every real-RAW suite. Minutes, and deliberately so.
INFRARED_RUN_RAW_FIXTURES=1 swift test
```

Setting `INFRARED_RUN_RAW_FIXTURES=1` with no fixture to be found is a
**failure**, not a skip: seventeen silent skips must never add up to a passing
extended run. The same goes for a value the reader has no meaning for —
`=true` is reported rather than quietly treated as off.

See [docs/testing.md](../docs/testing.md) for the whole policy, the per-subsystem
Tier 2 commands, and what real RAW is and is not for.
