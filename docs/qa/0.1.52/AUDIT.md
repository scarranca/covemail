# Cove 0.1.52, build 54 — published

0.1.52 ships everything since 0.1.50, including the 0.1.51 work that was built but never published (see `docs/qa/0.1.51/AUDIT.md`).

## Scope (details in this folder)

- `AUDIT-agents.md`: try an agent on recent mail and apply; notify on matches.
- `AUDIT-assistant.md`: screen context, navigation, approval-gated bulk changes.
- `AUDIT-inbox.md`: Important/Other split.
- `AUDIT-tasks.md`: Google Tasks from email.
- `AUDIT-ui.md`: inline AI writing and the simplification pass.
- `AUDIT-setup.md`, the latest round:
  - Connections hub and setup checklist; agents header with the halftoned portrait; agent templates.
  - Describe-to-build agents and the Try it panel.
  - Spam folder and Unsubscribe.
  - Event editor.
  - Ask Cove inside the email, and an assistant reply appearing in the open reader.
  - AI status at launch.
  - Tasks Done, overview, side column and Ignore.

## Verification

- `swift test` at `eddf5d4`: CoveCoreTests 255+ and CoveRenderingTests 343+, 0 failures. The new suites since then also passed: TaskMomentum, GoogleTasksClient, Unsubscribe, EventTimes, CustomAgentBlueprint/Template, Reader.
- Every QA build from `dist/QA-0.1.52-j` to `-v` was used by the user on their real account (QA bundle, `ai.cove.qa`).
- Landing: 1440 and 390 px headless renders inspected. The agents section halftones `site/assets/agent-portrait.jpg` (a generated face from Higgsfield, not a real person) on a canvas; it pauses offscreen and holds still under reduced motion.

## Release

- Distribution build: universal (x86_64 + arm64), Developer ID signed from the login keychain, hardened entitlements with `.local/Cove.provisionprofile`.
- App notarization `bc2646b8-b315-4b27-8350-99355595ae46`: Accepted, stapled.
- DMG notarization `563de04c-4181-4153-9033-83b9f411bd42`: Accepted, stapled (`finish-dmg.sh`: Notarized Developer ID). Stapled DMG: 21,977,558 bytes, SHA-256 `89d8846a32a94ec3a3b5662bd2cb410d4723f0e83599dd17630ababaf39f95cb`.
- `prepare-update.py 0.1.52` signed the feed (31 verified releases); `build-site.py` staged `dist/site`.
- Cloudflare Pages `covemail`, deployment `1391114e` (main). Redeployed as `a7d30c6b` after the user asked to replace "ICE" (a real customer) with the neutral example sender "Acme" on the landing. The custom domain took about a minute to serve it.
- Public checks:
  - `/release.json` and the appcast both list 0.1.52.
  - `/download/latest` redirects to `/downloads/Cove-0.1.52.dmg`.
  - The beta page says "Download Cove 0.1.52".
  - The landing serves the agents portrait (`/assets/agent-portrait.jpg` returns 200).
  - The downloaded DMG matches the bytes and SHA-256 above.
  - `scripts/qa/verify-update-signature.swift` verifies its Ed25519 signature with the bundled public key and rejects a tampered copy.
- Not run: the headless previous→current update probe (`probe-update.swift`). The user's running Cove was not replaced.
- Install: Cove → Check for Updates…
