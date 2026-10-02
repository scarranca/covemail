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
