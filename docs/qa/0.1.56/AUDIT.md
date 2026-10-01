# Cove 0.1.56, build 58: tasks, calendar and Ask Cove, smoother

The user tested this work in QA builds 0.1.55-d through 0.1.55-s, which use the real account in isolated QA data.

## Changes

### Ask Cove
- **Tasks from chat:** a new router action `task`. It shows `AssistantTaskCard` (editable title, due day, source email). Nothing is created until **Add task**.
  - "Remove", "clear" and "get rid of" mean archive, which happens only when the user asked and an email is open; the card offers Undo archive.
  - A task request never asks for a time.
- **Meetings with a person:** a new action `meetings` uses `GoogleCalendarClient.search` (q, up to 4 pages, ≤3 years; default is the past year plus the next 90 days).
  - `CalendarSearch.with` keeps only events where the address is a guest or the organizer.
  - Names resolve to people in the open thread (`ContactDirectory.participant`): a matching name, or else the only participant outside the user's domain. The heading shows the address searched.
  - Agendas that cross years show the year.
- **Embedded chat:** resizable with a drag handle (double-click toggles), plus an expand button. Tall also widens it, and the size is remembered (`askPanelHeight`).

### Tasks
- **Never a dead end:** when Jev flagged an email but the model found nothing, the sheet offers an editable fallback to-do or "Nothing to do here", which dismisses the email. A model answer that can't be read shows an error with Try again (`TaskDetection.parsedSuggestions`).
- **Actionable automated mail:** eligible when Jev's needsReply ≥ 0.65 and it isn't a newsletter. The gate counts requests to pay, sign or approve.
- **Create task** sits on actionable Jev cards; it hides once a task exists.
- **Emails show their tasks:** `LinkedTasksStrip` under the sender, matched by `createdTaskIDs` or the Gmail link in task notes, across the conversation. It offers Done and Open (`openTaskID`). Tasks load once per session for the reader.
- **Date picker:** `CoveDayPicker` replaces the native graphical picker for task due dates and the event editor's day.

### Calendar
- **Guests:**
  - The editor has a guests field with contact suggestions and an "Add a Google Meet link" option.
  - `create`/`update` send `sendUpdates=all` only when there are guests or the guest list changed. Existing guests keep their responses, and only the organizer edits guests.
- **Describe an event (✦ by Cancel/Add, and the new + in the header, ⌘E):**
  - The model fills title, time, guests and Meet (`AIIntent.describeEvent`, `EventDescription`).
  - Guest names must match exactly one contact; otherwise they're listed, never guessed. Past or missing times ask.
  - "First open spot" leaves the time to `AppStore.firstOpenSpot`: the named day, or the next seven weekdays, using `WritingAvailability` over the real calendar. The model never picks a free time.
- **Meeting files:** Google Calendar attachments (Gemini notes, transcripts, recordings) appear as `CalendarFile` links (docs/drive.google.com only) in event details and Ask Cove agendas.
  - The user declined Drive read access for now, so Cove links to these files and never reads them.
- **⌘Delete** on the selected event opens the existing confirmation (`CalendarDeleteShortcut`). Text fields, sheets and syncs keep the key.
- **Zero-length events** (reminders) no longer fail the bounded calendar read or `firstSlot`.

### Mail
- **Empty inbox:** an empty Important or Other tab shows `InboxDuskView`, a 24 fps Canvas of a dotted sun, sea and birds. It is still under Reduce Motion or when the window is inactive.
- **Sidebar count:** the Inbox number is `inboxBadgeCount`, unread Important mail (all unread when the split is off). It used to count every Inbox email.
- **Accents:** a `Mojibake` repair re-reads UTF-8 text that was decoded as Latin-1/1252 ("botÃ³n" → "botón"), on decode and when stored mail loads.
  - Policy change: this replaces the snippet-corroboration-only rule. Literal mojibake text is now repaired too (two old decoding tests were updated deliberately).

## Verification

- Full offline suite: CoveCoreTests 278 (1 skipped), CoveRenderingTests 367 (7 skipped), 0 failures.
- Rendered and inspected: task card, day picker, inbox dusk, meetings agenda, linked-task strip, event editor (guests, describe line).
- Not run live: real Google Tasks/Calendar writes, guest invitations, real-model parsing of event descriptions.

## Release

- **App notarization:** `16cf4951-4e2f-4076-bb94-f2465c523cfe`, Accepted and stapled.
- **DMG notarization:** `14f7e625-c1f4-49e0-a1b2-2e45dabb44d7`, Accepted and stapled.
- **DMG:** 22,521,792 bytes, SHA-256 `116751f2f32629cc374457a0dc1ed0a191987a11797186b52e2c7d8d2cb4ccc2`.
- **Feed and site:** signed feed with 35 verified releases; Cloudflare Pages deployment `bf472c84`.
- **Public checks:**
  - `/release.json` reports 0.1.56 (build 58); the appcast and `/download/latest` serve 0.1.56; the beta page says "Download Cove 0.1.56".
  - The downloaded DMG matches the bytes and SHA-256 above.
  - The Ed25519 signature verifies with the bundled key, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
