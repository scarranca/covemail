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

## Local-first mail index — phase 1: per-email storage

User decisions: index the last 365 days (plus older starred mail), keep formatted HTML for 365 days, configurable storage limit defaulting to 1 GB, and purge local copies when mail is deleted in Gmail. Phase 1 changes storage only; the app still loads the whole local mailbox.

- **Before:** every sync re-encrypted and rewrote the entire mailbox as one record (`mail`), plus `mailOverride:<id>` edits.
- **Now:** a `messages` table with one AES-GCM row per email (AAD `message:<id>`). `saveMailSnapshot` writes only emails that changed since they were loaded or saved and removes only emails this session loaded that are now absent. Cursor keys commit in the same transaction. A rolled-back snapshot restores change tracking. Erase clears the table and the tracking.
- **Migration:** v2 → v3 on open, all or nothing. The legacy snapshot plus overrides become rows. Only the `mail` and `mailOverride:` keys are removed; preferences, cursors and cloud state stay. Unkeyed rows are sealed if a plain store is later encrypted. Older Cove refuses a v3 store ("needs a newer version of Cove"); downgrading is not supported.
- **Clear-text metadata (deliberate):** id, thread id, date, and the starred, has-draft, in-Inbox and snoozed flags (booleans, not snooze times). `loadMail(since:)` uses them to load the recent window plus starred, drafted, Inbox and snoozed emails of any age without decrypting the rest. Old unarchived Inbox mail therefore never disappears from the list. Content stays encrypted. Moving a ciphertext to another id fails authentication (tested).
- **Performance** (release build, 30,000 encrypted emails, `COVE_PERF=1 swift test -c release -Xswiftc -enable-testing --filter MailStoragePerformanceTests`):
  - initial save: 884 ms
  - snapshot with one change: 29 ms (target < 50)
  - 90-day window load: 112 ms (target < 200)
  - full load: 382 ms
- **Load order:** stored mail loads newest first (date, then id), matching how sync orders mail. It no longer follows snapshot position, so the `MailboxPassageTests` fixture now sets explicit dates. Failure-injection triggers in `SendWorkflowTests` and `ThreadAnswerTests` now target `messages`.
- **Tests:**
  - New: `MailboxPersistenceTests` (legacy migration, changed-only writes via an insert-counting trigger, archive rows never dropped, starred/draft outside the window, newer version rejected, rollback then retry); `EncryptedStorageTests.testEncryptedSnapshotMigratesToEncryptedRows`; erase then re-save.
  - Core: 217 passed, 1 skipped (the perf test is opt-in).
  - Rendering: storage-related tests pass. `EmailRenderingTests` wheel/scroll tests failed only inside large batches; they pass alone on this branch (twice) and on the previous commit, so they are timing-sensitive, not storage-related.
- **Archive safety (steps 2–4):**
  - *Tracking:* only emails in the live mailbox are tracked for removal-by-absence. Migration output and the archive primitives (`storedMessageIDs`, `loadMessages`, `loadThread`, `storeArchived`, `deleteMessages`) are untracked, so a windowed load can never let a snapshot delete older rows. Test: `MailboxPersistenceTests.testArchiveAccessNeverJoinsTheLiveMailboxOrItsDeletions`.
  - *Single merge path:* all eight Gmail merge sites use `GmailSyncResult.merging`. Stored-but-unloaded emails are read first, so label changes and re-downloads keep the Jev decision, draft and snooze. Results outside the working set are written back untracked, and Gmail deletions purge the local copy. Stored ids are sent as "already stored", so Gmail returns only their labels. Search and cited sources adopt the stored copy. Tests: `ArchivedMailMergeTests`.
  - *Threads:* opening a conversation (and Ask Cove's thread scope) brings its stored older messages into memory. Only missing ids are decrypted. Test: `ReaderConversationTests.testOpeningAConversationLoadsItsStoredOlderMessages`.
  - *Known limit:* a full resync after Gmail's history expires verifies only loaded ids, so a Gmail deletion of unloaded mail during that gap is caught later by retention reconciliation (phase 4), not immediately.
- **Order from here:** keyed-hash index and wiring (search box, All mail/labels, Ask Cove downloaded mode) *before* narrowing the window. Otherwise already-downloaded mail from 90–365 days ago would vanish from lists and search.
  - Narrowing also needs: cloud snoozes applied to unloaded rows; every `saveMessage` caller confirmed to target loaded mail; a window of at least 30 days (cloud mirror); and a recorded decision on very large Inboxes, since Inbox mail of any age loads.
- **Not done yet:**
  - The app still calls `loadMail()`.
  - The working-set switch, keyed-hash index, 365-day backfill, retention/limit/purge and Settings → Storage are phases 2–5.
  - Before narrowing the working set: route Gmail merges for stored-but-unloaded emails through untracked archive reads and writes, so Jev decisions, drafts and snoozes are kept and Gmail deletions purge rows (the read-site audit found every merge site would otherwise overwrite archived rows); and load threads by `thread_id`.
- **Live real-account migration check (September 29):**
  1. A QA build of the published 0.1.49 commit (`5fd1f42`, bundle `ai.cove.qa`, data under `Cove/QA`, separate Keychain) was connected by the user to their real Gmail account.
     - Store: version 2, one 1.5 MB encrypted `mail` snapshot plus one `mailOverride:` record, no `messages` table.
  2. The user opened the 0.1.50 QA build over the same data and confirmed the inbox and opened emails looked the same.
     - Store after: version 3; `mail` and `mailOverride:` removed.
     - 150 message rows (132 threads, 145 in Inbox); the six other records (cursor, labels, pagination, snoozes, last sync, decoding version) kept.
  - Only metadata (version, counts, cleartext columns) was read; no mail content was read or logged. The user's own Cove and its data were not touched.

## Not done / limits

- Parallel research batches (the ChatGPT helper serves one request at a time) and API-provider SSE streaming.
- Using Jev (TypeSafe) to decide lookups was considered: it can confirm borderline "needs lookup" cases but cannot write queries or extract dates and names, and it sends request text to TypeSafe. Not implemented; its latency would need measuring first.
- Superhuman also prefetches and indexes the whole mailbox server-side. Cove indexes downloaded mail locally, and model speed is bounded by the user's provider.
- Full offline suite after review fixes: see commit; not yet checked live.
