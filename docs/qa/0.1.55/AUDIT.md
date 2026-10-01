# Cove 0.1.55, build 57 — keep working while Cove syncs; fast typing; Undo Send

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

## Accent typing bug (user report during QA)

- **Report:** typing an accent (´ then a vowel) in the email editor sent the cursor to the start.
- **Cause:** dead keys and input methods insert temporary "marked text". `ComposeTextEditor` pushed that intermediate text and selection into SwiftUI, and the next `updateNSView` re-set the string, which dropped the mark. The stale selection was out of range, so it fell back to location 0.
- **Fix:**
  - While `hasMarkedText()`, `updateNSView` leaves the editor untouched, and the delegate doesn't report text or selection until the character is committed.
  - An out-of-range selection now lands at the end of the text instead of the start.
  - This covers the composer, the reply editor and every other `ComposeTextEditor`.
- **Test:** `ComposeAccentTests` types "Hola ", sets the marked "´", forces a re-render, commits "é", then types "xito". Expected: "Hola éxito" with the cursor after é. On the old code the same test fails with the cursor at 0 and "xitoHola é".
- **Full `swift test`:** CoveCoreTests 264, CoveRenderingTests 350, 0 failures.

## Typing lag (user: "feels slow when writing")

- **Cause:** every keystroke in a reply or the composer called `saveReply`/`saveComposition`. Each call:
  - mutated `mails` (bumping `mailsRevision`), so the memoized `visible` list and the sidebar/Home counts recomputed over the whole mailbox;
  - encrypted and wrote the email to SQLite;
  - scheduled cloud sync.
- **Fix:** typing stays in the editor's state, and the draft is saved after 0.6 s of no typing.
  - **Reader:** `updateReply` debounces. `flushReply()` saves immediately when switching the reply target, opening another email, leaving the reader, or sending; `cancelReplySave()` drops a pending save on send or discard so it can't bring a draft back. The "reply written elsewhere" adoption ignores the reader's own delayed save (`savedReply`) and anything while a save is pending, so it never rolls back typing.
  - **Composer:** `scheduleSave()` debounces; Send, Close, Discard and leaving save immediately.
- **Test:** `ReaderDesignTests.testTypingAReplyDoesntTouchTheMailboxOnEveryKeystroke` types 23 characters with no `mailsRevision` change, then exactly one save after the pause.

## Undo Send instead of "Send this email?" (user request)

- **Composer:** the confirmation dialog is removed. Send (or ⌘Return) queues the email and closes the composer; a bottom bar like Delete shows "Sending to <first recipient>" with a 4-second countdown ring and Undo (⌘Z).
- **Reply box:** Send clears the box and queues the email the same way.
- **The queue (`AppStore.queueSend`):** nothing reaches Gmail until the window ends. Delivery then waits for any exclusive operation (`waitUntilIdle`) and calls `send`. Only one email waits at a time; a second Send delivers the first immediately.
- **Undo, or a failed send:** the text goes back where it was written. A reply returns to that email's reply box (picked up by the reader's adoption); a new email reopens the composer on its saved draft.
- **Tests:** `UndoSendTests`:
  - Undo: nothing is sent, and the reply text is restored.
  - Without Undo: nothing is sent at 1 s; it is sent after the window.

Full `swift test`: CoveCoreTests 264, CoveRenderingTests 353, 0 failures.
- **Reply buttons (user: "4 buttons when replying"):** while the reply box is open (being written or holding a saved draft), the reader hides its bottom bar (Continue reply / Forward / ✦ Ask Cove). It repeated actions next to the box's own Send, Template, Discard and ✦. The bar returns after Send or Discard. Render `/tmp/cove-reader-assistant-reply.png` inspected.

## Release

- **First build discarded:** a build made before the reply-bar fix was notarized (`d3f5a401-d7c3-488e-81b4-8316a874622d`) and discarded unpublished.
- **App notarization** `1e0c47f7-4147-4c99-8384-505690c357ab`: Accepted, stapled.
- **DMG notarization** `c6d70907-3958-47e2-9c02-0d6fdd638544`: Accepted, stapled. 21,755,962 bytes, SHA-256 `2a88cfdb64771f2a792718faca8f6a516b89e18bd01e5277cc2b4f594d91b8e5`.
- **Feed and site:** the feed is signed (34 verified releases). Cloudflare Pages deployment `0c483037`.
- **Public checks:**
  - `/release.json`, the appcast and `/download/latest` serve 0.1.55, and the beta page says "Download Cove 0.1.55".
  - The downloaded DMG matches the bytes and SHA-256 above.
  - The Ed25519 signature verifies, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
