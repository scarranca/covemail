# Cove distribution and simple onboarding

Cove distributes directly as a Developer ID-signed, notarized Mac app. The distribution build supports arm64 and x86_64 on macOS 14+. App Store submission, a shared Jev billing service and cloud/mobile synchronization are separate phases.

## Google sign-in

The dedicated Google Cloud project is `cove-mail-20260922` (Cove) in the existing gigstack.io organization. It was created with the console's existing DisruptiveLearningSAPICV billing account; no paid compute/database resources were deployed. Consent configuration was created in External testing after the account owner approved the Google API Services User Data Policy. The support/developer contact and sole initial tester are santiago.carranca@gigstack.io. The Cove macOS Desktop client was created, and Gmail and Calendar APIs are enabled. Declared scopes match the existing app: gmail.modify and optional calendar.events; users still authorize their own accounts at sign-in.

The downloaded **Desktop app** OAuth configuration is stored locally at `.local/google-oauth-desktop.json` (ignored by Git, mode 0600). Never provide a web-client secret, user refresh token, service-account key or TypeSafe API key as bundled app configuration. The packaging script accepts the `installed` JSON type and copies only the desktop client ID and desktop client secret into Info.plist. A native-app client secret is public configuration, not a security boundary; PKCE and Google consent protect authorization.

Fresh installs use this bundled configuration when Continue with Gmail is clicked. Optional custom client fields live under Advanced Google settings. Existing custom client preferences retain priority, and saved Google sessions continue refreshing with the exact client that issued them. A stale custom secret is never attached to the bundled client. Changes of active client require disconnection first.

External testing requires allowlisting each tester's Google account. A public launch needs the applicable Google brand/scope verification, real support/privacy pages on an owned domain and accurate disclosures covering TypeSafe processing. Test credentials are not a public-launch shortcut. The current Jev integration still uses a locally supplied user key; Gmail works independently.

## Build

```sh
COVE_DISTRIBUTION=1 \
COVE_GOOGLE_OAUTH_FILE="$PWD/.local/google-oauth-desktop.json" \
./scripts/build-app.sh
```

The script selects the single installed Developer ID Application identity, or accepts `COVE_SIGNING_IDENTITY`. Development builds still select Apple Development. Distribution requires valid desktop OAuth configuration, a secure signing timestamp and Hardened Runtime. It builds both CPU architectures and verifies the merged executable and signature before replacing the output bundle. Builds are staged and the prior bundle remains untouched on compilation/signing failure. The running development app at `dist/Cove.app` is separate from `dist/distribution/Cove.app`.

`COVE_VERSION` defaults to `0.1.27`; `COVE_BUILD` defaults to `29`. Increase both for subsequent releases. Distribution builds embed Sparkle 2.10.0; the menu and Settings expose update checks. Checks run daily while Cove is open and can be disabled. Downloads and installation require user interaction. Development and QA builds do not start the updater.

## Notarize

The Apple Developer account and installed Developer ID identity use team `27H459Y2P9`. Browser sign-in alone does not authenticate notarytool. The account holder must create/enter an app-specific password locally, or supply an existing appropriate App Store Connect API-key profile. Do not put secrets in chat, shell history, scripts or the repository. For a new local profile, run this in a user-controlled terminal and enter the app-specific password only at its hidden prompt:

```sh
xcrun notarytool store-credentials Cove-notarization \
  --apple-id YOUR_APPLE_ACCOUNT --team-id 27H459Y2P9
```

With the profile saved:

```sh
./scripts/notarize-app.sh Cove-notarization
# Record the returned ID. Check the same submission instead of submitting duplicates.
xcrun notarytool info SUBMISSION_ID --keychain-profile Cove-notarization
./scripts/finish-notarization.sh SUBMISSION_ID Cove-notarization
```

The finishing script requires Accepted status, staples/validates the app ticket, checks Gatekeeper and creates a signed DMG containing Cove.app and an Applications shortcut. To package an already-notarized app, run `./scripts/build-dmg.sh` directly. Submit the DMG once, then finish that submission:

```sh
xcrun notarytool submit dist/distribution/Cove-0.1.24.dmg \
  --keychain-profile Cove-notarization --output-format json --no-wait
# Keep the returned DMG submission ID and wait for Accepted status.
./scripts/finish-dmg.sh dist/distribution/Cove-0.1.24.dmg DMG_SUBMISSION_ID Cove-notarization
```

The DMG finishing script staples and validates the disk-image ticket, verifies its signature and checksum, and checks Gatekeeper before copying the final download to `dist/releases/`. Signing receipts and the SHA-256 file remain in `dist/distribution/`. A new build needs its own notarization; never publish the pre-notarization artifact as ready to install. ZIP is now used only for the intermediate app upload; the download format is DMG.

## What moves to another Mac

Only the app and its public OAuth configuration are shared. User mail, passwords, refresh tokens, TypeSafe keys and per-account encryption keys are not included. Another Mac signs into Gmail and creates its own encrypted local cache. Local-only drafts, contacts, preferences, calendar groups and Jev results do not synchronize yet. Copying the encrypted SQLite file without its device's key does not migrate the mailbox. No Windows build is provided.

## Initial distribution verification (0.1.1)

- 168 tests pass, including bundled/custom OAuth selection and invalid-configuration handling.
- Synthetic packaging checks verify that only Desktop client configuration is accepted, embedded user-token/API-key fields are ignored, and a distribution build without configuration fails closed.
- Both Apple Silicon and Intel release compilations and universal packaging pass. Developer ID signing, secure timestamp, Hardened Runtime and strict signature verification pass for `dist/distribution/Cove.app`.
- A separate bundle with isolated preferences was launched for a fresh-install UI check: it opens to the login screen with Continue with Gmail available. The live account was left connected in the existing development app. End-to-end authorization against the new client has not yet been exercised.
- Google policy acceptance, Desktop client, API enablement, tester allowlist and scope declarations are complete.
- Version 0.1.1 (build 3), including the Cove wave app icon, is notarized. Apple accepted submission `e717c00d-3bf6-4b9c-9446-e1f6c31f3c55` on September 22, 2026 (Pacific time), using the locally configured `Cove-notarization` Keychain profile. Stapling, ticket validation and strict signature verification passed; Gatekeeper reports `accepted` with source `Notarized Developer ID`.
- The shareable artifact is `dist/releases/Cove-0.1.1.dmg`. The DMG is independently signed and notarized under submission `7719e0b6-03fc-4064-8f64-28aaaa61ca19`; stapling, checksum validation and Gatekeeper assessment passed. A read-only mount verified the bundled app signature/ticket, icon, version and Applications shortcut. Open the DMG and drag Cove into Applications on macOS 14 or later. Its SHA-256 checksum and signing records stay in `dist/distribution/`. Google sign-in remains limited to the tester allowlist; public Google verification is separate from Apple notarization. Earlier ZIP releases remain as historical artifacts; future releases use DMG.

References: [Google native-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Google verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification), [Apple Developer ID](https://developer.apple.com/developer-id/), [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).


## Route to public launch

Start with a private DMG beta and explicitly allowlisted Google test accounts. Direct distribution already has universal Developer ID builds and notarization; a Mac App Store release is a separate integration/review effort.

Before general availability:

- Complete applicable Google OAuth brand and restricted-scope verification, including any assessment Google requires for the final data-handling architecture. Host accurate privacy, support and account/data deletion guidance on the owned product domain.
- Verify installation, first Google consent, Calendar permission, location denial, model setup and app updates on a clean Mac. No developer tools or developer credentials should be needed for ordinary onboarding.
- Keep the update signing key backed up securely and continue testing upgrades between releases.
- Decide whether Jev and writing models use customers' own credentials or a managed service. The current app has user-supplied credentials; do not distribute an owner's API keys.
- Keep disclosures precise: email storage is currently local to each Mac, with no deployed cloud synchronization. Location weather is opt-in, sends coordinates rounded to two decimal places to MET Norway, and offers manual city selection.

The latest implementation/release evidence is in the versioned `docs/qa/` audits and `docs/STATUS.md`; the initial checks above are historical.

Current finalized installer: `dist/releases/Cove-0.1.17.dmg` (universal, macOS 14+). App and DMG are notarized, stapled and Gatekeeper accepted; full evidence is in [the 0.1.17 audit](qa/0.1.17/AUDIT.md).


## covemail.xyz hosting setup — September 23, 2026

Cloudflare zone `f2ddf5cf3624e799642d9583d9216c03` was created on the Free Website plan in the authorized account. Porkbun remains the registrar. The domain's nameservers were saved and independently reloaded from Porkbun as:

- `destiny.ns.cloudflare.com`
- `greg.ns.cloudflare.com`

Porkbun had exactly two parking records: apex ALIAS and wildcard CNAME to `pixie.porkbun.com`, both TTL 600. Both destinations were preserved in Cloudflare as DNS-only CNAME records (the apex uses Cloudflare's apex flattening). No existing mail records were present. No DS record was returned by the registry at migration time.

Cloudflare's activation check was requested successfully. Last verification: Cloudflare status **pending**; registry/public delegation propagation is not yet complete. The new authoritative Cloudflare server answers the preserved parking addresses. No Cove landing page, Pages project, R2 bucket, or public installer was deployed in this step.

Cloudflare MCP is installed and OAuth-authenticated. The current session used a scoped local MCP client to reach the official server, keeping the OAuth credential in memory and out of logs/files.

## Signed update releases (0.1.24 onward)

The public configuration lives in `assets/update-config.json`. The Ed25519 private key is in the macOS login Keychain under Sparkle account `ai.cove.mac.updates`; it is never bundled or written to the repository. Keep the same key and Apple signing identity for subsequent releases. Back up the signing key to an appropriately protected offline location through Sparkle’s official key-management workflow; losing it complicates updates for installed users.

After both app and DMG notarization finish:

```sh
# Add docs/releases/VERSION.html, then sign and validate the final artifact.
python3 scripts/prepare-update.py 0.1.24
python3 scripts/build-site.py
# Publish dist/site to the existing Cloudflare Pages project: covemail.
```

Publish the feed and downloads together. The stable feed is `https://covemail.xyz/updates/appcast.xml`; versioned DMGs live under `/downloads/`. The preparation script verifies notarization, signs the DMG and feed, verifies both signatures, and stages metadata/checksums. Do not modify a signed feed; regenerate it. Historical download URLs remain available. Cloudflare Pages allows files up to 25 MiB; the script fails before staging larger artifacts. Move downloads to object storage before exceeding that limit.

Automatic installation is disabled. Sparkle validates Ed25519 signatures before extraction and macOS code signing before replacement. The app also defers relaunch for active mail/calendar operations, pending trash undo, and open editors/conversations. The user explicitly resumes from **Cove → Install Update and Relaunch…** after saving and closing their work. Update checks send no email content or credentials; Sparkle system profiling is disabled.

Users on 0.1.23 and earlier need one manual DMG installation to gain the updater. Each future release must increase CFBundleVersion, complete Apple notarization, and publish its newly signed feed. A build on a developer’s Mac does not automatically become an available update.

## Designed disk image window (since 0.1.53)

`scripts/build-dmg.sh` lays out the DMG window with `dmgbuild`. You get the background art from `scripts/dmg/render-background.py` (a 1x + 2x TIFF), Cove at (170, 210), Applications at (490, 210), 128-point icons, no toolbar, sidebar or status bar, and Cove's icon as the volume icon. It writes the layout directly, so Finder never opens during a build. One-time setup in the building checkout, kept out of git:

```sh
python3 -m venv .local/dmg-venv && .local/dmg-venv/bin/pip install "dmgbuild==1.6.7"
```

Without that environment, the script falls back to the old plain `hdiutil` image. Do not set `hide_extensions`: it writes Finder info onto the app bundle and breaks `codesign --verify --strict`. Finder shows only still backgrounds, so the motion is implied by the dot trail; the animated version is on the beta page (`.install-demo`, `?install=<ms>` draws one fixed moment for screenshots).
