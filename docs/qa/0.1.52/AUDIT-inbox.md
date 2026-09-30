# Cove 0.1.52 (unreleased): Important / Other inbox split, audit

Scope: split Inbox tabs, per-email and per-sender votes with Undo, a quieter list header. Not released, pushed or deployed. Every check used synthetic fixtures and hidden-window rendering. No Gmail calls were made, and no real account was involved.

## Behavior

- **Membership** (`Sources/CoveCore/InboxSplit.swift`) is checked in this order, and the first rule that matches wins:
  1. The user's vote on the email (`Mail.inboxVote`).
  2. The user's sender rule (`Preferences.inboxSenderRules`, keyed by the lowercased bare address).
  3. Jev `needsReply` or `urgent` ≥ 0.65 → Important. This keeps automated mail that needs action in Important.
  4. `isBulkOrAutomated == true` (List-Unsubscribe and similar headers) → Other.
  5. The sender's local part is a notification address (`noreply`/`no-reply`/`donotreply`, `notifications`, `notify`, `newsletter`, `mailer-daemon`) → Other.
  6. Jev category Newsletters, Updates or Purchases → Other. `MailCategory` has no Promotions category, so Purchases (receipts and offers) stands in for it.
  7. Everything else → Important.

  Each result carries a `Reason` with a one-line explanation.
- Two deliberate product choices:
  - Gmail's own `IMPORTANT` label does not decide the tab, because Gmail applies it to many newsletters. It still counts toward the Home "Needs attention" count (`isPriority`).
  - Older snapshots with `isBulkOrAutomated == nil` are not guessed into Other.
- **Where the split applies:**
  - It applies only in the Inbox, with the split on and the search empty. Search always covers both tabs.
  - It does not apply to label views, Jev flag views, or the "Needs attention" filter set from Home, Contacts or Chat. That filter now shows as a dismissible chip instead of silently filtering the list.
  - The Unread filter works with either tab, and with the unsplit Inbox.
- **Votes:**
  - The reader's More menu and the row context menu offer "Move to Important/Other" and "Always Important/Other from <sender>". These items are hidden for drafts and sent mail.
  - A vote is stored in the email's encrypted local record. `GmailSyncResult.applying(to:)` keeps it next to the decision, draft and snooze, which also covers `merging(into:store:)` for stored archived mail. The vote is not uploaded; the cloud DTO excludes it.
  - Choosing a sender rule clears any conflicting per-email votes for that sender, so the newest explicit choice wins.
  - A dark toast offers Undo for 6 s and restores the previous votes and rules.
  - When the open email is moved, it stays listed until selection moves on, the same way a read email does.
- **Setting:** a "Split inbox" toggle (on by default; `Preferences.splitInbox == nil` means on) sits in Settings → Reading. It needed a one-line change in `SettingsView.swift`: `ReadingSettingsView(showsHeading: false, store: store)`.
- **Header simplification:**
  - Removed the "N need attention · N drafts ready" strip and the Priority / Unread / All mail text row.
  - The header now holds the title, a sync icon with a tooltip, search, the Important/Other tabs with unread counts, and a compact Unread toggle.
  - Compose remains the sidebar's single primary button, so no second primary action was added.
  - Other folders show no filter row.
- **Performance:**
  - `VisibleKey` now includes the effective tab and the sender rules, in both the direct construction and the construction used for search narrowing.
  - Unread counts for the tabs are memoized under the same kind of key and are not recomputed on every read.

## Verified

- `swift build` passes.
- New `CoveCoreTests.InboxSplitTests` (4 tests) cover:
  - the membership rules and the precedence of vote over sender rule over Jev
  - that Gmail `IMPORTANT` alone does not move mail to Important
  - that a vote survives `merging(into:store:)` for both live and stored-archived emails, and that a snapshot reload keeps it
  - that older Preferences still decode, with the split on by default
- New `CoveRenderingTests.InboxSplitStoreTests` (6 tests) cover:
  - tabs, the Unread filter with either tab, search spanning both tabs, "Needs attention" bypassing the split, and non-Inbox folders
  - turning the split off shows everything, and the setting persists
  - a vote overrides immediately, Undo restores it, and the open-message grace works
  - a sender rule applies to new mail from that sender (address case ignored) and Undo restores the earlier vote
  - unread counts per tab
  - memoization: exactly one `visible` computation per tab switch on 5,000 emails, measured at about 11 ms for 6 reads, with an assertion under 250 ms. Search narrowing still computes once per keystroke state when a tab is part of the key.
- Full `swift test`:
  - CoveRenderingTests: 299 tests, 7 skipped (live, opt-in), 0 failures.
  - CoveCoreTests: 226 tests, 1 skipped, 0 failures.
  - Contacts/CoreData XPC log noise in the output is environmental.
- Screenshots inspected:
  - `/tmp/cove-mail-tabs-important.png` and `/tmp/cove-mail-tabs-other-unread.png` (1100 pt)
  - `/tmp/cove-mail-tabs-undo.png` and `/tmp/cove-mail-tabs-off.png` (900 pt, 300 pt list column)
  - `/tmp/cove-mail-900.png` (existing fixture)
  - Fixed while inspecting: the Unread toggle truncated to "Unr…" at 300 pt, and the capsule stroke left a stray edge in the cached render. The toggle is now fixed-size with a 6 pt rounded rectangle.

## Not verified / limits

- Not checked in a live app or on a real mailbox. How many emails land in Other depends on real List-Unsubscribe coverage and on Jev decisions.
- The context menus and More menu items were not exercised through UI automation. Their actions are covered by the store tests.
- VoiceOver was not tested live. The tabs expose a label with the unread count and the selected trait.
- `Mail.inboxVote` is local to this Mac. It does not reach the cloud mirror or other Macs.
