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

## TestFlight (first builds, October 4)

App Store Connect app **Cove Mail** (Apple ID 6819050615, bundle `ai.cove.ios`, SKU `cove-ios`) with the internal group **Cove Beta**. Builds 0.1.0 (2) and (3) were archived on the development Mac and uploaded with `xcodebuild -exportArchive` (method `app-store-connect`, destination `upload`, automatic signing through the Xcode account). Each build needs the export-compliance answer in App Store Connect before testers can install it.

## Codemagic: automatic TestFlight builds

`codemagic.yaml` has two workflows:

- **iPhone → TestFlight** (`ios-testflight`) runs on every push to `main` that changes the iPhone app or the shared core (`Package.swift`, `Sources/CoveCore`, `Sources/CSQLite`, `Sources/CoveMobile`, `iOS/`). Mac-only changes don't start it. It:
  1. generates the project and runs the offline core tests;
  2. signs with Codemagic's automatic code signing (App Store distribution for `ai.cove.ios`);
  3. sets the build number to the latest TestFlight build + 1;
  4. uploads to TestFlight for the beta group **Cove Beta**. It never submits to the App Store.
- **iPhone check** (`ios-check`) runs on pull requests that touch the same paths. It runs the core tests and a simulator build, with no signing.

One-time setup. These steps belong to the account owner: they involve the Apple account and keys, which never go in the repository or chat.

1. In App Store Connect, create the app record for bundle ID `ai.cove.ios` (team `27H459Y2P9`). Note its Apple ID, the number in the app's URL. Create a TestFlight group named **Cove Beta**, or change `beta_groups` in `codemagic.yaml`.
2. In App Store Connect → Users and Access → Integrations, create an API key with the App Manager role. In Codemagic → Team settings → Integrations → App Store Connect, add it under the name **Cove App Store Connect** (the name `codemagic.yaml` refers to).
3. In Codemagic, add this repository as an app that uses `codemagic.yaml`. Create the environment group **`cove_ios`** with:
   - `APP_STORE_APPLE_ID`: the app's Apple ID from step 1;
   - `COVE_GOOGLE_IOS_CLIENT_ID`: the iOS OAuth client ID. It's public configuration, but keep it out of the repository with the other local settings.
4. Codemagic needs an Apple Distribution certificate to sign. With an App Store Connect key, automatic signing can create one and the App Store profile. Or upload the existing Apple Distribution certificate under Code signing identities. Never copy a private key into the repository or chat.

The Mac app's release (Developer ID, notarization, Sparkle feed, Cloudflare Pages) is not in Codemagic. It still follows the release steps in `AGENTS.md`.

## Google sign-in on iPhone

The Mac uses a Desktop OAuth client and a loopback redirect. iOS needs Google's **iOS** client type:

1. In Google Auth Platform → Clients for project `cove-mail-20260922`, create an **iOS** client with bundle ID `ai.cove.ios`. Google may ask the user for a passkey confirmation, so hand that step to them.
2. Put its client ID in `Local.xcconfig`. It is public app configuration, like the bundled Desktop client: an iOS client has no secret.
3. The redirect is the reversed client ID (`com.googleusercontent.apps.<id>:/oauth2redirect`). `ASWebAuthenticationSession` catches it, so no URL type is needed in Info.plist.

The consent screen and tester allowlist are the same as the Mac's; a tester can sign in on either. iPhone sign-in asks for Gmail, Calendar and Tasks in one consent (`gmail.modify`, `calendar.events`, `tasks`), like the Mac's one-step Calendar. The granted scopes are read from the token, so a user who unticks Calendar or Tasks still signs in with Gmail; Home, Calendar, Tasks and Settings then offer **Connect Calendar & Tasks**, which signs in again with the account as `login_hint` and refuses a different account.

The session is stored in the iPhone Keychain as one `GoogleAccountSession` value (`ai.cove.ios` / `googleAccountSession`, this device only, available after first unlock). Token code exchange and refresh use `GoogleTokenClient` and callback parsing uses `OAuthSupport.response(callbackURL:…)`. Both live in `CoveCore` and are tested in `MobileOAuthTests`.

## What the iPhone app does

**iPad** (same app, `TARGETED_DEVICE_FAMILY` 1,2): at regular width, `MobileIPadRoot` shows the Mac's layout. A gray sidebar holds the wordmark, New message, Home, Mail (with its folders), Calendar, Contacts, Tasks and Settings. Mail adds the list column and the reader, which is empty until an email is chosen; archive, unread or trash moves to the next email. Pages switch layout on their actual width: from 900 pt (landscape) Home uses the Mac's hub columns and a side-by-side briefing; Calendar has the Mac's Workweek / Week / Month (time grid with quiet guides, all-day row, overlapping events side by side, current-time line; month cells with titles) and, from 1000 pt, the selected day's agenda beside it; Contacts shows the directory and the person side by side. Slide Over and narrow Split View use the iPhone tabs. DEBUG `-CoveHideSidebar` renders the wide layouts on a portrait simulator.

The iPhone app follows the Mac's design system exactly: the light `Palette` tokens (`MobilePalette`), bundled Inter with the Mac's text roles (reading text is 15 pt instead of 14), 6-point outlined/charcoal buttons, the gradient avatars, underlined Important/Other tabs and the night-blue Home and Tasks cards. It stays light like the Mac. Screens are native iPhone navigation (tab bar, sheets, swipe actions), so it reads as the iPhone version of Cove rather than a shrunken Mac window.

- **Home** (the Mac's Agent Hub, compact order): briefing banner with the mail tide chart and Ask Cove, setup checklist, Needs your decision, Today, Invitations (Accept/Maybe/Decline), Waiting on replies, Keep in touch (Ignore/Undo, stored on this iPhone) and tasks due. Contacts and Settings open from its header.
- **Mail:** Inbox (Important/Other, Unread filter), Flagged, Sent, Drafts and Archive, as on the Mac.
  - Date sections; unread rows are white and bold, read rows F7F7F7. Instant search over mail on the phone (`MailSearchIndex`), then all of Gmail.
  - Pull to refresh, sync about every two minutes while open, older mail loads at the real end of the list.
  - Swipe to archive, delete, flag and mark read or unread; long-press for the same menu.
  - Choose several emails with a two-finger drag down the list (iOS's multiple-selection gesture; trackpad drags work on iPad) or Select. The bar acts on all of them: Archive, Read/Unread, Flag, Delete. Label changes go to Gmail in one `batchModify`; Delete shares one 5-second Undo. DEBUG `-CoveSelectSome` renders the selection mode.
- **Reader:** the Mac's Formatted / Text only switch, with the same sanitizing (`MobileEmailBody`: JavaScript off, strict CSP, inert parse) and "Load external images" gate; labels, subject, sender header, Jev's assessment when the email has one (Flag for follow-up, Create task, Why this?, Hide), tasks linked to the conversation, the "Original email" or conversation cards.
  - Fixed bar: Reply (or Edit draft), Reply all, Forward and ✦ Ask about this email. Archive, Mark unread and More (Flag, Create task, Forward, Move to Trash) at the top.
- **Compose:** From, To, Cc and Subject rows; the ✦ "Ask Cove to write or change this…" line with writing tools; the suggestion previews with Apply draft and Discard, and Send is disabled while it's pending. Send waits out a 4-second Undo. Forward quotes the original; attachments aren't forwarded from iPhone yet.
- **Notifications** (Settings → Notifications): new mail within seconds through Gmail push (backend README → New-mail push). The device starts Gmail's watch, registers its APNs token with Cove's server, and the notification extension (`iOS/CoveNotifications`, bundle `ai.cove.ios.notifications`) reads the new email with the shared Keychain session (`keychain-access-groups` `$(AppIdentifierPrefix)ai.cove.ios`) and App Group `group.ai.cove` settings (`PushSettings`). It shows sender and subject (or just "New email"), Important only (default, the Inbox split rules) or all Inbox, never the text; per-sender Always notify / Mute from the reader's More menu. Actions: Archive, Mark as read, Flag, Open. A push with nothing new becomes a passive "up to date" entry removed by the next push (iOS can't drop a push without Apple's filtering entitlement). Gmail's watch lasts seven days and renews itself when fewer than three remain (`GmailPush.renewIfNeeded`, cursor untouched): on every new-mail push in the extension, in Background App Refresh (`ai.cove.ios.watch-refresh`, about every 12 hours as iOS allows) and when the app becomes active. Settings shows the next renewal. Sign-in now also asks for `openid email`, so older sign-ins sign in once more to turn notifications on. DEBUG `-CovePushSample` grants quiet permission and logs the sandbox APNs token, for a real push to a signed simulator build.
- **About you** (Settings): name, role, company, what you do, projects, notes and sign-off (`PersonalContext` in CoveCore, saved as `personalContext` in the device Keychain). Its bounded text (`promptText`, ≤ 2,500 bytes, identity and sign-off first) goes into every draft (`MobileWritingContext`) and Ask Cove answer as the user's own words, never as email facts; it can be switched off. "Fill in from my sent mail" suggests empty fields only, for review before Save. In Ask Cove, "remember …" / "recuerda …" adds a note and "forget …" / "olvida …" removes matching notes, without asking a model. Optional sync with the Mac and iPad ("Your other devices" in About you, off by default): `MobileMe.sync()` → `CloudPersonalSync` → `/v1/personal`, on open, after Save and when the app becomes active; newest edit wins. The Mac's separate Memories are not synced.
- **Writing context:** every draft request carries the sender's name and address, the recipients, subject and conversation, and the learned voice (`MobileWritingContext`). Drafts must not contain a Subject line or placeholders like [Your Name]; a stray "Subject:" line is removed and offered as the subject. The voice is learned on the phone from Sent (Settings → Your voice, `MobileVoice`, Keychain `voiceProfile.shared`), like the Mac. The Mac's cloud voice (`/v1/voice`) and memories are not read on iPhone: the backend accepts only the Mac's Google client in `GOOGLE_CLIENT_IDS`, and memories live only in the Mac's encrypted preferences.
- **Compose motion:** the Mac's thinking wave (`MobileThinkingBar`) with the real stage while Cove writes; the request is shown read-only and the Ask line is locked until it finishes. A non-streamed result reveals once over 1.25 s (tap finishes it; Reduce Motion skips it). To and Cc suggest people from mail on the phone as you type.
- **Calendar:** Week strip and Month grid (Monday first) with the selected day's agenda, Join for calls, event details (guests, description, files) and invitation answers. Nothing is created or moved from iPhone.
- **Tasks:** Google Tasks with the overview card, quick add ("Call Millet Friday"), groups by due date, steps, done/undone, and Open email for tasks created from mail.
- **History:** after each sync, older mail downloads quietly in the background (50 per page, 1.5 s apart) until the phone has the last 90 days or about 600 emails (`MobileMailbox.downloadHistory`). Rate limits stop it quietly until the next sync. Mail older than the window stays in the encrypted store.
- **Contacts:** people from downloaded mail, most messaged, search, and a person's recent conversations with Email.
- **Ask Cove:** questions about mail on the phone, the next 7 days of events and open tasks, with numbered sources that open the email. It cannot send, delete or change anything.
- **Writing and Ask Cove** (Settings): provider cards; long catalogs (OpenRouter) use a searchable model list grouped by vendor. A model the key may not use (403/404) is named in the error and the previous default stays.
- **Settings:** account, Connections (Gmail, Calendar, Tasks, Writing and Ask Cove), Split inbox, privacy note and version.

**Storage** is the same as on the Mac: one AES-GCM row per email in `Application Support/Cove/<sha256(email)>.sqlite`. The key is `mailboxEncryptionKey.<hash>` in the Keychain, insert-only. The file has protection `completeUntilFirstUserAuthentication`. Gmail merges go through `GmailSyncResult.merging(into:store:keepsLoaded:)`, and label edits made on the phone are re-applied over sync results until Gmail confirms them. Trash waits out a 5-second Undo window before Gmail is called.

**Not built yet:** agents and running Jev on the phone (assessments made on the Mac aren't synced either), inline (cid:) images in formatted mail, opening attachments, several accounts, background refresh, snoozes/reminders, labels/Categories and the Spam folder, creating or moving events.

**Design checks:** DEBUG builds accept `-CoveSample` (the sample mailbox, nothing reaches Google) plus `-CoveTab mail|calendar|tasks|search`, `-CoveOpenFirst`, `-CoveCompose`, `-CoveSettings`, `-CoveAssistant` and `-CoveContacts`, so screens can be rendered in the simulator with `xcrun simctl launch … ai.cove.ios -CoveSample -CoveTab mail` and `xcrun simctl io … screenshot`.

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

October 4, 2026, GitHub Actions **Apple builds** run `37197465161` (macos-26 runner, Xcode 26.6, macOS 26.5 SDK):

- **Passed:**
  - `swift build` (Mac app, with FoundationModels weak-linked);
  - `swift test --filter CoveCoreTests`, which includes `AppleIntelligenceTests` and `MobileOAuthTests`;
  - `xcodebuild` of the `CoveMobile` library for the iOS Simulator;
  - `xcodebuild` of the XcodeGen `CoveMobileApp` shell for the iOS Simulator.
- **Two older Mac files fixed:** `AgentChatView.swift` and `CalendarView.swift` didn't compile with Xcode 26.6 (a slow type-check and a `CGFloat` in a tuple). They have small fixes on this branch.
- **Not verified yet:**
  - the `CoveRenderingTests` suite, which includes the new `AIProviderSettingsTests` Apple Intelligence test;
  - running the iPhone app in a simulator or on a device;
  - a real Google sign-in with an iOS client;
  - an Apple Intelligence response on hardware that supports it;
  - launching the Mac app on macOS 14 or 15 to confirm the weak link;
  - the Codemagic workflows.

  Record those checks in a versioned QA audit before a release.
