# Cove design system

Source of truth: the user's **Cove Design System · Foundations** and **Components** HTML exports, supplied September 21, 2026. Exact copies are preserved in `docs/design-source/`. The original five product screens define the layouts; the Foundations and Components HTML files define component styling. The later **Cove · Sign in with Gmail** HTML export defines the current welcome screen and is preserved as `docs/design-source/SignIn.html`.

## Foundations

| Token | sRGB value | Native use |
| --- | --- | --- |
| Canvas | #FFFFFF | Reading and editing backgrounds |
| Surface | #FAFAFA | Secondary surfaces |
| Sidebar | #F0F0F0 | Navigation and contextual headers |
| Selected | #DEDEDE | Selected navigation |
| Muted | #737373 | Metadata on white and near-white |
| Body | #4B4B4B | Prose and text on gray fills |
| Ink | #303030 | Headings, controls, primary actions |

The native `Palette` preserves the supplied sRGB values. Darker body text is used when the muted token would fall below 4.5:1 on gray selected/sidebar surfaces.

Typography is bundled **Inter**: display 42 medium, page title 24 medium, detail title 20 medium, section 16 medium, subheading 14 medium, body 14 regular, text/labels 13 regular/medium, secondary text 12 regular, controls 12 medium, metadata/captions 11 regular/medium. Reading and compose paragraphs use 6-point extra leading; compact metadata stays single-spaced. Fonts are registered for the process through CoreText; no system font installation is required. SF Symbols supply native icons.

Spacing scale: 4, 8, 12, 16, 24, 32, 40, 56. Sidebar width 224. Content insets 28–40. Controls use 6-point radii and a 40-point minimum height; fields use 42 points; panels use 10 points. macOS owns sheet window chrome and presentation.

## Components

`DesignSystem.swift` contains the shared palette, Inter font helpers, primary and secondary button styles, field style, segmented picker, and gradient avatars. Buttons have supplied default, hover (#454545), pressed (#171717), disabled (#E8E8E8/#999999), and charcoal focus states. The explicit focus outline supplements native keyboard focus. Hover transitions last 180ms and respect reduced motion.

Draft badges use #EAE8EE / #62576F. Selected mail rows use the component export's #EBEBEB. People use the supplied periwinkle–lavender–peach gradient and dark #514960 initials. Memory removal offers Undo.

The sign-in screen uses the exact monochrome mountain JPEG extracted from the dedicated sign-in export, with its 600/840 split and larger 54-point Gmail button. The original dotted-wave JPEG from Foundations remains bundled for future brand surfaces. Artwork stays off reading/editing surfaces. The font is bundled with its SIL Open Font License.

## Behavior

The macOS app icon uses the exact three-wave vector from the sign-in export, in near-white on a charcoal rounded tile. Source artwork, the 1024px preview, all macOS icon sizes and `Cove.icns` live in `assets/AppIcon/`. Regenerate with `swift scripts/build-icon.swift` and `iconutil -c icns assets/AppIcon/Cove.iconset -o assets/AppIcon/Cove.icns`. Packaging copies the icon to the app's Resources directory and declares it through `CFBundleIconFile`.

Keep source passages labeled, preserve a review step before sending, show explicit errors, and distinguish sample data from connected data. Native date pickers, menus, keyboard shortcuts, and sheet behaviors remain in place. Model suggestions cannot send messages or create calendar events by themselves.

## Dedicated product exports

The later Main, Agent Hub, and Agent Chat HTML files are preserved in `docs/design-source/`. Main defines inbox and reading-pane spacing, date sections, summaries and draft controls. Agent Hub is the home route (⌘0), with the exact banner artwork, actual priority messages, contacts, attached files and activity counts. Agent Chat uses a maximum 752×800 modal that adapts to smaller windows, with an explicit email context picker, source passages and user-controlled actions. Hub counts and files derive from cached mail; assistant mailbox counts use live Gmail statistics when available and label local fallbacks. Jev's source excerpts remain labeled.

The dedicated **Inbox — No email selected** export is preserved as `docs/design-source/InboxUnselected.html`. Opening an account or folder leaves the reader empty until an explicit row click, arrow-key navigation, or source link selects a message. The reading pane uses the supplied centered envelope tile, heading, instructions, navigation keycaps, and reassurance. Sync and filtering preserve an empty selection; a selected message hidden by the current view clears it. Escape clears selection when the mail list has keyboard focus. Search and reply editors retain their own arrow-key behavior.

The **Cove · Contacts** export is preserved as `docs/design-source/Contacts.html`. Contacts uses its compact application navigation and groups, exact wave artwork, most-messaged strip, searchable directory, and detail pane. Contact records persist per account on this Mac; company and notes are user-maintained. Activity comes from downloaded mail. Calendar opens the existing calendar without creating an event, and Email opens an editable draft.

The September 22 typography refinement follows the lighter current Pen Integrations headings and the user’s request to ease boldness throughout the app. Explicit content headings and navigation emphasis use medium rather than semibold; the compact 26-point Cove wordmark retains its brand weight. Unread rows retain a distinct medium weight and unread marker.

Compose drafting motion (0.1.9): Cove's dotted-wave artwork informs a restrained monochrome particle stream from the assistant to the message canvas during real work. Actual generated text then reveals in a clearly labeled suggestion preview. Keep Apply/Keep original explicit; preserve the original draft and honor Reduce Motion. Provider configuration belongs in Integrations, not the writing flow. Context is visible beside instructions, with recipients suggested in To.

Compose motion (0.1.10): a compact incoming dot stream accompanies actual work; once a suggestion returns, up to 1,400 dots converge onto TextKit glyph outlines and uncover the same native selectable text. The finite 1.25-second reveal never gates Apply; pointer, scroll, or keyboard interaction finishes it immediately. Review edits never replay the reveal, and Reduce Motion skips it. Calendar event controls have explicit outlines, 4-point vertical gutters, 8-point horizontal gutters, and distinct selected/hover states. Presentation lanes account for minimum clickable heights so short consecutive events do not cover one another; their exact times remain unchanged.

0.1.11 motion refinement: AI waiting stages use static text and a cancel affordance, with no looping particles or refinement spinner. Preserve the finite dot-to-glyph reveal exactly when the actual suggestion arrives, along with immediate interaction and Reduce Motion behavior.


0.1.12 compose polish: thinking uses a small native progress indicator and truthful phase label, with a static skeleton in an empty canvas. Reduce Motion uses a static hourglass. No looping particles return. After generation, the wide compose canvas is the editable pending suggestion; the sidebar contains concise voice/request metadata, Apply/Keep original, collapsed comparison, a compact follow-up composer with prompt shortcuts, and collapsed Sources & checks. Compact layouts and replies keep inline editing. The finite returned-text reveal stays, finishes on interaction, and never replays for manual edits. Original text remains untouched until Apply.


0.1.13: the main canvas owns a compact, left-aligned Apply draft action below its text area. The wide sidebar keeps Keep original and refinement controls without a duplicate primary action. Selecting text reveals Rewrite selection on the canvas; the follow-up composer identifies selected scope. Writing shortcuts execute their labeled action. Native selection is synchronized across compact inline review and the main canvas, including focus changes. The finite text reveal and quiet waiting treatment are unchanged.


0.1.14 writing failures stay above the scrolling assistant panel so they remain visible even with many context cards. Show the attempted model, specific reason, Try again and Writing settings. Preserve pending text on failure; retries retain the prior scope and reject stale edits. Sources & checks includes actual Gmail queries and calendar date ranges.


0.1.15 assistant scheduling: calendar requests show truthful understanding/checking stages and a dedicated event card with date, time zone, overlap status, and Review event. Review opens the shared editable Calendar form; only Add event commits. Created events replace the proposal with confirmation, and failed saves remain visible. Calendar responses have no email source cards; inline Markdown emphasis now renders in assistant text.


0.1.16 Hub actions: each Keep in touch person has a small Ignore action beside their name. The ignored address stays excluded until Undo or restoration through the Ignored menu. Keep email Archive/Delete controls outside the priority card’s reader-opening button. Delete confirms Move to Trash and identifies the destination. Mail-list right-click menus expose the same actions; reader toolbar actions remain available.


0.1.17 Home: place today's agenda and pending invitations above priority mail, with compact explicit Accept/Maybe/Decline controls. Weather is an optional sidebar card with location permission, manual city fallback, cached forecast timestamps and source attribution. Mail deletion uses a small bottom notification, a five-second numeric/ring countdown and Undo. Enter from the bottom with a 200 ms fade/slide; Reduce Motion uses a fade. Delay the Gmail Trash request until expiry, reset the shared window for rapid deletions, and preserve native ⌘Delete text editing when an editor has focus. This replaces the prior confirmation dialog for existing-mail Delete actions.

0.1.18 Home hierarchy: HomeType scopes stronger hierarchy to Home. Today, Invitations, and Worth your attention use 18-point semibold headings; Weather, contacts, attachments, and activity use 16-point medium. Actionable event/email titles use 14-point semibold, while contact/file titles use 14-point medium. Explanatory excerpts use 12-point regular body color, actions use 12-point medium, and timestamps/provenance use 11-point metadata. Agenda start times are medium with monospaced digits; invitation dates no longer outweigh titles. Compact Home shows priority mail before Weather. Weather exposes city selection immediately and differentiates location, city search, and forecast loading.

Custom agents (0.1.19) follow Pen's Create custom agent and Your agents references. The management list uses aligned status/activity columns, quiet row dividers and native action menus. The editor keeps natural-language criteria on the left and an inert preview on the right; compact widths stack these with a persistent save footer. Draft/active/paused and match/no-match/review are explicit text states. Unsupported extraction is shown as source evidence and coverage warnings, never invented fields.

Conditional agents (0.1.20) extend the existing editor with ordered When/Then rules. Each rule has a compact action picker, with only the applicable label/reply fields visible. Order controls express first-match behavior. Routing previews show the matched condition and intended actions; editable sample text supports branch testing. Generated replies live in Activity with a small left-aligned Use reply as draft button. The list surfaces pending replies directly.

0.1.21 inbox: match the updated Pen `1. Cove` frame with a 40-point attention/draft status line, 700-weight unread sender/subject, white unread rows and F7F7F7 read rows. Selected EBEBEB and hover EFEFEF remain distinct. Three compact sibling quick actions replace the timestamp on hover/selection without shifting the row. Use a 140 ms fade, disabled under Reduce Motion. Native keyboard handling spans list and reader, yields to editors and dialogs, and supports Up/Down plus Escape/Left back. Reader navigation chevrons now point up/down and remain usable during sync.

0.1.23 agent chat: revised Pen `1. Cove Agent Chat` (Fe933/VxRhd) uses a single-line 16-point semibold header and 32-point emblem; plain 12-point context; 15-point questions and answers; a 464-point maximum question bubble; and borderless 18-point semibold source titles. Keep only the first source expanded by default. Outline Review draft/Open email, keep Remind me quiet, and ground the footer in an actual distinct-email count. The composer contains context, the configured model selector, compact Mail search and a 34-point send/stop control. Use a white input with a one-point outline and 12-point corners. Keep privacy/context details reachable from the small footer info control. Feedback remains visibly selected and local to the conversation; no remote feedback claim. Long answers scroll above the composer; compact widths shorten the Mail search control without removing its accessible name.

0.1.29 Integrations: Writing and answers occupies the main reading width above upcoming integrations. Show the saved default, one account selector with subscription/API billing labels, compact connected status with Manage connection, and one model selector. Version labels come from the official Claude CLI; Automatic is explicitly distinct from pinned versions. Test & use model validates before saving, with inline progress/cancel and success/error feedback. Keep connection internals and privacy details collapsed, preserve failed/cancelled defaults, and use the same model labels in chat.


0.1.35 agent chat: match Pen Fe933/VxRhd at up to 800×896. Use a 12-point-radius FAFAFA answer container with a one-point border and 20-point insets/gaps. Lead AI email responses with a short conclusion, optional 17-point semibold recommendation and source-linked 14-point secondary checks. Exact email quotations can form compact comparison rows; never manufacture conflicts or source references. Sources start collapsed; Copy and local feedback sit in the response footer. Questions use 14/10-point insets and the composer a 20-point internal gap. Draft reply opens the shared writing flow with the current source email and existing draft; the earlier recommendation is untrusted writer context and cannot direct tool lookups. Apply and Send remain separate user actions. Calendar agendas and plain Markdown retain their own content rendering within the shared container.


0.1.36 connectivity: transient URL networking failures from shared app operations and read-state updates use a small bottom-left connection tag instead of the global alert. The neutral pill opens details on click, with Retry sync for failed main-mailbox sync and an optional Dismiss. Successful retries clear the matching issue; local work or stale successes cannot clear it. Repeated failures do not replay the entrance. Honor Reduce Motion. Keep unconfirmed-send, certificate, storage, and other non-connectivity warnings explicit; do not automatically replay mutations.

### Calendar line hierarchy

Calendar guides use the existing line token at 50% opacity; half-hour guides use 22%. Event outlines use the line token instead of the input border, with stronger hover/selection states. Increase Contrast restores full guide opacity and stronger event borders. Text, event hit areas, layout, and the current-time marker retain their existing treatment.

### Calendar month and current time

The view selector offers Workweek, Week, and Month. Month uses a Monday-first six-week grid with selected-day agenda, all-day pills, compact event previews, and an overflow action to show the full day. Narrow grids prioritize titles; event details and times remain available in the agenda. Sync covers all 42 visible days, including adjacent-month dates. Week grids scroll near the current local time on entry and Today; selecting a timed event takes priority. Scrolling remains under user control between navigation actions.


### Settings and integrations readability (0.1.40)

Keep these task-focused pages in an 800-point reading column. Use 26-point medium page titles, 18-point medium section names, 14-point medium setting labels, and 13-point body-colored explanations. Do not use decorative landscape banners or a competing preview column here. Settings sections have full-width disclosure headers, icon/title/status grouping, and consistent 22-point insets; all sections participate in Collapse all. Cloud sync and Privacy have sidebar anchors. Advanced account settings remain nested disclosures. Integrations follows three explicit steps: account, model version, test and save. Saved default and connected-account status are separate facts; saving still follows a successful synthetic test. Future integrations stay under one collapsed disclosure.


0.1.41 Settings navigation supersedes the all-sections layout: each sidebar destination shows only its own content. The page header names the selected section; remove top-level accordions, Collapse all, and the redundant Settings destination. Keep nested advanced connection disclosures. Switching destinations resets that section’s scroll position while parent-owned credential input stays intact. Legacy Settings entry points resolve to Gmail.


0.1.42 settings density: use Cove’s shared 40-point outlined button for local/cloud removal actions; never leave a native automatic bezel among Cove controls. Retain the existing destructive confirmation. Page titles are 24-point medium, section titles 16-point medium, setting labels 13-point medium, explanatory text 12-point regular. Upcoming integrations and the footer use 12-point rows and 11-point secondary copy. Preserve line wrapping and control hit areas while reducing the visual weight of secondary content. This supersedes the larger 0.1.40 settings typography.


### Shared typography (0.1.43)

The role scale in Foundations supersedes the historical per-screen font sizes above. All routes use these shared roles, including compact button labels (12 medium). Compose and the AI preview share native Inter 14 and paragraph spacing. Unread email emphasis, Markdown hierarchy, proportional avatar initials, SF Symbol sizes, native date/menu internals, sign-in branding/artwork, and sender-authored HTML remain intentional exceptions. Settings continues showing one section at a time with 12-point supporting copy. Plain email body width is capped at 660 points; long agent prose columns use the same maximum.

### Email detail reader (0.1.44)

The September 26 live Pen `1. Cove` frame (`w3s2H`, reader `CQs4F`) supersedes the older reading-pane export. Use a 64-point labeled toolbar, 32-point content insets, 22-point section gaps, a distinct F4F6F8 Jev assessment panel with DEE4E9 outline, an Original email header with explicit reading modes, and a fixed Reply / Forward / Ask Cove bar. Narrow panes use accessible icon toolbar actions and wrap response controls. Sender metadata wraps without hiding addresses. Move to Trash and follow-up flags remain under More; Trash keeps Undo. Source excerpts, model assessments, and sender content remain distinct. Jev’s real scores do not imply a verified deadline or generated task summary. Task creation is not implemented; use the existing follow-up flag and local reminders. Translate opens a prepared assistant question; original content and drafts are preserved. The full original message remains scrollable. Shared semantic fonts and existing HTML/privacy settings continue to apply.
