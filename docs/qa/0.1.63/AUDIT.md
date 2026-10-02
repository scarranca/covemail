# Cove 0.1.63, build 65: the menu bar icon appears

## User report

On 0.1.62, with Settings → Menu bar → "Show Cove in the menu bar" turned on, nothing appeared in the menu bar.

## Cause

System Events reported no `menu bar 2` for Cove, so the status item was never created; it wasn't hidden behind the notch.

In 0.1.62 the `MeetingMenuBarModel` was held only as `@State` in `CoveApp`, and nothing in the scene read it. SwiftUI released the model, so its tick loop (`guard let self`) ended and no `NSStatusItem` was ever installed.

## Fix

`MeetingMenuBarModel.start(store:)` keeps one model in a static owner for the life of the process. It is started once from `App.init`, and a repeated `App.init` reuses it.

## Verification

- **Full offline suite:** CoveCoreTests 284 (1 skipped) and CoveRenderingTests 397 (7 skipped), 0 failures.
- **Live check on QA build 0.1.62-a**, with the setting preset in the QA domain:
  - System Events reported the status item "Cove meetings" at x=1463 in the menu bar;
  - the user confirmed it worked.
- **Previous fix still holds:** the 0.1.62 freeze fix showed 0.1% CPU on the user's installed 0.1.62.

## Release

- **App notarization:** `7ac23334-eac7-47bd-a4bd-8605bd15c807`, Accepted and stapled.
- **DMG notarization:** `14690278-7114-4d4e-9bfc-f63280fa4003`, Accepted and stapled.
- **DMG:** 22,979,941 bytes, SHA-256 `82983ff1532f2667a040a2b76fac5dca29cb8fdf6aa4762e6a74a87a49ab07c9`.
- **Feed and site:** signed feed with 42 verified releases; Cloudflare Pages deployment `55f32f76`.
- **Public checks** (with cache-busting queries):
  - `/release.json` reports 0.1.63 (build 65); the appcast and `/download/latest` serve 0.1.63; the beta page says "Download Cove 0.1.63".
  - The downloaded DMG's bytes and SHA-256 match the local build.
  - The Ed25519 signature verifies with the bundled key, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
