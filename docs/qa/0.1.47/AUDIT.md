# Cove 0.1.47 (unreleased) — reuse stored mail on reconnect

Implementation verified September 28–29, 2026. Not built, notarized or published; no version/build number was changed.

## Behavior

Mail downloaded on first connection already stays in the per-account encrypted SQLite store (AES-GCM records, Keychain key that survives Disconnect). Reconnecting the same account reopens that store and resumes from the saved Gmail history cursor, so only changes are fetched.

This change closes the remaining re-download paths:

- **Expired or missing history cursor** (for example, reconnecting after a long absence): the first page now requests `format=minimal` (labels only) for messages already stored, and `format=full` only for new ones. Stored messages on that page are no longer checked a second time by deletion reconciliation.
- **Older mail pages and label views**: listed messages already stored refresh their labels only. A confirmed 404 on a stored message removes it; in label views, its cloud snooze is cancelled the same way the main sync does.
- Refreshed stored messages keep their body, draft, Jev assessment and snooze.
- A pending decoder upgrade (`mailDecodingVersion` below the current version) still downloads full content, as before.

Security is unchanged: no new storage, keys, network destinations or plaintext copies. Fewer body downloads means less mail content in transit.

## Verification

- `swift build --target CoveCore` passed. The `Cove` app target could not be compiled on this Mac: only Command Line Tools are installed (no Xcode), and they lack the SwiftUI macro plugin and XCTest. The `AppStore.swift` changes were reviewed by hand and pass `swiftc -parse`, but are **not type-checked**; build with Xcode before release.
- XCTest was unavailable, so `Tests/CoveCoreTests/GmailSyncTests.swift` ran unchanged through a temporary Swift Testing harness (XCTest assertion shims, symlinked `CoveCore`). All 12 tests passed: 9 existing and 3 new (expired history refreshes stored messages by labels only, with one request each; older pages download only unstored messages; a decoder refresh still downloads full content).
- Mutation check: reverting the fallback to uncached listing makes the new expired-history test fail.

## September 29 — Xcode build and real-account check

- With Xcode 27.0 (`DEVELOPER_DIR` set per command; system `xcode-select` unchanged), `swift build` passed for the whole package, including `AppStore.swift`.
- Full offline `swift test`: 453 tests, 0 failures, 7 skipped (CoveRenderingTests 264, CoveCoreTests 189). Targeted: GmailSyncTests 12, LabelMailboxTests 7, MailboxPollingTests 7, EncryptedStorageTests 7, MailboxPersistenceTests 6.
- Real account, isolated `Cove QA` (`ai.cove.qa`, separate storage and Keychain; installed Cove 0.1.46 untouched). The QA binary carried a temporary, uncommitted logger recording Gmail request kinds only:
  - First connection: 54 Gmail requests (latest page listed and downloaded in full). Store created at `Cove/QA/<sha256>.sqlite` with mode 0600, directory 0700.
  - Quit and reopen: 2 requests (`history`, `labels`). No message content downloaded.
  - Disconnect (keep local data), then reconnect the same account: 1 `history` request plus 1 `format=minimal` label check for a message whose read state changed. No full downloads.
  - Messages opened in the reader triggered their normal thread refresh and a mark-as-read `modify`, as expected in 0.1.46.
- Not exercised live: expired-history fallback, older pages and label views (the cursor was fresh). These are covered by fixtures above.
- Logger caveat: the classifier printed the last path component for unrecognized paths, so two opaque Gmail thread IDs (no content) reached the local macOS unified log. The captured files were deleted; unified-log entries age out on their own.

## Limits

- After the history cursor expires, every stored message outside the first page still gets one `format=minimal` existence check. This client does not implement Gmail's multipart batch requests, and skipping the checks would let deleted mail linger.

## September 29 — Inbox Unread filter

Inbox's filter row is now **Priority · Unread N · All mail**; the three are mutually exclusive, and N counts unread, non-snoozed Inbox mail. The label-view unread toggle and the Inbox filter share `labelUnreadOnly`, which `chooseFolder` resets. In any unread-only list, the open message stays listed after it is marked read until selection moves on. Previously in label views, a background sync could deselect it and close the reader.

`LabelMailboxTests.testInboxUnreadFilterKeepsOpenMessageUntilSelectionMoves` covers counts, filtering, mark-read retention, keyboard movement and reset on folder change. LabelMailboxTests (8), MailPaginationTests (4) and MailNavigationTests (5) passed. No hidden-window screenshot of the new row was inspected.

## September 29 — one-step Calendar connection

**Connect Google Calendar** (Home, Calendar, and Settings → Gmail's new Calendar row) adds `calendar.events` to the current Google sign-in. It uses `login_hint` for the connected address and `include_granted_scopes=true`, with the bundled client, so no client ID or secret is needed. The mailbox, screen and selection are not reloaded. A different Google account, a declined Calendar permission, or an account change during sign-in commits nothing. Reconnect Gmail keeps Calendar when it was connected. The custom OAuth client fields stay under Google connection settings for Gmail. The authorization URL is built by `OAuthSupport.authorizationURL`, tested in `OAuthCalendarTests`.

Settings Gmail 900-point render inspected.

Live check (September 29, Cove QA, real gigstack.io account): the first attempt returned Gmail-only consent. Google silently dropped `calendar.events`, and Cove QA stayed disconnected; an inline explanation is now shown beside Connect. Checked read-only with `gcloud` and Cloud Console: the Calendar API is enabled in `cove-mail-20260922` (project number 1079898814598, which owns the bundled client), and `calendar.events` is registered as a sensitive scope on the consent screen. The cause was the gigstack.io Workspace API controls: Cove was not a configured app. After the user set Cove (client `1079898814598-8vau2s978c3ulmlhsoae7pka15d58o7f`) to **Trusted** in admin.google.com, Connect Google Calendar succeeded and `calendarConnected` became true for `ai.cove.qa`. Other Workspace domains may need the same admin approval. The installed Cove was untouched.

## September 29 — conversation reader cleanup and Reply all

- Thread messages are separate cards: the open card has a darker outline and collapsed cards are shaded. Each card header shows avatar, sender, unread dot, recipients (expanded) or snippet (collapsed), date, and attachment icon. Reply, Reply all (when applicable) and a message menu (Reply, Reply all, Forward, Translate) sit in the header. The duplicate header **…** menu, per-message Translate menu and "Reply to this message" button were removed. In conversations the reader header shows the subject and message count; single messages keep the sender row. Translate for a single message is in the toolbar's More menu.
- Reply editor: the Send, Template and AI buttons and the Discard icon share one centred 40-point row. The earlier misalignment came from `MailChipLayout` top-aligning mixed-height controls. Narrow widths split into two aligned rows.
- Reply all: `Mail.cc` is decoded from the Cc header. `""` means no Cc, and `nil` means an older snapshot, where Reply all stays hidden until the thread is reopened (opening fetches `format=full`). `GmailMessage.decodingVersion` was **not** bumped, so no cache-wide re-download happens. Recipients: incoming To = Reply-To or sender; Cc = original To ∪ Cc minus the account address and the To address; the sender is not added when Reply-To differs. Sent mail: To = original To, Cc = original Cc minus self. Addresses are validated with `ContactDirectory.isValidEmail`, deduplicated by normalized address, and re-rendered, keeping only safe display names. `rawMessage` rejects newlines in Cc. `ContactDirectory.addresses` now reads the final `<…>` as the address, so a quoted name containing `<` no longer hides it. The editor shows To/Cc and a Reply all ⇄ Reply to sender only switch that keeps the draft. `CloudMailRecord` has explicit fields, so Cc is not uploaded to the cloud pilot.
- Limit: send-as aliases are not stored, so only the primary account address is excluded from Cc.
- Tests: `ReplyAllTests` (5), `ReaderConversationTests.testReplyEditorActionsRenderOnOneAlignedRow` (includes a sample send carrying Cc). Full offline suite: 461 tests (266 rendering + 195 core), 0 failures, 7 skipped. Inspected `/tmp/cove-conversation-{420,760}.png` and `/tmp/cove-conversation-reply-{420,760}.png`. Pen frames `w3s2H`/`CQs4F` could not be consulted (no Pen MCP in this session); layout follows DESIGN.md roles and the existing palette.

## September 29 — reply menu, label picker, Ask Cove thread context

- **Reply** in the response bar is one primary button with an attached menu (Reply, Reply all) when reply-all recipients exist; the separate Reply all button and the card-header Reply all icon were removed (Reply all stays in each card's message menu and in the editor's recipient switch).
- **Labels**: the full-height native menu is replaced by a 280-point popover with a focused search field, checkbox rows (toggling applies/removes in Gmail), a 260-point scroll limit and Refresh labels.
- **Ask Cove**: when the open email belongs to a multi-message conversation, the scope now starts as **Whole thread** (the existing `aiThreadContext` Gmail thread fetch); "This email" remains in the scope picker. The user's question bubble hugs its text and aligns right (previously it was stretched to 464 points).
- **TypeSafe key**: Jev's missing-key error now names Settings → Jev · Mail agent (`JevClient.missingKeyMessage`), and Ask Cove shows **Add TypeSafe key** (opens that Settings section) and **Connect a writing model** (Integrations) instead of Try again.
- Inspected `/tmp/cove-reply-split.png`, `/tmp/cove-label-picker.png`, `/tmp/cove-assistant-design.png`. Full offline suite: 462 tests (267 rendering + 195 core), 0 failures, 7 skipped. The thread-scope default is view state and was not unit tested; live check pending.

## September 29 — learned writing voice

**Settings → Jev · Mail agent → Your voice → Learn from my sent mail** builds a `VoiceProfile` from the user's own sent mail:
- **Input:** up to 25 newest sent messages from the account address. Drafts, aliases, quoted replies ("On … wrote:", "El … escribió:", `>` lines) and forwarded blocks are removed, and each excerpt is capped at 1,200 characters. If fewer than 15 usable samples are stored, one Gmail `labelIds=SENT` page is fetched; stored IDs get only a `format=minimal` label check.
- **What the model returns:** the new `AIIntent.learnVoice` asks the connected writing model for style only (summary, greetings with `{name}`, sign-offs, traits, generic phrases, languages). It must not copy names, addresses, amounts or confidential content. The parser is bounded and rejects unreadable output.
- **What is saved:** only the profile, not sent bodies, in `Preferences.voiceProfile` inside the per-account AES-GCM encrypted SQLite store.
- **Where it's used:** `ComposeSuggestion.instruction(…, profile:)`, so AI replies, the composer's AI writing and custom-agent prepared replies all get it. Language rules keep precedence. **Forget my voice** removes it.
- **Persistence:** per Gmail account on this Mac. It survives Disconnect and reconnecting the same address, but does not follow a different account or another Mac. Syncing it through the cloud pilot would need a new backend table and migration with exact-SQL approval; not built.
- **Tests:** `VoiceProfileTests` (4), `VoiceLearningTests` (2: encrypted save/reopen/forget with quoted text excluded from the prompt; sent-page fetch without re-downloading stored mail). Settings Jev 900-point render inspected. Live learning in Cove QA pending the user.

## September 29 — new emails and introductions from Ask Cove

- The assistant router (`planAssistant`) gains `compose` for new emails to people named in the request ("make an intro between Ana and Luis", "email Carlos about Friday"). Replies to the selected email stay on the email route. The model returns names exactly as typed and is told never to invent an address.
- `RecipientResolver` (CoveCore) matches names to the user's own contacts (saved records plus correspondents): exact case- and accent-insensitive name first, then prefix-token match, ranked by recent mail. A bare address is accepted only if the user typed it or it's already a known contact; the account's own address is excluded. Ambiguous or unknown names produce a clarification listing candidates; nothing is written.
- `AppStore.draftNewEmail` writes the body with the `.write` intent, the voice profile and recent mail with those people. Introductions address both by first name and don't invent facts about either person; default subject is `Intro: A ⟷ B`. It then opens a local draft in the composer. Nothing is sent; the chat says so.
- Tests: `RecipientResolverTests` (3), `AssistantComposeTests` (1: route parse, resolution, voice in the prompt, draft recipients and subject, no sent mail, clarification for unknown people), `AssistantCalendarTests` unchanged and passing. Live check pending: ask for an intro between two real contacts in Cove QA, **open the draft, do not send**.
- Fix: introduction wording applies only when two or more people resolve; "introduce me to Maya" is a normal new email (covered in `AssistantComposeTests`).

## September 29 — AI key storage review (no code change)

- **Current storage:** `Vault` stores provider API keys (`aiProvider.*`), the TypeSafe key and Google credentials as generic-password items in the user's **login keychain** (legacy file-based keychain). Verified read-only on this Mac with `security find-generic-password` metadata (no secret printed): `ai.cove.qa/typesafeKey` is in `~/Library/Keychains/login.keychain-db`.
- **Protection:** items are encrypted at rest, and the item ACL trusts Cove's signing identity; other apps prompt. Keys never go to UserDefaults, SQLite, files, logs, the cloud mirror or prompts. They are read only when a request is made. Subscription connections (Codex CLI / Claude Code) keep their own credentials in the keychain from isolated config folders.
- **Finding:** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in `Vault` has **no effect** in the legacy keychain; accessibility classes apply only to the data-protection keychain (`kSecUseDataProtectionKeychain`). Changing it to `WhenUnlockedThisDeviceOnly` would also be inert, so it was not presented as hardening.
- **Real upgrade path (not implemented, needs Apple account setup):** move only `aiProvider.*`/`typesafeKey` to the data-protection keychain (`WhenUnlockedThisDeviceOnly`, non-synchronizable), optionally with a Touch ID `SecAccessControl` (`.userPresence`) opt-in. Migration: read legacy → write new → delete legacy. This requires an App ID, an embedded Developer ID provisioning profile and a `keychain-access-groups` entitlement (team `27H459Y2P9`). An ad-hoc QA build can't verify it (expected `errSecMissingEntitlement`), so it must be verified on a distribution-signed build. Do not migrate the Google session or mailbox key items.
- **Declined:** storing AI keys in the cloud database. The pilot server can decrypt what it stores (not end-to-end), and project rules keep owner keys on the device.

## September 29 — voice shared across accounts on this Mac

- The learned voice is also kept in a Mac-level Keychain entry (`voiceProfile.shared`, JSON `SharedVoiceRecord` in Cove's service, never UserDefaults). Opening any real account reconciles its copy with the shared record (newest wins), so a voice learned in one Gmail account is used by every account on this Mac and survives sign-out/sign-in. "Forget my voice" writes a dated empty record that clears older copies in other accounts when they open. Sample mailboxes don't share. A Keychain read failure never blocks opening a mailbox.
- Tests: `SharedVoiceTests` (2) with an injected in-memory store and offline transport. An earlier draft of this test used the live Gmail client and made one unauthenticated request (HTTP 401, dummy token, no data); the fixture now uses an offline transport.

## September 29 — hardened AI key storage (implemented; protected path pending a signed build)

- `HardenedSecrets` handles only `aiProvider.*` and `typesafeKey`; Google session and mailbox keys are unchanged.
- **Probe:** once per launch, a throwaway item is written to the data-protection keychain. On `-34018` (missing entitlement, as on ad-hoc/QA builds and today's Developer ID build) everything stays in the login keychain exactly as before.
- **When available:** keys are written to the data-protection keychain as `WhenUnlockedThisDeviceOnly` and non-synchronizable. The write is confirmed by reading attributes back before the login-keychain copy is deleted; a failed readback keeps the legacy copy. Existing keys move the first time they're read.
- **Touch ID (opt-in):** Settings → Privacy → Require Touch ID for AI keys. It's disabled with an explanation until the build is hardened. It uses `SecAccessControl(.userPresence)` and one `LAContext` with a 5-minute reuse window. Cancelling never falls back to another copy. While it's on, automatic custom-agent checks and automatic Jev organizing pause with a visible notice (manual runs continue), and opening Settings no longer pre-reads the TypeSafe key; saving never erases a key that wasn't loaded. The toggle re-saves keys off the layout pass.
- **Signing:** `assets/Cove.hardened.entitlements` (application-identifier, team-identifier, keychain-access-groups `27H459Y2P9.ai.cove.mac`, location). `scripts/build-app.sh` uses it and embeds `.local/Cove.provisionprofile` **only if that file exists**, after checking the profile's app ID and team. Otherwise the build is unchanged. `build-qa.sh` still uses the default entitlements (ad-hoc plus a restricted entitlement would be killed at launch).
- **Verified:** `HardenedSecretsTests` (7, fake Keychain: scope, no-entitlement fallback, device-only attributes, readback-gated move, failed readback, first-read migration, Touch ID access control, cancellation, context reuse); an ad-hoc probe binary confirmed `-34018` and that `SecAccessControl(.userPresence)` can be created. **Not verified:** the data-protection path on a real profile-signed build, which needs an App ID for `ai.cove.mac` plus a Developer ID provisioning profile. Verify at release on an isolated copy; don't launch a hardened build alongside the user's running Cove (same bundle ID, store and Keychain service).

## September 29 — cross-Mac voice (proposed only)

`backend/migrations/003_voice_profile.sql` proposes `cove_sync.voice_profiles` (one encrypted profile per Google identity, forced RLS like migrations 001/002). It is **not applied**, and no route code was written. It needs the user's exact-SQL approval, then backend routes and client sync under the opt-in cloud pilot. Server keys can decrypt it (not end-to-end).
