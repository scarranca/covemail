# Cove 0.1.69 (unreleased) — speed and error avoidance: assessment and plan

Goal (October 8, after the inbox-zero wave): make Cove feel fast and stop it from showing errors it
can avoid. This is a correctness-sensitive wave: every change is measured against the committed
baseline and runs the regression-trap suites. Branch: `scarranca/inbox-zero-triage` (wave 1 is there,
not on `main`; agents merge it at `HEAD` first).

## Baseline (committed benchmarks, Apple silicon, debug build)

`MailboxLoadBenchmarkTests` (CoveCore) and `MailboxSpeedBenchmarkTests` (Cove) print `BENCH` lines:

| Measure | Baseline |
| --- | --- |
| Load 4,000 encrypted emails (decrypt + decode, serial, on the calling thread) | 518 ms |
| Save a snapshot of 4,000 | 309 ms |
| One autosave write (encrypt + SQLite) | 0.22 ms |
| Full list rebuild, 4,000 emails (tab switch) | 6 ms |
| Autosave + list read (with the `editDraft` seam) | 0.6 ms |

What this tells us: the store's list work and the autosave write are cheap. "Writing feels slow" is
therefore not the filter or the write; the suspects are SwiftUI re-rendering the composer/reader and
the whole list on every `mails` change, `WKWebView` creation on open, and the main-thread decrypt at
launch. Measure before refactoring; quote before/after.

## Assessment

### Speed

| # | Evidence | Fix |
| --- | --- | --- |
| S1 | `openMailbox` → `loadMailbox` → `Database.loadMail` → `queryMessages` decrypts and JSON-decodes every row serially on the main thread; `MobileMailbox.open` does the same. 518 ms for 4,000; real mailboxes with big HTML bodies are slower. | Read all row blobs on the calling thread (SQLite is thread-confined), then decrypt+decode across cores (`DispatchQueue.concurrentPerform` or a task group over chunks), keep order and `savedMessages` tracking. Both platforms benefit. |
| S2 | Every expanded HTML message creates a new `WKWebView` with its own `.nonPersistent()` store and script handler; `ReaderView` is re-created per selection (`.id(account:mail)`), so opening an email pays web-view creation each time. `EmailBodyView`'s `.task(id:)` hashes the whole HTML per render. | A shared `WKWebViewConfiguration`/process pool and a small warm pool of `EmailWebView`s reused across opens (dismantle returns the view: stop loading, load `about:blank`, keep the handler). Task id on `mail.id` + a revision, not the HTML hash. |
| S3 | `MailRow` runs `replacingOccurrences` over the full body per render; iPhone already uses `.prefix(220)`. | A shared `Mail.preview` helper (first ~240 characters, newlines collapsed) used by Mac rows and `ReaderConversation` snippets. |
| S4 | Autosave mutates `mails` every 600 ms: SwiftUI re-evaluates every view observing `store` (composer, list, reader, Home badge). The store side is now cheap (`editDraft` patches caches in place). | Measure a hosted `ComposerView`/`ReaderView` over a 4,000-mail store during 20 autosaves. Likely costs: `AIWritingPanel(availableContext: store.mails)` passing the whole array as a view input, and rows compared as full `Mail` values. Fix what the measurement shows (pass counts/ids, or an `Equatable` row model). |
| S5 | Folder/label switches wait for a running sync: `MailViews` spins `while store.syncing`, `loadLabelMail` guards `!syncing`, `sync(older:)` returns silently mid-sync so reaching the list end may load nothing. | Verified: `sync` merges into `self.mails` at merge time and calls `reapplyLabelEdits`, so a label page landing mid-sync survives. Give label views and older pages their own flag (`loadingLabel`/`loadingOlder`), let them run beside the background sync, keep `syncing` for the status line. User-asked loads must not wait. |
| S6 | Opening an email changes `mails` several times (`markViewed`, `checkForTasks`, `loadUnsubscribeIfNeeded`, `refreshReaderThread`), each a save and a redraw. | Coalesce the local ones into one mutation where the data is already here; leave network results async; skip no-op writes. |

### Error avoidance

| # | Evidence | Fix |
| --- | --- | --- |
| E1 | A label change made offline is **reverted**: `modify`'s catch undoes the local change for every failure; `ConnectionIssue` only routes the message. `markViewed` says "Open it again to retry". | Durable label edits: keep the local change, retry network-class failures (URLError codes `ConnectionIssue` already lists) with backoff and on `connectionRecovered`/next sync, persist the queue (encrypted record `pendingLabelEdits`) and replay on open, revert only on a definitive refusal (4xx other than 401/429, after a token refresh). Must stay integrated with `labelEdits`/`reapplyLabelEdits` so a sync never undoes a queued change. |
| E2 | A 404 on `modify` (deleted elsewhere) alerts. | Purge locally, no alert. |
| E3 | `pollMailbox` → `sync` → `runSync` → `reportFailure` → `error =` for anything that isn't a URLError or 429: a revoked refresh token alerts **every 2 minutes**. | Background failures are a status line and the connection tag; only ⌘R / the sync button alerts. Auth failures (`invalid_grant`, 401 after refresh) show one persistent reconnect affordance; look for `needsGoogleIdentity`, `SignInWaitingBar`, "Sign in to it again" before inventing one. |
| E4 | `error` is set repeatedly with the same text (e.g. `persistMessage` on every autosave if storage fails). | Dedupe in the setter: the same message while one is showing doesn't restack. |
| E5 | iPhone alerts on everything: `sync()` offline → alert; `change` failure → revert + alert; `loadOlder` → alert; Trash → alert. | Same shape as E1/E3: a status line for background work ("You're offline · showing downloaded mail"), a durable retry queue for label edits (persisted, replayed on open), inline retry for paging, an alert only for a user action that definitively failed. |
| E6 | No quit handling: `CoveAppDelegate` has no `applicationShouldTerminate`; reply/compose saves are debounced 600 ms and flushed only on disappear; `queueSend` has a 4 s window. Quitting loses typing and possibly a send. | Editors flush on `NSApplication.willTerminateNotification`; the delegate returns `.terminateLater`, awaits `settleBeforeLeavingMailbox` (verify what it waits for) and then replies; bounded by its timeout. |

## Agents (one owner per file; worktrees start from `main`, so merge `scarranca/inbox-zero-triage` first)

- **Agent A (Opus 5.5) — `Sources/Cove/AppStore.swift`, `Sources/Cove/ConnectionStatus.swift`, new
  `Sources/Cove/LabelEditQueue.swift` if wanted, tests under `Tests/CoveRenderingTests/` (new files or
  `LabelEditInFlightTests`, `WorkWhileSyncingTests`, `ConnectionStatusTests`, `ReadStateTests`,
  `MailboxPollingTests`).** E1, E2, E3, E4, S5, S6. If it's too much, defer S5 and say so.
- **Agent B (Sonnet) — CoveCore only: `Sources/CoveCore/Database.swift`, `Models.swift`,
  `Tests/CoveCoreTests/` (new files; `MailboxLoadBenchmarkTests` quotes before/after).** S1 and the
  `Mail.preview` helper for S3. Nothing in `Sources/Cove` or `CoveMobile`.
- **Agent C (Sonnet) — Mac UI: `EmailBodyView.swift`, `ReaderConversation.swift`, `MailViews.swift`
  (row preview only), `SetupViews.swift` (`ComposerView`), `ReaderView.swift` (flush only),
  `CoveApp.swift` (delegate), rendering tests.** S2, S3 (use `Mail.preview` once B lands; until then a
  local prefix), S4 measurement and fix, E6.
- **Agent D (Sonnet) — `Sources/CoveMobile/` only, plus iPhone tests if a seam exists.** E5 and the
  open-time load off the main thread (create the `Database` inside the detached task and hand it over;
  it's used from one actor afterwards).

## Rules

- Build with Xcode: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. iPhone library:
  `xcodebuild build -project iOS/*.xcodeproj -scheme CoveMobile -destination 'generic/platform=iOS Simulator' -quiet`.
- Regression traps (AGENTS.md): never retry non-GET requests after server errors (retry *network*
  failures, never 5xx on writes); rate limits stay a status line; `busy` never blocks user actions;
  every Gmail merge calls `reapplyLabelEdits`; `AppStore` never calls `applying(to:)` directly;
  `saveMessage` only for mail in `mails`; the clear-text columns stay as they are; Trash keeps its
  Undo window.
- Measure, don't assume: quote `BENCH` lines (or a hosted-view timing) before and after.
- No release, no push to `main`.
