# Cove 0.1.49 (unreleased) — large questions across mail

## Problem (user screenshot, September 29)

Ask Cove with Mail search turned "angel hub" into `{from:"angel hub" to:"angel hub"}` (a topic treated as a person), found nothing and stopped with "No emails matched". Answers covered at most 20 emails: `GmailClient.search` capped at 20 sequential fetches, `SourcePassages(mailbox:)` at 20 candidates, and `AIPrompt` at 20 emails / 48 KB. Gmail searches also needed a manual review step.

## Change

- **Query rules (`AIIntent.search`):** topics, companies and events are searched as full text (keywords, quoted phrase, OR variants); `from:`/`to:` only when the user means a sender/recipient or supplies an address; never `{from:X to:X}` for a topic; dates only when asked. Follow-ups pass recent conversation so "and the fees?" keeps its topic.
- **`GmailClient.research`:** paginates `messages.list` up to 100 matches and reports Gmail's estimate and whether more pages exist (`hasMore`). Messages already stored locally are reused; new ones are fetched 5 at a time.
- **`MailboxResearch` (CoveCore):**
  - One Gmail query, retried with deterministic broadening when nothing matches (operators, braces, quotes and exclusions removed).
  - Up to 20 matches: one assistant-answer pass. More: batches of 20 (≤2,000 characters per email) produce bounded `[n]`-cited notes (new `researchNotes` intent; email text is untrusted), and citations are remapped to global emails using only emails that fit in each prompt.
  - The final structured answer (Draft-reply card still works) uses the 20 most-cited emails as numbered sources plus the notes as evidence, budgeted under the 12 KB evidence limit including history and header.
  - The source line says truthfully "Read all N matching emails" or "Read N of about M matching emails (partial)", plus the queries used. Zero results after broadening give an honest answer listing the searches tried.
- **Ask Cove:** the Mail search toggle now means *search all of Gmail* (on by default) vs *downloaded mail only* (now up to 100 candidates, also batched). The manual "Review Gmail search" card and its state were removed. Research results stay in memory; only emails the answer cites are saved locally (so source links open), so a question never adds 100 emails to the mailbox or the cloud mirror. Progress shows each step ("Reading emails 41–60 of 97…"). Selected-email and thread questions are unchanged.
- **Tests:** `MailboxResearchTests` (6: broadening, citation remap, 45-email batching with ≤20 final sources and no leaked global numbers, small/empty results, evidence budget and partial marking, Gmail paging with stored-mail reuse). Full offline suite: 490 tests (280 rendering + 210 core), 0 failures, 7 skipped.

## Review fixes

- Progress callbacks are `@MainActor`, so UI state is never mutated off the main thread.
- Cited emails are saved from `outcome.read` (full bodies), not the shortened prompt excerpts.
- The downloaded-mail path reports partial when it reaches its 100-candidate cap.
- Prompt and intro examples are neutral (no real user topics).
- Losing or switching the model no longer silently turns off Mail search (the toggle is disabled without a model).
- The email writer's `search_mail` tool still uses the 20-result `aiSearchMail`; it was out of scope.
- Full offline suite after fixes: see the commit; `MailboxResearchTests` (6), `AssistantChatRenderingTests` (2) and `AssistantCalendarTests` (12) pass.

## Limits

- At most 100 Gmail matches per question (newest first); more are reported as partial.
- Large questions make 1 + ceil(N/20) + 1 model calls (about 7 for 100 emails). With a subscription CLI model this can take a couple of minutes; progress stays visible.
- Not yet checked live on a real account (Cove QA was deleted at the user's request; a live check needs a new QA build and sign-in, or a release).

## September 29 — assistant actions and memories

- **Memories:** `Preferences.memoryPrompt` gives bounded (≤30 × ≤200 characters, one line each) saved memories, only when "Use my saved memories" is on. They reach every writer (`ComposeSuggestion.instruction(memories:)`: reply sheet, composer, agent replies, chat drafts) and assistant answers (mailbox research, selected email, briefing), labelled as the user's own notes, not email facts.
- **New router actions (`planAssistant`)** with guards in `AssistantCalendar`:
  - `remember` / `forget`: memory text only from the user's request, sanitized to one line. Stored in encrypted preferences and editable in Agents → Memories.
  - `reply`: only with a selected email, otherwise a clarification.
  - `contact`: a name as typed.
  - `brief`: today's overview.
- **Reply from chat:** `AppStore.draftReply` uses `WritingAgent` (voice, memories, read-only mail/calendar lookups), saves the text as the email's draft, selects it and closes the assistant. Nothing is sent.
- **New emails and introductions from chat:** now also use `WritingAgent` via `assistantWriter`, so "schedule a meeting at my first available time" uses real calendar availability. Without Calendar, the existing visible error is shown and no draft opens.
- **Contact questions:** answered deterministically from `RecipientResolver` and downloaded mail (address, count, most recent date, three recent conversations, company). No model and no guessed addresses; ambiguity asks.
- **Briefing:** today's events (live when Calendar is connected), pending invitations and up to 15 inbox emails (priority and unread first), summarized in one cited answer with a coverage line.
- **UI:** "Brief me on today" and "Draft a reply" suggestions, and updated empty-state copy.
- **No new mutations:** nothing sends, archives, labels or deletes.
- **Tests:** `AssistantMemoryTests` (1), `AssistantActionTests` (5: router guards, remember/forget and writer injection, contact summary, reply saved as a draft with no send, availability requires Calendar); `AssistantComposeTests` updated for the writer planner. Full offline suite: 496 tests (285 rendering + 211 core), 0 failures, 7 skipped. Not yet run on a real account.
