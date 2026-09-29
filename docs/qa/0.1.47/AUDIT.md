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
