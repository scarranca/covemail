# Cove 0.1.50 (unreleased) — speed: instant search, fewer model calls, streaming drafts, focused follow-ups

## Search

- **Before (release build, 5,000 synthetic emails):** each read of the mail list took about 89 ms. It reran `localizedCaseInsensitiveContains` over every body, and SwiftUI reads `visible` several times per redraw, so one keystroke cost roughly 530 ms.
- **Now:**
  - `MailSearchIndex` (CoveCore) folds sender/address/subject/body once per email (case- and accent-insensitive) into bytes and matches with `memmem`. Every query word must appear, in any order, and entries refresh only when an email's searchable fields change.
  - `AppStore.visible` is memoized per state: mail revision (observed), folder, search, filters, selection, queued trash and minute. Typing that extends the query narrows the previous results.
- **After (release):**
  - A fresh query takes about 15 ms for six reads (one computation), and the first search builds the index (about 25 ms, once).
  - Extending a query ("renovacion" → "renovacion trimestral") takes about 0.3 ms.
  - `MailSearchSpeedTests` asserts accent/case/word-order matching, one computation per state and invalidation on mail changes.
- The mail list offers **Search all of Gmail for "…"** (at the end of results and in the empty state), which fetches up to 20 Gmail matches into the mailbox and keeps the search (switching to All mail when matches are outside the folder).

## Drafting

- `WritingAgent` skips its planning call when a request has no lookup signal (`WritingToolPlan.mightNeedLookup`: search, meeting, calendar, dates, proposing times, attachments, in English and Spanish). Tone, length, grammar and translation edits now take one model call instead of two. Anything with a signal still plans, and false positives only cost the old extra call. Tests: `WritingLookupSignalTests`, `WritingCallCountTests`; existing planner-safety tests now use lookup-worthy requests.
- The ChatGPT connection reuses a successful `account/read` for 5 minutes while the helper runs (reset when it stops), so each request skips that round trip.
- **Streaming:** the Codex app-server's `item/agentMessage/delta` notifications (confirmed from `codex app-server generate-json-schema`, codex-cli 0.158.0) are forwarded as `onPartial`. Draft text appears as it's written: in the composer canvas (read-only, then replaced by the normal reviewable suggestion) and in the reply writing panel. Lookup plans (JSON) never stream. ChatGPT subscription only; API-key providers and Claude still show the finished text. This changes perceived, not total, latency. Test: `ChatGPTConnectionTests.testDraftStreamsAndAccountCheckIsReusedBetweenRequests`.

## Ask Cove follow-ups

- The router's `followup` action (only offered when the previous answer used emails) makes refinements like "make it more 'Hola Jerjes, te encargo…'" reuse the previous answer's emails instead of starting a new 100-email Gmail search. This fixes the user-reported regression and turns a multi-call research run into one call. Test: `AssistantActionTests.testFollowUpReusesPreviousEmailsOnlyWhenTheyExist`.

## Review fixes

- Streaming callbacks are `@MainActor` end to end (`AIProviderSettings`, `ChatGPTConnection`, writing sheet), so UI state is only changed on the main thread.
- `MailSearchSpeedTests.testNarrowingWhileTypingAlwaysMatchesAFreshSearch` types 14 steps (including a space and backspaces) and asserts the narrowed list equals a cold search every time.
- **Search all of Gmail** switches to All mail when any match isn't visible in the current folder. It deliberately saves up to 20 matches locally because the user asked for them, unlike Ask Cove research, which saves only cited mail.
- Lookup signals match "free" and "time(s)" as whole words and ignore "feel free", so "feel free to shorten this" stays one call.

## Not done / limits

- Parallel research batches (the ChatGPT helper serves one request at a time) and API-provider SSE streaming.
- Using Jev (TypeSafe) to decide lookups was considered: it can confirm borderline "needs lookup" cases but cannot write queries or extract dates and names, and it sends request text to TypeSafe. Not implemented; its latency would need measuring first.
- Superhuman also prefetches and indexes the whole mailbox server-side. Cove indexes downloaded mail locally, and model speed is bounded by the user's provider.
- Full offline suite after review fixes: see commit; not yet checked live.
