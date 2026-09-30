# Cove 0.1.52 — UI simplification pass (Home, navigation, Settings, Integrations, Contacts, Calendar header, Welcome)

The request: "make the UI easier to understand, show only one important CTA, remove text, improve navigation". This is presentation only; no feature was removed. Unreleased, not published.

Base: merged `scarranca/secure-incremental-mail-cache` at `1f20f97` (contains `6deac6b`). The only conflict was the Calendar header: kept the new sync icon and drag gestures, and dropped the duplicate New event button.

## Rules applied

- **One primary action per pane.** The sidebar's create button (Compose / New event / New contact / Create agent, ⌘N) is the app-wide primary action. A content pane shows at most one `PrimaryButton`, and never one that repeats the sidebar's action.
- **Less text.** Subtitles, reassurance lines and explanatory paragraphs became `.help` tooltips or labeled disclosures. Disclosures that matter stay visible in one short line: "Not end-to-end encrypted" for cloud sync, provider billing, the weather data source and its attribution links, and "Senders may learn that you opened their email".
- **Navigation.** The sidebar always shows the same destinations in the same order, and the selected destination is always highlighted.

## Per screen, before → after

| Screen | Before | After |
| --- | --- | --- |
| Sidebar (`CoveApp.swift`, `Sidebar` struct only) | Four different nav sets depending on the screen. Home showed "Agent Hub" and hid Integrations/Settings; Calendar lacked Agents; Contacts lacked Home. A "Your agents" card repeated the Agents row. | The same five rows on every screen: Home ⌘0, Mail ⌘1, Calendar ⌘2, Agents ⌘3, Contacts ⌘4. Order and names match the Go menu, and shortcuts are shown in tooltips. Below them sits a contextual group: Mail folders, Categories and Jev flags; the mini-calendar; or contact Groups. Integrations and Settings are always at the bottom. The agents card became a one-line busy status / "Checked …" line. The Mail row shows the inbox count when you are outside Mail. |
| Home | Three primary "Review" buttons; Delegate shown on every row; toolbar "Agent Hub" plus a Settings gear; count tags repeating the briefing; a footer reassurance line; empty-state paragraphs; "View activity" text. | Only the top decision's Review is primary; the others are secondary. Delegate… moved into each row's ⋯ menu. The title reads "Home" and the gear is gone (Settings is in the sidebar). Only the invitations tag remains. Empty states are one line. Waiting/Keep-in-touch/activity details are tooltips. |
| Home › Today/Invitations/Weather | "Your primary Google Calendar · next 90 days" line; the RSVP note repeated under every invitation; a weather tagline. | The scope note is a tooltip on Invitations. The RSVP note is the tooltip and accessibility hint of each Accept/Maybe/Decline button (shared with Calendar's event detail). Weather keeps the short "City search by Apple · forecasts by MET Norway (rounded location)" line and the MET Norway / CC BY 4.0 links. |
| Settings | Every section had a subtitle; "Privacy & local data" vs sidebar "Privacy"; Connect Gmail appeared twice (once inside the advanced disclosure); long toggle captions; a version footer. | Titles match the sidebar, with no subtitles. The single Connect Gmail stays at the top, and the disclosure keeps Save credentials. Toggle explanations are tooltips. Voice learning details sit under **What's sent and saved**. Touch ID gets one short line, with details in a tooltip. The version footer is gone (App updates shows it). |
| Settings › Reading | Two long captions and a footer. | One short caption each. The external-images privacy caveat stays. |
| Settings › Cloud sync | Three paragraphs; all buttons secondary. | One line: "A copy of recent mail on Cove's servers. Not end-to-end encrypted." Full retention/storage/keys text is under **What's stored**. Enable cloud sync… is the primary action. |
| Integrations | Subtitle, Collapse/Expand all, footer, several guidance paragraphs; Save key and Test & use model could both be primary. | Title only. Connect/Sign in/Save key is primary until the account is ready; after that, Test & use model is the single primary action. Test, model-list and sign-in guidance are tooltips. Billing lines and **Privacy & email context** remain. |
| Contacts | "N contacts" label, a footer note, the "A little context" paragraph, and multi-sentence empty states. | The count shows as a number, with the scope in a tooltip. The detail pane has a plain **Notes** section (Add a note). Empty states are one line, and the unselected pane fills its column. Email remains the pane's single primary action. |
| Calendar (header/agenda text only) | A "breathing room" banner, a header New event (duplicating the sidebar), the "Your time. Your call." footer, and focus-time paragraphs. | The banner is removed; the focus suggestion stays in the grid and the agenda. New event lives only in the sidebar (⌘N). The agenda section is "Focus time", with the explanation as a tooltip. Gesture code is untouched. |
| Welcome | A two-line subtitle, a final-say line, and a two-line footer. | One subtitle line and a one-line local-storage footer. Continue with Gmail is the only primary action. `ComposerView` (same file) is untouched. |

## Screenshots

Hidden-window renders, inspected by eye. Copies are in the worktree's ignored `.build/ui-shots/{before,after}/`.

- **Before** (Sep 29 23:48): `cove-hub-0133-{1040,1440}`, `cove-home-0118-{720,1100}`, `cove-settings-*-{900,1100}`, `cove-cloud-settings`, `cove-claude-integrations-{620,760,1100}`, `cove-type-{welcome,contacts-*}-{900,1280}`, `cove-calendar-full-week`.
- **After** (Sep 30 00:01–00:02, unique paths): `/tmp/cove-ui-sidebar-{home,mail,calendar,contacts,agents,integrations}.png`, `/tmp/cove-ui-screen-{home,calendar,contacts,settings-Gmail,settings-Jev,settings-Readi,settings-Priva}.png`, `/tmp/cove-ui-home-extras.png`. Earlier after-shots from the shared paths: `cove-hub-0133-1440`, `cove-home-0118-720`, `cove-settings-*`, `cove-cloud-settings`, `cove-claude-integrations-760`, `cove-type-{welcome,contacts-detail}-1280`.
- **Caveat:** other agents' suites write the same `/tmp/cove-*.png` names. Twice, a shared-path file was overwritten by another worktree's build: `cove-type-welcome-900` and `cove-calendar-full-week` still showed the old banner. The new `SidebarNavigationRenderingTests` therefore writes `cove-ui-*` paths, which are the authoritative after-evidence.

## Tests

- New: `SidebarNavigationRenderingTests`. It renders the sidebar for six destinations, Home's extras, and whole screens (sidebar + destination) plus four Settings sections, all offscreen. It asserts the windows are never visible.
- No existing test asserted a removed string. `CalendarSyncTests` still checks `newItemTitle == "New event"` (the sidebar).
- Full `swift test` after the merge: CoveRenderingTests passed 312 tests with 7 skipped. CoveCoreTests passed 232 tests with 1 skipped. There were 0 failures.

## Recommendations outside this scope

- **Mail list / `MailViews.swift`:**
  - Give the list header one title that matches the selected sidebar row (Inbox, Flagged, a Category name).
  - Keep compose as the only primary action; row actions should be hover icons with tooltips.
  - Move the empty-reader keycap instructions into a single line.
- **Reader / `ReaderView.swift`:**
  - Make Reply the single primary action. Reply all, Forward, labels, snooze and translate belong in secondary buttons or the message menu.
  - Collapse the Jev assessment/source into a disclosure when there is no action.
- **Jev flags (`MailLabelViews.swift`):** the disclosure leaves a large vertical gap in the sidebar render. Consider plain rows under the Mail group.
- **Settings sidebar:**
  - "Back to Cove" returns to Inbox even when Settings was opened from Home or Calendar. Remember the previous screen instead.
  - On the Integrations route, the Settings sidebar replaces the main sidebar. Consider keeping the main sidebar and highlighting Integrations.
- **Calendar event detail:** it stacks up to five full-width secondary buttons (View email, Join Meet, Open in Google Calendar, Edit, Delete). Keep Join/Edit visible and move the rest into a ⋯ menu.
- **Agents (`CustomAgentViews.swift`), chat (`AgentChatView.swift`):** apply the same one-primary rule (owned by other agents).
