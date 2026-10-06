# Cove 0.1.66, build 68: attach files

## User request

"Attach files to an email, ideally the app on mac should detect if we're drafting an email and allow to drop anywhere + the button to attach, on mac the button (icon) to attach is fine". The user approved the release with "yes please".

## Changes

- **Core:**
  - `OutgoingAttachment` reads the bytes when a file is added (security-scoped), uses composed Unicode names that can't break a header, and caps a set at Gmail's 25 MB.
  - `GmailClient.mimeMessage` builds multipart/mixed only when files are present. With no files the message is byte-identical to before.
  - `uploadSend` uses Gmail's multipart upload with the `threadId`, is retried only on rate limits, and is never retried after a server error.
- **Mac:**
  - A paperclip sits beside Send in the composer and the reply box.
  - The composer is a drop target. The window is a drop target that joins the reply being written (`replyDraftTarget`) or starts a new email.
  - Chips show name, size and remove, with the total against 25 MB.
  - Files are encrypted draft records `attachments.<target>`, never on `Mail` and never in the cloud mirror. They leave the draft only after Gmail accepts the send, so Undo or a failure keeps them.
- **iPhone/iPad:** a paperclip menu offers Photo Library (HEIC becomes JPEG) and Choose File. Files are listed under Subject and restored on Undo.

## Verification

- **Mac suite:** TEST SUCCEEDED, with CoveRenderingTests at 407 tests (7 skipped), 0 failures. New tests:
  - `OutgoingAttachmentTests` (core):
    - the no-attachment message is unchanged;
    - multipart parts round-trip byte for byte, with an RFC 2231 filename;
    - header injection is stripped;
    - the 25 MB limit holds;
    - the upload URL and `threadId` are correct;
    - a 500 is attempted only once.
  - `DraftAttachmentTests` (rendering):
    - files survive a restart after the original is deleted;
    - a folder is refused;
    - the upload carries the file;
    - the record is removed after the send;
    - drop routing goes to the reply or to a new email.
- **Renders:**
  - Mac: `/tmp/cove-compose-attachments.png`.
  - iPhone simulator: `-CoveSample -CoveTab mail -CoveCompose -CoveAttachSample`.
- **Not done:** no real email was sent. Drag-and-drop from Finder was not exercised by a person, and iPad drag-and-drop isn't supported.

## Release

- **App notarization:** `55ef214f-907f-4807-8469-8407b630e72d`, Accepted and stapled.
- **DMG notarization:** `9081b89e-e377-48c2-89fe-0268d5a326ba`, Accepted and stapled.
- **DMG:** 24,503,888 bytes, SHA-256 `cfe2b9c55af18c990ac3ea36df99690b3717d226485db2cfac719134feae9f7c`.
- **Feed:** signed with 45 verified releases. The 0.1.64 and 0.1.65 entries were reformatted only; their signatures are unchanged.
- **Site:** Cloudflare Pages deployment `db8f8622`.
- **Public checks:**
  - `/release.json` reports 0.1.66 (build 68); the beta page and `/download/latest` serve 0.1.66.
  - The downloaded DMG's SHA-256 matches.
  - The Ed25519 signature verifies, and a one-byte change is rejected.
- **Not run:** the headless update probe.
- **TestFlight:** build 13 was uploaded.
