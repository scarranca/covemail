# Cove 0.1.43 — typography across the app

September 26, 2026. Scope: every native app destination and its principal editors, chat, and settings; keep compact Settings density and the supplied Inter/monochrome identity.

## Changes

Shared Inter roles replace per-screen literals: page 24 medium, detail 20 medium, section 16 medium, subheading 14 medium, reading 14 regular, labels 13 medium, secondary 12 regular, controls 12 medium, metadata 11 regular. Compact buttons retain smaller geometry but use the same 12 medium label. Compose and AI previews share native 14-point text and 6-point paragraph spacing. Agent prose inputs explicitly pass the reading font into the field style. Plain-text email and long agent columns have a 660-point maximum measure. Shaded mail/sidebar attribution uses darker body text. Narrow calendar RSVP controls stack and place loading progress separately.

Settings keeps one destination at a time; removal controls use the existing outlined Cove button and existing confirmation. No credentials, email, calendar event, or cloud data was changed during QA.

## Assessment and verification

Two independent typography assessments inspected semantic roles and mechanically inventoried native font declarations. The final review caught compact RSVP width overflow and three remaining agent prose inputs; both were corrected. The Impeccable HTML/CSS detector was rerun, but its empty output is not treated as evidence for SwiftUI. A native post-scan verified that remaining numeric sizes belong to the intentional exceptions below.

The affected suite ran 41 distinct tests. The first run passed 40; the added route fixture initially assumed fixed-width native sheets would expand to its window size. Correcting those fixture widths and rerunning the affected tests passed. The final RSVP capture also passed after adding a containing layout, eliminating a fixture-only vertical crop. No foreground windows or live provider calls were used. Existing compose tests verify draft preservation, native selection, finite text reveal, and Reduce Motion; settings tests verify that changing sections does not reload credentials. Calendar tests verify separate event hit rectangles.

Rendered production views were inspected across these routes (artifact paths under `/tmp`, reproducible from `Tests/CoveRenderingTests`):

| Destination | Render coverage and artifact prefix |
| --- | --- |
| Welcome | 900/1280, `cove-type-welcome` |
| Home | 1040/1440, `cove-hub-0133`; weather/invitations/undo covered by HomeUpdateTests |
| Mail | 900/1200 empty reader and row states, `cove-mail`; plain reader 900/1280, `cove-type-reader` |
| Categories and label/flag mail | 1040/1440, `cove-categories-view`, `cove-label-view`; folder variants share the verified mailbox implementation |
| Calendar | Workweek and month at compact/wide widths, `cove-calendar-full-week`, `cove-calendar-month`; event/search editors, `cove-type-event-editor`, `cove-type-calendar-search`; narrow loading RSVP at 192, `cove-type-rsvp-loading` |
| Contacts | Empty selection/detail at 900/1280, `cove-type-contacts`; editor at its native 490 width, `cove-type-contact-editor` |
| Your agent | 900/1280, `cove-type-your-agent` |
| Custom agents | List/create/rule editor/activity at 720/1100, `cove-agents`, `cove-conditional` |
| Settings | Gmail, Jev, Reading, Privacy, App updates at 900/1100, `cove-settings`; paused Cloud sync, `cove-cloud-settings` |
| Integrations | Connected versioned catalog and expanded future integrations at 620/760/1100, `cove-claude-integrations` |
| Assistant | Normal/long/Markdown/error at compact/design sizes, `cove-assistant`; agenda 560/800, `cove-agenda-chat`; long model list fixture |
| Compose | Native draft, waiting, editable suggestion, selection, compact review, reduced motion, `compose-context`, `compose-canvas-preview`, `cove-compose-review` |

Visual review found no new clipping in the inspected titles, controls, prose, or settings copy. Long lists and conversations continue scrolling; month cells intentionally abbreviate titles with full details in the adjacent agenda. The RSVP snapshot's initial crop came from its root sizing, not the production control.

## Intentional exceptions and limits

- Sign-in display/wordmarks and artwork retain their larger brand sizes; avatar initials scale with the avatar. SF Symbols use optical icon sizes, not text roles.
- Unread email bold emphasis and Markdown semantic emphasis remain. Code blocks use a native monospaced font. Sender-authored HTML retains its own typography and existing security policy.
- Native menu/date-picker internals and disabled controls retain platform behavior. This is a typography/layout pass, not a claim of a complete accessibility certification.
- Sample Reader rendering skips restoring real writing credentials. Real-account behavior is unchanged.
- No running Cove app was quit or replaced; delivery uses the signed in-app updater.

## Release verification

- Universal Apple silicon/Intel Developer ID build succeeded.
- App notarization: `b0c03c6d-0ec3-4bf1-b104-2f4197251dd7`; DMG notarization: `0562bd69-3126-447a-9cab-e9e651d669de`. Both accepted and stapled; Gatekeeper and disk-image verification passed.
- Pages deployment: `b34bccdd-133e-4005-ba46-8926fbbfe70c`.
- Public beta page, latest redirect, release metadata and signed feed all resolve to 0.1.43/build 45. Downloaded bytes equal the local notarized DMG; public-key signature verification passes and tampering is rejected.
- DMG: 16,810,400 bytes; SHA-256 `738fc30fc8cc4a150539113c6f8a0b3f97e3ac729ffe2415dbc56472a8c85231`.
- Headless Sparkle checks: build 44 discovers 45; build 45 is current. No installation or foreground window was requested.
- Completion review: every top-level app route uses the shared typography scale, all identified typography inconsistencies are corrected or documented as intentional exceptions, and the update is publicly available.
