# Cove 0.1.73 — inline pasted images

October 12, 2026. Follow-up to 0.1.72: the user wants pasted images inside the email body.
Publication authorized October 12, 2026: Mac 0.1.73 (75), iPhone/iPad 0.1.0 (24).
No running installation is replaced and no real email is sent as a test.

## Behavior

- Mac new-message and reply editors insert images at the caret, replacing selected text just like
  normal Paste. Native TextKit 1 attachment characters render bounded previews (ImageIO thumbnails);
  PNG/JPEG/GIF source bytes remain intact for sending. Text paste stays plain text.
- iPhone/iPad use the same persistent image tokens and native text attachments, with explicit-paste
  clipboard access. Files/Photos/paperclip/drop attachments retain their ordinary attachment behavior.
- The draft body stores stable image tokens, while the existing encrypted attachment record holds
  the bytes. Native selection ranges map to model ranges for scoped editing. Removing an image
  removes its body reference; retained bytes support Undo and are excluded from outgoing MIME.
  The existing conservative 25 MB draft attachment cap includes retained Undo data.
- Outgoing mail contains plain-text and HTML alternatives, with CID-referenced image parts inside
  multipart/related. Ordinary files remain separate multipart/mixed attachments. Text is HTML escaped;
  missing referenced image data blocks sending with an error. Reply headers stay intact.
- Inline images are omitted from the ordinary file chips. Old drafts decode without inline metadata.
  Existing file attachments are not moved into the body automatically.
- Writing prompts ask models to preserve image tokens. Suggestions containing inline images use
  the native editor for review; applying and sending remain separate actions.

## Verification

Results are recorded below after completion. Tests use synthetic mail, isolated databases and private
pasteboards. Hidden-window rendering does not interrupt the user's running Cove session.

- Full `swift test`: 460 rendering tests (7 skipped), 353 core tests (1 skipped), zero failures,
  exit 0. Log: `/tmp/cove-inline-full.log`.
- After the final preview, reply-test and fixture changes: focused suite passed, 15 rendering tests
  and 3 core tests, zero failures, exit 0 (`/tmp/cove-inline-final-tests.log`). Covers native
  insertion/replacement, image formats, invalid paste, text paste, read-only paste, Undo/Redo,
  deletion, UTF-16 selection mapping, encrypted draft reload, reply-target persistence, IME accents,
  compose review regressions, MIME structure, missing images, legacy decoding and typing benchmarks.
- Final typing benchmarks with 4,000 fixture emails: reply 2.8 ms, composer body 3.8 ms, To 4.1 ms
  per keystroke through layout. These are local benchmark measurements, not device-wide claims.
- Python's standard MIME parser independently parsed the emitted fixture without defects and
  resolved the HTML CID to its inline image. No live message was sent to Gmail or another client.
- Final iPhone/iPad simulator build passed (`/tmp/cove-inline-ios-final2.log`). Mobile clipboard,
  keyboard, Undo and physical-device behavior remain runtime-unverified.
- Inspected `compose-inline.png`: the synthetic blue image sits between Before and After at the
  cursor position, with no ordinary file chip. A first render exposed an invalid named-color test
  fixture; fixed it to use explicit RGB pixels, then reran and inspected the render.
- `git diff --check` passed before release preparation.

## Release verification

- Release review caught a missing attachment argument in the mobile pre-send MIME validation.
  It now validates the same body and attachments that are sent. The MIME/preflight suite passed
  (3 tests, zero failures, `/tmp/cove-073-preflight-tests.log`).
- Publication receipts and public checks follow below as they complete.
- Universal Mac Developer ID build passed (arm64 and x86_64); version 0.1.73, build 75 verified.
  App notarization submission: `a933238a-33a4-4aeb-a166-8ff7cb6deb05`.
- Final signed iPhone/iPad archive passed after the preflight fix; app and notification extension
  both report 0.1.0 (24). Upload passed: **EXPORT SUCCEEDED**, Apple **Upload succeeded** and
  **Uploaded package is processing**, October 12 18:48 UTC. Notification filtering remains disabled.
  Tester availability and physical-device behavior are unverified.
- Mac app notarization **Accepted**, stapled and Gatekeeper accepted.
- Installer notarization `5461a163-e323-4831-aa77-533facc52a66` **Accepted**; final DMG stapling,
  signature, checksum and Gatekeeper checks passed. Plain installer fallback used in this checkout.
- Final `Cove-0.1.73.dmg`: 25,585,076 bytes; SHA-256
  `0bfbed07b922563d0e9744f346d79a83fa1fa01af2ea75871dbc42a3c80baf2c`.
- Sparkle artifact/feed signatures verified by `prepare-update.py`. Site staging verified
  52 releases and retains historical download URLs.
- **Published:** Cloudflare Pages production deployment `89ebad0d`,
  https://89ebad0d.covemail.pages.dev, account `f1bf637a915898a7dfe461bd5883357d`.
- Public `/release.json`, `/beta/` and `/updates/appcast.xml` serve 0.1.73 (75).
- Headless Sparkle probes passed with isolated hosts: 0.1.72 discovers 0.1.73 (75), and 0.1.73
  correctly finds no newer release. No user app was opened, quit or updated.
