# 0.1.52 — Tasks from email (Google Tasks)

- **Request:** the user sent Millet "of course I'll add this to your account" and wants the promise kept. They asked for Jev to check sent and received mail, an AI-powered way to create tasks, a cool after-send animation, and no tasks from marketing or sales mail.
- **Google Cloud (September 30):**
  - The Tasks API was enabled in `cove-mail-20260922` with `gcloud services enable tasks.googleapis.com`.
  - After the user confirmed with their passkey, `https://www.googleapis.com/auth/tasks` was added in Google Auth Platform → Data Access. Google shows "Data access changes saved", and the sensitive scopes are now tasks and calendar.events alongside gmail.modify.
- **Sign-in:**
  - New scope `tasks`, requested with `include_granted_scopes` and a login hint.
  - `tasksConnected` is optional (Keychain back-compat). Both the Calendar and Tasks flags are read from the granted `scope`.
  - Tests: `TaskDetectionTests.testSessionsSavedBeforeTasksStillDecodeAndScopesAreKept`.
- **Eligibility:** bulk/automated, no-reply, Other-tab and Jev newsletter/update/purchase mail never reach Jev. The user's sent mail is always eligible. Test: `testOnlyPersonalAndSentMailIsEligible`.
- **Jev gate:** a fixed custom-agent instruction. It runs once per email, and the result is saved on `Mail.taskCheck` and kept by `GmailSyncResult.merging`. It is never run on sample mail or without a TypeSafe key. The reader runs it when an email opens; a send runs it on the sent text.
- **Extraction:** the `.extractTasks` prompt treats the email as untrusted and extracts commitments (sent) or requests (received). Parsing is strict: JSON only, at most 5 tasks, titles up to 120 characters, dates validated (never guessed). It runs only on click. Test: `testSuggestionsAreParsedStrictly`.
- **Creation:**
  - `TaskSuggestionsView` shows checkboxes, editable titles and optional due dates, with one primary "Add N tasks" button (or "Connect Google Tasks").
  - Tasks go to `@default`, with notes that link to the Gmail thread. Rate limits back off.
  - Test: `TasksFlowTests.testJevChecksEligibleMailOnceAndApprovedTasksReachGoogleTasks`: marketing gets no Jev call, the check is saved once, suggesting creates nothing, and approval creates the task with its link.
- **UI:**
  - After-send toast: "Sent" with the tide wave while checking, then "Sent · you made a promise" with **Create task** (12 s), or a plain "Sent".
  - In the reader: a "Create tasks" toolbar icon when Jev found something, and **Find tasks** in the More menu.
  - A Tasks screen (sidebar ⌘5) with open tasks, completion, due dates (overdue in red) and a link to the source email.
  - A real Google Tasks card in Integrations.
  - Renders inspected: `/tmp/cove-tasks-toast-found.png`, `/tmp/cove-tasks-screen.png`.
- **Fixed during QA:** Google's midnight-UTC due date showed one day early in Pacific time. It is now read as a calendar date, with a test.
- **Not verified live:** the Google consent with the new scope, real Jev and model quality, and real Tasks creation. These need the user's reconnect in QA.

## Tasks redesign with AI (September 30)

- **User feedback:** the detail view "is not SUPER good", the due date is "super old school", and the task list needs AI.
- **Details:**
  - A large checkbox with a spring fill, and an in-place title in the page-title style.
  - Due-date chips: Today / Tomorrow / Next week / Pick date (a graphical calendar popover) / ✕.
  - Plain notes. Changes save automatically (about 0.9 s after typing, and immediately for dates) with "Saving… / Saved". Cove's source lines are preserved.
  - Subtask checklist.
  - **Get it done:**
    - Draft a reply, or "Tell <name> it's done", on the source email via `draftReply`. It opens the reader for review; nothing is sent.
    - Break into steps: the `.taskSteps` prompt returns 2–5 steps; the user approves them and they become Google subtasks (`parent`), kept in order.
    - Find time: the first free 30 minutes today or tomorrow, 09:00–18:00, from the real calendar, then Add to calendar.
  - A tappable source-email card.
- **List:**
  - Quick add with instant date parsing (`TaskQuickAdd`: today/tomorrow/mañana plus `NSDataDetector`; a live date chip).
  - Groups: Overdue / Today / Tomorrow / Upcoming / No date, with subtasks indented and a collapsed Done group.
  - ✦ Plan my day: the `.planDay` prompt picks at most 3 tasks, limited to real task ids, each with a reason and a duration snapped to 15/30/60/90. Each pick has Find time → Add at the time found.
- **Tests:** `TaskQuickAddTests`, `TaskDetectionTests` (update and clearing a due date), and `TasksFlowTests` renders (`/tmp/cove-tasks-detail.png`, `/tmp/cove-tasks-screen-grouped.png`), all inspected.
- **Not verified live:** the model's quality for steps and plans, real subtask ordering in Google Tasks, and the reply draft on a real thread.

## Related context for tasks (September 30)

- **Request:** "Call Millet" should look through the latest emails for anything matching Millet.
- **`TaskContext`** runs locally, with no model and no network:
  - It takes the task's meaningful words, ignoring English and Spanish filler verbs.
  - Contacts are matched by first name, last name, address or full name, ignoring case and accents; the most frequent correspondents come first.
  - The latest emails with those people are shown, one per conversation. With no matching person, it shows emails containing every keyword.
  - Upcoming meetings with those people (as guests, or named in the title) are shown too.
- **Details panel, Related section:** a person card with email and call (when the contact has a phone), the upcoming meeting, and the latest emails.
  - Each email opens on click; **Link** makes it the task's source, and the link syncs to Google Tasks through its notes.
  - List rows show the matched person when the task has no source email.
- **Performance:** `AppStore.contacts` was rebuilt from all mail on every read. It is now cached by mail revision, contact records and account.
- **Tests:** `TaskContextTests` (names, accents, Spanish, newest-first per conversation, keyword fallback, meetings) and `TasksFlowTests` (the Related render, `/tmp/cove-tasks-related.png`, inspected).
