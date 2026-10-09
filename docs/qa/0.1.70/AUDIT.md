# Cove 0.1.70 (unreleased) — typing speed and To-field contact search

The user reported that searching contacts while writing was slow (October 8, after 0.1.69).

## Typing lag (the user's actual report: "it feels slow when typing")

Main-thread time per typed letter, measured through the window's own layout and display pass
(`UISpeedBenchmarkTests.testTypingInTheComposerWithLargeMailbox` / `testTypingAReplyWithLargeMailbox`, 4,000
emails, debug build, 60 letters, three runs each; numbers are noisy, so ranges are quoted):

| Field | Before | After |
| --- | --- | --- |
| Reply box in the reader | 19–23 ms | 0.8–1.6 ms |
| Composer body | 10–15 ms | 2–5 ms |
| To field | 9–13 ms | 7 ms |

A frame is 8–16 ms, so the reply box dropped frames on every letter before.

Causes, found by profiling and a probe on the hosting view's `needsLayout`:
- **TextKit 2 subviews.** The native editor (TextKit 2) adds a drawing subview for each new line or
  paragraph; each added subview invalidates SwiftUI's layout, which then re-measured the whole reader or
  composer (the window's minimum size). `ComposeTextEditor` now uses TextKit 1
  (`NSTextView(usingTextLayoutManager: false)`), which draws in place. `WritingMotion` already used TextKit 1.
- **Typed text in the parent's `@State`.** The reply text, its caret and its pending save were `@State` on
  `ReaderView` (the composer's body, caret and save on `ComposerView`), so every letter rebuilt the whole view.
  They now live in `TypedText` (`TypedText.swift`). The text is not observed. Only `isBlank` (Send, AI tools),
  `highlight` (a selection, not the caret), `wordCount` (composer, once per word) and `revision` (text replaced
  from outside the editor) are observed, read inside `TypedTextReader`. Verified that the AI panel still re-renders
  when the draft stops being blank.
- **To and Subject.** These are now `FieldText` boxes read only by their own fields. The writer gets copies that
  settle after 250 ms (`settledTo`/`settledSubject`), and the save and Gmail lookup triggers moved onto the field.

## Contact search (measured, `RecipientSuggestionBenchmarkTests`, debug build)

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

- Full Mac suite: 341 core tests (1 skipped) and 452 rendering tests (7 skipped), 0 failures.
- Reader reply and composer renders inspected after the TextKit change: the same layout, and the word count is right.
- `swift build` and the iPhone app shell (`CoveMobileApp`, simulator, unsigned) build.

## Not verified

- Typing was measured in hidden test windows, not in the running app. The iPhone composer was not changed or measured.

- No run in the real app or on a device; the Gmail lookup's network time (a search plus up to 12 header
  reads) is unchanged apart from the shorter pause.
- The composer shows no local suggestions for the moment the index takes to build after it opens.
