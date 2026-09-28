# Cove 0.1.46 — conversations, previews and pointer-targeted deletion

Implementation verified September 26–27, 2026. The user authorized publishing on September 27. Version 0.1.46/build 48 is being packaged; public version remains 0.1.45 until the publication checks below complete. No running-app replacement or installation is performed.

## September 27 — delete the hovered mail row

⌘Delete now resolves the mail row under the current pointer at keypress time and queues that message for the existing five-second Trash/Undo flow. Another selected email stays selected. With no row under the pointer, the shortcut retains its selected-message fallback. There is no cached hover ID, so scrolling, row removal and reuse cannot retain an old target. A disappearing row already excluded from the visible mailbox cannot redirect the operation to a different selected message. Native editor/compose handling and key-repeat suppression remain; sheets, modal windows, editable fields and popup controls are guarded.

25 affected tests passed: HomeUpdateTests (13), HubActionsTests (8), MailNavigationTests (4). New hidden-window tests use real SwiftUI rows and injected pointer coordinates to verify hovered-over-selected priority, no-selection deletion, selection preservation, Undo, selected-message fallback in the reader, disappearing rows, hidden/clipped rows and row reuse. The first run exposed that AppKit’s `visibleRect` can extend beyond a view’s bounds; requiring both actual bounds and visible geometry fixed it. Existing tests verify editor/compose focus, countdown/Undo, delayed/busy operations, failure restoration and mailbox changes. No real mailbox mutation or visible-window interaction occurred. These changes remain local and unreleased.

## Behavior

Opening an email fetches its Gmail thread and shows messages chronologically in the same reader. The selected email is expanded; other messages show sender/date/snippet and expand independently. Draft, Spam and Trash siblings are excluded. Fetching does not mark collapsed messages read. Cached content remains available while refreshing or offline, with inline retry. Thread refresh preserves draft edits, concurrent label/read changes, snoozes, selection and Gmail history/pagination cursors; cancelled navigation/account changes cannot persist stale results.

Each expanded message exposes its own attachments, translation and reply action. The shared editor scopes draft persistence and sending to that message without changing mailbox selection. Sent-message continuations address the original To recipients, including sent aliases; incoming mail retains Reply-To behavior. Sending a reply preserves another message’s saved draft.

Preview expands inside each attachment row, with Save still available. PDFs use PDFKit and common images use AppKit. Text, Office and supported audio/video formats use embedded Quick Look with autoplay disabled. HTML attachments become plain source text. An allowlist and canonical generated filename avoid opening arbitrary attachment types or using sender paths. Known sizes above 25 MiB are rejected before fetch and decoded content is checked again before writing. Temporary directories/files have 0700/0600 permissions and normal close/navigation releases them. Attachment requests use injected or account auth and reject results after account lifetime changes; sample mode never fetches remote attachment IDs.

## Verification

- `swift build` passed; final targeted test builds passed.
- 67 distinct affected tests passed: ReaderConversationTests (10), ReaderDesignTests (3), ThreadAnswerTests (7), ThreadQuestionsTests (8), GmailAttachmentTests (7), MailNavigationTests (4), ReadStateTests (8), SendWorkflowTests (11), EmailRenderingTests (9). This is not a full-suite result.
- New tests exercise thread caching, drafts/cursors/selection, concurrent edits, stale navigation, offline/sample behavior, empty-thread isolation, sent/incoming reply routing, attachment auth, disconnected responses, file permissions/lifetime, limits, unsupported types and late preview results.
- Hidden NSWindow fixtures render the reader at 420/760 points and attachment previews at 640 points. Actual screenshots are inspected, including `/tmp/cove-conversation-420.png`, `/tmp/cove-conversation-760.png`, `/tmp/cove-attachment-preview.png`, `/tmp/cove-attachment-png.png` and `/tmp/cove-attachment-pdf.png`. Controls remain visible and narrow attachment rows stack their actions.
- An initial native Quick Look fixture attached a preview item successfully but rendered images/PDFs blank. Visual inspection caught this; dedicated AppKit/PDFKit renderers replace that path and the ten conversation tests were rerun. The earlier fixture compilation issue (actor-isolated default argument) was also corrected.
- PDF pages draw through PDFKit into a scrollable AppKit canvas, avoiding blank hidden-window PDFView rendering. A two-page fixture verifies the full scroll height. Image/PDF screenshot checks now assert colored document pixels so a blank native view cannot pass merely by holding a document.
- Existing HTML rendering checks cover blocked active/external content, explicit image opt-in, CID images and scrolling. Existing read/send tests cover racing read updates, account changes, draft preservation and uncertain send outcomes.

## Limits

The PDF canvas is a visual, scrollable preview; text selection, forms, search and editing require saving and opening the document in a full viewer.

All fixtures use synthetic messages/transports and temporary databases. No real mail was sent or fetched, no visible window was opened, and the installed/running Cove session was untouched. Backend/schema/cloud APIs are unchanged; this feature adds no attachment upload.

Real-account thread/attachment interaction and the full Office/audio/video format matrix were not exercised. Quick Look support depends on macOS and the file. Preview files are temporary plaintext; normal lifecycle cleanup is verified, but crash leftovers and OS preview caches are not guaranteed erased. Unknown-size downloads are checked after decoding, so 25 MiB is a preview-file limit, not a strict network-memory ceiling. Test logs include existing Swift isolation/deprecated-Keychain warnings and macOS Contacts helper diagnostics; the targeted tests completed without failures.

## Release preparation — September 27

Version/build advanced to 0.1.46/48. The public feed and metadata were checked at 0.1.45/47 before packaging; remote main and the working branch share release checkpoint 04fc3ad. Release notes and beta-page copy cover conversations, attachment previews and hovered-row deletion. Three AppUpdaterTests passed in addition to the feature suites above. The Desktop OAuth configuration was reused from the existing lugworm checkout; no credential or signing identity was recreated.

The universal arm64/x86_64 distribution build passed with the existing Developer ID identity (team 27H459Y2P9), Hardened Runtime and signature checks. The app was submitted once to Apple as `784771c5-3db5-41d4-a2eb-4e1020fa60cb`; Apple accepted this submission. App stapling, ticket validation and Gatekeeper assessment passed. Isolated updater probe copies use separate bundle identifiers, automatic checks disabled and a headless probe executable.

The signed 0.1.46 DMG was submitted once as `4fc476ec-8df1-4e8b-90eb-b450aa9e475c`. Final installer validation and publication follow its acceptance.

Apple accepted the DMG submission. Installer stapling, ticket/signature validation, disk-image verification and Gatekeeper passed. The final DMG is 17445519 bytes with SHA-256 `2c31a7a46dab7603b6414e98aeaa7025c8c05cfa87388002a7fe82a08d4303e9`. The signed feed and archive passed Sparkle verification; independent public-key verification accepted the artifact and rejected a tampered copy. The site was staged with historical downloads preserved. Publication is pending the existing publishing helper’s local Keychain authorization.
