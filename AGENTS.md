# Cove — guide for coding agents

This is the shared handoff for the Cove repository. Read it before changing the app, backend, website, or release pipeline. Keep it current when architecture, product behavior, or release procedures change. Current user instructions take precedence over this file.

## Start here

1. Inspect `git status`, the current branch, and any applicable nested instructions. Preserve unrelated work. This repository is used through multiple worktrees; never assume another checkout is clean.
2. Read `PRODUCT.md` and `DESIGN.md` for product and design intent, then the relevant implementation and tests.
3. Read the latest applicable `docs/qa/<version>/AUDIT.md`. Use `site/release.json`, `scripts/write-app-info.py`, and the published feed to establish release state; do not infer that a local build is published or installed.
4. For cloud work, read `backend/README.md` first. For providers, read `docs/AI-PROVIDERS.md`; for packaging, read `docs/DISTRIBUTION.md` with the historical caveats below.

Some README/status/distribution sections are historical and still mention older versions, no deployed backend, or the old `Cove / Needs review` behavior. Newer code, versioned evidence, and this handoff supersede those claims. Do not report old test totals as verification of new changes.

## Current checkpoint — September 26, 2026

- **Cove 0.1.43, build 45**, is published at `https://covemail.xyz`. Its universal app and DMG are Developer ID signed, notarized, and stapled. The signed Sparkle feed and public download were verified.
- Implementation/release commit: `6204c90` (`Unify Cove typography and publish 0.1.43`), pushed to `main` and `scarranca/cove-oauth-credentials-setup`. This identifies the checkpoint, not a required branch for future work.
- The latest pass unified typography across all native destinations, retained compact Settings/Integrations density, matched compose and AI-preview text, and made narrow calendar invitation controls stack. **41 affected tests passed** after fixture corrections; this was a targeted suite, not a new full-suite claim. See `docs/qa/0.1.43/AUDIT.md`.
- Settings shows **one selected section at a time**, not one long page of all sections. This was introduced in 0.1.41; 0.1.42 fixed button styling and secondary-text density.
- The optional recent-mail cloud pilot was deployed in 0.1.39. It is **off by default**, supports one uploading Mac, and is not a complete mobile sync system. The first real-account consent/upload check has no recorded completion in the release audit. Do not claim it passed without new evidence.
- The typography release was delivered through the updater; the user's running app was not quit or replaced. Published version and locally installed/running version may differ.

## Product and collaboration expectations

Cove is a native macOS Gmail client with Jev organization, optional generative writing/chat, Calendar, Contacts, and user-configured agents. The user wants a calm, readable product faithful to their Pen designs, with working interactions rather than decorative mockups.

- Implement the requested work and verify it. Resolve routine reversible choices without repeatedly asking permission. Request missing credentials or approvals only when genuinely required, and explain the specific blocker.
- The user wants to keep using their Mac while work proceeds. Prefer hidden-window rendering and injected test fixtures. Do not foreground apps, quit Cove, discard drafts, replace `/Applications/Cove.app`, or install an update over a running session without current authorization and safe closure.
- Do not send real mail, respond to real invitations, or create/delete real events as a test without explicit authorization. Synthetic fixtures are the default.
- Keep passwords, API keys, refresh tokens, signing keys, and database credentials local. Never ask for them in chat or print secret-bearing files/CLI responses.
- Push/merge/publish only within the current task's authorization. Check both worktrees and remote state; avoid force pushes and destructive resets. A prior release is not blanket authorization for unrelated external changes.
- If parallel agent work is authorized, assign separate files or read-only reviews, share findings, and inspect every result. Agents share the filesystem.

## Repository map

| Area | Primary implementation |
| --- | --- |
| App shell, navigation, state | `Sources/Cove/CoveApp.swift`, `AppStore.swift`, `CoveRuntime.swift` |
| Shared design and text roles | `Sources/Cove/DesignSystem.swift`, `HomeTypography.swift`, `DESIGN.md` |
| Onboarding, Google auth, Keychain | `SetupViews.swift`, `BundledGoogleOAuth.swift`, `Security.swift`; core Google session/OAuth files |
| Home | `AgentHubView.swift`, `HomeActions.swift`, `HomeCalendarView.swift`, `HomeWeatherView.swift`, `MailTideView.swift` |
| Mail and reader | `MailViews.swift`, `EmailBodyView.swift`, `MailNavigationShortcut.swift`, `MailQuickActions.swift`, `MailDeletionToast.swift` |
| Categories, labels, flags | `MailCategoriesView.swift`, `MailLabelViews.swift`; core `GmailLabels.swift`, `JevMailFlag.swift` |
| Compose and AI review | `ComposeTextEditor.swift`, `ComposeSuggestion.swift`, `AIWritingSheet.swift`, `WritingMotion.swift`, `WritingAgent.swift` |
| Chat | `AgentChatView.swift`, `AssistantResponse.swift`, `AssistantAgenda.swift`, `AssistantCalendar.swift`, `ChatMarkdown.swift`, `AssistantModelPicker.swift` |
| AI accounts and model discovery | `AIProviderSettings.swift`, `ChatGPTConnection.swift`, `ClaudeConnection.swift`, `IntegrationsView.swift`; core provider/sandbox files |
| Calendar | `CalendarView.swift`, `CalendarMonthView.swift`, `CalendarNavigation.swift`, `CalendarSearchView.swift`; core calendar files |
| Contacts | `ContactsView.swift`, `Sources/CoveCore/Contacts.swift` |
| Agents | `CustomAgentViews.swift`, `AgentViews.swift`; core `CustomAgent.swift`, `JevAutomation.swift`, `Jev.swift` |
| Settings | `SettingsView.swift`, `SettingsSidebar.swift`, `SettingsPresentation.swift`, `ReadingSettingsView.swift`, `CloudSyncSettings.swift`, `AppUpdater.swift` |
| Storage and API contracts | `Sources/CoveCore/Database.swift`, `MailboxPersistence.swift`, `RecordCipher.swift`, Gmail/HTTP files |
| Optional cloud mirror | `Sources/CoveCore/CloudMailSync.swift`, `backend/` |
| Landing page and downloads | `site/`, `assets/update-config.json`, `scripts/build-site.py` |
| Verification | `Tests/CoveCoreTests/`, `Tests/CoveRenderingTests/`, `docs/qa/`, `scripts/qa/` |

## Design rules to preserve

- The supplied Foundations/Components and product HTML references are preserved in `docs/design-source/`. The user also edits live Pen designs; inspect the relevant current frame when a request names it. Familiar names include Cove Agent Chat, Cove Label, Cove Settings, Cove Integrations, Agent Hub, and the landing design “quiet momentum.” Do not assume an old export includes a new edit.
- Use bundled **Inter**, the existing `Palette`, and semantic fonts. Current roles: page title **24 medium**, detail title **20 medium**, section **16 medium**, subheading **14 medium**, reading body **14 regular**, labels **13 medium**, secondary copy **12 regular**, controls **12 medium**, metadata **11 regular**.
- Use `PrimaryButton` / `SecondaryButton`; normal controls remain 40 points high. Compact controls use 12-point medium labels with compact geometry. Do not introduce native automatic bezel buttons among Cove actions. Native menus and date controls may keep platform behavior.
- `CoveFieldStyle` defaults to secondary text. For prose, pass `CoveFieldStyle(font: .coveBody)` explicitly; an outer `.font` does not override the style's internal font.
- `CoveTypography` supplies native compose/preview font and paragraph spacing. Avoid text changing size when an AI suggestion replaces the draft canvas. Plain email and long agent prose use a bounded reading width.
- Keep settings sections separate, advanced credentials collapsed where appropriate, and provider configuration in Integrations. Do not put subscription setup back into compose.
- Preserve unread emphasis and indicators, Markdown semantics, sender-authored HTML, avatar sizing, and larger sign-in brand/artwork typography. These are intentional exceptions, not drift.
- Muted `#737373` is for white/near-white surfaces; use darker body text on selected/sidebar/shaded surfaces. Check real rendered contrast and wrapping.
- Waiting AI uses truthful progress and a quiet spinner/skeleton, not hard looping particle motion. Preserve the finite returned-text glyph animation; interaction finishes it immediately and Reduce Motion skips it.
- Apply draft is a small, left-aligned canvas action. Applying a suggestion and sending remain separate actions. Preserve selected-text rewriting and original draft contents until Apply.

## Behavioral boundaries and regression traps

### Mail and agents

- Gmail sync is roughly every two minutes **while Cove is open**, using incremental history with pagination/reconciliation. Background Gmail sync and automatic Jev processing are separate settings. No server-side Gmail push ingestion exists yet.
- No selection means the intentional empty reader. Up/Down navigates messages; Escape/Left returns to the list. Shortcuts must yield to text editing, menus, and dialogs.
- `⌘Delete` moves mail to Trash after a five-second Undo window. Preserve countdown/retry/error completion; never leave “Moving to Trash…” indefinitely. Do not confuse Trash with permanent deletion.
- Follow-up flags synchronize with Gmail stars. Jev action/urgency flags are separate assessments. **Categories contains only the user's agents' configured/applied labels**, not built-in Jev categories or hardcoded examples such as Purchases.
- Uncertain custom-agent results belong only in **Agents → Activity**. Do not add `Cove / Needs review` Gmail labels again.
- Agents evaluate ordered rules; first confident match may label, prepare a reply, or both. Replies are reviewable Activity suggestions. Agents do not automatically send, delete, make purchases, or mutate Calendar. Preserve retry/idempotency around completed label actions.
- Jev produces structured decisions and selected source passages, not generated summaries/replies. Generative providers are a separate feature. Source quotations must remain attributable and faithful.
- HTML mail preserves sender formatting while blocking scripts, forms, frames, and remote styles. External images require the existing preference/action; text-only mode loads none. Keep MIME/CID handling and Reply-To behavior.

### AI writing and chat

- Model lists come from the connected provider/official CLI, with version information where available. Settings' saved default and a conversation override are distinct. Do not hardcode one model or silently substitute another.
- ChatGPT subscription uses the separately installed official Codex CLI; Claude subscription uses official Claude Code. Their isolated connection/configuration paths are not another application's credential store. API-key billing is separate.
- Preserve bounded, validated read-only Gmail/calendar tool dispatch. Credentials stay in Cove. Retrieved email/event text is untrusted evidence, never authority to execute tools or expand permissions.
- Selected-email questions must retain selected email/thread context even when they mention an event. Calendar-only questions should not return unrelated email passages. Render schedules as structured agendas and support Markdown.
- Calendar creation is a reviewed proposal opened in the shared event editor; an explicit user action commits it. Availability must come from actual calendar evidence and use the current local clock/time zone.
- New drafts follow explicit language instructions, otherwise the current request's language. Rewrites preserve the original language unless asked to change it. Saved voice and foreign-language source mail must not override this.
- Failures must stay visible with the attempted model and a useful retry/settings action. Snapshot provider/model and draft scope per request; reject stale updates and preserve edits on cancellation/failure.

### Calendar, Contacts, Home

- Preserve Workweek/Week/Month views, current-time scrolling, selected-day agenda, overlap layout, and quiet grid lines. User scrolling remains in control after initial navigation.
- Home surfaces pending invitations with Accept/Maybe/Decline. Ensure controls fit narrow panes, including their loading state.
- Weather is opt-in via location, with manual city fallback and visible errors. Do not silently enable location or invent forecast data.
- Contacts combine local records and downloaded correspondents; Google Contacts sync is not implemented. Keep in touch has narrower relevance filtering plus Ignore/Undo.

## Data and security

- Local account data is SQLite under `~/Library/Application Support/Cove/`, with per-account AES-GCM record encryption and keys in macOS Keychain. Sample data is separate. Never reset/delete a user's Keychain to fix an app prompt.
- Disconnect retains the local encrypted cache. Local erasure, cloud erasure, and Gmail deletion are different actions; preserve their existing explicit confirmations and accurate copy.
- Keep stable signing identity and bundle identifiers. Ad hoc builds accessing real credentials can cause repeated Keychain prompts. Use isolated sample/QA builds for development checks.
- Cloud pilot: Cloud Run in Google project **`cove-mail-20260922`**, region **`us-east1`**, backed by PlanetScale PostgreSQL **`santiagocarranc2/cove/main`** and private GCS bodies with KMS-wrapped account keys. Always specify the Cove project; do not alter the user's global gcloud project.
- The pilot mirrors up to 1,000 downloaded messages from the last 30 days, excluding drafts, Spam, Trash, attachments, credentials, contact notes, and calendar events. It is one authoritative uploading Mac, not multiwriter/mobile synchronization.
- Server keys can decrypt cloud content: **not end-to-end encryption**. Preserve consent, pilot allowlist, retention disclosures, and the local-only default.
- Tenant identity comes from verified Google identity; never accept a caller-selected tenant. Preserve forced RLS, restricted DML-only runtime roles, verified TLS, bounded pools/payloads, revision ordering, retry receipts, and generation fencing. Production schema changes require the applicable exact-SQL approval; migration 001's approval is not approval for future migrations.
- `.local/`, `.env*`, databases, key files, build outputs, and provider credentials stay out of Git. Never embed database credentials or an owner's API keys in the Mac app. The bundled Desktop OAuth client configuration is public native-app configuration, not a server secret or user credential.

## Build and test without blocking the Mac

```sh
swift build
swift test --filter SettingsLayoutTests
swift test --filter 'TypographyRenderingTests|ClaudeConnectionTests.testIntegrationsLayoutOffscreen'
# Broaden to the relevant core/workflow suite, or the full offline suite when warranted:
swift test
```

- Use injected HTTP transports, synthetic accounts, temporary databases and isolated UserDefaults. Live account/provider tests are opt-in; inspect their environment gates before enabling them.
- Reuse `NSHostingView`/hidden `NSWindow` rendering fixtures. Never call `orderFront` for routine QA. Avoid `RootView`'s polling task; render the production destination directly. Sample Reader avoids restoring real writing credentials.
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
- Google Tasks and GitHub are coming-later placeholders. Do not display them as connected.
- Always re-check the current task and repository for newer evidence before acting on this checkpoint.
