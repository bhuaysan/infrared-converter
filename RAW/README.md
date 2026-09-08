# Local RAW test fixtures

RAW files are large and generally not redistributable, so none is committed.
Tests that need one skip cleanly when it is absent.

## Providing a fixture

Drop an Olympus `.ORF` here:

```text
RAW/OLYMPUS.ORF
```

The reference camera is the **Olympus PEN E-PL3**.

Alternatively, point the tests at a file anywhere on disk:

```bash
INFRARED_TEST_ORF=/path/to/your.ORF swift test
```

Resolution order is: `INFRARED_TEST_ORF`, then `RAW/OLYMPUS.ORF`, then any other
`.orf` file in this directory.

Everything in this directory except this README is git-ignored.
