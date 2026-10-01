# Cove 0.1.54 (unreleased) — catch-up sync in batches; connect during sync

## User report (0.1.53, after a reinstall)

"Syncing Gmail…" wasn't moving, then the alert "Cove couldn't finish: Gmail is limiting how fast Cove can read mail right now." Unified logs from the live app showed roughly 230 successful and 33 refused (403) Gmail requests in three minutes: a long catch-up hitting the per-user rate limit. The Calendar/Tasks "Set up" buttons did nothing during the sync.

## Changes

- **`GmailClient.synchronize` / `fetchUpdates`:**
  - Fetches three emails at a time instead of five, still through the shared pacer.
  - If Gmail rate-limits after at least one batch, it returns what arrived plus `GmailSyncResult.pendingIDs` (the emails not reached) instead of throwing.
  - The next sync passes `pendingIDs` and checks them first, on both the history and the full-page paths.
  - A limit on the very first batch still throws, so a sync that made no progress is never silently looped.
- **`AppStore.sync`:**
  - Persists pending IDs encrypted (`gmailPendingIDs`).
  - After a partial or rate-limited sync, shows a status ("Caught up on part of your mail · N more in a minute" / "Gmail asked Cove to slow down · continuing in a minute") and continues once after 60 s (`scheduleSyncContinuation`, cancelled on account switch).
  - The history cursor still advances, which is safe because the unreached emails are saved and re-checked.
- **No modal for rate limits:** `reportFailure` skips them, and `run` sets a quiet status. `AppStore.error` also drops `HTTPFailure.gmailRateLimitMessage` and turns it into a status, so features that set the error directly can't raise the alert. Real errors still alert.
- **Connect during a sync:**
  - `connectCalendar`/`connectTasks` used to return silently while `busy`. They now record `connectingStep`, wait for the sync (`waitUntilIdle`, up to 2 minutes, then give up if the mailbox changed), and connect.
  - The Home checklist row shows "After sync…" or "Connecting…".
  - Other Connect buttons are no longer disabled by `busy`, only while a connection is already pending.

## Tests

- `GmailSyncTests.testRateLimitPartwayKeepsWhatArrivedAndRemembersTheRest` (9 changes, a 403 `userRateLimitExceeded` after the first batch: 3 kept, 6 pending, and the next sync fetches the 6).
- `GmailSyncTests.testRateLimitBeforeAnythingArrivesStillFails`.
- `ConnectWhileSyncingTests`.
- Full `swift test`: CoveCoreTests 260, CoveRenderingTests 344, 0 failures.
- Not verified live yet: a real rate-limited catch-up.
