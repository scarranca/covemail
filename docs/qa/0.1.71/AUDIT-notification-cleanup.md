# Mobile notification cleanup — unreleased, October 11, 2026

Reading, archiving, trashing or deleting an email elsewhere should remove its delivered iPhone/iPad
notification. Implementation and offline checks were completed October 11; the October 12
TestFlight upload is recorded below. No Mac release, server deployment or local installation.

## Implementation

- Existing Gmail Inbox push remains the trigger. History now includes changed/deleted message IDs
  without filtering out messages that have left the Inbox. After five pages, continue from the last
  processed history record rather than skipping to Gmail's head cursor.
- `MailNotificationCleanup` checks current labels using minimal Gmail reads. Keep unread Inbox mail,
  including an already-undone read/archive; remove read/non-Inbox/Spam/Trash mail or a confirmed 404.
  Dedupe message reads and map back to all matching notification request IDs (APNs UUID or mail ID).
- Errors abort cleanup and leave the history cursor unchanged. Successful message fetches now precede
  cursor advancement, so a fetch failure does not skip unnotified new mail.
- The iOS adapter handles mail and code alerts only, tags new alerts with the account, guards against
  account changes during awaits and excludes foreign-account alerts. Legacy alerts still use this
  device's single registered account. Snooze notifications are untouched.
- Run from the extension, on app activation, after successful foreground sync, and in the scheduled
  background watch-refresh task. No full background mailbox sync was added.
- Notification filtering is opt-in at build time, with a separate entitlement file. Defaults preserve
  the existing passive cleanup placeholder. Approval request text and build instructions are in
  `docs/IOS.md`; the request was prepared but not submitted to Apple.

## Verification

Toolchain: `/Applications/Xcode.app/Contents/Developer` (Xcode 27.0, 27A266a), selected per command;
the machine's global xcode-select setting was not changed.

- `swift test --filter CoveCoreTests`: **351 tests, 1 skipped, 0 failures**.
- Six new `MailNotificationCleanupTests` cover read/archive/Spam/Trash/delete, duplicate delivered IDs,
  preserved unread mail/Undo, account isolation and legacy content, errors including offline/auth/quota,
  history label/delete pagination, bounded-page resumption and malformed incomplete history.
- Generated Xcode project and built `CoveMobileApp` for generic iOS Simulator with signing disabled:
  **BUILD SUCCEEDED** (includes the shared mobile library and notification extension).
- Built the same scheme with the optional filtering condition and entitlement path: **BUILD SUCCEEDED**.
  This verifies compilation; unsigned builds cannot verify Apple's entitlement grant.
- Local Google sign-in configuration is absent in this checkout; no Google account, real mailbox,
  notification registration or credentials were used for verification.
- Published feed fetch failed with HTTPError during this run. Local `site/release.json` and
  `scripts/write-app-info.py` still say 0.1.71 / 73. No claim of a new public release.

## Physical-device checks still required

Using controlled test messages on a registered iPhone and iPad:

1. Receive a new unread Inbox message and verify its mobile notification appears.
2. Read it on desktop while the mobile app is backgrounded: its original notification should clear
   after Gmail/APNs delivery. Default builds can leave one passive “up to date” entry.
3. Repeat for archive, Trash, Spam and permanent deletion; unread unrelated notifications must stay.
4. Read/archive and undo before the device processes the push: the unread Inbox notification stays.
5. Disconnect the device, change mail on desktop, reconnect and open Cove: reconciliation clears stale
   alerts, including messages outside its downloaded mailbox window.
6. Test code alerts and old pre-upgrade notifications. Sign out/switch accounts during a refresh and
   verify the previous account cannot affect notifications tagged for the new one.
7. After Apple grants filtering and profiles are regenerated, test a signed filtering-enabled build:
   cleanup-only pushes should remove stale alerts without creating a replacement notification.

APNs delivery and Background App Refresh scheduling remain controlled by iOS; no instant-delivery
promise. Nothing was run on physical devices in this session.

## TestFlight deployment — October 12

- User authorized deployment. Main checkout was clean and `origin/main` matched `86bce9228c4d2aade39a754a48942731029d2a5b` before building.
- Version **0.1.0 (22)** for both the app and extension, archived with Xcode 27.0 using automatic
  signing and the existing developer account. `xcodebuild archive`: **ARCHIVE SUCCEEDED**.
- Reused the existing ignored iOS Google configuration from the iOS worktree, verified the archived
  app has a configured Google client, and confirmed the file remains ignored in this checkout.
- Inspected signed app/extension identity and build numbers. Notification filtering is **disabled**
  in both signed entitlements; no Apple entitlement request was submitted.
- Archive: `/tmp/cove-notification-release/Cove-22.xcarchive`.
- Upload: `xcodebuild -exportArchive`, `method=app-store-connect`, `destination=upload`, automatic
  signing, `manageAppVersionAndBuildNumber=false` (so the uploaded build remains 22).
- App Store Connect browser session is signed out. Processing, tester availability and any required
  export-compliance answer cannot be verified from that session.

- **Upload confirmed:** October 12, 08:04 UTC (01:04 PDT), `Upload succeeded`, `EXPORT SUCCEEDED`, exit 0. Apple reported “Uploaded package is processing.” Tester availability remains unverified.
