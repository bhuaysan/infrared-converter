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

---

## Amendment (2026-09-12) — an open is an image, not a prepared source

Decision 1 above wrote the table in terms of "owned ok" and "owned fails", and
the implementation read "owned ok" as `prepare(decoding:using:)` returning a
`Source`. Those are not the same thing, and the gap was reachable:

```text
decodeMosaic        succeeds
prepare             succeeds
metadata flip       9, which this application does not model
render              refuses with unsupportedDecoderOrientation
legacy decode       fails
```

Every expensive stage succeeded, there was no displayable image anywhere, and
the workspace reported `.decoded`. The API said the file was open while the
screen had nothing on it.

### The corrected boundary

**The owned path counts as successful only when the initial workspace render
completed.** A prepared source is the expensive preparation, not a photograph.

The owned path is now modelled as one value with three outcomes — prepared and
rendered, prepared but unrenderable, never prepared — and `decode` switches on
it against the reference's two, so the six pairings are written out as six
cases rather than inferred:

```text
owned prepared + rendered / legacy ok      → .decoded, adjustable
owned prepared + rendered / legacy fails   → .decoded, adjustable, reference missing
owned fails at prepare    / legacy ok      → .decoded, owned unavailable, no source
owned fails at render     / legacy ok      → .decoded, owned unavailable, source kept
owned fails at prepare    / legacy fails   → .failed
owned fails at render     / legacy fails   → .failed          ← the missing case
```

The no-fallback rule is untouched: rows three and four still report the owned
refusal and still never show the LibRaw image in its place.

### `isAdjustable` is a rendered fact, not a retained buffer

It was `source != nil`, which answered a different question — whether the
expensive preparation exists — and answered `true` for a file where every
possible adjustment would refuse.

It is now a stored fact established at open time: **the owned pipeline
rendered this source at least once.**

The source itself is still retained when the render refuses it, because a
prepared scene-linear state is the most informative thing about such a file.
Retained and adjustable are simply different properties, and only the second
one builds a render slot.

Two things follow, both deliberate:

- A file whose recorded orientation this application cannot read shows its
  refusal and offers no rotate or flip control. There is no camera- or
  error-specific branch in the view: the decision is a field on the workspace
  state, where the reasoning lives. With orientation the only adjustment, and
  every one of its failure modes independent of which orientation was asked
  for, "the initial render failed" and "no adjustment can succeed" are the
  same condition. A future adjustment that could repair a render failure would
  be a reason to revisit this, deliberately.
- A render that fails *after* the file is open does **not** disable the
  controls, because the fact is stored rather than read back from the current
  preview. Otherwise a user could not undo the adjustment that broke it.

### The failure keeps its type

`RAWPathFailure` carried a `RAWDecodingError?` and a message, which lost every
other error the chain throws. It now carries the refusal itself plus the stage
that produced it — owned preparation, owned render, or the legacy reference —
with `decoding` and `orientation` as projections.

That is what lets a test assert `unsupportedDecoderOrientation(flip: 9)` rather
than match on a sentence, and what lets `DocumentOpenError` name which half of
the owned path refused. `message` and `failureReason` remain the user-facing
strings, and neither can carry LibRaw's internal integer codes: the decoder's
`failureReason` reports diagnostics through `userFacingSummary`, which omits
them.
