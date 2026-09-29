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

## Limits

- At most 100 Gmail matches per question (newest first); more are reported as partial.
- Large questions make 1 + ceil(N/20) + 1 model calls (about 7 for 100 emails). With a subscription CLI model this can take a couple of minutes; progress stays visible.
- Not yet checked live on a real account (Cove QA was deleted at the user's request; a live check needs a new QA build and sign-in, or a release).
