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
