# Cove 0.1.52 — Agents audit (unreleased)

Scope: "Try on recent mail" (backfill preview, then apply), Notify mode, and a simpler agents list/editor.
Branch base: `6deac6b` (scarranca/secure-incremental-mail-cache). Nothing was released, pushed or deployed.

## What changed
- **Try on recent mail** (`CustomAgentBackfill` in CoveCore; `AppStore.previewAgentBackfill/applyAgentBackfill/cancelAgentBackfill`; `CustomAgentBackfillPanel`).
  - Editor → Try it → *Recent mail*. Candidates: downloaded Inbox mail from the last 14 days, not Sent/Draft/Trash/Spam, not from the account, not `local-`, newest first, at most 200. Mail the active agent already watches (after `activeSince`) and mail it already handled is excluded.
  - Classification reuses `previewCustomAgent` (same TypeSafe/Jev path and attachment handling), 4 in flight, cancellable; 401/402/403/429/5xx and network errors stop the batch.
  - Preview changes nothing: no Gmail writes, no runs saved. Summary card: "Would label N · U unclear · M no match", compact list (sender · subject · label) and the unclear rows.
  - One primary CTA "Apply to N emails" (the footer's "Create & turn on" is demoted to secondary while a preview awaits apply). Apply saves the agent first with its current status (a draft stays a draft), labels exactly the matches through the shared idempotent `applyAgentLabel` path (also used by the new-mail loop), writes unclear results to Activity only (never labeled), and prepares replies as Activity suggestions (never sent). No-match results are not written to Activity.
  - Result: "Applied to N · K already labeled · F failed · U unclear in Activity", also posted as the list notice. Cancel works while checking and applying; counts stay exact.
  - Charges line: "Uses TypeSafe for each email checked. Charges apply."
- **Notify mode**: per-agent `notifyOnMatch` (optional, nil = off; saving it does not restart `activeSince`). On a confident match of new mail in `runCustomAgents` (at run completion), `agentNotifier.post` sends title = agent name, body = sender · subject, never body text. `SystemAgentNotifier` wraps `UNUserNotificationCenter` (only inside an `.app` bundle); clicking opens the email via `openNotifiedMail` (same account only). Permission is requested only when the toggle turns on; if denied, the toggle returns off and shows "Notifications are off for Cove." with Open Settings.
- **One-CTA UI**: the list drops the subtitle, footer shield line and "Check new mail now"; the per-row Edit button is gone (the whole row opens the editor; the menu keeps the rest); filters/search appear only with more than 5 agents; the empty-state template is a plain link. Editor/Activity back links read "All agents"; leaving an unchanged editor no longer asks to discard. The three-step editor is kept.

## Verified (synthetic fixtures, hidden windows, no real mail/Gmail/TypeSafe)
- New `Tests/CoveRenderingTests/CustomAgentBackfillTests.swift` (10 tests): preview changes nothing; apply labels exactly the matches; unclear go to Activity only; replies prepared, not sent, no Gmail writes; already-labeled mail skipped and not re-charged on a second preview; 200/14-day bound (Sent/archived/Trash excluded); cancellation of preview and apply; new matches notify with minimal content while non-matches, unclear, historical and backfill do not; notify persists without resetting `activeSince`; render.
- Existing `CustomAgentTests` and `CustomAgentEditorRenderingTests` pass (label-path refactor keeps retry/idempotency).
- Full `swift test`: CoveCoreTests 232 (1 skipped), CoveRenderingTests 311 (7 skipped), 0 failures.
- Screenshots inspected: `/tmp/cove-agent-editor-backfill-1180.png`, `/tmp/cove-agent-editor-backfill-820.png`, `/tmp/cove-agent-editor-820.png`, `/tmp/cove-agents-list-1100.png`.

## Not verified / left for a live check
- Real `UNUserNotificationCenter` permission prompt, banner and click-to-open in a signed build (the system notifier is a no-op outside an `.app` bundle; tests use the injected recorder).
- A real TypeSafe backfill on a real mailbox (cost and latency at 200 emails).
- Opening a notification while the editor has unsaved changes navigates to Mail, like the existing Activity "Open email"; unsaved editor text is lost.
