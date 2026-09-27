# Cove 0.1.44 — reader design

September 26, 2026. Implemented against `/Users/santiagocarranca/Pen/Cove.pen`, frame `w3s2H` (1. Cove), reading pane `CQs4F`, inspected through Pen MCP. The design document was read only. Release artifacts are prepared as 0.1.44 / build 46; publication verification is recorded below. No installation or running-app replacement was performed.

## Reader changes

- Dedicated `ReaderView.swift` separates the 64-point toolbar, identity block, Jev assessment, original email, and fixed response bar. Content uses 32-point horizontal insets, 24-point top padding, 22-point section spacing, and existing semantic Inter roles.
- Toolbar names Archive, Snooze, Mark read/unread, and More. Narrow readers retain accessible icon actions. More holds follow-up flag, Jev assessment, and Move to Trash; the existing five-second undo and navigation remain intact.
- Inbox/Draft/Sent/Archived/Trash/Spam status and custom labels precede the subject. Sender details wrap and dates stack in narrow panes.
- Jev’s distinct panel displays actual action/urgency assessments and attributable source text. Why this? expands scores, model, and Jev flags. Hide affects only the current reader and is reversible through More.
- Original email exposes Formatted/Text only choices while honoring global reading settings. Plain-only messages explain their format. HTML, CID images, sanitization, and external-image consent remain in the existing renderer. Full content stays available by scrolling.
- Reply/Continue reply, Forward, and Ask Cove remain at the bottom. Reply reveals the inline editor, Forward uses the existing reviewable draft workflow (attachments explicitly excluded), and no-reply copy checks the effective Reply-To destination.
- Translate prepares a language-specific question in the existing assistant with the selected email. The user submits it using a connected generative model; the original email and draft remain untouched. It does not make an automatic provider call.

## Intentional capability differences from the static reference

Task creation remains future work: the reader offers the real Gmail-backed follow-up flag and local Remind me actions. Jev does not invent a task title, generated summary, or “No deadline found” claim from its scores. Hide does not claim to train Jev or dismiss a task. The full email is already rendered, so there is no redundant Read full message control. Shared typography remains the 0.1.43 scale.

## Verification

`swift build` passed. The affected suite selected ReaderDesignTests, MailNavigationTests, LabelMailboxTests, EmailRenderingTests, SendWorkflowTests, and HomeUpdateTests: 45 distinct tests. The first pass passed 44 and found one genuine compact-reader width failure: Continue reply required a 450-point pane instead of 420. Wrapping response actions fixed this; all three ReaderDesignTests passed on rerun and again after the final reminder styling refinement. The other 42 checks passed in the affected run. No full-suite claim.

Hidden-window production screenshots inspected: formatted readers at 420/620/824 points, a 420-point long sender/recipient and saved-reply case, an 824-point text-only reader, and a 1050-point mailbox. Reproducible artifacts: `/tmp/cove-reader-{formatted,plain,saved-reply,mailbox}-WIDTH.png`. The compact footer wraps without expanding the pane; long content scrolls above the fixed actions. No app was foregrounded.

Existing tests cover sanitization, script/frame blocking, external images and CID handling, global reading preferences, navigation/editor focus, flags/labels, Reply-To sending, draft preservation, and Trash undo/failure recovery. New checks cover effective no-reply detection, preparation of a selected-email translation question without modifying drafts, and reader widths. Live mail sending, live translation, task creation, and real account changes were not performed. Existing actor-isolation/Keychain-deprecation build warnings remain.

## Release artifacts

- Universal Apple silicon / Intel distribution build succeeded using the existing Developer ID identity.
- App notarization: `b31abf88-39a0-463d-9880-2561e632314e`; DMG notarization: `b4401f0d-1307-4c14-a5dd-9f6299851a1b`. Both accepted and stapled. Strict code-signature, Gatekeeper, and DMG integrity checks passed.
- Sparkle archive and feed signatures verified during preparation. The site stages 24 checksum-verified historical/current downloads.
- DMG: 16730835 bytes; SHA-256 `093cfa88c6662337a6ff7d643b078c1278d60d48fcb4eed77b404e150f3e7f33`.
- Public deployment and updater verification pending at artifact-preparation commit.
