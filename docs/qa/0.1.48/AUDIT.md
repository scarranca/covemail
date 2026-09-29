# Cove 0.1.48 — hotfix: AI and TypeSafe keys deleted on hardened builds

Published September 29, 2026 at the user's request, after they reported that Jev said the TypeSafe key was missing right after saving it in 0.1.47. Root cause, fix and probe evidence are in `docs/qa/0.1.47/AUDIT.md` ("Post-release defect").

## Change

- `Vault.legacyQuery` scopes every login-keychain read, save, delete and mailbox-key insert with `kSecUseDataProtectionKeychain: false`. On a build with the data-protection entitlement, an unscoped delete also removed the protected copy just written.
- Settings reads the TypeSafe key back after saving and shows an error instead of "Credentials saved" if it wasn't stored.
- Regression test `HardenedSecretsTests.testLoginKeychainQueriesNeverReachProtectedItems`. Full offline suite: 484 tests, 0 failures, 7 skipped.
- A Developer ID probe with the same profile and entitlements confirmed: an existing login-keychain key migrates on first read and remains in the protected keychain, the legacy copy is removed, and a new save persists.

## Release

- Version 0.1.48, build 50. Universal Developer ID build with the embedded "Cove Developer ID" profile and hardened entitlements; strict verification and secure timestamp passed.
- App notarization `e0fca5d3-f604-4fb2-bb59-5778291375ea` **Accepted**, stapled, Gatekeeper "Notarized Developer ID".
- DMG notarization `dd166275-a90d-4208-8ec3-0613f8f8ae48` **Accepted**, stapled, `hdiutil verify` VALID. `Cove-0.1.48.dmg`: 17,953,739 bytes, SHA-256 `43d57a209da95ff613e8ce3a0eb7ea0c007c75d83d2c6bbc48b745ac55c0cfbb`.
- Signed feed verified (tamper rejected); site staged with 28 verified releases.
- Cloudflare Pages `covemail` (account `f1bf637a…`), branch `main`, commit `1baecef`: deployment **`75e0a625`**.
- Public checks: `/release.json` 0.1.48/50 with matching bytes/SHA; `/download/latest` 302 to 0.1.48; beta page and feed show 0.1.48; the public DMG has matching bytes/SHA, the feed signature verifies and Gatekeeper accepts it; 0.1.47 is still downloadable.
- Not run: the headless `probe-update.swift` check. The user's installed Cove was not replaced; they install via **Cove → Check for Updates…**.
- 0.1.47 users must re-enter AI provider API keys and the TypeSafe key once after updating (the lost keys cannot be recovered).
- Signing prompts: the Developer ID private key is in the System keychain, so each `codesign` use asks for an administrator password. The user was given steps to move it to the login keychain.
