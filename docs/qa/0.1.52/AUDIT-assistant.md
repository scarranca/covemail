# Cove 0.1.52 (unreleased): Ask Cove context, navigation and approval-gated bulk changes

Branch `worktree-agent-a54025f8ff0729bec`, merged with `scarranca/secure-incremental-mail-cache` at `1f20f97`. Not released, pushed or deployed.

## What changed

- **Screen context.** `AppStore.assistantScreenContext()` builds an `AssistantScreenContext` (screen; folder or label and visible count; search; selected email subject, sender and thread size; calendar day; selected event title and time). `promptText` flattens every field to one line, bounds each one and caps the whole context at 1,500 bytes. The router receives it as untrusted evidence, not as the instruction. The planner prompt now resolves "this" and "it" to the selected email, or to the selected event on the calendar screen, and "these" and "this label" to the current view. It says never to ask which item is meant when the context names it.
- **New router actions** (`AssistantCalendar.respond(_:screen:)`):
  - `navigate` accepts only mail, calendar, contacts, agents or home. Folders map to the sidebar names (Starred → Flagged). Labels must match one of the user's labels by full name or visible name. An unknown label returns a question that lists close matches and never guesses. Days must be valid `YYYY-MM-DD`. A requested search is applied after `chooseFolder`, because `chooseFolder` clears it. The chat shows "Opened Drafts." and closes.
  - `view` answers questions about the up to 20 newest emails in the current view ("summarize this label").
  - `bulk` covers archive, markRead, markUnread, star, unstar, addLabel and removeLabel, with scope `current` or `query` plus `exclude`. Trash, delete and send are not in the enum, so they fail to decode. The prompt also tells the model they are unavailable.
  - `move` reschedules only the selected calendar event. It keeps the event's length unless an end is given and checks for overlaps. The card's primary button is "Move event". It notes when guests will see the change, and Undo moves the event back.
  - Mail-side questions use a new `.question` result, so they are no longer labelled "Calendar · nothing created".
- **Bulk approval card** (`AssistantBulkCard`):
  - Review shows "Archive 23 emails" with the scope and how many emails were left out because they were already in that state. It lists the first 8 emails (sender · subject), then "and 15 more". It has one primary button ("Archive 23") and a quiet Cancel.
  - While running, it shows a progress bar with "Archiving 13 of 23…".
  - When finished, it shows "Archived 21 · 2 failed", the reason for each failure (up to 5 listed), and a secondary Undo.
- **Resolution and execution** (one extension at the end of `AppStore.swift`):
  - `resolveBulk` only reads. `current` uses `store.visible`, optionally narrowed by `AssistantMailFilter` (words, quoted phrases, from:, to:, subject:, is:, label:, negation). `query` uses Gmail `countMatches` ids (cap 500; `capped` shows "limited to the first 500") and headers-only `format=metadata` for emails not stored on this Mac. Those emails are never added to the store. With Mail search off, or in sample mode, `query` searches downloaded mail locally.
  - Drafts, Spam, Trash and queued-trash emails are never targets. Emails the change would not affect are left out, so Undo restores the previous labels exactly.
  - `applyBulk` waits for `busy` to clear (45 s, then every email fails with a clear message and nothing changes). It holds the mutation slot for the batch and applies each email through the same `applyLabelChange` path as `modify`, which is now shared: Gmail first, then the local copy and store. Gmail calls go through `modifyPaced` (GmailPacer plus the existing 429/403 backoff). It awaits pending mark-as-read tasks and records each email's success or failure. Undo runs the inverse on exactly the emails that succeeded.
- **One call to action.** The empty state is a short title, one short line and three compact suggestion chips that fit the current screen (for example Brief me on today, Summarize these, Open my drafts), replacing the long paragraph. Each card has at most one primary button. The move card drops Edit.
- `AGENTS.md` now records the approval-gated bulk rule and the fact that the assistant still cannot send mail, trash anything or delete permanently.

## Verified

All runs are offline with injected transports, temporary databases and hidden windows. No Gmail, Calendar or provider calls were made, and no window was ordered front.

- `swift build` passes.
- New tests in `Tests/CoveRenderingTests/AssistantScreenBulkTests.swift` (10 tests, all passing):
  - The context reaches the router in `prompt.evidence`, not `prompt.user`. It contains the label, visible count and selected email, and the system prompt contains the bulk action and the "never ask which" rule. A pathological 20 KB multi-line context stays ≤ 1,500 bytes with short lines.
  - "Move this to 3pm" with a selected event returns a proposal carrying that event's id and its 45-minute length. With no event selected, the router asks the user to open the event.
  - Navigate:
    - "drafts" opens Drafts, and the assistant closes.
    - The nested label `Finance/Receipts` matches "receipts", and its search survives `chooseFolder`.
    - "Newsleters" asks with the suggestion "Newsletters", and a label with no close match also asks.
    - The settings screen is refused, 2026-02-31 is rejected, and a valid day opens Calendar.
  - "Archive these" in a label view resolves to exactly the visible Inbox emails, with no draft and "1 already archived". Exclude drops a sender. Gmail receives no requests and no labels change before Approve. `operation: trash` fails to decode.
  - Approve sends Gmail modify requests for exactly the listed ids, removing INBOX. No trash, send or DELETE request is made, unlisted mail is untouched and `busy` is released. Undo restores the exact previous labels.
  - A 400 on one email is reported with its subject and message. That email keeps its labels while the others change.
  - Gmail-search scope lists remote emails by headers only, reuses stored emails, never adds remote mail to the store, and Approve changes all listed ids.
  - In sample mode the transport fails the test on any request. Zero requests were made and the local labels changed.
  - Cap at 500 with the "limited to the first 500" detail, and the local filter operators.
- Full suite: CoveRenderingTests 321 tests (7 skipped), CoveCoreTests 232 tests (1 skipped), 0 failures.

## Screenshots inspected

- `/tmp/cove-assistant-bulk-review.png`: the card with 8 rows, "and 15 more", a primary "Archive 23" and a quiet Cancel.
- `/tmp/cove-assistant-bulk-running.png`: progress bar and "Archiving 13 of 23…".
- `/tmp/cove-assistant-bulk-finished.png`: "Archived 21 · 2 failed", the per-email reasons and a secondary Undo.
- `/tmp/cove-assistant-move.png`: the move card with a single "Move event" primary.
- `/tmp/cove-assistant-empty.png`: the short empty state with three chips.
- `/tmp/cove-assistant-artifacts.png`: the existing event and draft cards, unchanged.

## Not verified / limits

- No live model has routed real requests. Routing quality ("these", "this label", navigate vs. email) depends on the provider following the updated planner prompt, so it needs a live check with a connected model.
- No live Gmail bulk run. Pacing (about 20 requests per second) and 429 backoff are exercised only by existing unit tests. A 500-email change takes roughly 25 seconds or more plus header fetches for remote matches.
- The move action's store path (`createEvent(editing:)` and move-back Undo) reuses the Calendar drag code but has no dedicated automated test. Only the router and the card rendering are tested.
- Chat exchanges are view `@State`. An approved bulk change keeps running after the chat closes, but closing the chat loses the result card and its Undo button. The change itself is complete and visible in Gmail and the mail list.
- While a bulk change runs, Cove's mutation slot is held, so sync and other label actions wait. That is the same rule as other writes, only longer.
- Navigating to a label only calls `chooseFolder("label:…")`, the same call the sidebar makes. Whether older, uncached label mail then loads depends on the mail view reacting to the folder change. That was not verified here, because it lives in `MailViews.swift`, which belongs to another agent.
- The local filter (sample mode, or Mail search off) ignores Gmail operators it doesn't know, such as `newer_than:` and `after:`. Those results can be broader than the equivalent Gmail search. The card lists every email, so the user sees exactly what would change before approving.
- Resolving a 500-match Gmail query fetches headers for uncached matches before the card appears (up to about 25 s), and the progress line shows no count during that time.
- The move card's destination comes from the event itself (Google or this Mac), not from whether Calendar is connected.
- `current` scope uses `AppStore.visible` as-is. If the Important/Other inbox split changes what `visible` returns, "these" follows that change.
