# Cove 0.1.55 (unreleased) — keep working while Cove syncs

## User report

"Why can't I continue using Cove while syncing, like connecting Calendar?" One `busy` flag serialized everything: sync, label views, Jev organizing, agent checks, the AI thread read, archive/star/labels, trash, calendar writes and connections. `run()` started with `guard !busy`, and 81 view controls were disabled by it. A long catch-up made the whole app look frozen.

## Changes (Superhuman's approach: instant local actions, a per-thread queue, sync merges around them)

- **New `syncing` flag** for background mail work: `sync`, older pages, `loadLabelMail`, Jev organizing, custom-agent checks and the AI thread read (`runSync`). These no longer set `busy`.
  - Background work still serializes with itself.
  - Sign-out and local erase wait for it (`!syncing`); the Disconnect menu shows "Disconnect (after sync)".
  - The sidebar and list spinners and the Sync buttons follow `syncing`.
  - An action finishing during a sync restores the sync's status text instead of claiming "Up to date".
- **Instant label actions:** `modify` (archive, star, labels, read/unread) applies locally first, then sends to Gmail on a per-email task chain (`labelTasks`) in the order made. If Gmail refuses, only that change is undone (labels the change added and that weren't there before are removed; labels it removed are restored) and the user is told. It no longer uses `run`/`busy`.
- **Sync can't undo user changes:** every label change records a `LabelEdit` (net add/remove, revision, in-flight revisions).
  - Approved bulk changes also record through `applyLabelChange`.
  - The three merge sites (sync, label views, thread refresh) call `reapplyLabelEdits(since:)` with the revision at which their Gmail read started: newer or still-in-flight edits win over the older Gmail copy.
  - After a sync, `pruneLabelEdits(through:)` drops edits that reached Gmail before it started.
  - This generalizes the existing read/unread reconciliation (`readChanges`), which is kept.
- **Unchanged on purpose:**
  - Calendar writes and trash commits still use `busy` (calendar refresh waits for them).
  - Approved bulk changes still hold `busy` for their single batch call.
  - Connect Calendar/Tasks waits only for `busy`, so it no longer waits for a sync.

## Review fixes (independent review before QA)

- **One record per change:** `LabelEdit` keeps a list of changes per email (revision, add, remove, in flight), replayed in order. A refused change drops only its own record. Before, a refused star could be re-applied if an archive of the same email was queued.
- **Trash:** `trash()` (also used when the 5-second undo window ends) records TRASH/−INBOX while in flight. `busy` no longer excludes sync, so without this a sync overlapping the commit could briefly un-trash it.
- **Fourth merge site:** the AI thread read now re-applies changes too.
- **Account switch** clears `labelEdits` and cancels `labelTasks`.
- **Rate-limited action:** if Gmail rate-limits one of the user's own changes after its retries, the change is undone with a status line saying why (still no alert).

## Tests

- `WorkWhileSyncingTests`:
  - archiving during a sync applies at once, doesn't set `busy`, and a stale sync result can't undo it; after pruning nothing is re-applied;
  - repeated changes to one email replay in order;
  - a change Gmail refuses (400) is undone, reported, and never re-applied.
- `HubActionsTests` was updated: archiving during a sync now applies and sends one request, where it used to be blocked. The sample mailbox still never sends.
- `MailboxPollingTests`: a poll is skipped while a sync is running.
- `LabelEditInFlightTests`:
  - A real `sync()` runs while a fake Gmail holds the archive request; history says the email is back in the Inbox. It stays archived before and after Gmail confirms, and the record is pruned by the next sync. Confirmed to fail with the sync's re-apply removed.
  - Star and archive are queued on one email and Gmail refuses the star: the star is undone, the archive stays, and only the archive is ever re-applied.
- Full `swift test`: CoveCoreTests 264, CoveRenderingTests 349, 0 failures.
- Not yet verified live: archiving and starring during a long real catch-up.
