# Cove 0.1.57, build 59: mail from the keyboard

## Changes

`MailNavigationShortcut` handles these letters by character, so they follow the user's keyboard layout. They act on the selected email, only on the Mail screen, and not while a text field, sheet or menu has focus.

- **R:** reply. It sets `AppStore.replyRequestID`, and the reader opens its reply box through the same `startReply` path as the Reply button (or the composer for a local draft).
- **E:** done. It archives the Inbox email and immediately selects the next one (or the previous one, at the end of the list).
- **U:** toggles read/unread through `modify`, which is optimistic and queued.
- **Existing keys:** ⌘Delete (Trash with Undo), ↑ ↓ and Esc/← are unchanged. The list footer shows "↑ ↓ emails · R reply · E done · U unread", and its tooltip lists everything.
- **Design change during QA:** the user first had R as done; they then asked for R = reply, the Gmail/Superhuman convention.

## Verification

- **Full offline suite:** CoveCoreTests 278 (1 skipped) and CoveRenderingTests 368 (7 skipped), 0 failures.
- **`MailNavigationTests.testUTogglesReadEArchivesThenOpensTheNextAndRReplies`** checks:
  - U with nothing selected passes through, and U on a selected email marks it read.
  - R requests a reply for the open email without moving the selection.
  - E archives and selects the next email.
  - R and E pass through while typing.
- **Left for the user's QA build:** opening the reply box and its focus.

## Release

- **App notarization:** `96dc2ab7-7e75-4c5a-9157-5af0c8817263`, Accepted and stapled.
- **DMG notarization:** `8cde71bc-08d7-473d-8f9f-f2d61da0ccae`, Accepted and stapled.
- **DMG:** 22,534,814 bytes, SHA-256 `1d1b73eb7a83acf883bd9b7dd7994e90f2598a9e41cbce543310bbfde92bddd1`.
- **Feed and site:** signed feed with 36 verified releases; Cloudflare Pages deployment `da94d37e`.
- **Public checks:**
  - `/release.json` reports 0.1.57 (build 59); the appcast and `/download/latest` serve 0.1.57; the beta page says "Download Cove 0.1.57".
  - The downloaded DMG's bytes and SHA-256 match the local build.
  - The Ed25519 signature verifies with the bundled key, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
