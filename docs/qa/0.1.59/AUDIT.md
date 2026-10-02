# Cove 0.1.59, build 61: a locked AI key is quiet

## User report

The user saw this alert repeatedly: "Cove couldn’t finish · Keychain could not read your AI key (-25308)."

## Cause

-25308 is `errSecInteractionNotAllowed`.
- On hardened builds, AI and TypeSafe keys live in the data-protection keychain as `WhenUnlockedThisDeviceOnly` items, optionally gated by Touch ID.
- Background work (Jev organizing on sync, task checks) read a key while the Mac was locked, or while Touch ID couldn't be shown with Cove in the background.
- `HardenedSecrets.read` turned the failure into a generic error, and `AppStore.error` showed it as an alert.

## Change

- **Read:** `HardenedSecrets.read` maps `errSecInteractionNotAllowed` to `HardenedSecrets.lockedMessage`.
- **Alert:** `AppStore.error` turns that message into the status line "AI paused while your key is locked · it resumes when you’re back" (the same pattern as Gmail rate limits). The work runs again on the next sync.
- **Unchanged:** user cancellations and auth failures keep their own message, and foreground use still prompts for Touch ID.

## Verification

- **Full offline suite:** CoveCoreTests 278 (1 skipped) and CoveRenderingTests 370 (7 skipped), 0 failures.
- **`HardenedSecretsTests.testALockedKeyIsAQuietStatusNotAnAlert`:** a read returning -25308 throws the locked message, and setting it on the store produces a status line, not an error.
- **Not reproduced live:** locking the Mac during a background Jev run.

## Release

- **App notarization:** `421aaa6e-f085-4230-b874-c89e66779355`, Accepted and stapled.
- **DMG notarization:** `741a648a-3613-4b28-9fa4-b5063102000d`, Accepted and stapled.
- **DMG:** 22,658,600 bytes, SHA-256 `d38dc0e9686aa12e8b37a0637a00f110140f4f6ad089d803ce4437b79bf91e2d`.
- **Feed and site:** signed feed with 38 verified releases; Cloudflare Pages deployment `994e38a7`.
- **Public checks:**
  - `/release.json` reports 0.1.59 (build 61); the appcast and `/download/latest` serve 0.1.59; the beta page says "Download Cove 0.1.59".
  - The downloaded DMG's bytes and SHA-256 match the local build.
  - The Ed25519 signature verifies with the bundled key, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
