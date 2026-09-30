# 0.1.52 — New-user setup (Connections)

Problem: a new user could open Agents and turn on Jev without an AI account or TypeSafe key, and Integrations did not say what to connect or why.

## Changes

- **Integrations → Connections** (sidebar, menu and settings sidebar). One hub with "N of 5 connected" progress and one row per step: Gmail, AI writing and chat, Jev (TypeSafe key), Calendar, Tasks. Each row says what it powers and has a single action; the first missing AI/Jev step expands on open. The sidebar shows a badge with the remaining count.
- **Inline Jev key** (`JevKeyField`): saves to the Keychain via `Vault`, reads it back to verify, records only a non-secret flag (`setup.jevKeySaved`) so status checks never trigger Touch ID.
- **Gates**: Agents list and Settings → Jev show `JevRequiredBanner` with the key field inline when no key is saved; the Jev toggle is disabled until then.
- **Home**: dismissible `SetupChecklistCard` with the remaining steps; Calendar/Tasks connect directly, AI/Jev open Connections focused on that row (`AppStore.integrationsFocus`).

## Verification

- `swift test`: CoveCoreTests 247 (1 skipped), CoveRenderingTests 337 (7 skipped), 0 failures.
- `NewUserSetupRenderingTests` renders `/tmp/cove-setup-connections.png`, `/tmp/cove-setup-home-checklist.png`, `/tmp/cove-setup-agents-gate.png`; screenshots inspected.
- Not verified live: first-run on a clean Mac with a real TypeSafe key.
