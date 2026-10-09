# Cove 0.1.69 — speed and error avoidance, wave 1

The assessment and plan are in `PLAN-speed.md`; the baseline numbers there were measured before any
change. Four agents (Opus 5.5 for the store, Sonnet for CoveCore, the Mac UI and iPhone) built this on
`scarranca/inbox-zero-triage`. Released as 0.1.69 (see Release below).

## Numbers (debug builds, Apple silicon; `BENCH` lines from the committed benchmarks)

| Measure | Before | After |
| --- | --- | --- |
| Load 4,000 encrypted emails (`MailboxLoadBenchmarkTests`) | 518–542 ms | 84–235 ms (parallel decrypt + decode) |
| One autosave write | 0.22 ms | 0.20 ms (unchanged) |
| Full list rebuild, 4,000 emails | 6 ms | 6 ms (unchanged) |
| Autosave + list read | rebuilt the list | 0.6 ms, list patched in place |
| Opening an HTML email, steady state (`UISpeedBenchmarkTests`) | 73–96 ms | 24–38 ms (web view pool) |
| First HTML open | 217 ms | 40–280 ms (first view creation, noisy) |
| Reader autosave, 4,000 emails, main-thread time | 34–67 ms | 23–24 ms |
| Composer autosave | 2–3 ms | unchanged |
| Opening an unread email with a stored conversation (`ReaderOpenBenchmarkTests`) | 3–4 mailbox changes, 3 Gmail requests | 2–3 changes, 2 requests |

## What changed

### Speed

- **Launch (S1, CoveCore):** `Database.queryMessages` reads the rows on the SQLite thread and decrypts and
  decodes them in chunks of 64 across cores (`decodeRows`), keeping order and throwing the first error
  in row order. Loads of 64 rows or fewer take the old path. iPhone and Mac both use it.
- **iPhone open:** `MobileMailbox.openIfNeeded()` opens the store, loads the key and reads mail in a
  detached task and hands the result to the main actor in an `@unchecked Sendable` box, with the
  documented invariant that only the main actor touches the database afterwards. "Opening your mailbox…"
  shows meanwhile; a sync can't start before the load finishes.
- **Opening HTML email (S2, Mac):** `EmailWebViewPool` keeps one shared `WKWebViewConfiguration` (one
  non-persistent store, one script handler) and up to 3 blank views reused across opens. A returned view
  is held back until its blank page commits, so no content, cookies or scroll state carry between
  messages; a reused view never reports a previous document's height; a crashed web process is
  discarded. JavaScript stays off, the CSP document and sanitising script are unchanged, remote images
  still load only when allowed. The render task is keyed on the HTML's length, not a hash of it.
- **Rows (S3):** `Mail.preview` (first 240 characters, whitespace collapsed, cheap) replaces per-render
  scans of the whole body in the Mac rows, the conversation snippets and the iPhone rows.
- **Autosave (S4):** `AppStore.editDraft` patches the cached lists in place; only a draft appearing or
  disappearing rebuilds them. The reader's `conversationCount` no longer scans the whole mailbox per
  body evaluation. The `availableContext: store.mails` suspect was measured and was not a cost.
- **Folder and label switches (S5):** `loadLabelMail` and older-page loads have their own flags
  (`loadingLabelMail`, `loadingOlderMail`) and run beside a background sync, waiting only for each
  other; the list no longer spins on `syncing`. An older page no longer rewinds the history cursor.
- **Opening an email (S6):** `markViewed` brings in the stored conversation with the same change; the
  unsubscribe lookup is skipped for the open email because the reader's thread fetch brings the
  headers (the conversation view is always shown beside the reader); stored thread messages write only
  their own rows.

### Error avoidance

- **Durable label edits on the Mac (E1, E2; `LabelEditQueue.swift`):** `modify` and `markViewed`
  apply the change on screen, queue it per email, and save the queue under `pendingLabelEdits`.
  Offline, timeout and rate limit keep the change and retry at 5 s, 30 s, then every 2 min, and at
  once after a sync succeeds or the connection recovers. A 401 refreshes once. A 404 removes the email
  through the sync-deletion path, silently. Any other 4xx reverts only that change (an alert if the
  user just acted, a status line for a background retry). A 5xx on a write is never retried. Queued
  changes count as in flight for `reapplyLabelEdits`, so a sync never undoes them; they replay when the
  mailbox opens. The triage Undo never waits for the connection: a still-queued archive and its undo
  cancel out locally.
- **Quiet background sync (E3):** `sync(older:interactive:)`; automatic callers pass `interactive:
  false` (poll, continuation, post-connect, switch, reopen, the launch content refresh). Background
  failures show only in the status line and the connection tag, without flicker or repeats. A refused
  token refresh sets `googleSignInNeeded` once, pauses the two-minute checks, and the tag offers "Sign
  in to Google again" (`signInAgain()`). The tag also counts waiting changes.
- **No stacked alerts (E4):** setting `error` to the message already showing is a no-op.
- **iPhone (E5):** background sync never alerts ("You're offline · showing downloaded mail", the rate
  limit status, or "Couldn't check Gmail · pull to retry"); a 401 refreshes once and then shows a
  sign-in banner using the existing reconnect path. Label edits and committed Trash moves go through
  one persisted queue (`pendingLabelEdits`, `pendingTrash`) with the same classification
  (`GmailFailureKind`, `LabelEditRetry` in CoveCore) and backoff, grouped into `batchModify`, replayed
  after the mailbox loads and when the app comes to the front, inside a background task. A 404
  removes the email; a definitive refusal reverts with an alert; 5xx writes are never retried. "Load
  older" failures show an inline "Couldn't load more · Try again" row.
- **Quit safety (E6, Mac):** editors save pending edits on `willTerminateNotification`; the app
  delegate returns `.terminateLater` for a pending send or Trash work, awaits
  `settleBeforeLeavingMailbox` (8 s bound) and then replies. Queued label edits don't hold the quit:
  they are persisted and replayed on the next open.

## Verification

- `swift build`, the iPhone library (`xcodebuild … -scheme CoveMobile`) and the full app shell with its
  notification extension (`-scheme CoveMobileApp`, simulator, unsigned) all build on the merged branch.
- Every `sync()` caller outside `AppStore.swift` is a button (⌘R, the list, Home, Contacts, Settings,
  the tag's Retry), so the interactive default is right; automatic callers pass `interactive: false`.
- Full Mac suite on the merged branch: **340 core tests (1 skipped) and 450 rendering tests (7 skipped), 0 failures.**
  `BENCH` lines from that run: load 4,000 encrypted emails 75 ms; HTML opens 34, 26, 26, 28, 25, 25, 24, 26, 26, 26 ms
  with 2 views created for 10 opens; reply autosave + layout 24 ms; composer autosave + layout 2.2 ms; list
  rebuild 5.5 ms; autosave + list read 0.5 ms; opening an unread email with a stored thread 2–3 mailbox
  changes and 2 Gmail requests.
- New suites: `ParallelMailLoadTests`, `LabelEditRetryTests` (7), `DurableLabelEditTests` (17),
  `ReaderOpenBenchmarkTests`, `UISpeedBenchmarkTests`, `QuitSafetyTests`, `MailboxLoadBenchmarkTests`,
  `MailboxSpeedBenchmarkTests`. `ReadStateTests`' offline mark-as-read test now asserts the new
  behavior (stays read, reaches Gmail when the connection is back).

## Not verified

- Nothing ran on a device, in a simulator or in the user's Cove: real offline behavior, the
  sign-in banner and the 401-then-refresh path, queued edits surviving a relaunch, the load-older
  retry row, the web view pool in the real app, the quit path.
- The iPhone off-main open is reasoned correct (one actor touches the database after the handoff),
  not exercised.
- Timings are debug builds on one machine; the web view numbers are noisy.

## Known limits

- Ask Cove's approved bulk changes and the Mac Trash commit keep their Gmail-first path (not queued).
- `signInAgain()` reconnects without a login hint; picking a different Google account in the browser
  opens that account.
- `GoogleAuth` has no `invalidateAccessToken()`; the 401 refresh uses `activate(email:)`'s side effect.
- If a history-expired full sync resets the page cursor while an older page is loading, that page is
  dropped, not merged.
- iPhone and Mac label-edit queues are separate shapes (per platform); snoozes stay per device.
- Further reader costs noted, not done: `tasks(for:)` and `unsubscribeRoute(for:)` scan `mails` per
  render.

## Release (October 8)

- **Version:** 0.1.69, build 71 (both waves on this branch: inbox zero and speed/error avoidance).
- **App notarization:** `5e6b2b43-a70c-4c41-9df0-ec0f794821bb`, Accepted and stapled.
- **DMG:** notarization `8c764ab5-a778-4ae7-879a-2e623d392128`, Accepted and stapled. 24,773,516 bytes, SHA-256 `6141a863e4d364f65ef1099aa7b474c38d04a878a8e4e8d76e2e404860a1a441`.
- **Feed:** signed, 48 verified releases.
- **Site:** Cloudflare Pages deployment `0d941844` (production, `main`).
- **Public checks:**
  - `/release.json` reports 0.1.69 (71); the beta page and `/download/latest` point to 0.1.69.
  - The downloaded DMG's size and SHA-256 match.
  - The Ed25519 signature verifies with the bundled key, and a one-byte change is rejected.
  - No headless previous-build update probe was run.
- **TestFlight:** iPhone/iPad build 19 (0.1.0), archived and uploaded with `xcodebuild -exportArchive`. It still needs the export-compliance answer in App Store Connect if that isn't automatic.
- The full suite was not rerun after the version bump; nothing else changed since the 340/450 run.
