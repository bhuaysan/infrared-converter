# 0012 — The two RAW paths are independent

Status: accepted
Date: 2026-09-12

## Context

The workspace reads a RAW file through two entirely separate paths:

```text
decodeMosaic(at:) → normalise → balance → demosaic → convert → mix → orient → encode
                                                            the workspace image

decode(at:options:)  LibRaw's own processed RGB
                                                            a diagnostic reference
```

ADR 0008 and ADR 0009 established that the first is the photograph and the
second is a labelled reference shown small beside it, so that a reader can
compare the two without either being mistaken for the other. `DocumentState`
already refused to substitute one for the other: an owned-pipeline failure is
reported as a failure even when the LibRaw decode succeeded, because a
plausible picture from a different pipeline looks exactly like success.

The control flow said something different from the architecture:

```swift
let decoded = try decoder.decode(at: url, options: .init(halfSize: true))
...
let prepared = Result { try WorkspacePreviewPipeline().prepare(...) }
```

The `try` is the whole problem. The diagnostic decode ran **first**, and threw
first. A file that LibRaw's processed-RGB path could not open was reported as
a failed open, and the application-owned pipeline — the actual workspace image
— was never asked whether it could read it. The reference was a gatekeeper for
the photograph.

This is not hypothetical for this project. The owned path and the LibRaw path
have different support surfaces, and older or unusual formats are explicitly in
scope.

## Decision 1 — Both paths run, neither gates the other

`DocumentState.decode` runs the owned pipeline first, captures each path's
outcome as a `Result`, and decides afterwards:

```text
owned ok    / legacy ok      → workspace image + diagnostic reference
owned ok    / legacy fails   → workspace image; the reference is reported missing
owned fails / legacy ok      → the owned failure, reported; never a fallback
owned fails / legacy fails   → DocumentOpenError, naming both refusals
```

The third row is unchanged from before and is the reason the fourth exists
rather than being folded into it: a fallback is still forbidden, so "the
reference decoded it" is not a reason to show anything.

## Decision 2 — The reference is optional in the type, not by convention

```swift
enum LegacyReference {
    case decoded(DecodedRAW, preview: CGImage?)
    case unavailable(RAWPathFailure)
}
```

`Loaded` no longer reaches its `url` and `metadata` through the legacy decode.
Both are now stored, with metadata taken from whichever path read it — the
owned one by preference, since that is the image on screen. A diagnostic
reference that cannot read the file must not be able to empty the inspector
either.

The inspector renders the `unavailable` case as a stated absence with its
reason, which is a more useful thing for a reader than a section that silently
vanishes.

## Decision 3 — A typed open error that keeps both refusals

```swift
struct DocumentOpenError: Error, Equatable, LocalizedError {
    let url: URL
    let owned: RAWPathFailure     // the one that matters: it is the image
    let legacy: RAWPathFailure    // kept: a difference between them is the diagnosis
}
```

`RAWPathFailure` keeps the decoder error where the decoder was the stage that
refused, and the message in every case — the owned pipeline's stages throw
`RAWProcessingError`, `IRProcessingError` and `OrientationError` as well as
`RAWDecodingError`, and flattening all of them to a string would lose the one
fact a test can assert on.

Two identical messages say the file is unreadable. Two different ones say which
stage disagreed, which is exactly the information the old flow destroyed.

`Status.failed` therefore carries a `DocumentOpenError` rather than a
`RAWDecodingError`: an open now fails for a compound reason, and the type says
so.

## Consequences

- A file the owned pipeline can read opens, and works fully — including the
  orientation controls — even when LibRaw's processed-RGB path refuses it.
- An owned-pipeline failure is still reported, still never replaced, and now
  distinguishable from a file nothing could read.
- The inspector reports a missing reference instead of hiding it.
- The architectural claim and the control flow now say the same thing.
- Nothing about the workspace image changed: same pipeline, same stages, same
  pixels.
