# Cove 0.1.71 — sign-in codes

The user asked (October 11) for a notification "whenever you receive a code to sign in", on the device or in the menu bar.

## What it does

- **Detection** (`SignInCode`, CoveCore): deterministic, no model. A strong sign-in phrase (English and Spanish, accents folded) near a code-shaped token: 4–8 digits, digit groups (`482 913`), or 6–8 capital letters and digits with at least two digits (`K7Q-2PM`). The plain word "code" counts only in a subject that isn't a reply, and only for 6+ digits. Coupons, bookings, parcels, postcodes, meeting invitations (by phrase, never by bare domain) and card-ending digits are excluded. Only incoming mail from the last 10 minutes, never Sent, Drafts, Spam or Trash.
- **Mac** (`SignInCodes.swift`): after each sync, emails that just arrived are checked once each. The newest code shows as a transient menu bar item (`key 482913`, click copies, removed after 10 minutes or on copy) and, when notifications are allowed, a notification with Copy code that is removed after 10 minutes. Settings → Menu bar → Sign-in codes (`codes.enabled`, `codes.notify`, both on by default; turning notify on asks macOS once).
- **Faster arrival on the Mac**: on the 30-second tick between two-minute syncs, `probeForNewMail` reads Gmail history (2 quota units) and syncs early only when new Inbox mail is there. Not before 60 seconds on battery, never while Gmail is unreachable, only while sign-in codes are on.
- **iPhone** (notification extension): `NewMailAlert.signInCode` runs before the usual alert, so a code notifies even under "Important" (code senders are automated and would be in Other). Muted senders and mail already read elsewhere still don't. The title is the code; category `cove.sign-in-code` has Copy code (needs unlock), Mark as read and Open. With "Show sender and subject" off, the code is hidden. Delivered codes are removed after 10 minutes. Settings → Notifications → Sign-in codes.
- **Deliberate privacy exception**: notifications showed only sender and subject. The extracted code is now the one piece of email text shown, and only when previews are on. Recorded in AGENTS.md and the Settings copy on both platforms.

## Verification

- Full Mac suite before release: 345 core tests (1 skipped) and 455 rendering tests (7 skipped), 0 failures.
- New tests: `SignInCodeTests` (positive and negative fixtures, freshness, the iPhone alert rules), `SignInCodeNoticeTests` (Mac: only fresh arrivals, once, never the user's own mail), `MailboxPollingTests.testProbeBetweenSyncsSyncsEarlyOnlyForNewMail`, and `TrashUndoHitTests` (a real click on the Trash toast's Undo in the full window restores the email).
- `MailboxPollingTests` fixture: history entries now carry `labelIds` (`INBOX`, `UNREAD`), as Gmail sends them.
- Settings → Menu bar rendered and inspected (`/tmp/cove-settings-Menu bar-900.png`).
- Builds: Mac app, `CoveMobile` (iOS Simulator) and the iPhone app shell with the notification extension.

## Not verified

- Not run against real mail, in the running Mac app or on a device.
- The iPhone Copy code action writes the pasteboard from a background action. Unverified; if it fails on a device, make the action `.foreground`.

## Separate report: Trash Undo "does nothing" (0.1.70, ⌘Delete)

Not reproduced. A real mouse click on Undo in the full window (widths 1000–1700, HTML email open, Reply ▾ split button below, offline status line showing) restores the email every time; the installed app is the same code (0.1.70, build 72). No code change. Next step when it recurs: check whether Z restores during the countdown (same `undoQueuedTrash`), then a QA build with logging.
