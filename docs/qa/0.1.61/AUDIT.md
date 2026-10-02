# Cove 0.1.61, build 63: meetings in the menu bar

## Changes

- **Setting:** Settings → Gmail → Google services → **Meetings in the menu bar** (`menuBar.meetings`, off by default). It inserts a `MenuBarExtra` in window style.
- **Next meeting** (core `MeetingAlert.next`):
  - It is the next timed event within 12 hours, or one that started at most 5 minutes ago.
  - All-day, declined and free events are skipped.
- **Levels:**
  - `later`: icon only.
  - `soon` (≤ 10 min): "Standup in 8m".
  - `now` (≤ 1 min, up to 5 min late): "Join Standup", or "Standup now" with no link.
- **Pulse:** when the meeting has other guests and a call link, and is starting (≤ 2 min, or started), the icon alternates between `video.fill` and `video` every 0.7 s. It is still under Reduce Motion, and meetings without guests or a link stay quiet.
- **Call links** (`MeetingLink`): Meet from Calendar's `hangoutLink`, otherwise https links found in the location or description on known hosts (Meet, Zoom, Teams, Webex, Whereby, Around).
- **Panel:** the next meeting with time, countdown and guests, Join (Return), Open in Cove, later meetings today with join buttons, Open Cove, and Hide this icon.
- **Refresh:** while the icon is on, today's and tomorrow's events refresh every 5 minutes. The refresh is skipped during a Calendar sync or a user action, and merges only inside its own range.

## Verification

- **Full offline suite:** CoveCoreTests 284 (1 skipped) and CoveRenderingTests 396 (7 skipped), 0 failures.
- **`MeetingAlertTests`:** levels, titles, prominence, skipped events and late joins, and link detection, including https-only and known hosts.
- **`MeetingMenuBarTests`:** the model's tick with a fixed clock (Join title, pulse cadence, later list, off state), and a panel render that was inspected.
- **Not tested automatically:** the menu bar label itself (it can't be rendered off-screen), so it is left for the QA build.

## Release

- **App notarization:** `05975416-016e-41c5-8861-5f69c71e1b9d`, Accepted and stapled.
- **DMG notarization:** `0df3e39e-2660-4e9e-9e12-80116cd0c82d`, Accepted and stapled.
- **DMG:** 22,969,948 bytes, SHA-256 `0ebb7043d4e13cd8d3ccd4014bb9bdd9df2ab98930c2deb922ec3f8fd07f25fc`.
- **Feed and site:** signed feed with 40 verified releases; Cloudflare Pages deployment `1d1e3de0`.
- **Public checks:**
  - `/release.json` reports 0.1.61 (build 63); the appcast and `/download/latest` serve 0.1.61; the beta page says "Download Cove 0.1.61".
  - The downloaded DMG's bytes and SHA-256 match the local build.
  - The Ed25519 signature verifies with the bundled key, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
