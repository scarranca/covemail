# Cove 0.1.51 — QA audit (unreleased)

## Gmail rate limits (the "gmail.googleapis.com returned 403" alert)

- **Evidence:**
  - On September 29 the user's 0.1.50 made about 200 Gmail requests over 22:36–22:38, then got 46 fast 403s interleaved with occasional 200s (CFNetwork summaries in the unified log; no URLs or content were read).
  - That pattern matches Gmail's per-user rate limit. It was not proven, because Cove discarded Google's reason.
- **Fix:**
  - `checked()` now keeps only Google's reason identifier (`error.errors[0].reason`, `details[].reason` or `status`, restricted to `[A-Za-z0-9_]`), never its message text.
  - Rate limits (429, or 403 `rateLimitExceeded` / `userRateLimitExceeded` / `RESOURCE_EXHAUSTED`) and missing scopes get specific messages.
  - `GmailClient.request` retries rate-limited requests (any method; Google did not perform them) and GET server errors, with exponential backoff plus jitter (1–32 s, 5 retries). Sends and label changes are never retried after a server error.
  - Bulk loops (page, research fetch, history updates) are paced to about 20 requests per second via `GmailPacer`. A rate limit pauses all bulk work. Interactive requests are not queued.
- **Tests:** `GmailRateLimitTests`. `ReaderConversationTests.testOfflineAndSampleKeepCachedConversation` now expects 6 requests (1 plus 5 retries) for a GET returning 503.
- **Next step:** if a 403 recurs, its message now names Google's reason, which will confirm the cause.

## Calendar

- **Event details:** the actions are one quiet icon row, reusing `ReaderActionStyle` like the email reader: back, Meet, email, open in Google, edit, delete. Sync moved to an icon in the header. Test: `CalendarSeparationRenderingTests.testSelectedEventShowsQuietIconActions`; the screenshot was inspected.
- **Drag on empty grid space:** opens the editor prefilled with that span, snapped to 15 minutes. A click proposes an hour. Nothing is created until the user saves.
- **Drag an event:** moves it, keeping its duration, across days of the visible week. Dragging its bottom 8 points changes the end time.
  - Only timed events that are local or organized by the user are movable (`LocalEvent.canReschedule`). Invitations and all-day events stay put, and clicks still open them.
  - The change saves immediately, with a six-second Undo notice. An event with other guests asks first: Google updates their calendars without emailing them, and for a repeating event only that occurrence moves.
  - A drop during a sync explains why nothing changed.
- **Tests:**
  - `CalendarDragTests`: snapping, direction, clamping, cross-day moves, the minimum length and permissions.
  - `CalendarDragInteractionTests`: drives the real SwiftUI column with synthesized mouse down/drag/up events and checks that click, move, edge resize, blank-space creation and a fixed invitation each behave correctly.
- **Test exception:** SwiftUI gestures only run in an ordered window. This test orders its window with `orderFrontRegardless` at alpha 0 and 40,000 points off every screen, and never activates the app, so nothing appears on or takes focus from the user's Mac.
- **Not done:**
  - Dragging in Month view.
  - Dragging all-day events.
  - Moving the confirmation for guests into a Google-style "notify guests?" choice.
  - An end-to-end drag through the whole `CalendarView` (the commit path reuses `createEvent(editing:)`, which is already covered).

## Reopening the window

- **Report:** "sometimes the app can't open, it shows the dot of open, but is not opening again."
- **Evidence:** the user's running 0.1.50 (pid 61924, idle at 0% CPU) had no main window, only two 39-point off-screen helper windows (window metadata read via `CGWindowListCopyWindowInfo`, no contents). The window had been closed and the Dock click never created a new one.
- **Fix:** `CoveAppDelegate.applicationShouldHandleReopen` decides explicitly.
  - Cove's own main windows are tracked (a window is removed when it closes).
  - A minimized or hidden window is restored.
  - With none left, a new window opens via SwiftUI's `openWindow(id: "main")`.
  - The mailbox, drafts and sync live in app-level state, so a new window keeps them.
- **Tests:** `AppReopenTests` covers the decision rules, closed windows being forgotten, and the open path, with activation stubbed so tests never take focus.
- **Still to check:** a real Dock click in a QA build.

## Agent editor

- **Report:** "super hard to create one, a lot of noise."
- **New layout:** three numbered steps: What should it look for? (moved first) → Then (label, or rules and replies) → Name it.
  - The run trigger and the attachment option live under a collapsed Options section.
  - The notes about label reuse, unclear mail, "leave it as it is" and the safety banner became one muted line: "Unclear emails wait in Activity for you. Agents never send, delete or pay."
  - The test panel is titled "Try it". The TypeSafe and provider data disclosure is kept, shortened.
- **Checked:** screenshots at 1180 and 820 points (`CustomAgentEditorRenderingTests`) were inspected.

## Ask Cove: counts by sender, date or topic

- **Report:** "how many emails from ICE on the last week?" was refused ("Counts filtered by sender, date, or topic aren’t supported here yet").
- **Fix:** with Mail search on and a writing provider connected, a filtered count goes through `AppStore.countMatchingMail`.
  - The model writes the Gmail search (the same `.search` prompt as research), and `GmailClient.countMatches` counts every match exactly by listing ids only (500 per page, capped at 5,000, excluding Trash, Spam and Drafts).
  - The answer names the search used. The five newest matches are shown as sources and saved like cited emails.
  - Unfiltered folder counts keep their instant path. Without Mail search or a provider, the reply explains what to turn on.
- **Tests:** `GmailCountTests` (exact counting across pages, duplicate ids, cap) and `FilteredCountTests` (the question routes here, the model's search is used, the count is exact, stored copies are reused, and drafts and the sync cursor are untouched).
- **Limit:** the model chooses the date range ("last week" usually becomes `newer_than:7d`), and it is shown in the answer. The local index (phase 2) is not needed for this, because Gmail counts all mail, not just downloaded mail.

## Ask Cove: "first available time" and calmer chat

- **Report:** "create an event, for tomorrow at the first time available 10 min for focus" got the question "What start time tomorrow should I check…?"
  - Cause: the planner prompt told the model to ask whenever a start time was missing, and the assistant had no availability tool.
- **Fix:** a new planner action, `find` (title, day, duration and window: default 09:00–17:00, morning, afternoon, after/before).
  - Cove reads that day from the calendar and uses `WritingAvailability.firstSlot` to propose the earliest free interval as a reviewable event. Events marked free don't block, and past times are skipped.
  - A full day, or Calendar not connected, gets a specific question. The model still never invents availability.
- **Tests:** `AssistantCalendarTests.testFirstAvailableTimeIsFoundFromTheRealCalendarNotAsked`.
- **Chat UI:**
  - Answers are plain text instead of bordered cards.
  - Sources are a small "N sources" chip. Copy and feedback icons are smaller and muted.
  - The header icon lost its tile.
  - Mail search is a filled chip rather than a pill with a switch. It keeps an explicit focus outline, and the system focus ring is disabled because it drew clipped marks.
  - Renders inspected: `AssistantChatRenderingTests` design and compact sizes.

## Suites

- Full offline run: core 232 passed (1 skipped), rendering 301 passed (7 skipped).
