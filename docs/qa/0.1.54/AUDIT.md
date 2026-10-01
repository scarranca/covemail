# Cove 0.1.54, build 56 — Gmail sync within Google's budget, Superhuman-style

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

## Research (user asked how Superhuman does it)

- **Superhuman:**
  - The client calls the Gmail API and caches everything locally, with a modifier queue per thread ([blog, offline architecture](https://blog.superhuman.com/architecting-a-web-app-to-just-work-offline-part-1/)).
  - It pre-caches the Inbox, Sent and the labels you use, and has "two speeds of pre-caching", about ten times faster when plugged in, to avoid pegging the CPU ([SE Daily 1132](https://softwareengineeringdaily.com/wp-content/uploads/2020/09/SED1132-Superhuman.pdf)).
- **Google's official numbers** ([quota](https://developers.google.com/workspace/gmail/api/reference/quota)):
  - 6,000 quota units per user per minute.
  - Costs: `messages.get` 20, `messages.list` 5, `history.list` 2, `messages.modify` 5, `batchModify` 50, `send` 100.
  - The sync guide recommends `history.list` for partial sync, `format=minimal` for label-only refreshes, and batches of at most 50, each call still counted ([sync](https://developers.google.com/workspace/gmail/api/guides/sync), [batch](https://developers.google.com/workspace/gmail/api/guides/batch)).
  - History messages carry only `id`/`threadId`; `labelsAdded`/`labelsRemoved` carry `labelIds`.
- **Cove's old pacer** assumed 250 units per second and 5 units per read, so it could read 20 per second, about four times Google's sustained 5 per second. A catch-up spent the per-minute budget in about 15 seconds.

## Budget pacing, label changes from history, newest first, two speeds

1. **`GmailPacer` is a budget:** 6,000 units per minute, refilled continuously.
   - Every Gmail request spends its official cost (`GmailClient.quotaCost`).
   - Background work (`pacedBulk(cost:)`) waits until the budget stays above a 1,500-unit reserve, so opening, sending and archiving are never starved.
   - A rate limit pauses everything and zeroes the budget.
2. **Label changes from history:** `history.list` label changes (`labelsAdded`/`labelsRemoved` with `labelIds`) are replayed in order into `GmailSyncResult.labelChanges` and applied to the stored copy.
   - Only emails Cove doesn't have (new, or labelled but never downloaded) are read.
   - `merging` loads unloaded stored emails that the label changes touch.
   - Before, every changed email cost a 20-unit read.
3. **Newest first:** catch-up reads go in descending id order (Gmail ids grow with time), so recent mail lands first.
4. **Two speeds:** the minimum gap between background reads is 0.06 s on power and 0.6 s on battery or in Low Power Mode (`PowerState`).

## Tests

- `GmailSyncTests.testRateLimitPartwayKeepsWhatArrivedAndRemembersTheRest` (9 changes, a 403 `userRateLimitExceeded` after the first batch: 3 kept, 6 pending, and the next sync fetches the 6).
- `GmailSyncTests.testRateLimitBeforeAnythingArrivesStillFails`.
- `ConnectWhileSyncingTests`.
- `GmailBudgetTests`: the cost table, background reads waiting for budget above the reserve, the pause after a rate limit, and label replay order.
- History fixtures now carry `labelIds` like real Gmail and assert that label-only changes trigger no reads. The deletion-safety test uses an email that isn't stored, so a read is still required and still fails safely.
- Full `swift test`: CoveCoreTests 264, CoveRenderingTests 344, 0 failures.
- Not verified live yet: a real rate-limited catch-up.
