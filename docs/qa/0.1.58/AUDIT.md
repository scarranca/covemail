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
