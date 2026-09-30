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

## Suites

- Full offline run: core 230 passed (1 skipped), rendering 296 passed (7 skipped).
