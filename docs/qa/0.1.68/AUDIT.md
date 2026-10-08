# Cove 0.1.68 (unreleased) — faster writing and opening, recipients from all of Gmail

The user reported that writing and fetching mail feel slow. They also said the To field only suggests the people from roughly the last 30 conversations, while Gmail on the web finds anyone.

## Recipients (Mac and iPhone/iPad)

- **Cause:** suggestions were built only from mail downloaded to the device, which is the recent window.
- **Live lookup:** `GmailClient.people(matching:)` (`CoveCore/GmailPeople.swift`) searches all of Gmail with `{from:X to:X cc:X} -in:spam -in:trash`. It reads only the From, To and Cc headers of up to 12 matches (`format=metadata`), never bodies, and ranks people by how often they appear, then how recently.
  - It uses the existing `gmail.modify` scope, so there is no new consent.
  - Google Contacts / "other contacts" via the People API would match Gmail's own field more closely. It needs a new scope (`contacts.other.readonly`), a consent-screen change in the Console, and every user signing in again. Not done; that's the user's decision.
- **Merge order:** `ContactDirectory.suggestions` puts downloaded people first, ranked by whether the name or address starts with the text, then by how many emails. Gmail's extra matches come after, without duplicates or addresses already chosen.
- **When it runs:** downloaded matches show instantly. Gmail is asked after a 300 ms pause, at 2 or more characters, only while To (or Cc on iPhone) has focus. Results are cached per account and text for the session. A lookup is never retried: `request(retries: 0)` means a rate limit or error just leaves the downloaded suggestions.
  - Caveat: Gmail matches whole words, so a partial word like "mar" finds Gmail-only people only once the word is complete. Downloaded people still match partial words.
- **iPhone:** the contact directory is cached against `listRevision` (`MobileMailbox.contacts`). It used to be rebuilt on every keystroke in To/Cc and on every Contacts redraw.

## Writing (Mac)

- `ComposerView` no longer scans all mail on each keystroke.
  - `WritingContext.recentMail` and the recipient names for the writer are computed when To changes, after a 250 ms pause.
  - The contact directory is read once when the composer opens. Every 600 ms autosave changes `mails`, so reading it live forced a full rebuild after each save.
- Reader reply box: `ReaderView.current`/`replySource` use `AppStore.mail(id:)`, an index cached per `mailsRevision`. `ReaderConversation` uses `AppStore.conversation(for:)`, memoized. Previously several linear scans ran per keystroke.

## Opening and moving through mail (Mac)

- **`visible`:** the list is cached without the selection. The open email is inserted on top only where it must stay listed (Inbox tabs, Unread). Arrow keys and clicks no longer re-filter and re-sort the mailbox. Test: `MailSelectionSpeedTests`.
- **`refreshReaderThread`:**
  - It doesn't fetch the same conversation again within 2 minutes; sync still brings new replies.
  - When the fetch changes nothing, it no longer rewrites the store snapshot or replaces `mails`.
- **Inline images:** fetched in parallel (up to 20) instead of one by one. The last 12 emails' images are kept in memory, never on disk.

## Fetching

- `GmailClient.search` (Ask Cove search, iPhone search) reads results 5 at a time instead of one after another.
- `page(interactive: true)` skips the background spacing (0.6 s per email on battery) when the user scrolls to load older mail or opens a label (Mac), or scrolls on iPhone. The iPhone history backfill stays paced. Interactive requests still record their cost in `GmailPacer`.

## Verification

- `swift build` (Xcode toolchain) and `xcodebuild build -scheme CoveMobile -destination 'generic/platform=iOS Simulator'` both succeed.
- `swift test`: 321 core and 409 rendering tests, 0 failures (8 skipped, as before).
- New tests:
  - `GmailPeopleTests`: query sanitizing, headers-only lookup, 404 tolerance, no retry on 429, merge order.
  - `MailSelectionSpeedTests`.
- `ComposeWorkspaceRenderingTests` caught a lookup firing for a prefilled draft without focus, which is now fixed. Its compose render was inspected and is unchanged.
- **Not verified:**
  - live timing on the user's real account;
  - the Gmail lookup against real Gmail;
  - an iPhone simulator or device run.
