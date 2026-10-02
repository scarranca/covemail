# Cove 0.1.62, build 64: hotfix for the 0.1.61 launch freeze

## User report

Cove 0.1.61 became "not responding" right after it opened. Because it froze, it couldn't update itself either.

## Cause

`sample` of the frozen process showed:
- the main thread in a continuous SwiftUI graph update, including `AppDelegate.makeMainMenu`, at about 99% CPU;
- memory growing from 540 MB to 1.3 GB in a minute.

0.1.61 added `MenuBarExtra(isInserted: $meetingsInMenuBar)`, bound to `@AppStorage` in the `App` body. That kept the app scene (main menu and commands included) re-evaluating even with the item off. In addition, the meetings model re-assigned unchanged observable values on every tick.

## Fix

- **Status item:** the menu bar item is now an AppKit `NSStatusItem` with an `NSPopover` (`MeetingMenuBarModel`), outside the SwiftUI app scene, created and removed when the setting changes. There is no `MenuBarExtra` and no `@AppStorage` in `CoveApp`.
- **Model:** it publishes only real changes, so an idle or disabled tick notifies nothing.
- **Panel:** it opens Cove through `CoveAppDelegate.showMainWindow` instead of `openWindow`.
- **Setting:** it moved to a top-level Settings → **Menu bar** section ("Show Cove in the menu bar", with "What it shows: Your next meeting").

## Verification

- **Full offline suite:** CoveCoreTests 284 (1 skipped) and CoveRenderingTests 397 (7 skipped), 0 failures.
- **`MeetingMenuBarTests.testQuietTicksDoNotNotify`** is the regression test: ticks that change nothing don't notify observers.
- **Settings render:** the Menu bar section was inspected.
- **Not verified live:** the QA build with the fix was built but not observed under a live launch before release, because the user asked to ship. The user's installed Cove was replaced by them with 0.1.60, which ran at 0% CPU.

## Recovery for affected users

A frozen 0.1.61 can't install updates. Force quit it, then install 0.1.62 from the website DMG.

## Release

- **App notarization:** `314cf71e-bf19-4663-8dd9-5c547e7dee31`, Accepted and stapled.
- **DMG notarization:** `5e8f4a9a-0be2-459f-94d4-6473eabf4906`, Accepted and stapled.
- **DMG:** 22,979,887 bytes, SHA-256 `5661fe73d7959da5eb43a17874ea3f419fc18b74fe0bec5935341046b5081b9b`.
- **Feed and site:** signed feed with 41 verified releases; Cloudflare Pages deployment `1f638a28`.
- **Public checks:**
  - `/release.json` (0.1.62, build 64) and the beta page briefly served 0.1.61 from the edge cache, then 0.1.62 with a cache-busting query. The deployment URL served 0.1.62 directly.
  - The appcast and `/download/latest` serve 0.1.62.
  - The downloaded DMG's bytes and SHA-256 match the local build.
  - The Ed25519 signature verifies with the bundled key, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
