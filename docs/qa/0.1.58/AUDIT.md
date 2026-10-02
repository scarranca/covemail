# Cove 0.1.58, build 60: send from the right address; Gmail settings

## Changes

- **Default From:** `Preferences.defaultSender` stores the From for new emails, set in Settings → Gmail → Sending.
  - Only verified Gmail send-as addresses are offered (`AppStore.sendingAliases`, loaded once per session).
  - A saved alias that no longer exists falls back to the account address. Saving the account address stores nil.
- **Reply From:** `AppStore.replySender(for:)` picks the address for a reply:
  - the alias found in the original email's To/Cc;
  - the default, when several aliases match (and it's one of them) or none do (for example, mailing lists).
  - The reply box shows a "From …" menu to change it for that reply.
  - The send path still rechecks the alias at send time (existing behavior).
- **Settings → Gmail redesign:** account card (avatar, status, Sync now, ··· Reconnect/Disconnect), Sending, Sync, and Google services (Calendar and Tasks, with Connect/Connected states). The custom Google client moved to a collapsed "Advanced" section.
  - New `SettingsGroup`/`SettingsCard`/`SettingsRow`/`SettingsStatusPill` building blocks.
  - The default-From picker moved from Reading to Gmail.

## Verification

- **Full offline suite:** CoveCoreTests 278 (1 skipped) and CoveRenderingTests 369 (7 skipped), 0 failures.
- **`DefaultSenderTests`** covers the default, the reply-to alias, several matches, the list fallback and a removed alias.
- **Settings Gmail render** inspected at 1100 and 900 points wide.
- **Not run live:** real send-as aliases and a real send from an alias.

## Release

- **App notarization:** `31e5e3a2-d2e7-4be1-83af-fcd7e17977fb`, Accepted and stapled.
- **DMG notarization:** `891c5ada-0c03-415b-baab-d497cc24bc3e`, Accepted and stapled.
- **DMG:** 22,671,149 bytes, SHA-256 `6e06ef7880d6d852ed7241fbe2cea39f2485e0a13af3dfb76a3bfcf9c586ebbd`.
- **Feed and site:** signed feed with 37 verified releases; Cloudflare Pages deployment `c549bea2`.
- **Public checks:**
  - `/release.json` reports 0.1.58 (build 60); the appcast and `/download/latest` serve 0.1.58; the beta page says "Download Cove 0.1.58".
  - The downloaded DMG's bytes and SHA-256 match the local build.
  - The Ed25519 signature verifies with the bundled key, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
