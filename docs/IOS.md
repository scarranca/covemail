# Cove for iPhone

Cove for iPhone lives in this repository next to the Mac app. It reuses `CoveCore`: Gmail sync, the encrypted per-email store, Inbox split, AI prompts and providers. Only the screens and the iPhone-specific plumbing are new.

| Piece | Where |
| --- | --- |
| Shared logic (Mac and iPhone) | `Sources/CoveCore/` |
| iPhone screens and state (all `#if os(iOS)`) | `Sources/CoveMobile/` (SwiftPM library `CoveMobile`) |
| Xcode app shell (`@main`, Info.plist, icons) | `iOS/CoveMobileApp/`, generated project from `iOS/project.yml` |
| Apple Intelligence (Mac and iPhone) | `Sources/CoveCore/AppleIntelligence.swift` |

The package declares `.iOS("26.0")`. iOS 26 is the first release with the Foundation Models framework, so Apple Intelligence never needs a fallback build on iPhone.

## Build and run

1. Install XcodeGen once: `brew install xcodegen`.
2. Create `iOS/Config/Local.xcconfig` from `iOS/Config/Local.example.xcconfig` and set `COVE_GOOGLE_IOS_CLIENT_ID` (see the next section). Without it the app builds, but sign-in stays disabled with an explanation.
3. Run `scripts/ios/generate-project.sh`, open `iOS/CoveMobile.xcodeproj`, choose the **CoveMobileApp** scheme and a simulator or device, then Run.

The project's development team is `27H459Y2P9` and the bundle identifier is `ai.cove.ios`. Register that App ID in the Apple Developer account before installing on a device or uploading to TestFlight. The generated `.xcodeproj` and `Local.xcconfig` are not committed.

To check that the shared code compiles for iPhone without the app shell, run `xcodebuild build -scheme CoveMobile -destination 'generic/platform=iOS Simulator'` from the repository root. The **Apple builds** GitHub workflow (`.github/workflows/apple-builds.yml`) runs that, the Mac build, the core tests and the app-shell build. It runs on demand and on pull requests that touch Swift code.

## Google sign-in on iPhone

The Mac uses a Desktop OAuth client and a loopback redirect. iOS needs Google's **iOS** client type:

1. In Google Auth Platform → Clients for project `cove-mail-20260922`, create an **iOS** client with bundle ID `ai.cove.ios`. Google may ask the user for a passkey confirmation, so hand that step to them.
2. Put its client ID in `Local.xcconfig`. It is public app configuration, like the bundled Desktop client: an iOS client has no secret.
3. The redirect is the reversed client ID (`com.googleusercontent.apps.<id>:/oauth2redirect`). `ASWebAuthenticationSession` catches it, so no URL type is needed in Info.plist.

The consent screen and tester allowlist are the same as the Mac's; a tester can sign in on either. iPhone sign-in asks for Gmail only (`gmail.modify`). Calendar and Tasks are not on iPhone yet.

The session is stored in the iPhone Keychain as one `GoogleAccountSession` value (`ai.cove.ios` / `googleAccountSession`, this device only, available after first unlock). Token code exchange and refresh use `GoogleTokenClient` and callback parsing uses `OAuthSupport.response(callbackURL:…)`. Both live in `CoveCore` and are tested in `MobileOAuthTests`.

## What the iPhone app does (first version)

- **Mail:** Inbox with Important/Other tabs (`InboxSplit`, can be turned off), plus Starred, Sent and All mail.
  - Pull to refresh, sync about every two minutes while open, and older mail loads at the real end of the list.
  - Swipe to archive, trash, star and mark read or unread.
- **Reader:** the conversation as cards. Other messages are marked read when expanded.
  - Bottom bar: Reply, Archive (or Move to Inbox), ✦ Ask Cove, and More (Star, Mark as unread, Move to Trash).
- **Compose:** To, Cc and Subject fields.
  - "Ask Cove to write or change this…" with writing tools. The suggestion previews on the canvas with Apply and Discard, and Send is disabled while a suggestion is pending.
  - Send waits out a 4-second Undo. Undo, or a failed send, reopens the email.
- **Search:** Gmail search (`GmailClient.search`, 20 results).
- **Settings:** account and sign-out (the encrypted cache is kept), AI models, Split inbox, version.

**Storage** is the same as on the Mac: one AES-GCM row per email in `Application Support/Cove/<sha256(email)>.sqlite`. The key is `mailboxEncryptionKey.<hash>` in the Keychain, insert-only. The file has protection `completeUntilFirstUserAuthentication`. Gmail merges go through `GmailSyncResult.merging(into:store:keepsLoaded:)`, and label edits made on the phone are re-applied over sync results until Gmail confirms them. Trash waits out a 5-second Undo window before Gmail is called.

**Not built yet:**
- Calendar, Tasks, Contacts, agents and Jev.
- HTML rendering (text only for now).
- Attachments (listed only).
- Several accounts.
- Background refresh and push notifications.
- Snoozes, labels and the Spam folder.

## AI on iPhone

`MobileAI` offers **Apple Intelligence** (the default) and the user's own **API keys** (Anthropic, OpenAI, OpenRouter), stored in the Keychain. The ChatGPT and Claude subscription connections run the official Codex and Claude Code CLIs, which cannot run on iOS, so they stay on the Mac. A model becomes the default only after a short test with no email in it.

## Apple Intelligence (Mac and iPhone)

`AIProvider.appleIntelligence` runs Apple's on-device model through the Foundation Models framework (`AppleIntelligence.complete`). It needs no key or account and the text never leaves the device.

- **Availability:**
  - `AppleIntelligence.status` maps `SystemLanguageModel.default.availability` to a message: device not eligible, Apple Intelligence off, or model not ready.
  - Older systems report `unsupportedSystem`.
  - On the Mac, `CoveCore` weak-links FoundationModels (`Package.swift`), so Cove still launches on macOS 14 and 15. The framework is used only when it is available at runtime (macOS 26 or later).
- **Small context:** the on-device model shares about 4,096 tokens between instructions, prompt and reply.
  - `AppleIntelligence.fit` rebuilds the prompt with `AIPromptLimits.onDevice` (about 4 KB of email, 1.5 KB of lookups), then `.onDeviceMinimal`. `AIPrompt.resized` keeps the email order, so source numbers stay valid.
  - When even that is over the 11 KB budget, Cove shows "too long for Apple Intelligence… choose another model". It never silently cuts the request or switches to another provider.
  - The model's context-window error gets the same message.
- **Mac:** Settings → Connections lists **Apple Intelligence · on this Mac** with its status. Test & use makes it the default for writing and chat. It streams into the writing preview like ChatGPT.
- **Good fits:** rewrites, short replies, Ask Cove about one email, task extraction.
- **Poor fits:** the assistant's routing prompt and large mailbox research. Those may exceed the budget and ask for another model.

This document does not use Private Cloud Compute or newer Foundation Models features. Re-check Apple's documentation before adding them.

## Verification status

This branch was written in a Linux container with no Swift toolchain or Apple SDK, so nothing here has been compiled or run yet. Compile with the Apple builds workflow or locally in Xcode before a release. Record results in a versioned QA audit, as for the Mac app.
