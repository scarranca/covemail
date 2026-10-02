# Cove 0.1.60, build 62: more than one account

## Changes

### Several Google accounts, one open at a time
- **Sign-in layer** (`Security.swift`, new `AccountRoster.swift`):
  - each account's session is its own Keychain entry `googleAccountSession.<sha256(lowercased email)>`;
  - the roster lives in UserDefaults `accounts.roster`;
  - `GoogleAuth.activate(email:)` switches the active account, and `disconnect()` signs out only the active account.
  - `GoogleAuth(storage:)` is an injectable seam for tests.
- **Moving the existing sign-in:**
  - the legacy single `googleAccountSession` is copied to its per-account entry, and deleted only after the copy reads back identical;
  - a legacy entry that can't be decoded is left untouched;
  - if the move fails, the active account keeps using the legacy entry (`sessionStore` fallback) instead of blocking launch, and the move is retried later.
- **App side** (`AppStore.swift`):
  - **`switchAccount(to:)`** settles the current account first (`settleBeforeLeavingMailbox`): it delivers a waiting Undo Send, waits for label/read/Trash queues, sync and cloud sync, and refuses during a user action. It then opens the other mailbox and clears account state (`resetAccountScopedState`).
  - **`addAccount(client:)`** runs the browser sign-in first, while the user keeps working, and settles the current account only after sign-in succeeds. New accounts start with Gmail only.
  - **`disconnect()` / `eraseLocalMailbox()`:** with several accounts, the next account opens; both refuse while an Undo Send is waiting or a switch is running.
  - **Missing sign-in:** a roster account whose session is gone is dropped (`hasSession` is checked before its mailbox opens), and sign-out tries the remaining accounts in order.
- **UI** (`CoveApp.swift`): the sidebar account menu lists accounts with a check on the open one, plus Add account…, Add work account… and Account settings…. An Account command menu offers ⌃1–⌃9.
- **Account chooser:** Google shows it whenever there is no login hint (`prompt=select_account consent`).

### Work accounts with the organization's own client
- `GoogleAuth.connect(client:)` signs in with an organization's Desktop client, and the client is stored in that account's session.
- Reconnecting an account (login hint) reuses its own client.
- `OrgClientSheet` collects the client ID and secret; `docs/ORG-GOOGLE-CLIENT.md` is the admin guide (Internal audience).

### Other changes
- **Sign-in waiting bar:** `SignInWaitingBar` offers Copy link, Open again and Cancel while Google sign-in waits. Cancel shows the quiet status "Account not added", not an error.
- **Agent captions:** they read "agent → label · subject", with Re:/Fwd: and [repo] tags removed and the subject shortened.

## Review

- **How it was built:** two agents worked in parallel on separate files (sign-in layer; AppStore and UI), and the lead integrated them.
- **Independent read-only review:** it found no way to lose the existing sign-in. These findings were fixed before release:
  - an Undo Send could be lost during Add account;
  - changes made during the browser sign-in were dropped;
  - a failed move blocked launch;
  - an account with a missing session stayed stuck in the menu;
  - Google could silently reuse the browser's account;
  - a new account copied the current account's permission choices.

## Verification

- **Full offline suite:** CoveCoreTests 281 (1 skipped) and CoveRenderingTests 395 (7 skipped), 0 failures, with no concurrent runs.
- **Earlier hang:** a hang at `ReaderConversationTests` and 3 reader-scroll/pagination failures were caused by concurrent test runs. They were reproduced on the previous commit and pass when run alone.
- **Account tests** (`GoogleAuthAccountsTests`, `AccountSwitchTests`, `AccountRosterTests`) cover:
  - the move: success, read-back failure fallback, corrupt legacy entry;
  - commit, activate and disconnect;
  - switching: refused while busy, while a sync never ends, or when activation fails;
  - a waiting send delivered for the old account;
  - Disconnect falling back to the next account;
  - `hasSession` telling a missing entry from a locked Keychain;
  - the account-chooser prompt.
- **Not tested live:**
  - the move against the user's real Keychain (planned on the isolated QA bundle first);
  - a real second-account sign-in;
  - a real Internal organization client.

## Known limits

- Only the open account syncs.
- Settings → Gmail shows only the open account.
- A notification for another account doesn't switch to it.
- After the move, downgrading to an older Cove looks signed out.
