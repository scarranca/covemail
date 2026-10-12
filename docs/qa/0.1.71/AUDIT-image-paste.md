# Paste images in new messages and replies — unreleased, October 12

## Behavior

- Mac composer and reply body accept ⌘V/Paste of copied images and image files. Add to the existing
  draft/reply attachment target; preserve body text, selection, encrypted persistence, Undo Send,
  removal controls and Gmail's combined 25 MB limit. Finder files use original bytes, not thumbnails.
- Clipboard PNG/JPEG/GIF bytes are preserved (including GIF animation); TIFF and other supported
  ImageIO formats become PNG. No temporary file or external upload is needed to paste raster bytes.
- Image errors appear in the existing attachment notice. Read-only and AI preview editors cannot
  add attachments. Ordinary text paste still uses native text editing, including selection replacement.
- iPhone/iPad's shared compose/reply canvas uses a native UITextView, accepting Paste and hardware
  keyboard ⌘V. Preserve Inter, dynamic type, paragraph spacing, focus, composition/marked text,
  expanding body height, placeholder and the existing attachment UI.
- Images are attachments. No inline HTML/CID body layout or automatic send was added.

## Verification

- 18 relevant tests passed (14 rendering/editor/draft tests plus 4 core outgoing-attachment tests):
  `swift test --filter 'ComposeImagePasteTests|ComposeAccentTests|ComposeReviewRenderingTests|DraftAttachmentTests|OutgoingAttachmentTests'`.
- Four new image-paste tests cover one attachment for multiple clipboard representations, unchanged
  selected text, TIFF conversion, byte-preserved JPEG/GIF, native text paste, read-only rejection,
  original file versus thumbnail, visible malformed/oversized image errors, and an actual hosted
  ComposerView paste that reaches the encrypted draft store and renders an attachment chip.
- Tests use named private pasteboards and synthetic images/mailbox/HTTP, not the user's clipboard,
  account, mail or running app. The existing attachment suite verifies MIME and send persistence with
  fixture HTTP. No real mail was sent.
- Inspected the hidden-window composer render `/tmp/cove-pasted-image.png`; the pasted PNG appears
  in the normal attachment row above the footer with its name, size and remove control.
- iPhone/iPad app shell, mobile library and notification extension: generic iOS Simulator build passed
  with Xcode 27.0 and signing disabled. Physical-device paste, iPad hardware keyboard, iOS context-menu
  paste and mobile text-view sizing are not runtime-verified in this session.
- `git diff --check` passed. No new release/upload or installation over the user's running app.

## Subsequent release

Published release work for Mac 0.1.72 (74) and iPhone/iPad TestFlight build 23 is recorded in
`../0.1.72/AUDIT.md`. The implementation-session limits above remain accurate for that session.
