# 0.1.52 — New-user setup (Connections)

Problem: a new user could open Agents and turn on Jev without an AI account or TypeSafe key, and Integrations did not say what to connect or why.

## Changes

- **Integrations → Connections** (sidebar, menu and settings sidebar). One hub with "N of 5 connected" progress and one row per step: Gmail, AI writing and chat, Jev (TypeSafe key), Calendar, Tasks. Each row says what it powers and has a single action; the first missing AI/Jev step expands on open. The sidebar shows a badge with the remaining count.
- **Inline Jev key** (`JevKeyField`): saves to the Keychain via `Vault`, reads it back to verify, records only a non-secret flag (`setup.jevKeySaved`) so status checks never trigger Touch ID.
- **Gates**: Agents list and Settings → Jev show `JevRequiredBanner` with the key field inline when no key is saved; the Jev toggle is disabled until then.
- **Home**: dismissible `SetupChecklistCard` with the remaining steps; Calendar/Tasks connect directly, AI/Jev open Connections focused on that row (`AppStore.integrationsFocus`).

## Verification

- `swift test`: CoveCoreTests 247 (1 skipped), CoveRenderingTests 337 (7 skipped), 0 failures.
- `NewUserSetupRenderingTests` renders `/tmp/cove-setup-connections.png`, `/tmp/cove-setup-home-checklist.png`, `/tmp/cove-setup-agents-gate.png`; screenshots inspected.
- Not verified live: first-run on a clean Mac with a real TypeSafe key.

## Round 2 (user feedback: cards hard to use, agents feel like filters)

- `ConnectionRow`: the whole header is clickable, with a hover tint; rows with settings show a rotating chevron, others a chevron right when connected. Connected shows a pill; AI's subtitle shows the model and provider in use (the "Saved default" box is gone).
- Open AI writing: steps 1–3 are separate `SetupSubsection` cards (number turns into a check when done) on a shaded panel; Refresh is a small icon.
- Agents: `AgentsHeader` (dark, like Home) explains the value and shows live tags (on, filed this week, replies to review). `AgentFaceView` draws a three-quarter face from dots: a shaded height field with warm eyes and lips, and a reading line sweeping down every 9 s at 15 fps. It is still with Reduce Motion or when the app is inactive. The captions show real recent agent work, or examples marked "For example".
- `CustomAgentTemplate.all`: Finance (files invoices and drafts a reply to overdue reminders), Receipts, Client requests (label and draft), Meeting requests (draft), Hiring, Travel. They are shown as cards ("Start from an idea"; "More ideas" once you have agents). Each opens as a draft in the editor; nothing runs until it is turned on. `CustomAgentTemplateTests` validates every template.
- Verified: full `swift test` (CoveCoreTests 248, CoveRenderingTests 338, 0 failures). Screenshots inspected: `/tmp/cove-setup-connections.png`, `/tmp/cove-setup-agents-gate.png`, `/tmp/cove-setup-agents-header.png`, `/tmp/cove-agent-face.png`.
- Round 3 (user: "creepy"): the portrait is now painted only by its shadows. Dots gather on the side turned away from the light, along the outline and in painted strokes (brows, lids, soft irises, nostrils, mouth line); the lit side stays open. The jaw tapers, the eyes no longer glow, and the only warm tint is a faint one on the lips. Verified in `/tmp/cove-agent-face.png` (320×250, the header's size) and `/tmp/cove-setup-agents-header.png`.
- Round 4 (user: "super weird"; asked for a generated realistic portrait): the Higgsfield MCP (`https://mcp.higgsfield.ai/mcp`, user scope) generated four `gpt_image_2_5` portraits of a generated, non-real person (job `6c78e284-40b2-4b65-a7db-ccbfbc63e18d` chosen; about 0.25 credits). Its white background was removed locally by flood-filling from the edges; the result was cropped and saved as grayscale `Sources/Cove/Resources/agent-portrait.jpg` (36 KB). `AgentPortrait` halftones it on the dark card: dot size follows the light, so the lit side is drawn in dots and the shadow side and hair fade into the dark. The procedural face remains only as a fallback if the image is missing. `AgentPortraitHalftoneTests` checks orientation; renders inspected.

## Create agent: describe it, review the plan (user: "setting rules … should be the agent working")

- A blank agent opens with one question, "What should this agent do?". The user describes the job in plain words; there are three example chips, and ✦ Build agent (⌘Return) is the one action. With no AI account the button is replaced by "Connect AI", which opens Connections on the AI row; "Or set it up step by step" keeps the manual path.
- `AIIntent.buildAgent` asks the writing model for strict JSON (name, instructions, 1–5 rules with label/draft/both, notify, note). `CustomAgentBlueprint.agent(from:keeping:)` validates it: unknown actions and empty conditions are dropped; reserved labels downgrade to draft-only or drop the rule; at most 8 rules; the edited agent's id is kept; the result is always a draft. The model may explain in `note` what agents can't do (send, delete, archive, pay, calendar). Nothing is saved or run by building.
- The review shows "How it works" as numbered cards: When / Then / Says (reply gist), from `CustomAgent.plan`. Each card opens the existing step editor in place; there are Add a step and Describe it again. The name is editable in the title. What it looks for, attachments and where it runs sit under one disclosure. Try it and the save buttons appear only once there is a plan.
- Tests: `CustomAgentBlueprintTests` (3); editor renders `/tmp/cove-agent-editor-1180.png` (describe) and `/tmp/cove-agent-editor-plan.png` (plan) inspected. Full `swift test`: CoveCoreTests 251, CoveRenderingTests 339, 0 failures. Not verified live: a real model's output for varied descriptions.
- Try it (user screenshot: native segmented control, popup menu, long body): it now uses `CoveSegmentedPicker`. Inbox email is a search field plus up to six sender/subject rows to click, instead of a popup menu. The chosen email is a compact card (sender, subject, 4-line snippet, Change). The result reads "It would act on this / leave this alone / isn't sure, so it would ask you", with how sure it is, the step it matched, the label, whether it drafts a reply and the quoted evidence. Render `/tmp/cove-agent-editor-inbox.png` inspected.

## Spam folder (user: "we don't have spam folder anywhere")

- The sidebar has a Spam folder (after Archive). It is a live Gmail view like label views: `mailScopeLabelID` is `SPAM`, and `GmailClient.page` lists spam only in that case (`q=in:spam`, `includeSpamTrash=true`); every other view still excludes it. Only the Spam view shows SPAM mail; Inbox, counts, search, Jev, agents and tasks keep excluding it.
- Actions: the reader toolbar shows Not spam instead of Archive for spam (it adds INBOX and removes SPAM). The reader's More menu and the list's context menu have Report spam (adds SPAM, removes INBOX and STARRED) or Not spam. Both are reversible; nothing is deleted.
- Spam never loads remote images, even with automatic images on, and the body shows "In Spam · images stay off and links may be unsafe". Ask Cove can open it ("open spam", "junk").
- Tests: `GmailSyncTests.testSpamIsListedOnlyWhenItsFolderAsksForIt`. Full `swift test`: CoveCoreTests 252, CoveRenderingTests 339, 0 failures. Not verified live against a real Spam folder.

## Unsubscribe

- `MailUnsubscribe.parse` reads `List-Unsubscribe` and `List-Unsubscribe-Post`, keeping only HTTPS links and single mailto addresses. It is one-click only when both headers say so (RFC 8058). New and refreshed emails keep it on `Mail.unsubscribe`. Older stored bulk emails get just those two headers (`format=metadata`) when opened, once per session.
- The reader shows Unsubscribe only when the sender offers it and the email isn't spam, sent or a draft. A confirmation says what will happen:
  - One-click: `UnsubscribeClient` POSTs `List-Unsubscribe=One-Click` over `LiveHTTP` (ephemeral, no cookies, credentials or redirects; 2xx/3xx is success). The sender is recorded in encrypted `unsubscribedSenders`, and the toolbar shows "Unsubscribed".
  - Email: opens an unsent draft to the mailto address.
  - Web: opens the HTTPS page in the browser.
- After one-click, a note offers Archive. Spam never offers it, because answering spam confirms the address is read. The sample mailbox records the choice without contacting anyone.
- Tests: `UnsubscribeTests` (parsing, unsafe entries, the exact one-click request, error status), `ReaderDesignTests.testNewsletterOffersUnsubscribeButSpamNeverDoes` (render `/tmp/cove-reader-unsubscribe-824.png` inspected). Not verified live against a real sender.

## Event editor (user screenshot of "Make a little space")

- The title field is the headline ("Add a title"; Return saves). One clock row holds a day chip (graphical date popover), start and end time chips and the length with the time zone name. Time chips open a 15-minute list scrolled to the current time; end times show their length ("5:00 PM · 45 min"); changing the start keeps the length. One "Save to" chip opens Google Calendar or a calendar on this Mac. Cancel is quiet; Add event is the default action.
- Behavior change: a new event (not an assistant proposal) defaults to Google Calendar when Calendar is connected; it can still be switched to this Mac. The save path, account and past-time guards are unchanged.
- Tests: `EventTimesTests`; render `/tmp/cove-type-event-editor-440.png` inspected. Full `swift test`: CoveCoreTests 255, CoveRenderingTests 341, 0 failures.
