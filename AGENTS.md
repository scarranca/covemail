# Cove — guide for coding agents

This is the shared handoff for the Cove repository. Read it before changing the app, backend, website, or release pipeline. Keep it current when architecture, product behavior, or release procedures change. Current user instructions take precedence over this file.

## Start here

1. Inspect `git status`, the current branch, and any applicable nested instructions. Preserve unrelated work. This repository is used through multiple worktrees; never assume another checkout is clean.
2. Read `PRODUCT.md` and `DESIGN.md` for product and design intent, then the relevant implementation and tests.
3. Read the latest applicable `docs/qa/<version>/AUDIT.md`. Use `site/release.json`, `scripts/write-app-info.py`, and the published feed to establish release state; do not infer that a local build is published or installed.
4. For cloud work, read `backend/README.md` first. For providers, read `docs/AI-PROVIDERS.md`; for packaging, read `docs/DISTRIBUTION.md` with the historical caveats below.

Some README/status/distribution sections are historical and still mention older versions, no deployed backend, or the old `Cove / Needs review` behavior. Newer code, versioned evidence, and this handoff supersede those claims. Do not report old test totals as verification of new changes.

## Current checkpoint — September 30, 2026

- **Unreleased (branch `claude/ios-apple-intelligence`, October 4): Cove for iPhone and Apple Intelligence.** See `docs/IOS.md`.
  - **iPhone app:** iOS 26+. `Sources/CoveMobile` is a SwiftPM library, and `iOS/project.yml` generates the Xcode shell with XcodeGen. It uses the Mac's exact light palette, Inter roles and components (`MobileTheme.swift`) and has Home, Mail, Calendar, Tasks, Search, Contacts, Ask Cove and Settings; sign-in asks for Gmail, Calendar and Tasks together. DEBUG `-CoveSample` renders a sample mailbox in the simulator (docs/IOS.md → Design checks).
  - **New-mail push (deployed Oct 4):** migration 004 `push_devices` (user-approved exact SQL), Cloud Run `cove-sync-api-00007-hm7` (now `00008-xgz`, Oct 5: live-only mail quota, #2), Pub/Sub `gmail-push` → `gmail-push-to-api`, APNs key `Z7S2G2N9NT` in Secret Manager `cove-apns-key`. The server holds no Gmail credential; the iPhone's notification extension reads the email. See backend/README.md → New-mail push.
  - **About you (Oct 4):** `PersonalContext` (CoveCore) on iPhone (Settings → About you, Keychain) and Mac (Agent → About you, encrypted `Preferences.personal`). It reaches every writer and Ask Cove through `Preferences.memoryPrompt` on the Mac and `MobileMe.prompt` on iPhone. Optional sync between devices (Oct 5, off by default per device): `/v1/personal` with its own KMS-wrapped key per Google identity, independent of the mail mirror (no `accounts` row needed); newest edit wins (`CloudPersonalSync`). On the Mac it needs the `openid email` scope, so `needsGoogleIdentity` keeps it in every reconnect. Migration 005 `personal_contexts` (user-approved exact SQL) was applied Oct 5 and is served by `cove-sync-api-00009-lzv`.
  - **Apple Intelligence:** `AIProvider.appleIntelligence` (`CoveCore/AppleIntelligence.swift`) on Mac and iPhone. FoundationModels is weak-linked on macOS. Prompts are refitted with `AIPromptLimits.onDevice`; a request that is still too long is reported, never silently cut or rerouted.
  - **Verification:** the Apple builds workflow (Xcode 26.6) compiles the Mac app, the iPhone library and the app shell, and the core tests pass. The app has not run on a device yet; see `docs/IOS.md`.
  - **Codemagic:** `codemagic.yaml` uploads to TestFlight on `main` pushes that touch iPhone or core code, after one-time setup by the account owner (docs/IOS.md).
- **Cove 0.1.66, build 68**, is published (Pages deployment `db8f8622`): attach files on Mac (paperclip, drop on a draft or the window) and iPhone/iPad (Photos, Files); TestFlight build 13. Evidence: `docs/qa/0.1.66/AUDIT.md`.
- **Cove 0.1.65, build 67**, was published (Pages deployment `d2b2bece`): About you syncs between Mac, iPhone and iPad (opt-in per device). Backend `cove-sync-api-00009-lzv` with migration 005 `personal_contexts` (user-approved exact SQL, applied Oct 5); TestFlight build 12. Evidence: `docs/qa/0.1.65/AUDIT.md`.
- **Cove 0.1.64, build 66**, was published (Pages deployment `8211f067`), released from `claude/ios-apple-intelligence`. It has Jev agents with context (thread, sender, About you, learned verdicts), agent extras, a redesigned Activity and Try it, and About you on the Mac. Evidence: `docs/qa/0.1.64/AUDIT.md`. iPhone TestFlight build 11 was uploaded the same day.
- **Cove 0.1.63, build 65**, was published (Pages deployment `55f32f76`): the menu bar model is held by a static owner (`MeetingMenuBarModel.start(store:)`). An unread `@State` in `App` is released, which is why the icon never appeared in 0.1.62. Verify status items with System Events (`menu bar 2` of the process). Evidence: `docs/qa/0.1.63/AUDIT.md`.
- **Cove 0.1.62, build 64**, was published (Pages deployment `1f638a28`): hotfix for the 0.1.61 launch freeze. Never use SwiftUI `MenuBarExtra(isInserted:)` with `@AppStorage` in the `App` body: it re-rendered the app scene at 100% CPU. The menu bar item is now an AppKit `NSStatusItem` + `NSPopover` (`MeetingMenuBarModel`), and its setting lives in Settings → Menu bar. Evidence: `docs/qa/0.1.62/AUDIT.md`.
- **Cove 0.1.61, build 63**, was published (and froze on launch; see 0.1.62) (Pages deployment `1d1e3de0`): optional meetings menu bar item (`MeetingMenuBar.swift`, core `MeetingAlert`/`MeetingLink`, setting `menuBar.meetings`, off by default). Countdown within 10 minutes; a pulse for calls with guests and a link (still under Reduce Motion); Join from the panel. Evidence: `docs/qa/0.1.61/AUDIT.md`.
- **Cove 0.1.60, build 62**, was published (Pages deployment `e183aae4`): several Google accounts, one open at a time. Evidence: `docs/qa/0.1.60/AUDIT.md`.
  - **Sign-ins:** each account's session is its own Keychain entry `googleAccountSession.<sha256(lowercased email)>`, with a roster in `accounts.roster`.
  - **Legacy move:** the single legacy session is moved only after read-back; if the move fails, the old entry keeps working.
  - **Switching:** `AppStore.switchAccount`/`addAccount` settle the current mailbox first (Undo Send, Gmail write queues, sync).
  - **Work accounts:** they can use the organization's own Desktop client (`connect(client:)`, `OrgClientSheet`, `docs/ORG-GOOGLE-CLIENT.md`). Reconnecting reuses the account's own client.
  - **Not yet built:** only the open account syncs.
- **Cove 0.1.59, build 61**, was published (Pages deployment `994e38a7`): a locked AI key (`errSecInteractionNotAllowed`, -25308) during background work is a status line ("AI paused…"), not an alert (`HardenedSecrets.lockedMessage`). Evidence: `docs/qa/0.1.59/AUDIT.md`.
- The design system is mirrored in Pen at `~/Pens/Cove.pen` (tokens, components, five screens beside app renders in `~/Pens/cove-reference/`); build Pen screens from those components and compare with test renders.
- **Cove 0.1.58, build 60**, was published (Pages deployment `c549bea2`): default From (`Preferences.defaultSender`, `AppStore.sendingAliases`), replies from the alias the email was sent to (`replySender(for:)`, From menu in the reply box), Settings → Gmail as cards (`SettingsGroup/Card/Row`). Evidence: `docs/qa/0.1.58/AUDIT.md`.
- **Cove 0.1.57, build 59**, was published (Pages deployment `da94d37e`): mail keyboard shortcuts R reply, E done (archive and open the next), U read/unread (`MailNavigationShortcut`, `AppStore.replyRequestID`). Evidence: `docs/qa/0.1.57/AUDIT.md`.
- **Cove 0.1.56, build 58**, was published (Pages deployment `bf472c84`): Ask Cove tasks and meetings-with-a-person, linked tasks in the reader, calendar guests/Meet, describe-an-event (✦, +/⌘E, first open spot via `firstOpenSpot`), Gemini notes links (no Drive scope, user decision), ⌘Delete on events, inbox dusk scene, Important-unread badge, mojibake repair. Evidence: `docs/qa/0.1.56/AUDIT.md`.
- **Cove 0.1.55, build 57**, was published (Pages deployment `0c483037`): keep working while Cove syncs (`syncing` vs `busy`, instant label actions with `LabelEdit` re-apply), debounced draft saves, accent-safe editor, Undo Send (4 s), no duplicate reply bar. Evidence: `docs/qa/0.1.55/AUDIT.md`.
- **Cove 0.1.54, build 56**, was published (Pages deployment `6646faf7`): Gmail sync within Google's real per-user budget and continuing quietly after rate limits; Calendar and Tasks connect after a running sync. Evidence: `docs/qa/0.1.54/AUDIT.md`.
- **Cove 0.1.53, build 55**, was published (Pages deployment `ace91a3e`): the 0.1.52 app in the designed installer window (`scripts/dmg/`, dmgbuild in `.local/dmg-venv`; see `docs/DISTRIBUTION.md`). Evidence: `docs/qa/0.1.53/AUDIT.md`.
- **Cove 0.1.52, build 54**, was published (Pages deployment `83d56e1c` adds the animated install demo on /beta/; earlier `a7d30c6b`, first `1391114e`). It includes the unshipped 0.1.51 work:
  - agents built from a description, with templates, Try it and the dot-portrait header;
  - Google Tasks from email (overview, Done, side column);
  - Ask Cove inside the email; approval-gated bulk changes;
  - Important/Other tabs, a Spam folder and Unsubscribe;
  - inline AI writing, calendar dragging and the event editor;
  - Connections setup.
  Evidence: `docs/qa/0.1.52/AUDIT.md` (and the `AUDIT-*.md` files beside it).
- **QA builds** (`scripts/build-qa.sh` with `COVE_GOOGLE_OAUTH_FILE`) are copied to `dist/QA-<version>[-letter]/Cove QA.app`.
  - The QA bundle (`ai.cove.qa`) keeps its data under `~/Library/Application Support/Cove/QA`, and that data holds the user's real, migrated account. Treat it as real mail.
  - The user launches QA builds themselves. Never force-quit one.
- The Higgsfield MCP (`https://mcp.higgsfield.ai/mcp`, user scope) is connected for generated imagery; the agents portrait came from it. Generations spend the user's credits, so preflight with `get_cost`.
- **Cove 0.1.50, build 52**, is published (Pages deployment `e50c3f33`). It adds instant search, faster and streaming drafts, Ask Cove follow-ups that reuse found emails, per-email encrypted storage (storage version 3, verified by a real-account migration check), and a landing refresh. Evidence: `docs/qa/0.1.50/AUDIT.md`. The local-first index continues: the working set is not narrowed yet (see the audit's order).
- 0.1.49, build 51 (Pages deployment `463c0cae`, commit `5fd1f42`). It adds large-question Gmail research (up to 100 matches, batched and cited), a daily brief, chat replies, contact lookups and memories in every AI draft. Evidence: `docs/qa/0.1.49/AUDIT.md`.
- 0.1.48 (deployment `75e0a625`) was a hotfix for 0.1.47: login-keychain queries must set `kSecUseDataProtectionKeychain: false` (`Vault.legacyQuery`), because otherwise deletes also remove data-protection items on the hardened build. Evidence: `docs/qa/0.1.48/AUDIT.md` and `docs/qa/0.1.47/AUDIT.md`.
- 0.1.47 (deployment `9c0a9d4f`) added the learned voice (shared across accounts and, via cloud sync, across Macs), Ask Cove new emails and introductions, conversation cards with a Reply menu, a searchable label picker, Inbox Unread, one-step Calendar, and hardened AI/TypeSafe keys with optional Touch ID.
- Backend: migration 003 `voice_profiles` applied (user-approved exact SQL); Cloud Run `cove-sync-api-00005-xtt` serves `/v1/voice`.
- Release builds need `.local/Cove.provisionprofile` and `.local/google-oauth-desktop.json` in the building checkout, plus historical DMGs in `dist/releases` (kept in the main checkout). Publishing uses Wrangler OAuth; `whoami` must show account `f1bf637a…`. Signing identities (Developer ID Application, Apple Distribution, Apple Development) were copied on September 29 into the login keychain with `codesign` in their access list; the release scripts sign from the login keychain (`COVE_SIGNING_KEYCHAIN`), so builds no longer ask for an administrator password. The user then removed the System-keychain originals (verified: 0 identities there, 3 in login; Developer ID signing with timestamp still passes).
- Published and installed/running versions may differ; the user's running app was not replaced.

## Product and collaboration expectations

Reader behavior in 0.1.44: `ReaderView.swift` now implements the September 26 Pen `1. Cove` reader (`w3s2H` / `CQs4F`), with labeled toolbar, distinct Jev assessment/source sections, reading-mode choices, and fixed response actions. Task creation remains unimplemented; follow-up flags and local reminders are the available actions. Translation prepares a selected-email assistant question. See `docs/qa/0.1.44/AUDIT.md` for local and public release verification.

Cove is a native macOS Gmail client with Jev organization, optional generative writing/chat, Calendar, Contacts, and user-configured agents. The user wants a calm, readable product faithful to their Pen designs, with working interactions rather than decorative mockups.

- Implement the requested work and verify it. Resolve routine reversible choices without repeatedly asking permission. Request missing credentials or approvals only when genuinely required, and explain the specific blocker.
- The user wants to keep using their Mac while work proceeds. Prefer hidden-window rendering and injected test fixtures. Do not foreground apps, quit Cove, discard drafts, replace `/Applications/Cove.app`, or install an update over a running session without current authorization and safe closure.
- Do not send real mail, respond to real invitations, or create/delete real events as a test without explicit authorization. Synthetic fixtures are the default.
- Keep passwords, API keys, refresh tokens, signing keys, and database credentials local. Never ask for them in chat or print secret-bearing files/CLI responses.
- Push/merge/publish only within the current task's authorization. Check both worktrees and remote state; avoid force pushes and destructive resets. A prior release is not blanket authorization for unrelated external changes.
- If parallel agent work is authorized, assign separate files or read-only reviews, share findings, and inspect every result. Agents share the filesystem.
  - Worktree-isolated agents start from `main`, not the current branch. Tell them to merge the working branch first, then review, merge and run the full suite yourself.

## Repository map

| Area | Primary implementation |
| --- | --- |
| App shell, navigation, state | `Sources/Cove/CoveApp.swift`, `AppStore.swift`, `CoveRuntime.swift` |
| Shared design and text roles | `Sources/Cove/DesignSystem.swift`, `HomeTypography.swift`, `DESIGN.md` |
| Onboarding, Google auth, Keychain | `SetupViews.swift`, `BundledGoogleOAuth.swift`, `Security.swift`; core Google session/OAuth files |
| Tasks (Google Tasks) | `TasksViews.swift` (list, details, suggestions sheet, after-send toast); core `GoogleTasks.swift`, `TaskDetection.swift` (eligibility, extraction parsing, quick add, related context) |
| Home | `AgentHubView.swift`, `HomeActions.swift`, `HomeCalendarView.swift`, `HomeWeatherView.swift`, `MailTideView.swift` |
| Mail and reader | `MailViews.swift` (Important/Other tabs; core `InboxSplit.swift`), `ReaderView.swift`, `ReaderConversation.swift`, `AttachmentPreview.swift`, `EmailBodyView.swift`, `MailNavigationShortcut.swift`, `MailQuickActions.swift`, `MailDeletionToast.swift` |
| Categories, labels, flags | `MailCategoriesView.swift`, `MailLabelViews.swift`; core `GmailLabels.swift`, `JevMailFlag.swift` |
| Compose and AI review | `ComposeTextEditor.swift`, `ComposeSuggestion.swift`, `AIWritingSheet.swift`, `WritingMotion.swift`, `WritingAgent.swift` |
| Chat | `AgentChatView.swift`, `AssistantScreen.swift` (screen context), `AssistantBulkCard.swift` (core `AssistantActions.swift`), `AssistantResponse.swift`, `AssistantAgenda.swift`, `AssistantCalendar.swift`, `ChatMarkdown.swift`, `AssistantModelPicker.swift` |
| AI accounts and model discovery | `AIProviderSettings.swift`, `ChatGPTConnection.swift`, `ClaudeConnection.swift`, `IntegrationsView.swift`; core provider/sandbox files |
| Calendar | `CalendarView.swift`, `CalendarMonthView.swift`, `CalendarNavigation.swift`, `CalendarSearchView.swift`; core calendar files |
| Contacts | `ContactsView.swift`, `Sources/CoveCore/Contacts.swift` |
| Agents | `CustomAgentViews.swift`, `CustomAgentBackfillView.swift`, `AgentNotifications.swift`, `AgentViews.swift`; core `CustomAgent.swift`, `CustomAgentBackfill.swift`, `JevAutomation.swift`, `Jev.swift` |
| Settings | `SettingsView.swift`, `SettingsSidebar.swift`, `SettingsPresentation.swift`, `ReadingSettingsView.swift`, `CloudSyncSettings.swift`, `AppUpdater.swift` |
| Storage and API contracts | `Sources/CoveCore/Database.swift` (records and per-email `messages` rows), `RecordCipher.swift`, `GmailSync.swift` (merging), Gmail/HTTP files |
| Optional cloud mirror | `Sources/CoveCore/CloudMailSync.swift`, `backend/` |
| Landing page and downloads | `site/`, `assets/update-config.json`, `scripts/build-site.py` |
| Verification | `Tests/CoveCoreTests/`, `Tests/CoveRenderingTests/`, `docs/qa/`, `scripts/qa/` |
| iPhone app | `Sources/CoveMobile/` (screens, `MobileMailbox`, `MobileAuth`, `MobileAI`), `iOS/` (XcodeGen shell), `docs/IOS.md` |
| Apple Intelligence | `Sources/CoveCore/AppleIntelligence.swift`, Connections card in `IntegrationsView.swift` |

## Design rules to preserve

- The supplied Foundations/Components and product HTML references are preserved in `docs/design-source/`. The user also edits live Pen designs; inspect the relevant current frame when a request names it. Familiar names include Cove Agent Chat, Cove Label, Cove Settings, Cove Integrations, Agent Hub, and the landing design “quiet momentum.” Do not assume an old export includes a new edit.
- Use bundled **Inter**, the existing `Palette`, and semantic fonts. Current roles: page title **24 medium**, detail title **20 medium**, section **16 medium**, subheading **14 medium**, reading body **14 regular**, labels **13 medium**, secondary copy **12 regular**, controls **12 medium**, metadata **11 regular**.
- Use `PrimaryButton` / `SecondaryButton`; normal controls remain 40 points high. Compact controls use 12-point medium labels with compact geometry. Do not introduce native automatic bezel buttons among Cove actions. Native menus and date controls may keep platform behavior.
- `CoveFieldStyle` defaults to secondary text. For prose, pass `CoveFieldStyle(font: .coveBody)` explicitly; an outer `.font` does not override the style's internal font.
- `CoveTypography` supplies native compose/preview font and paragraph spacing. Avoid text changing size when an AI suggestion replaces the draft canvas. Plain email and long agent prose use a bounded reading width.
- Keep settings sections separate, advanced credentials collapsed where appropriate, and provider configuration in Integrations. Do not put subscription setup back into compose.
- Preserve unread emphasis and indicators, Markdown semantics, sender-authored HTML, avatar sizing, and larger sign-in brand/artwork typography. These are intentional exceptions, not drift.
- Muted `#737373` is for white/near-white surfaces; use darker body text on selected/sidebar/shaded surfaces. Check real rendered contrast and wrapping.
- Waiting AI uses truthful progress. Since 0.1.52 (user request) writing shows `WritingThinkingBar`: the Home tide chart's point cloud as a slow travelling wave above the ask line, with the real stage text; Reduce Motion keeps it still. Avoid anything faster or louder. Preserve the finite returned-text glyph animation; interaction finishes it immediately and Reduce Motion skips it.
- Since 0.1.52, AI writing is inline (`AIWritingPanel(inline: true)`): a ✦ at the left of the ask line (above Send) grows open into one "Ask Cove to write or change this…" line (Esc/✕ closes it) with a tools menu (Rewrite, Fix grammar, Polish, Shorten, tone, translate) that acts on the selected text or the whole draft; the suggestion previews on the editor canvas with Apply/Discard, and Send is disabled while a suggestion is pending. A streamed draft is not re-animated when it becomes the preview (`WritingActivity.streamed`). There is no Write with AI pop-up or composer side panel.
- Apply draft is a small, left-aligned canvas action. Applying a suggestion and sending remain separate actions. Preserve selected-text rewriting and original draft contents until Apply.

## Behavioral boundaries and regression traps

### Mail and agents

- Gmail sync is roughly every two minutes **while Cove is open**, using incremental history with pagination/reconciliation. Background Gmail sync and automatic Jev processing are separate settings. No server-side Gmail push ingestion exists yet.
- Since 0.1.45: `MailPagination.swift` loads older mail when the actual list end becomes visible, using independent mailbox/label cursors, a loading indicator and explicit failure retry. Do not restore the permanent Load older mail button or trigger requests from speculative lazy-row appearance. See `docs/qa/0.1.45/AUDIT.md`. Unreleased (0.1.47): page loads (history-expired fallback, older pages, label views) fetch only labels (`format=minimal`) for messages already in the encrypted local store, and full content only for new ones or during a decoder refresh. This is intentional, not a regression; see `docs/qa/0.1.47/AUDIT.md`.
- Published 0.1.44 reminders are local. The snooze backend and approved migration `backend/migrations/002_snoozes.sql` were deployed September 26 to Cloud Run revision `cove-sync-api-00004-qjf`. Published 0.1.45 adds the encrypted Mac outbox under opt-in cloud sync. Older Mac versions keep snoozes local. Snoozes survive mail-mirror expiry. Local/pending/synced/conflict states must be truthful. There is no scheduler, APNs delivery or Gmail-side snooze yet. Tomorrow morning is the following calendar day at 9 a.m. local time. See `backend/README.md` and `docs/qa/0.1.45/AUDIT.md`.
- No selection means the intentional empty reader. Up/Down navigates messages; Escape/Left returns to the list. Shortcuts must yield to text editing, menus, and dialogs.
- Unreleased (0.1.50): `AppStore.visible` is memoized and search uses `MailSearchIndex` (folded bytes); never reintroduce per-read filtering or `localizedCaseInsensitiveContains` over bodies. `WritingAgent` skips planning when `WritingToolPlan.mightNeedLookup` is false. ChatGPT drafts stream via `item/agentMessage/delta`. Ask Cove `followup` reuses the previous answer's emails.
- Unreleased (0.1.49): Ask Cove also handles reply (selected email → draft in reader), remember/forget (user's words only, `Preferences.memoryPrompt`), contact (deterministic, no model) and brief. Chat drafts use `AppStore.assistantWriter` (`WritingAgent`), so availability comes from Calendar. Memories reach every writer and answer when enabled.
- Unreleased (0.1.49): Ask Cove's Mail search toggle means live Gmail research (default on) vs downloaded mail only. `MailboxResearch` reads up to 100 matches in batches of 20 with cited notes and saves only cited emails (full bodies). The `.search` prompt treats topics as full text, never `{from:X to:X}`. See `docs/qa/0.1.49/AUDIT.md`.
- Unreleased (0.1.47): AI provider/TypeSafe keys go through `HardenedSecrets`: data-protection keychain with optional Touch ID only when signed with `assets/Cove.hardened.entitlements` and `.local/Cove.provisionprofile`; otherwise the login keychain, unchanged. Never extend it to Google session or mailbox keys. The learned voice is also shared across this Mac's accounts via the Keychain entry `voiceProfile.shared`. Migration 003 (`voice_profiles`) is approved, applied and served by `cove-sync-api-00005-xtt`. App ID `ai.cove.mac` and the Developer ID profile "Cove Developer ID" exist; keep the profile at `.local/Cove.provisionprofile` (never commit it) in the checkout used for release builds.
- Unreleased (0.1.47): Ask Cove's `compose` route drafts new emails and introductions. Recipients come only from `RecipientResolver` (user contacts or addresses the user typed); ambiguous names ask, and the draft opens in the composer unsent.
- Unreleased (0.1.47): `VoiceProfile` is learned from the user's own sent mail (style only, never bodies) into encrypted `Preferences.voiceProfile` and injected via `ComposeSuggestion.instruction(profile:)`; keep language rules above voice.
- Unreleased (0.1.47): conversation messages render as cards with header actions (Reply, Reply all, message menu); Reply all uses decoded Cc (`nil` = unknown, hidden). Calendar is added to the current Google sign-in via `AppStore.connectCalendar()`, without client credentials or mailbox reload. On Google Workspace domains, an admin may need to mark Cove as a Trusted app (Admin → Security → API controls); otherwise Google silently drops the Calendar scope. See `docs/qa/0.1.47/AUDIT.md`.
- Conversation/preview behavior shipped in 0.1.46; evidence is recorded in `docs/qa/0.1.46/AUDIT.md`. Opening a message refreshes its Gmail thread in the same pane. Other messages start collapsed and are marked read only when expanded. Preserve per-message drafts, the selected anchor, pagination cursors and account-lifetime guards. Replying to sent mail uses its original recipients.
- Attachment Preview is explicit and local: PDFKit for PDFs, AppKit for images, embedded Quick Look for other allowed formats. Save remains available. Private temporary preview files are removed on normal close/navigation; do not claim encrypted preview files or guaranteed crash/cache erasure. HTML attachments are displayed as text source. Known files over 25 MiB are rejected before download; decoded bytes are checked again afterward. There is no new cloud attachment upload.
- Outgoing attachments (Oct 6): `OutgoingAttachment` (CoveCore) reads bytes when a file is added (security-scoped, composed Unicode names, header-safe), caps the set at Gmail's 25 MB, and `GmailClient.mimeMessage` builds multipart/mixed only when files are present (no files = the old single text part, byte for byte). Sends with files go through Gmail's upload endpoint (`uploadSend`, multipart/related with the `threadId`, retried only on rate limits, never after a server error). Mac: files are encrypted records `attachments.<target>` (`AttachmentTarget.draft/reply`, `DraftAttachments.swift`), never on `Mail` and never in the cloud mirror; they leave the draft only after Gmail accepts the send (Undo keeps them). The composer is a drop target and has a paperclip beside Send; the main window is a drop target that joins the reply being written (`replyDraftTarget`, published by `ReaderView`) or starts a new email. iPhone/iPad: paperclip menu (Photo Library, HEIC → JPEG; Choose File) in the composer header, files kept with the in-memory draft and restored on Undo.
- `⌘Delete` moves mail to Trash after a five-second Undo window. Since 0.1.46 it targets the mail row under the pointer first, falling back to selection outside the rows. Resolve the pointer against current visible row geometry; never retain a stale hover ID after scrolling/reflow. Native editors and dialogs retain their keys. Preserve countdown/retry/error completion; never leave “Moving to Trash…” indefinitely. Do not confuse Trash with permanent deletion.
- Follow-up flags synchronize with Gmail stars. Jev action/urgency flags are separate assessments. **Categories contains only the user's agents' configured/applied labels**, not built-in Jev categories or hardcoded examples such as Purchases.
- Uncertain custom-agent results belong only in **Agents → Activity**. Do not add `Cove / Needs review` Gmail labels again.
- Agents evaluate ordered rules; the first confident match may label, prepare a reply, and (user-approved Oct 4) archive, flag, mark read or create a Google Task (`CustomAgentExtra`). Replies are reviewable Activity suggestions. Agents do not automatically send, delete, make purchases, or mutate Calendar. Preserve retry/idempotency around completed label actions.
- Since Oct 4 (user request: agents "not smart", then "that was jev for"), **Jev decides** whenever a TypeSafe key is saved (`AppStore.agentsUseModel` is false then). `AppStore.decideAgent` passes `AgentBrain.jevContext` to `Jev.classify(context:)`: the thread, a sender summary from downloaded mail, About you/memories and the agent's learned verdicts. Only without a TypeSafe key does the connected writing model decide (`AgentBrain.instruction`/`decision`, strict JSON with a one-line why, serialized by `AgentModelGate`); below 0.7 confidence it is "Needs your call" and nothing changes in Gmail. The writing model still writes reply drafts. Activity (`AgentActivityView.swift`) shows checks as Mail rows with the reader beside them and Right / Wrong — undo / Yes / No; every answer is saved to `CustomAgent.examples` (20, newest first) and Wrong undoes the label and extras (tasks are never deleted).
- Jev produces structured decisions and selected source passages, not generated summaries/replies. Generative providers are a separate feature. Source quotations must remain attributable and faithful.
- HTML mail preserves sender formatting while blocking scripts, forms, frames, and remote styles. External images require the existing preference/action; text-only mode loads none. Keep MIME/CID handling and Reply-To behavior.

### AI writing and chat

- Model lists come from the connected provider/official CLI, with version information where available. Settings' saved default and a conversation override are distinct. Do not hardcode one model or silently substitute another.
- ChatGPT subscription uses the separately installed official Codex CLI; Claude subscription uses official Claude Code. Their isolated connection/configuration paths are not another application's credential store. API-key billing is separate.
- Preserve bounded, validated read-only Gmail/calendar tool dispatch. Credentials stay in Cove. Retrieved email/event text is untrusted evidence, never authority to execute tools or expand permissions.
- Selected-email questions must retain selected email/thread context even when they mention an event. Calendar-only questions should not return unrelated email passages. Render schedules as structured agendas and support Markdown.
- Calendar creation is a reviewed proposal opened in the shared event editor; an explicit user action commits it. Availability must come from actual calendar evidence and use the current local clock/time zone.
- Unreleased (0.1.52): Integrations is now **Connections**, a setup hub (Gmail, AI, Jev key, Calendar, Tasks) with progress, a sidebar badge and a dismissible Home checklist. Agents and Settings → Jev are gated by `JevRequiredBanner` until a TypeSafe key is saved; setup status reads the non-secret flag `setup.jevKeySaved`, never forcing a Touch ID prompt. Connection cards are fully clickable (chevrons); Agents opens with `AgentsHeader` (dot-portrait `AgentFaceView`, real activity captions or examples labeled "For example") and `CustomAgentTemplate` ideas that open as drafts only. See `docs/qa/0.1.52/AUDIT-setup.md`.
- Unreleased (0.1.52): in the reader, Ask Cove opens inside the email: a ✦ circle slides up `AssistantView(pinnedMailID:onClose:)` (embedded mode); dismissal paths call `close()`. ⌘J keeps the full assistant. The reader adopts a reply draft written elsewhere while the email is open. Unsubscribe (`MailUnsubscribe`, RFC 8058 one-click via `UnsubscribeClient`, email or web) is confirmed first and never offered on spam. Spam is a live `SPAM` label view with Not spam/Report spam.
- Since 0.1.55:
  - `busy` is only for exclusive user operations. Background mail work (sync, label views, organizing, agent checks, the AI thread read) uses `syncing` via `runSync`; never block user actions on it.
  - Label actions apply locally first and go to Gmail on a per-email queue. Every Gmail-result merge must call `reapplyLabelEdits(since:)`, and sync prunes delivered edits.
  - Editors debounce draft saves (never save per keystroke) and must ignore marked text (`hasMarkedText`).
  - Send uses `queueSend` with a 4 s Undo bar (`SendUndoToast`), not a confirmation dialog.
- Unreleased (0.1.52): Ask Cove receives a bounded (≤1,500 bytes) `AssistantScreenContext` (screen, folder/label and visible count, search, selected email, calendar day and selected event) as untrusted evidence, so "this", "it" and "these" resolve without asking. `navigate` opens only validated folders, labels (unknown names ask with close matches), days and searches. `move` reschedules only the selected event, after the user clicks Move event.
- Unreleased (0.1.52, user-approved rule change): Ask Cove may archive, mark read/unread, star/unstar, or add/remove a label on many emails, **only after the user clicks the primary button on `AssistantBulkCard`**, which lists exactly the emails that will change (capped at 500). `AppStore.resolveBulk` only reads; `applyBulk` uses the shared `applyLabelChange` path with Gmail pacing/backoff, reports per-email failures, and Undo reverses exactly the succeeded emails. The assistant still cannot send mail, move mail to Trash or delete anything permanently; those operations do not exist in its plan. See `docs/qa/0.1.52/AUDIT-assistant.md`.
- New drafts follow explicit language instructions, otherwise the current request's language. Rewrites preserve the original language unless asked to change it. Saved voice and foreign-language source mail must not override this.
- Failures must stay visible with the attempted model and a useful retry/settings action. Snapshot provider/model and draft scope per request; reject stale updates and preserve edits on cancellation/failure.

### Inbox split and agents (0.1.52)

- The Inbox has Important/Other tabs (`InboxSplit.classify`). The first rule that matches decides:
  1. the user's vote on the email;
  2. the user's rule for that sender;
  3. Jev reply or urgency ≥ 0.65 → Important;
  4. bulk headers → Other;
  5. a notification sender → Other;
  6. a Jev newsletter, update or purchase category → Other;
  7. everything else → Important.
- Gmail's IMPORTANT label does not decide the tab. Votes live on `Mail.inboxVote`, are kept by `GmailSyncResult.merging`, and stay on this Mac. Settings → Reading → "Split inbox" turns it off. Keep the tab switch to a single `visible` recalculation.
- "Try on recent mail" previews an agent over up to 200 Inbox emails from the last 14 days without changing anything. "Apply" labels exactly the matches, idempotently. Unclear results go only to Activity.
- "Notify me when it matches" posts a local notification (sender · subject, never the body) for **new** matches only, never for backfill.

### Tasks (0.1.52)

- Google Tasks uses scope `https://www.googleapis.com/auth/tasks` (Tasks API enabled in `cove-mail-20260922`, scope on the consent screen). `GoogleAccountSession.tasksConnected` is optional so older Keychain sessions still decode; granted Calendar/Tasks flags are read from the token's `scope`, so adding one never drops the other.
- Detection: `TaskDetection.eligible` skips bulk/automated, no-reply, Other-tab and Jev newsletter/update/purchase mail before any call. Jev (custom-agent gate) checks eligible mail once; the result is saved on `Mail.taskCheck` and kept across sync merges. The writing model extracts tasks (`.extractTasks`, strict JSON, max 5, validated dates) only on the user's click. Tasks are created in `@default` only after the user approves in `TaskSuggestionsView`; notes link to the Gmail thread. After a send, `lookForTasks` shows `PostSendTaskToast` (wave while checking, “Create task” if found).

### Calendar, Contacts, Home

- Preserve Workweek/Week/Month views, current-time scrolling, selected-day agenda, overlap layout, and quiet grid lines. User scrolling remains in control after initial navigation.
- Unreleased (0.1.51): in the week grids, dragging empty space opens the editor prefilled; dragging an event moves or resizes it (bottom 8 pt), saved immediately with Undo; events with other guests confirm first; only `LocalEvent.canReschedule` events move. The event's drag gesture uses the column's fixed coordinate space (the event follows the pointer via offset). Event details use icon actions like the reader. See `docs/qa/0.1.51/AUDIT.md`.
- Gmail requests back off on rate limits; never retry non-GET requests after server errors, and never surface provider error text.
  - Since 0.1.54, `GmailPacer` is a budget of Google's real 6,000 units per user per minute. Every request spends its official cost (`GmailClient.quotaCost`: a read costs 20). Background work waits above a 1,500-unit reserve and runs about 10× slower on battery (`PowerState`).
  - Sync applies history label changes without re-reading emails (`GmailSyncResult.labelChanges`), reads newest first, and keeps partial progress (`pendingIDs`) when Gmail rate-limits partway.
  - Rate limits are a status line, never an alert.
- Home surfaces pending invitations with Accept/Maybe/Decline. Ensure controls fit narrow panes, including their loading state.
- Weather is opt-in via location, with manual city fallback and visible errors. Do not silently enable location or invent forecast data.
- Contacts combine local records and downloaded correspondents; Google Contacts sync is not implemented. Keep in touch has narrower relevance filtering plus Ignore/Undo.

## Data and security

- Local account data is SQLite under `~/Library/Application Support/Cove/`, with per-account AES-GCM record encryption and keys in macOS Keychain. Sample data is separate. Never reset/delete a user's Keychain to fix an app prompt.
- Since storage version 3 (unreleased, see `docs/qa/0.1.50/AUDIT.md`), each email is its own AES-GCM row in `messages`, bound to `message:<id>`; a sync rewrites only changed emails. Deliberate clear-text columns: message id, thread id, date, and starred/has-draft/in-Inbox/snoozed flags, needed to choose which emails load (recent window plus starred, drafted, Inbox and snoozed mail of any age). Subjects, senders, bodies and labels stay encrypted. Opening a version-3 store with an older Cove shows "needs a newer version of Cove" rather than resetting it. Only emails loaded in the current session can be removed by a snapshot omitting them; keep archive/index reads out of that tracking. `AppStore` never calls `GmailSyncResult.applying(to:)` directly: every Gmail merge goes through `merging(into:store:keepsLoaded:)` so unloaded stored emails keep their Jev decision, draft and snooze and Gmail deletions purge them; search/cited results use `Database.adopting`. `loadMessages`, `loadThread`, `storeArchived` and `deleteMessages` never touch tracking; `saveMessage` does, so pass it only mail that is in `mails`.
- Disconnect retains the local encrypted cache. Local erasure, cloud erasure, and Gmail deletion are different actions; preserve their existing explicit confirmations and accurate copy.
- Keep stable signing identity and bundle identifiers. Ad hoc builds accessing real credentials can cause repeated Keychain prompts. Use isolated sample/QA builds for development checks.
- Cloud pilot: Cloud Run in Google project **`cove-mail-20260922`**, region **`us-east1`**, backed by PlanetScale PostgreSQL **`santiagocarranc2/cove/main`** and private GCS bodies with KMS-wrapped account keys. Always specify the Cove project; do not alter the user's global gcloud project.
- The pilot mirrors up to 1,000 downloaded messages from the last 30 days, excluding drafts, Spam, Trash, attachments, credentials, contact notes, and calendar events. It is one authoritative uploading Mac, not multiwriter/mobile synchronization. The deployed separate snooze API has per-record revision checks, queryable UTC dates and its own change cursor; it does not add multiwriter mail sync or notification delivery.
- Server keys can decrypt cloud content: **not end-to-end encryption**. Preserve consent, pilot allowlist, retention disclosures, and the local-only default.
- Tenant identity comes from verified Google identity; never accept a caller-selected tenant. Preserve forced RLS, restricted DML-only runtime roles, verified TLS, bounded pools/payloads, revision ordering, retry receipts, and generation fencing. Production schema changes require the applicable exact-SQL approval; migration 001's approval is not approval for future migrations.
- `.local/`, `.env*`, databases, key files, build outputs, and provider credentials stay out of Git. Never embed database credentials or an owner's API keys in the Mac app. The bundled Desktop OAuth client configuration is public native-app configuration, not a server secret or user credential.

## Connecting to services

Connections are machine/session-specific. The repository contains public configuration and instructions, not reusable login sessions. Discover the available tools first, check existing authentication, and request a private browser sign-in only if it has expired. Never recreate infrastructure or rotate credentials just because an agent cannot see a connector.

### PlanetScale: agent access versus application access

**Agent inspection:** prefer the configured PlanetScale MCP. Hosted MCP endpoint: `https://mcp.pscale.dev/mcp/planetscale`; configure it as a remote HTTP MCP server in the agent client and complete its private OAuth flow if setting up a new machine. Scope access to Cove; billing/payment-method access is unnecessary. Available tool names may have a client-specific namespace prefix.

- Target `organization: "santiagocarranc2"`, `database: "cove"`, `branch: "main"` (**PostgreSQL**).
- Inspect metadata with `planetscale_get_branch` / `planetscale_get_branch_schema`; use `planetscale_execute_read_query` for SQL. Start with `SELECT 1 AS connection_ok`, not a mailbox-content dump.
- Read tools use short-lived credentials. The read role does not bypass RLS: zero returned rows do **not** prove a protected table is empty. Never disable RLS to make an inspection work.
- The write-query tool requires the applicable approval of exact mutations/DDL. Do not reuse approval for migration 001 as authorization for other SQL. Avoid billing tools unless the user specifically requests billing work.

**CLI fallback:** `pscale` is installed on the original development Mac. Load its installed guide (`pscale --skill`) and inspect subcommand help; CLI flags can evolve. Automation uses JSON output and explicit organization/branch:

```sh
pscale auth check --format json
# Only if authentication is missing: complete the browser authorization locally.
pscale auth login --format json
pscale branch list cove --org santiagocarranc2 --format json
pscale sql cove main --org santiagocarranc2 --format json --role reader --query 'SELECT 1 AS connection_ok'
# Optional interactive session, explicitly read-only (shell otherwise defaults to admin):
pscale shell cove main --org santiagocarranc2 --role reader --format json
```

`pscale connect` / `password` are MySQL/Vitess workflows; Cove's Postgres uses `sql`, `shell`, and `role`. Do not create persistent passwords for routine inspection. CLI mutations and `--force` still need the applicable authorization.

**Backend runtime:** Cloud Run receives `DATABASE_URL` from the pinned Google Secret Manager secret **`cove-sync-database-url`**. The separately provisioned LOGIN inherits only `cove_sync_runtime`. MCP/CLI ephemeral reader credentials are not this application connection. Do not export/print the runtime URL or copy it into the Mac app. If an authorized deployment needs a replacement credential, follow `backend/README.md`: provision the restricted role, validate TLS and role privileges, save directly to Secret Manager, and pin the tested secret version.

### Google Cloud / Cloud Run

Use the installed `gcloud` CLI. On the original Mac it is also available at `~/google-cloud-sdk/bin/gcloud` if absent from PATH. Check authentication before asking for another sign-in:

```sh
gcloud auth list --filter=status:ACTIVE --format='value(status)'
# Only if expired/missing; complete Google sign-in privately:
gcloud auth login
gcloud run services describe cove-sync-api --project=cove-mail-20260922 --region=us-east1 --format='value(status.url)'
```

Use the deployed API origin in `assets/cloud-sync-config.json` for the Mac; Cloud Run may also report an equivalent service hostname. `GET /v1/status` is the public health check. Mail routes require the user's Google ID token and pilot consent; do not extract the app's refresh token to test them. CLI admin login is distinct from app-user Google consent and from the runtime service account.

For an authorized deployment, `backend/infra/deploy.sh` takes `COVE_SYNC_ENV_FILE` (local YAML) and `COVE_DB_SECRET_VERSION` (pinned version). The runtime service account is `cove-sync-api@cove-mail-20260922.iam.gserviceaccount.com`. Inspect existing deployed secret references/configuration before changing them; do not guess a secret version or rerun provisioning as a connection fix. `backend/infra/verify.sh` creates/runs a synthetic verification job, so it is not a purely read-only login check.

### Cloudflare, Pen, GitHub, and Apple

- **Cloudflare:** use the configured `cloudflare_api` MCP with its existing private OAuth session. Discover endpoints with its `search` tool before `execute`. Cove's account ID is `f1bf637a915898a7dfe461bd5883357d`, Pages project `covemail`, and domain zone ID `f2ddf5cf3624e799642d9583d9216c03`. Verify the selected resource before writes. If reconnecting, use the agent client's integration authorization; do not paste/export OAuth tokens. Porkbun remains the registrar; normal app/site releases need no registrar or nameserver changes.
- **Pen:** use the configured `pencil` MCP, inspect `get_app_state`, and load its relevant `read_skill` instructions before design operations. The original desktop setup used stdio command `/Applications/Pen.app/Contents/Resources/app.asar.unpacked/out/mcp-server-darwin-arm64` with args `["--app", "desktop"]` and no custom environment. This path is machine/architecture-specific: verify it exists and Pen is available before configuring another Mac. A named live frame can supersede an exported HTML reference.
- **GitHub:** repository remote is `https://github.com/scarranca/emailclassifier`. Use the configured Git credential flow or authenticated GitHub integration. Inspect `git remote -v` and current branch/worktree state; do not place a PAT in the remote URL or project files. Git authentication does not grant permission for unrelated repository changes.
- **Apple:** distribution uses the existing Developer ID identity and Keychain profile `Cove-notarization`. Follow the release section and `docs/DISTRIBUTION.md`. If the profile is missing, have the user enter credentials at the local notarytool prompt; do not treat browser sign-in as notarytool authentication or reset their Keychain.

Google Cloud changes on September 30: `tasks.googleapis.com` was enabled with `gcloud`, and `https://www.googleapis.com/auth/tasks` was added in Google Auth Platform → Data Access. The Cloud Console asks the user for a passkey confirmation first, so hand that step to them. Consent scopes are now `gmail.modify`, `calendar.events` and `tasks` (plus `openid email` for cloud sync).

Access checked September 26, 2026: PlanetScale MCP returned `connection_ok: 1`; `pscale auth check` reported authenticated for the intended organization; `gcloud` successfully read the Cove Cloud Run service URL. These checks read no mailbox content and changed no database/cloud resources. Sessions may expire; recheck rather than assuming this record means a new agent is authenticated.

## Build and test without blocking the Mac

Build with Xcode's toolchain: the Command Line Tools' macOS 27 SDK lacks SwiftUI's `@State` macro plugin, so a plain `swift build` fails with "SwiftUIMacros not found" while Xcode builds cleanly. The build scripts set `DEVELOPER_DIR` themselves; in a terminal, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once (or prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). XCTest (`swift test`) also needs Xcode.

```sh
swift build
swift test --filter SettingsLayoutTests
swift test --filter 'TypographyRenderingTests|ClaudeConnectionTests.testIntegrationsLayoutOffscreen'
# Broaden to the relevant core/workflow suite, or the full offline suite when warranted:
swift test
```

- Use injected HTTP transports, synthetic accounts, temporary databases and isolated UserDefaults. Live account/provider tests are opt-in; inspect their environment gates before enabling them.
- Reuse `NSHostingView`/hidden `NSWindow` rendering fixtures. Never call `orderFront` for routine QA.
  - The one exception is SwiftUI gesture tests (`CalendarDragInteractionTests`): gestures only run in an ordered window, so those use `orderFrontRegardless` at alpha 0, 40,000 points off-screen, without activating the app.
  - Several suites write PNGs to the same `/tmp/cove-*.png` names. Give new renders unique names and inspect them right after the run.
  - Test files that build `MailContact` or other internal-init types need `@testable import CoveCore`. Avoid `RootView`'s polling task; render the production destination directly. Sample Reader avoids restoring real writing credentials.
- Useful fixtures: `SettingsLayoutTests`, `TypographyRenderingTests`, `ClaudeConnectionTests.testIntegrationsLayoutOffscreen`, `AgentHubDesignTests`, `MailNavigationTests`, `LabelMailboxTests`, `CalendarSeparationRenderingTests`, `CustomAgentTests`, `AssistantChatRenderingTests`, `AssistantAgendaTests`, and compose rendering/selection suites.
- Inspect the actual screenshots, not only test exit status. Fixed-width sheets can resize their hosting windows; use their native width or a containing layout rather than treating a cropped fixture as a production bug. Web-only design scanners cannot certify SwiftUI.
- `scripts/build-qa.sh` creates a separate QA bundle; read its isolation settings before launch. Do not launch a real-account build merely to check typography.
- Backend tests require the disposable loopback PostgreSQL fixture described in `backend/README.md`. They recreate synthetic schema/roles: **never point them at PlanetScale**. Use `npm ci --ignore-scripts` and `npm test` from `backend/` with that fixture.
- Record what was actually verified, skipped, or left for a live check in a versioned QA audit. Do not add tests that only restate constants for trivial visual edits.

## Release and website workflow

A documentation-only change does not need an app release. For an authorized app release:

1. Determine the next version/build from `scripts/write-app-info.py` and `site/release.json`; both increase. Add `docs/releases/VERSION.html` and a QA audit; update the beta page's version and release copy.
2. Build the universal distribution app:
   ```sh
   COVE_DISTRIBUTION=1 COVE_GOOGLE_OAUTH_FILE="$PWD/.local/google-oauth-desktop.json" scripts/build-app.sh
   ```
3. Submit the app once with `scripts/notarize-app.sh Cove-notarization`. Save the submission ID; poll that ID. Never resubmit an uncertain/in-progress upload. After Accepted, run `scripts/finish-notarization.sh APP_ID Cove-notarization` to staple and create the signed DMG.
4. Submit that version's DMG once with `xcrun notarytool submit ... --keychain-profile Cove-notarization --output-format json --no-wait`. After Accepted, run `scripts/finish-dmg.sh DMG_PATH DMG_ID Cove-notarization`.
5. Run `python3 scripts/prepare-update.py VERSION`, then `python3 scripts/build-site.py`. These verify/sign artifacts, stage checksums/feed/metadata, and preserve historical downloads. Never hand-edit a signed feed.
6. Publish `dist/site` through the authenticated Cloudflare integration to the existing **`covemail` Pages project**, with downloads and feed together. Domain **covemail.xyz** is registered at Porkbun and hosted through Cloudflare. Temporary `/tmp` deployment helpers from an earlier session are not portable tooling; inspect or replace them rather than depending on their existence.
7. Verify the public beta page, `/download/latest`, `/release.json`, `/updates/appcast.xml`, DMG bytes/SHA-256 and Ed25519 signature. Use `scripts/qa/verify-update-signature.swift` and `scripts/qa/probe-update.swift` for signature/tamper checks and headless previous/current-build update probes. Probe isolated copies; do not launch/install over the user's running Cove.
8. Record notarization IDs, deployment ID, checksum, tests and limits. Commit/push within authorization; if merging to `main`, inspect its worktree and use a safe fast-forward where possible. Report how to install: **Cove → Check for Updates…**.

Signing team: `27H459Y2P9`. Notarization profile: `Cove-notarization`. Sparkle public configuration: `assets/update-config.json`; private signing key remains in Keychain. Never rotate identities/keys to bypass a local prompt. Cloudflare Pages' current pipeline enforces a 25 MiB download limit.

Google OAuth remains a private beta/tester-allowlist flow. Apple notarization does not make Google consent publicly approved. Adding a beta user requires the applicable Google tester configuration; do not promise anyone can sign in solely because they downloaded the DMG.

## Outstanding work, not promises

- Record the real-account first cloud consent/upload check; synthetic infrastructure checks already passed in 0.1.39.
- Mobile UI, multiwriter synchronization, server Gmail ingestion/watch, server-side Jev, and cloud drafts are future work requiring additional design/security review.
- General-public Google OAuth verification and clean-Mac onboarding coverage remain distinct from shipping notarized private-beta updates.
- GitHub is a coming-later placeholder; do not display it as connected. Google Tasks is real since 0.1.52 (see below).
- Tasks: Jev checks mail when it is opened or sent. It does not check new mail as it arrives, which is proposed but not built.
- Before publishing 0.1.52, refresh the landing page (it currently shows the 0.1.51 feature set) and remove "Google Tasks · Coming soon" from its tools row.
- Always re-check the current task and repository for newer evidence before acting on this checkpoint.
