# Cove 0.1.69 (unreleased) — inbox zero: the Superhuman gap, and the plan

Goal (October 8): find where Cove's experience falls short of Superhuman, especially at getting the user to
inbox zero, then build the first wave with parallel agents.

## What Superhuman does that keeps people at inbox zero

From its current public feature set (keyboard-first navigation, split inbox, Done/Snooze/Remind, AI drafts
and one-line summaries) and from using it: the product is a *triage loop*. Every email is one key away from
leaving the inbox, every action advances to the next email, and every action can be taken back with Z.

| Superhuman | Cove today (0.1.68) | Gap |
| --- | --- | --- |
| E = Done, auto-advances | E archives and opens the next (`MailNavigationShortcut`) | ✓ |
| Archive/Snooze/Trash from the toolbar also advance | Toolbar Archive clears the reader; Snooze and ⌘⌫ leave it empty | **inconsistent** |
| Z undoes anything (done, read, snooze, send) | Undo only for Trash (5 s), Send (4 s) and Important/Other votes | **no undo for archive/read/flag/snooze** |
| H snooze: Later today / Evening / Tomorrow / Weekend / Next week / pick a date | Menu with "In one hour", "Tomorrow morning"; no key; reader only; "Notifications are not available yet" | **thin** |
| X selects, Shift+arrows extend, ⌘A selects all; then one key acts on all | iPhone has pick-and-bulk; Mac only via Ask Cove's approval card | **no Mac multi-select** |
| Keys for everything: J/K, S star, C compose, #, !, ⇧E, ⌘K palette, `?` reference | ↑↓, R, E, U, ⌘⌫, ⌘K focuses search, ⌘N | **few keys, no reference** |
| Split inbox: Important / VIP / Team / Calendar / Newsletters / Other, each with counts | Important / Other tabs with unread counts, user votes, sender rules | partial |
| "You're done" state per split | `InboxDuskView` "All caught up" for an empty tab | ✓ (could offer "Clear Other") |
| Remind me if nobody replies (sent mail) | Follow-up flag only | **missing** (wave 2) |
| Send later | None | missing (wave 2; needs the app open or the backend) |
| AI: instant replies, one-line summary above every email | Inline ✦ writing, agents' prepared replies, Jev excerpt | partial (wave 2) |
| Snooze returns with a notification | Returns to the Inbox silently when the time passes while Cove is open | **no notification** |
| iPhone: swipe to snooze, same presets | No snooze on iPhone | **missing** |
| Read statuses | None | **skip**: conflicts with Cove's privacy stance (no tracking) |
| Dense single-line rows | 106-point rows with preview and badges | design decision; not in this wave |

The biggest multipliers for inbox zero, in order: Mac multi-select with one-key bulk actions, Z undo so
acting fast is safe, a real snooze (presets, H, rows, iPhone, a notification when it comes back), and
consistent auto-advance.

## Wave 1 (this branch, `scarranca/inbox-zero-triage`)

Shared seams, written first so the agents compile independently (commit "Triage seams"):

- `CoveCore/SnoozePreset.swift`: `laterToday` (+3 h to the next quarter hour, today only), `thisEvening`
  (18:00), `tomorrowMorning` (9:00), `thisWeekend` (Saturday 9:00; next Saturday from the weekend),
  `nextWeek` (Monday 9:00, never today). `date(from:calendar:)` is nil within 30 minutes or in the past;
  `available(from:)` lists what's worth offering; `describe(_:)` gives "Today 1:30 PM", "Tomorrow 9:00 AM",
  "Sat 9:00 AM", "Oct 21, 9:00 AM". Tests: `SnoozePresetTests`.
- `AppStore`: `selectedIDs: Set<String>` (never part of `VisibleKey`), `triageUndo: TriageUndo?`,
  `showShortcutHelp`, `snoozeRequestID`.
- `Cove/MailTriage.swift`: `TriageAction` (archive, moveToInbox, markRead, markUnread, flag, unflag, trash,
  snooze(Date?)), `TriageUndo` (message, reselect, restore closure), `triageTargets(for:)`,
  `inboxMails(in:)`, `triage(_:_:)` (stub: loops `modify`), `snooze(_:preset:)`, `undoLastTriage()`.

### Agent A — Mac triage core (Opus 5.5)

Owns `Sources/Cove/AppStore.swift` (the only agent allowed to edit it), `MailTriage.swift`,
`MailNavigationShortcut.swift`, `Tests/CoveRenderingTests/MailNavigationTests.swift`, new
`MailTriageTests.swift`.

1. `triage(_:_:)` for real: apply through `modify`/`queueTrash`/`snooze(_:until:)` (bulk of more than 25
   emails may use `applyBulk`), one `TriageUndo` for the whole set, clear `selectedIDs`, and advance:
   when the open email leaves the current list, select the next one below (or the one above at the end),
   exactly like E does today. Archive/Snooze/Trash from the reader toolbar and row actions must call it
   so they advance too.
2. `undoLastTriage()`: exact reversal (archive ↔ moveToInbox, read ↔ unread, flag ↔ unflag, snooze ↔ the
   previous `snoozedUntil`, queued trash → `undoQueuedTrash`), then reopen the email.
   `triageUndo` is replaced by the next action and cleared on folder/account change (`mailboxGeneration`).
3. Keys in the existing guarded switch (yield to editors, sheets, popups, other screens): J/K as
   aliases of ↓/↑; S flag toggle; H → `snoozeRequestID = id`; X toggles the open or hovered email in
   `selectedIDs`; Shift+↓/↑ extend the selection while moving; ⌘A (only with the list focused and no
   editor) selects all visible; Esc clears the selection first, then the reader; Z →
   `undoLastTriage()`; ⇧E = move back to Inbox; C = `newDraft()`; `?` → `showShortcutHelp = true`.
   E/U/S/H/⌘⌫ act on `triageTargets(for: selectedMail)`.
4. Selection hygiene: `selectedIDs` cleared when folder, search, inbox tab or account changes and when
   emails leave `visible`; `reconcileSelection` prunes it.
5. Tests: every key with the `letter()` helper; bulk E on three chosen emails archives all three with
   one Undo; Z restores and reselects; shortcuts still pass through to editors.

### Agent B — Mac UI (Sonnet)

Owns `ReaderView.swift`, `MailViews.swift`, `UnselectedMailView.swift`, `InboxDuskView.swift`, new
`ShortcutHelpView.swift`, new `MailSelectionBar.swift`, rendering tests (unique PNG names).

1. Snooze menu (reader toolbar and the assessment's Remind me): `SnoozePreset.available()` with the date
   beside each title, "Pick a date…" (native date picker in a popover, min = now + 30 min), "Return to
   inbox" when snoozed; the detail line keeps `store.snoozeSyncDetail`; drop "Notifications are not
   available yet" (Agent C adds the notification). The menu opens when `store.snoozeRequestID == current.id`
   (then clears it).
2. Rows: a snooze quick action beside Archive; a selection ring/check at the left that appears on hover
   and stays when chosen; chosen rows use `Palette.mailSelection`-adjacent tint; a selection bar above
   the list ("3 selected · Archive · Read · Flag · Snooze · Delete · ✕") that calls
   `store.triage(store.triageTargets(for: nil), …)`.
3. Undo toast for `store.triageUndo` on the `InboxMoveToast` pattern (message · Undo · Z), replacing
   itself per action, Reduce Motion honored.
4. Empty Important tab: when Other has mail, offer "Archive all N in Other" (`inboxMails(in: .other)` →
   `triage(…, .archive)`), with the count and one Undo. Keep the dusk scene.
5. `?` sheet (`ShortcutHelpView`): every mail key in Cove's typography, grouped (Move, Act, Select,
   Write, Go). Update the status hint and `UnselectedMailView` keycaps to teach E, H, X, Z and `?`.

### Agent C — iPhone/iPad snooze and the return notification (Sonnet)

Owns `Sources/CoveMobile/*`, new `Sources/Cove/SnoozeNotifications.swift`, `Sources/Cove/CoveApp.swift`
(one start line), `Sources/Cove/AgentNotifications.swift` if the notifier protocol needs a snooze method.

1. iPhone: `MobileMailbox.snooze(_:until:)` persists through `update(id)` (saveMessage); the Inbox hides
   snoozed mail until its time (`computeVisible`, with a minute-level recompute and on foreground); a
   Snoozed folder; reader toolbar Snooze menu and a leading-edge swipe with the same `SnoozePreset`s;
   Undo through the existing pending-change window if it fits, otherwise a "Return to inbox" action.
   Copy says "on this iPhone" — iPhone snoozes do not sync to the Mac (the Mac's cloud snooze API is not
   wired on iPhone; say so, don't wire it in this wave).
2. iPhone and Mac: schedule a local notification at the snooze time ("Back in your inbox · sender ·
   subject", never the body) with `UNUserNotificationCenter` time triggers; cancel it on unsnooze, archive
   or trash; tapping opens the email (Mac: `openNotifiedMail`). On the Mac use the agents' notifier
   plumbing (`SystemAgentNotifier`), permission requested on first snooze with clear copy; if permission
   is denied the snooze still works and the menu says notifications are off. State honestly in the audit
   whether a scheduled Mac notification fires when Cove is closed (verify or label unverified).

## Rules every agent follows

- Build with Xcode: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; `swift build`,
  `swift test --filter …`; the iPhone library builds with
  `xcodebuild build -scheme CoveMobile -destination 'generic/platform=iOS Simulator'` (after
  `scripts/ios/generate-project.sh` if the project is missing).
- Every Gmail change goes through `modify`/`applyBulk` (Mac) or `change` (iPhone) so sync reapplies it;
  never restore by snapshot. Trash keeps its Undo window and pointer-follow behavior.
- `busy` never blocks triage; rate limits are a status line. No real mail, no launching Cove.
- Design: Inter roles, `Palette`, `.help` on every control, `PrimaryButton`/`SecondaryButton`, Reduce
  Motion on anything animated, no native bezels. Mac parity for anything that lands on iPhone.
- Not in this wave: send later, remind-if-no-reply, VIP/Team splits, dense rows, read statuses (never).

## Wave 2 candidates

- Remind me if nobody replies (sent mail → Snoozed with a thread check when it returns).
- Send later (local scheduler while Cove is open; honest about it).
- A one-line summary above each conversation and "Instant reply" (three short drafts) with the
  connected writer, cached per email.
- More splits (VIP from About you / Contacts favorites, Calendar invitations, Newsletters).
- A compact row density setting.
- ⌘K command palette (search stays the default mode).
