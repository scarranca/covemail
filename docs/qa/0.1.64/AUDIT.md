# Cove 0.1.64, build 66: smarter agents and About you

## User reports

- "the agents are not smart at all, lol and the UI still is super hard"; "i click and opens without doing anything".
- Try it showed "1 no match · 75 not checked", and later "A ChatGPT request is already running."
- "ok but i mean that was jev for..": Jev, not ChatGPT, should decide.

## Changes

- **Jev decides with context:** whenever a TypeSafe key is saved, `AppStore.decideAgent` passes `AgentBrain.jevContext` to `Jev.classify(context:)`. That context holds the thread, a sender summary, About you and memories, and up to 12 learned verdicts.
- **Fallback:** the writing model decides only without a TypeSafe key, serialized by `AgentModelGate`.
- **Extras:** archive, flag, mark read and create Google Task (`CustomAgentExtra`), applied after the label. Wrong undoes them, but tasks are never deleted.
- **Activity (`AgentActivityView`):**
  - Needs you / Matched / All checks.
  - Mail rows with the reader beside them.
  - Right / Wrong — undo / Yes / No; each answer is saved to `CustomAgent.examples`.
- **Try it:**
  - Groups: Would act on, Unclear, Not a match, each row with a reason.
  - The first error is shown, and the check stops after 5 failures with no success.
- **About you (Agent → About you):** encrypted `Preferences.personal`, sent through `Preferences.memoryPrompt` to every writer and Ask Cove.

## Verification

- **Full offline suite** (`xcodebuild test -scheme Cove-Package`): TEST SUCCEEDED, CoveCoreTests 306 (1 skipped), 0 failures. New tests: AgentBrainTests, PersonalContextTests, and `CustomAgentTests.testJevGetsConversationSenderAboutYouAndVerdicts` and its siblings.
- **Live check:** on a QA build with the user's real account, Try it → Recent mail with Jev. The user reported "worked lot's better".

## Release

- **App notarization:** `11a053f4-d7b8-40a9-91bc-dbbcbee7b00d`, Accepted and stapled.
- **DMG notarization:** `72e6f057-a5ec-4f99-b355-b12ccdfdc8e0`, Accepted and stapled.
- **DMG:** 24,009,033 bytes, SHA-256 `17697c1b990a03b830d89958af90d80b88972040a1b03206475ee3ec99da6621`.
- **Feed and site:** signed feed with 43 verified releases; Cloudflare Pages deployment `8211f067`.
- **Public checks** (with cache-busting queries):
  - `/release.json` reports 0.1.64 (build 66); the appcast and `/download/latest` serve 0.1.64; the beta page says "Download Cove 0.1.64".
  - The downloaded DMG's SHA-256 matches.
  - The Ed25519 signature verifies with the bundled key, and tampering is rejected.
- **Not run:** the headless previous→current update probe.
- **Same deploy:** iPhone/iPad TestFlight build 11 was uploaded. No backend deploy was needed: Cloud Run `cove-sync-api-00007-hm7` already runs the committed backend.
