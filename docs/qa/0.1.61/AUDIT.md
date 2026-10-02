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
