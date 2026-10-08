# Cove 0.1.69 (unreleased) — inbox zero, wave 1

The analysis and the plan are in `PLAN.md` beside this file. The user asked for the gap against
Superhuman to be analyzed, planned and built with parallel agents (Opus 5.5 for the Mac triage core,
Sonnet for the Mac UI and for iPhone). Branch: `scarranca/inbox-zero-triage`. Not released, not pushed.

## What changed

### One triage path on the Mac (`MailTriage.swift`, `AppStore`)

- `triage(_:_:)` / `beginTriage(_:_:)` handle archive, move to Inbox, read, unread, flag, unflag, trash
  and snooze for one email or a chosen set. Only emails the action really changes are touched.
- **Auto-advance:** the next email (below, or above at the end, skipping emails leaving in the same
  action) is chosen before anything is applied. The reader toolbar, row actions, Home, Ask Cove's
  archive-after-task and the keys all advance now; before, only E did.
- **Undo (Z, or the toast):** one `TriageUndo` per action, reversed exactly through `modify`/`applyBulk`
  (never a snapshot), previous snooze times restored per email, a pending Trash cancelled. The Undo
  waits for the change it reverses to reach Gmail, so it can't be overtaken. Replaced by the next
  action; cleared on folder or account change. Trash keeps its five-second countdown toast; the triage
  toast stays hidden for it (`endsWithTrashWindow`) and Z cancels the move.
- Up to 25 emails go through `modify` side by side; more go through `applyBulk` as one `batchModify`.
  A row action on an email outside the chosen set leaves the set chosen.
- `archive(_:)` and `snooze(_:preset:)` go through `triage`, so every existing caller gets Undo and
  advance.

### Keys (`MailNavigationShortcut.swift`)

J/K = ↓/↑; S flag; H snooze (opens the chooser for the open email); X chooses the row under the
pointer, else the open email; ⇧↓/⇧↑ extend the choice while moving; ⌘A chooses every listed email
(only when no text or web view has focus); Esc clears the choice first, then the reader; Z undo;
⇧E back to Inbox (also wakes a snoozed email); C new email; `?` the shortcut sheet. E, ⇧E, U, S and
⌘⌫ act on the chosen set when it includes the open or pointed email. Letters still pass through to
editors, sheets and other screens. The one changed test: ⇧↓ no longer passes through.

### Mac UI (`MailSelectionBar.swift`, `ShortcutHelpView.swift`, `MailViews`, `ReaderView`, `InboxDuskView`)

- **Snooze chooser** (popover, shared by the reader toolbar, Remind me, rows and the selection bar):
  `SnoozePreset.available()` with each date beside it, digits 1–5, "Pick a date…" (graphical picker, at
  least 30 minutes ahead), "Return to inbox" when snoozed, the `snoozeSyncDetail` line. The line
  "Notifications are not available yet" is gone (see notifications below).
- **Multi-select:** a circle at the row's left (on hover, on every row once anything is chosen, always
  for chosen rows); chosen rows are tinted; a bar under the filters says "N selected" with Archive,
  Read/Unread, Flag/Unflag, Snooze, Delete and ✕ (icon-only when the column is narrow).
- **Undo toast** on the `InboxMoveToast` pattern with a Z keycap, stacked above it, Reduce Motion
  honored.
- **Empty Important tab:** "Archive N in Other" under the dusk scene, only when Other has mail. N counts
  the Other emails downloaded to this Mac; older Other mail still in Gmail is not included.
- **`?` sheet:** every mail key in five groups. The list footer and the empty reader teach E, H, X, Z
  and `?`.

### Snooze presets (`CoveCore/SnoozePreset.swift`)

Later today (+3 h to the next quarter hour, today only, hidden when it would fall after This evening),
This evening (18:00), Tomorrow morning (9:00), This weekend (Saturday 9:00; the next one from the
weekend), Next week (Monday 9:00, never today). Anything within 30 minutes or in the past is hidden.
`describe` gives "Today 1:30 PM", "Tomorrow 9:00 AM", "Sat 9:00 AM", "Oct 21, 9:00 AM".

### iPhone and iPad (`MobileSnooze.swift`, `MobileMailbox`, inbox and reader views)

- `snooze(_:until:)` saves the time on the email in the encrypted store. The Inbox, unread counts and
  Home hide snoozed mail until its minute; the clock refreshes every minute and on foreground.
- A **Snoozed** folder (clock icon, after Flagged) with "Until Tomorrow 9:00 AM" on rows.
- Reader toolbar Snooze menu (presets with dates, Pick a date…, Return to inbox); leading swipe
  "Snooze" opens the same choices; a Snooze submenu in the context menu. Snoozing from the reader
  leaves it, like Archive.
- Archiving or trashing a snoozed email ends its snooze (Trash only when it commits, so Undo keeps it).
- Copy says: "Snoozes are saved on this iPhone and don't sync to your Mac yet." The Mac's cloud snooze
  API is not wired on iPhone in this wave.

### "Back in your inbox" notification (iPhone and Mac)

- `CoveCore/SnoozeNotice.swift`: identifier `snooze.<mailID>`, title "Back in your inbox", body
  "sender · subject", never the email's body.
- Mac: `SnoozeNotifications` (started from `CoveApp`) watches the mailbox and keeps one pending local
  notification per snoozed Inbox email, cancelling it on unsnooze, archive or trash; stale requests from
  earlier sessions are swept for the open account. Permission is asked only when the user sets a snooze
  themselves (`AppStore.snooze` → `requestPermissionIfNeeded`), never on launch, from a sync or from a
  cloud snooze arriving; a denied snooze still works. A click opens the email through the agents' notifier.
- iPhone: `MobileSnoozeNotifier` does the same with calendar triggers; a tap opens the email through
  the existing push routing.

## Verification

- `swift build`: succeeds with the merged branches.
- `xcodebuild build -scheme CoveMobile -destination 'generic/platform=iOS Simulator'`: succeeds, 0 errors.
- `swift test` (full suite, after all three merges and the integration edits): **329 core tests (1 skipped) and 423 rendering tests (7 skipped), 0 failures.**
- New tests: `SnoozePresetTests` (5), `SnoozeNoticeTests`, `MailTriageTests` (6: bulk E with one
  Undo, Z restores and reselects, snooze undo restores the time, selection cleared on folder change,
  choosing doesn't recompute `visible`), `MailNavigationTests` (every new key, pass-through to editors),
  `MailTriageRenderingTests` (5 renders, inspected: `/tmp/cove-triage-*.png`).

## Not verified

- No run of the Mac app or the iPhone app: the popover opening from H, the digits inside it, the
  swipe/dialog flow on iPhone and the Snoozed folder have only been rendered or compiled, not used.
- Whether a scheduled local notification fires while Cove (Mac) or the iPhone app is closed. Both use
  system-scheduled triggers, which is the documented behavior, but neither was observed.
- Large sets (more than 25) wait for Gmail before rows change and mark Cove busy for the batch; that
  path isn't protected against a sync running at the same time, as in Ask Cove's bulk path before.
- Archives from Home or Ask Cove set `triageUndo` too, but the toast and Z live in Mail, so that Undo
  is reachable only after switching there.
- `SnoozeNotifications` scans `mails` on every revision, including autosaves; linear and cheap, but it
  sits beside 0.1.68's autosave item.
- Account switch clearing the choice and Undo is implemented in `mailboxGeneration`'s didSet but not
  covered by a test.

## Known limits and decisions

- Snoozes don't sync between iPhone and Mac. Mac snoozes still sync through the cloud snooze API when
  cloud sync is on, as before.
- H needs an open email; with a chosen set and nothing open, use the selection bar's Snooze.
- The Unread and oldest-first toggles don't clear the chosen set; actions apply only to emails still
  listed.
- Read statuses were deliberately not built (privacy).
- Wave 2 candidates are listed in `PLAN.md`: remind-if-no-reply, send later, instant replies and
  one-line summaries, more splits, a compact row density, a ⌘K palette.
