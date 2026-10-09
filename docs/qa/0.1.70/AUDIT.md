# Cove 0.1.70 (unreleased) — To-field contact search

The user reported that searching contacts while writing was slow (October 8, after 0.1.69).

## What was slow (measured, `RecipientSuggestionBenchmarkTests`, debug build)

| Cost | Before | After |
| --- | --- | --- |
| Ranking the directory per keystroke in To (1,500 people) | 6–15 ms, every keystroke | 0.04 ms (`ContactSearchIndex`) |
| Building the directory when a Mac composer opens (4,000 emails) | ~170 ms on the main thread | off the main thread (`AppStore.contactSearchForWriting`) |
| iPhone directory build | on the main thread at the first keystroke and after new mail | off the main thread when the composer opens (`MobileMailbox.contactSearchForWriting`) |
| Empty To (four recent people) | ~15 ms sort per render | precomputed |
| Pause before asking Gmail | 300 ms | 200 ms |

`ContactSearchIndex` (CoveCore) folds every name and address once and ranks with byte comparisons;
the ranking is the same as before (exact prefix, then a name word, then contains; ties by most emailed,
then most recent), checked against the old ranking for accented, multi-word and mixed-case queries.
It stops scanning once enough exact-prefix matches are found. `ContactDirectory.suggestions` remains
for small lists and now uses the index.

## Verification

- Full Mac suite: 341 core tests (1 skipped) and 450 rendering tests (7 skipped), 0 failures.
- `swift build` and the iPhone app shell (`CoveMobileApp`, simulator, unsigned) build.

## Not verified

- No run in the real app or on a device; the Gmail lookup's network time (a search plus up to 12 header
  reads) is unchanged apart from the shorter pause.
- The composer shows no local suggestions for the moment the index takes to build after it opens.
