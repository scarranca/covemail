#if os(iOS)
import CoveCore
import CryptoKit
import Foundation
import Observation
import UIKit

/// The open account's mail on iPhone. It uses the same encrypted per-email store, Gmail sync and merge
/// rules as the Mac (`Database`, `GmailClient.synchronize`, `GmailSyncResult.merging`), so local state
/// survives syncs. Label changes apply on the phone first, then go to Gmail; Trash and Send wait for an
/// Undo window before anything reaches Gmail.
@MainActor @Observable final class MobileMailbox {
  enum Folder: String, CaseIterable, Identifiable {
    case inbox, starred, snoozed, sent, drafts, all
    var id: String { rawValue }
    var title: String {
      switch self {
      case .inbox: "Inbox"
      case .starred: "Flagged"
      case .snoozed: "Snoozed"
      case .sent: "Sent"
      case .drafts: "Drafts"
      case .all: "Archive"
      }
    }
    var systemImage: String {
      switch self {
      case .inbox: "tray"
      case .starred: "flag"
      case .snoozed: "clock"
      case .sent: "paperplane"
      case .drafts: "doc.badge.ellipsis"
      case .all: "archivebox"
      }
    }
  }

  /// A change waiting out its Undo window.
  struct PendingAction: Identifiable, Equatable {
    let id = UUID()
    let title: String
  }

  private(set) var mails: [Mail] = [] { didSet { listRevision &+= 1 } }
  /// Bumped whenever the loaded mail or hidden set changes; the list and counts are cached against it
  /// (and the folder and filters), so a redraw doesn't re-sort and re-filter every email.
  private(set) var listRevision = 0
  @ObservationIgnored private var visibleCache: (key: VisibleKey, mails: [Mail])?
  @ObservationIgnored private var unreadCache: (revision: Int, counts: [InboxSplit: Int])?
  private struct VisibleKey: Equatable {
    var revision: Int; var now: Date; var folder: Folder; var unreadOnly: Bool; var inboxTab: InboxSplit; var splitInbox: Bool
  }
  var folder: Folder = .inbox
  /// The clock for snoozes, to the minute. Mail snoozed past it is hidden from the Inbox; the app
  /// refreshes it every minute and when it comes to the front (`refreshClock`).
  private(set) var now = MobileMailbox.minute(Date())
  /// Whether iOS lets Cove notify when a snooze ends; nil until the first snooze asked.
  private(set) var snoozeNotificationsAllowed: Bool?
  var inboxTab: InboxSplit = .important
  /// The Inbox's Unread filter (as on the Mac).
  var unreadOnly = false
  var splitInbox: Bool {
    didSet { UserDefaults.standard.set(splitInbox, forKey: "mail.splitInbox") }
  }
  private(set) var syncing = false
  private(set) var loadingOlder = false
  /// The last page of older mail failed to load. The list shows "Couldn’t load more · Try again" instead of
  /// asking again by itself; `retryLoadOlder()` clears it.
  private(set) var loadOlderFailed = false
  /// The encrypted store is being opened and decoded off the main thread; the list isn't empty, just not here yet.
  private(set) var opening = false
  private(set) var hasOlder = true
  /// Quiet progress, such as Gmail asking Cove to slow down. Never an alert.
  private(set) var status: String?
  /// When Gmail last finished a sync for this mailbox, for the list's "Updated …" line.
  private(set) var lastSynced: Date?
  var error: String?
  private(set) var searchResults: [Mail]?
  private(set) var searching = false
  private(set) var pending: PendingAction?
  /// An email whose sending was undone (or failed), to reopen in the composer.
  var restoredDraft: MobileDraft?

  let auth: MobileAuth
  @ObservationIgnored private let searchIndex = MailSearchIndex()
  private let gmail = GmailClient()
  /// Attachment text read this session for Ask Cove, by email ID.
  @ObservationIgnored var attachmentTextCache: [String: ([AgentAttachmentText], [String])] = [:]
  private var database: Database?
  private var openEmail: String?
  private var historyID: String?
  private var nextPage: String?
  private var pendingIDs: Set<String> = []
  /// Label changes still on their way to Gmail, re-applied over every sync result until delivered.
  /// Persisted (`pendingLabelEdits`) so a change made offline still reaches Gmail after a relaunch.
  private var labelEdits: [String: PendingLabelEdit] = [:]
  /// Emails moved to Trash on the phone (Undo window over) that Gmail hasn't confirmed; they stay hidden.
  private var queuedTrash: Set<String> = []
  @ObservationIgnored private var flushTask: Task<Void, Never>?
  @ObservationIgnored private var flushToken = UUID()
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var retryAttempts = 0
  /// Bumped by `close()`, so an open that finishes after the account changed is dropped.
  @ObservationIgnored private var openGeneration = 0
  static let openingStatus = "Opening your mailbox…"
  static let offlineStatus = "You’re offline · showing downloaded mail"
  static let queuedOfflineStatus = "You’re offline · changes will send when you’re back"
  static let rateLimitStatus = "Gmail asked Cove to slow down. Mail will finish updating shortly."
  static let syncFailedStatus = "Couldn’t check Gmail · pull to retry"
  private var hiddenIDs: Set<String> = [] { didSet { listRevision &+= 1 } }
  private var pendingTask: Task<Void, Never>?
  private var pendingCommit: (@MainActor () async -> Void)?
  private var pendingCancel: (@MainActor () -> Void)?
  /// Emails older than this stay in the encrypted store unless starred, drafted or in the Inbox.
  private let windowStart = Calendar.current.date(byAdding: .day, value: -MobileMailbox.historyDays, to: Date()) ?? .distantPast
  /// How much history the phone keeps loaded and downloads in the background: 90 days or about 600 emails,
  /// whichever comes first. Contacts, search, suggestions and voice learning all read this mail.
  static let historyDays = 90
  static let historyLimit = 600
  /// Already-downloaded emails one sync re-checks; the rest wait for the next syncs.
  static let verificationsPerSync = 60
  /// Quiet progress of the background history download, for Settings and Contacts.
  private(set) var historyStatus: String?
  private(set) var downloadingHistory = false

  init(auth: MobileAuth) {
    self.auth = auth
    splitInbox = UserDefaults.standard.object(forKey: "mail.splitInbox") as? Bool ?? true
  }

  // MARK: Opening

  /// What `open` reads from the encrypted store. The `Database` is created and used on a background
  /// thread for the heavy decrypt-and-decode, then handed to the main actor in this box.
  /// `@unchecked Sendable` is sound because the box is built once, the background task ends when it
  /// returns it, and from then on only the main actor touches the database: it is never used from two
  /// threads at once.
  private struct OpenedStore: @unchecked Sendable {
    let database: Database
    let mails: [Mail]
    let historyID: String?
    let nextPage: String?
    let pendingIDs: Set<String>
    let edits: [String: PendingLabelEdit]
    let trash: Set<String>

    static func load(email: String, windowStart: Date) throws -> OpenedStore {
      let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true)
        .appendingPathComponent("Cove", isDirectory: true)
      let filename = SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
      let url = root.appendingPathComponent(filename + ".sqlite")
      let keyName = "mailboxEncryptionKey." + filename
      let key = try MailboxEncryptionKey.load(
        existingEncryptedStore: Database.requiresEncryptionKey(at: url),
        read: { try MobileKeychain.read(keyName) }, write: { try MobileKeychain.insert($0, name: keyName) })
      let db = try Database(url: url, encryptionKey: key, namespace: filename)
      // Mail stays readable while the phone is locked, as it must for a background refresh.
      try? (url as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication,
                                           forKey: .fileProtectionKey)
      let mails = try db.loadMail(since: windowStart)
      var historyID = try db.load(String.self, key: "gmailHistoryID")
      let version = try db.load(Int.self, key: "mailDecodingVersion") ?? 0
      if version < GmailMessage.decodingVersion { historyID = nil }
      return OpenedStore(
        database: db, mails: mails, historyID: historyID, nextPage: try db.load(String.self, key: "gmailNextPage"),
        pendingIDs: try db.load(Set<String>.self, key: "gmailPendingIDs") ?? [],
        edits: (try? db.load([String: PendingLabelEdit].self, key: "pendingLabelEdits")) ?? [:],
        trash: (try? db.load(Set<String>.self, key: "pendingTrash")) ?? [])
    }
  }

  /// Opens (or reopens) the signed-in account's encrypted store and shows what it already has. The
  /// decrypting and decoding of every row runs off the main thread; `sync()` waits for it (it needs the
  /// database), so it can't start first.
  func openIfNeeded() async {
    guard let email = auth.email, email != openEmail else { return }
    close()
    if auth.isSample {
      openEmail = email
      mails = Samples.mail.map { mail in
        // One formatted sample, to check the Formatted / Text only reader.
        guard mail.senderEmail.hasPrefix("oliver@") else { return mail }
        var formatted = mail
        formatted.htmlBody = """
          <div style="max-width:560px;margin:0 auto;font-family:Helvetica,Arial,sans-serif">
          <h1 style="font-size:24px;color:#222">Your workspace, a little faster</h1>
          <p>A few updates we think you’ll love.</p>
          <table style="width:100%;border-collapse:collapse"><tr>
          <td style="padding:12px;background:#f3f4f8;border-radius:8px"><b>Search</b><br>Find anything in a keystroke.</td>
          <td style="padding:12px;background:#f3f4f8;border-radius:8px"><b>Updates</b><br>Simpler project updates.</td>
          </tr></table>
          <p><a href="https://linear.example/changelog">Read the changelog</a></p>
          <img src="https://linear.example/banner.png" width="560" alt="Banner">
          <script>alert('never runs')</script>
          </div>
          """
        return formatted
      }
      hasOlder = false
      return
    }
    openEmail = email
    let generation = openGeneration
    opening = true
    status = Self.openingStatus
    let window = windowStart
    let loaded = await Task.detached(priority: .userInitiated) {
      Result { try OpenedStore.load(email: email, windowStart: window) }
    }.value
    guard openEmail == email, generation == openGeneration else { return }
    opening = false
    if status == Self.openingStatus { status = nil }
    switch loaded {
    case .failure(let failure):
      openEmail = nil
      self.error = failure.localizedDescription
    case .success(let opened):
      labelEdits = opened.edits
      queuedTrash = opened.trash
      hiddenIDs.formUnion(opened.trash)
      historyID = opened.historyID
      nextPage = opened.nextPage
      pendingIDs = opened.pendingIDs
      mails = opened.mails
      database = opened.database
      hasOlder = nextPage?.isEmpty == false || mails.isEmpty
      // A reinstall or a cleared notification list shouldn't lose a snooze's return notice.
      MobileSnoozeNotifier.reconcile(SnoozeNotice.pending(in: mails), account: email)
      // Changes made offline in an earlier session go to Gmail now (or wait for the connection).
      flushQueued(immediately: true)
    }
  }

  func close() {
    commitPendingNow()
    openGeneration &+= 1
    opening = false
    if status == Self.openingStatus { status = nil }
    flushTask?.cancel(); flushTask = nil
    retryTask?.cancel(); retryTask = nil
    retryAttempts = 0
    queuedTrash = []
    loadOlderFailed = false
    database = nil
    openEmail = nil
    mails = []
    historyID = nil
    nextPage = nil
    labelEdits = [:]
    searchResults = nil
    peopleCache = [:]
    contactsCache = nil
  }

  // MARK: What's shown

  var visible: [Mail] {
    // Reading each input here also tells SwiftUI to redraw when any of them changes.
    let key = VisibleKey(revision: listRevision, now: now, folder: folder, unreadOnly: unreadOnly, inboxTab: inboxTab, splitInbox: splitInbox)
    if let visibleCache, visibleCache.key == key { return visibleCache.mails }
    let list = computeVisible()
    visibleCache = (key, list)
    return list
  }

  private func computeVisible() -> [Mail] {
    mails.sorted { $0.date > $1.date }.filter { mail in
      guard !hiddenIDs.contains(mail.id), mail.labels.isDisjoint(with: ["TRASH", "SPAM"]) else { return false }
      switch folder {
      case .inbox:
        guard mail.labels.contains("INBOX"), !isSnoozed(mail) else { return false }
        if unreadOnly && !mail.isUnread { return false }
        return !splitInbox || InboxSplit.split(mail) == inboxTab
      case .starred: return mail.isStarred
      case .snoozed: return mail.snoozedUntil.map { $0 > now } ?? false
      case .sent: return mail.labels.contains("SENT")
      case .drafts: return mail.labels.contains("DRAFT") || !mail.draft.isEmpty
      case .all: return !mail.labels.contains("INBOX") && !mail.labels.contains("DRAFT") && !mail.labels.contains("SENT")
      }
    }
  }

  func unreadCount(_ tab: InboxSplit) -> Int {
    let revision = listRevision
    if let unreadCache, unreadCache.revision == revision { return unreadCache.counts[tab] ?? 0 }
    var counts: [InboxSplit: Int] = [:]
    for mail in mails where mail.labels.contains("INBOX") && mail.isUnread && !hiddenIDs.contains(mail.id) && !isSnoozed(mail) {
      counts[InboxSplit.split(mail), default: 0] += 1
    }
    unreadCache = (revision, counts)
    return counts[tab] ?? 0
  }

  func mail(id: String) -> Mail? {
    mails.first { $0.id == id } ?? searchResults?.first { $0.id == id }
  }

  /// The loaded messages of the email's conversation, oldest first.
  func conversation(for mail: Mail) -> [Mail] {
    let thread = MailConversation.messages(in: mails.filter { !hiddenIDs.contains($0.id) }, anchor: mail)
    return thread.isEmpty ? [mail] : thread
  }

  // MARK: Sync

  /// Checks Gmail. Background callers (the two-minute loop, coming to the front) never raise an alert:
  /// trouble becomes a status line, or the sign-in banner. Only a pull-to-refresh (`interactive`) may
  /// alert, and only for a definitive failure (never for being offline or rate limited).
  func sync(interactive: Bool = false) async {
    guard !syncing, !auth.isSample, let database else { return }
    syncing = true
    defer { syncing = false }
    var refreshedToken = false
    while true {
      do {
        guard try await syncOnce(database) else { return }
        // Gmail answered, so the connection is up: queued changes go now.
        flushQueued(immediately: true)
        return
      } catch is CancellationError {
        return
      } catch {
        // A stale access token: refresh once and read again before calling the sign-in broken.
        if !refreshedToken, GmailFailureKind.classify(error) == .unauthorized {
          refreshedToken = true
          auth.discardAccessToken()
          continue
        }
        guard self.database === database else { return }
        reportSyncFailure(error, interactive: interactive)
        return
      }
    }
  }

  /// One Gmail sync. Returns false when nothing was merged (Gmail asked Cove to slow down, or the
  /// account changed meanwhile).
  private func syncOnce(_ database: Database) async throws -> Bool {
    let token = try await auth.token()
    let result: GmailSyncResult
    do {
      result = try await gmail.synchronize(
        token: token, cached: mails, historyID: historyID, refreshContent: historyID == nil && !mails.isEmpty,
        storedIDs: (try? database.storedMessageIDs()) ?? [], pendingIDs: pendingIDs,
        // New mail first: re-checking what's already here is spread over later syncs (60 at a time).
        maxVerifications: Self.verificationsPerSync)
    } catch let failure as HTTPFailure where failure.isRateLimited {
      status = Self.rateLimitStatus
      return false
    }
    guard self.database === database else { return false }
    try apply(result, keepsAll: false)
    pendingIDs = result.pendingIDs
    try database.save(pendingIDs, key: "gmailPendingIDs")
    lastSynced = Date()
    status = result.pendingIDs.isEmpty ? nil : "Checking \(result.pendingIDs.count) older emails…"
    return true
  }

  private func reportSyncFailure(_ error: Error, interactive: Bool) {
    // The banner (`auth.needsSignIn`) says it; no alert, no competing status line.
    if error is MobileAuth.SignInExpired { status = nil; return }
    switch GmailFailureKind.classify(error) {
    case .network: status = Self.offlineStatus
    case .rateLimited: status = Self.rateLimitStatus
    case .unauthorized:
      auth.requireSignIn()
      status = nil
    case .gone, .refused, .server, .other:
      status = Self.syncFailedStatus
      if interactive { self.error = error.localizedDescription }
    }
  }

  /// Loads the next page of older mail when the end of the list appears.
  func loadOlder() async {
    // After a failure the list shows a Try again row; scrolling doesn't keep asking.
    guard !loadOlderFailed else { return }
    do { try await loadOlderPage(interactive: true) } catch is CancellationError {
    } catch { if self.database != nil { loadOlderFailed = true } }
  }

  func retryLoadOlder() async {
    loadOlderFailed = false
    await loadOlder()
  }

  /// One page (50) of older mail. Emails already stored come back as labels only, so walking pages
  /// Cove already has is cheap. Returns false when there was nothing to load.
  @discardableResult
  private func loadOlderPage(interactive: Bool = false) async throws -> Bool {
    guard !loadingOlder, !syncing, hasOlder, let database, let next = nextPage, !next.isEmpty else { return false }
    loadingOlder = true
    defer { loadingOlder = false }
    let token = try await auth.token()
    let page = try await gmail.page(token: token, pageToken: next, cachedIDs: (try? database.storedMessageIDs()) ?? [],
                                    interactive: interactive)
    guard self.database === database else { return false }
    try apply(GmailSyncResult(messages: page.messages, labels: page.labels, deletedIDs: page.deletedIDs,
                              historyID: historyID ?? "", nextPage: page.next, resetsPagination: true),
              keepsAll: true)
    return true
  }

  /// Downloads older mail in the background after a sync, page by page with a pause between pages,
  /// until the phone has the last 90 days or about 600 emails. Rate limits and failures stop it quietly;
  /// the next sync continues where it stopped. Never an alert.
  func downloadHistory() async {
    guard !downloadingHistory, !auth.isSample, database != nil else { return }
    downloadingHistory = true
    defer { downloadingHistory = false }
    let target = windowStart
    while !Task.isCancelled, hasOlder, mails.count < Self.historyLimit,
          (mails.map(\.date).min() ?? Date()) > target {
      if syncing || loadingOlder {
        try? await Task.sleep(for: .seconds(2))
        continue
      }
      historyStatus = "Downloading older mail · \(mails.count) emails on this iPhone"
      do {
        guard try await loadOlderPage() else { break }
      } catch let failure as HTTPFailure where failure.isRateLimited {
        historyStatus = "Gmail asked Cove to slow down. Older mail continues later."
        return
      } catch {
        historyStatus = nil
        return
      }
      // Gentle on Gmail's per-user budget and the battery.
      try? await Task.sleep(for: .seconds(1.5))
    }
    historyStatus = nil
  }

  private func apply(_ result: GmailSyncResult, keepsAll: Bool) throws {
    guard let database else { return }
    let window = windowStart
    let keepsLoaded: (Mail) -> Bool
    if keepsAll {
      keepsLoaded = { _ in true }
    } else {
      keepsLoaded = { mail in
        mail.date >= window || mail.isStarred || !mail.draft.isEmpty || mail.labels.contains("INBOX")
          || mail.labels.contains("DRAFT") || mail.snoozedUntil != nil
      }
    }
    var merged = try result.merging(into: mails, store: database, keepsLoaded: keepsLoaded)
    // Changes made on the phone that Gmail hasn't confirmed yet win over what the sync read.
    for index in merged.indices {
      if let edit = labelEdits[merged[index].id] {
        merged[index].labels.formUnion(edit.add)
        merged[index].labels.subtract(edit.remove)
      }
    }
    try database.saveMailSnapshot(
      merged, historyID: result.historyID.isEmpty ? nil : result.historyID, nextPage: result.nextPage,
      updatesPagination: result.resetsPagination, decodingVersion: keepsAll ? nil : GmailMessage.decodingVersion)
    mails = merged
    if !result.historyID.isEmpty { historyID = result.historyID }
    if result.resetsPagination {
      nextPage = result.nextPage
      hasOlder = result.nextPage?.isEmpty == false
    }
  }

  // MARK: Search

  func search(_ query: String) async {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { searchResults = nil; return }
    searching = true
    defer { searching = false }
    do {
      let token = try await auth.token()
      let found = try await gmail.search(query: query, token: token, limit: 20)
      try Task.checkCancellation()
      let live = Dictionary(uniqueKeysWithValues: mails.map { ($0.id, $0) })
      let adopted = try database?.adopting(found, live: Set(live.keys)) ?? found
      // Results already loaded keep their local state; the rest come from Gmail or the store.
      let stored = Dictionary(adopted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      searchResults = found.map { live[$0.id] ?? stored[$0.id] ?? $0 }
    } catch is CancellationError {
    } catch let error as URLError where error.code == .cancelled {
    } catch {
      self.error = error.localizedDescription
    }
  }

  func clearSearch() { searchResults = nil }

  /// Reads one email from Gmail (opened from a notification before the next sync) and keeps it.
  func fetch(id: String) async -> Bool {
    if auth.isSample { return mail(id: id) != nil }
    do {
      let token = try await auth.token()
      guard let found = try await gmail.message(id: id, token: token), let database else { return false }
      let adopted = (try? database.adopting([found], live: Set(mails.map(\.id)))) ?? [found]
      searchResults = (searchResults ?? []) + adopted.filter { candidate in !(searchResults ?? []).contains { $0.id == candidate.id } }
      return true
    } catch {
      return false
    }
  }

  /// Instant matches in mail already on this iPhone (the Mac's folded byte search), newest first.
  func localMatches(_ query: String, limit: Int = 50) -> [Mail] {
    let terms = MailSearchIndex.terms(query)
    guard !terms.isEmpty else { return [] }
    return Array(mails.lazy.filter { !self.hiddenIDs.contains($0.id) && $0.labels.isDisjoint(with: ["TRASH", "SPAM"]) }
      .filter { self.searchIndex.matches($0, terms: terms) }.sorted { $0.date > $1.date }.prefix(limit))
  }

  /// Every loaded email in the Inbox, newest first (Home's source).
  var inbox: [Mail] {
    mails.filter { !hiddenIDs.contains($0.id) && $0.labels.contains("INBOX") && !isSnoozed($0) && $0.labels.isDisjoint(with: ["TRASH", "SPAM"]) }
      .sorted { $0.date > $1.date }
  }
  var allLoaded: [Mail] { mails.filter { !hiddenIDs.contains($0.id) } }

  // MARK: Writing context

  /// The account's display name, from mail the user sent (Gmail's From name), or nil if none is known.
  var accountName: String? {
    let own = ContactDirectory.normalizedEmail(auth.email ?? "")
    return mails.lazy.filter { ContactDirectory.normalizedEmail($0.senderEmail) == own && !$0.sender.isEmpty && !$0.sender.contains("@") }
      .map(\.sender).first
  }

  /// Everyone in loaded mail, rebuilt only when the loaded mail changes (not on every keystroke).
  var contacts: [MailContact] {
    let account = auth.email ?? ""
    if let contactsCache, contactsCache.revision == listRevision, contactsCache.account == account {
      return contactsCache.value
    }
    let value = ContactDirectory.build(mails: allLoaded, records: [], accountEmail: account)
    contactsCache = (listRevision, account, value)
    return value
  }
  @ObservationIgnored private var contactsCache: (revision: Int, account: String, value: [MailContact])?
  /// People Gmail found for a typed name, kept for the session so retyping doesn't search again.
  @ObservationIgnored private var peopleCache: [String: [MailContact]] = [:]

  /// People to suggest while typing an address, from mail on this iPhone (instant).
  func contactSuggestions(_ text: String, excluding: Set<String> = [], remote: [MailContact] = [],
                          limit: Int = 6) -> [MailContact] {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    return ContactDirectory.suggestions(text, local: contacts, remote: remote, excluding: excluding, limit: limit)
  }

  /// People matching `text` anywhere in Gmail, beyond the mail downloaded here, as Gmail's To field
  /// finds them. Quiet on failure: the local suggestions stay.
  func lookUpPeople(_ text: String) async -> [MailContact] {
    let folded = MailSearchIndex.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !auth.isSample, folded.count >= 2 else { return [] }
    let key = (auth.email ?? "") + "\n" + folded
    if let cached = peopleCache[key] { return cached }
    do {
      let token = try await auth.token()
      try Task.checkCancellation()
      let found = try await gmail.people(matching: text, token: token, accountEmail: auth.email ?? "")
      try Task.checkCancellation()
      peopleCache[key] = found
      return found
    } catch { return [] }
  }

  /// Excerpts of what the user wrote in Sent, for learning the voice. Reads one page of Sent from Gmail
  /// when the phone has too few (as the Mac does).
  func sentSamples() async throws -> [Mail] {
    let account = auth.email ?? ""
    var candidates = mails
    if VoiceProfile.samples(from: candidates, accountEmail: account).count < 15, !auth.isSample {
      let token = try await auth.token()
      let page = try await gmail.page(token: token, labelID: "SENT")
      candidates += page.messages.filter { message in !candidates.contains { $0.id == message.id } }
    }
    return VoiceProfile.samples(from: candidates, accountEmail: account)
  }

  // MARK: Label changes

  func setRead(_ mail: Mail, _ read: Bool) {
    guard mail.isUnread == read else { return }
    change(mail, add: read ? [] : ["UNREAD"], remove: read ? ["UNREAD"] : [])
  }
  func toggleStar(_ mail: Mail) {
    change(mail, add: mail.isStarred ? [] : ["STARRED"], remove: mail.isStarred ? ["STARRED"] : [])
  }
  func archive(_ mail: Mail) {
    change(mail, add: [], remove: ["INBOX"])
    endSnooze(mail.id)
  }
  func moveToInbox(_ mail: Mail) { change(mail, add: ["INBOX"], remove: []) }

  private func change(_ mail: Mail, add: Set<String>, remove: Set<String>) {
    let id = mail.id
    guard !id.hasPrefix("local-") else { return }
    update(id) { $0.labels.formUnion(add); $0.labels.subtract(remove) }
    if auth.isSample { return }
    queueEdit([id], add: add, remove: remove)
  }

  /// Keeps the change on the phone and queues it for Gmail. It stays queued (and persisted) until Gmail
  /// confirms it or definitively refuses it; being offline or rate limited only delays it.
  private func queueEdit(_ ids: [String], add: Set<String>, remove: Set<String>) {
    for id in ids {
      var edit = labelEdits[id] ?? PendingLabelEdit()
      edit.combine(add: add, remove: remove)
      labelEdits[id] = edit
    }
    persistQueue()
    flushQueued()
  }

  private func persistQueue() {
    guard let database else { return }
    try? database.save(labelEdits, key: "pendingLabelEdits")
    try? database.save(queuedTrash, key: "pendingTrash")
  }

  // MARK: Delivering queued changes

  /// How one try at a Gmail write ended.
  private enum Delivery {
    case delivered
    /// Offline, rate limited or the sign-in needs renewing: keep it queued, try again later.
    case blocked(QueueBlock)
    /// 404: the email is gone from Gmail.
    case gone
    /// Gmail definitively refused (other 4xx, or a server error, which is never retried for a write).
    case refused(String)
  }
  private enum QueueBlock { case offline, rateLimited, signIn }

  /// Runs one Gmail write with a fresh token; a 401 refreshes the token once.
  private func attempt(_ operation: (String) async throws -> Void) async -> Delivery {
    var refreshed = false
    while true {
      do {
        try await operation(try await auth.token())
        return .delivered
      } catch is MobileAuth.SignInExpired {
        return .blocked(.signIn)
      } catch is CancellationError {
        return .blocked(.offline)
      } catch {
        switch GmailFailureKind.classify(error) {
        case .network: return .blocked(.offline)
        case .rateLimited: return .blocked(.rateLimited)
        case .gone: return .gone
        case .unauthorized:
          if refreshed { auth.requireSignIn(); return .blocked(.signIn) }
          refreshed = true
          auth.discardAccessToken()
        case .refused, .server, .other: return .refused(error.localizedDescription)
        }
      }
    }
  }

  /// Sends queued label changes and Trash moves in the background. Safe to call any time; one drain runs
  /// at once. `immediately` also restarts the backoff (a successful sync, coming to the front).
  func flushQueued(immediately: Bool = false) {
    guard !auth.isSample, let database, !(labelEdits.isEmpty && queuedTrash.isEmpty) else { return }
    if immediately { retryAttempts = 0 }
    guard flushTask == nil else { return }
    retryTask?.cancel(); retryTask = nil
    let token = UUID()
    flushToken = token
    // Leaving the app mid-send shouldn't strand the change until the next launch.
    let background = UIApplication.shared.beginBackgroundTask(withName: "Cove queued changes")
    flushTask = Task { [weak self] in
      await self?.drainQueue(database)
      if self?.flushToken == token { self?.flushTask = nil }
      if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
    }
  }

  private func drainQueue(_ database: Database) async {
    var block: QueueBlock?
    while self.database === database, block == nil, !Task.isCancelled {
      let edits = labelEdits, trash = queuedTrash
      if edits.isEmpty && trash.isEmpty { break }
      block = await sendEdits(edits, database)
      if block == nil { block = await sendTrash(trash, database) }
    }
    guard self.database === database else { return }
    if let block { scheduleRetry(block) } else {
      retryAttempts = 0
      if status == Self.queuedOfflineStatus { status = nil }
    }
  }

  /// Sends a snapshot of the queued label changes, one Gmail request per distinct change. Returns why it
  /// had to stop, or nil when every email in the snapshot was settled.
  private func sendEdits(_ edits: [String: PendingLabelEdit], _ database: Database) async -> QueueBlock? {
    var groups: [PendingLabelEdit: [String]] = [:]
    for (id, edit) in edits {
      if edit.isEmpty { if labelEdits[id] == edit { labelEdits[id] = nil } } else { groups[edit, default: []].append(id) }
    }
    var refused: [String] = []
    var message = ""
    var block: QueueBlock?
    for (edit, ids) in groups {
      block = await deliver(edit, to: ids.sorted(), refused: &refused, message: &message)
      if block != nil { break }
    }
    guard self.database === database else { return block }
    persistQueue()
    if !refused.isEmpty {
      self.error = refused.count == 1 ? "Couldn’t update Gmail. " + message
        : "Couldn’t update \(refused.count) emails in Gmail. " + message
    }
    return block
  }

  private func deliver(_ edit: PendingLabelEdit, to ids: [String], refused: inout [String], message: inout String)
    async -> QueueBlock?
  {
    let result = await attempt { token in
      if ids.count == 1 {
        try await gmail.modify(id: ids[0], token: token, add: Array(edit.add), remove: Array(edit.remove))
      } else {
        for start in stride(from: 0, to: ids.count, by: 1000) {
          try await gmail.batchModify(ids: Array(ids[start..<min(ids.count, start + 1000)]), token: token,
                                      add: Array(edit.add), remove: Array(edit.remove))
        }
      }
    }
    switch result {
    case .delivered:
      for id in ids where labelEdits[id] == edit { labelEdits[id] = nil }
    case .blocked(let block):
      return block
    case .gone, .refused:
      if ids.count > 1 {
        // One bad email fails a whole batch; settle them one by one so the rest still go through.
        for id in ids {
          if let block = await deliver(edit, to: [id], refused: &refused, message: &message) { return block }
        }
      } else if case .refused(let text) = result {
        // Gmail won't take it: put the labels back and say so.
        if labelEdits[ids[0]] == edit { labelEdits[ids[0]] = nil }
        update(ids[0]) { $0.labels.subtract(edit.add); $0.labels.formUnion(edit.remove) }
        refused.append(ids[0])
        message = text
      } else {
        removeLocally(ids)
      }
    }
    return nil
  }

  private func sendTrash(_ ids: Set<String>, _ database: Database) async -> QueueBlock? {
    var failed = 0
    var block: QueueBlock?
    for id in ids.sorted() {
      switch await attempt({ token in try await gmail.trash(id: id, token: token) }) {
      case .delivered:
        guard self.database === database else { return nil }
        update(id) { $0.labels.insert("TRASH"); $0.labels.remove("INBOX") }
        endSnooze(id)
        queuedTrash.remove(id)
        hiddenIDs.remove(id)
      case .blocked(let reason): block = reason
      case .gone: removeLocally([id])
      case .refused:
        queuedTrash.remove(id)
        hiddenIDs.remove(id)
        failed += 1
      }
      if block != nil { break }
    }
    guard self.database === database else { return block }
    persistQueue()
    if failed > 0 { self.error = failed == 1 ? "Couldn’t move the email to Trash." : "\(failed) emails couldn’t be moved to Trash." }
    return block
  }

  /// The email no longer exists in Gmail (404): drop it here, quietly.
  private func removeLocally(_ ids: [String]) {
    let gone = Set(ids)
    for id in gone { labelEdits[id] = nil }
    queuedTrash.subtract(gone)
    hiddenIDs.subtract(gone)
    mails.removeAll { gone.contains($0.id) }
    searchResults?.removeAll { gone.contains($0.id) }
    try? database?.deleteMessages(ids: gone)
    persistQueue()
  }

  private func scheduleRetry(_ block: QueueBlock) {
    switch block {
    case .signIn: return  // the inbox banner asks; a successful sync after signing in sends the rest
    case .offline: if status == nil { status = Self.queuedOfflineStatus }
    case .rateLimited: status = Self.rateLimitStatus
    }
    retryAttempts += 1
    let delay = LabelEditRetry.delay(afterAttempts: retryAttempts)
    retryTask?.cancel()
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.retryTask = nil
      self?.flushQueued()
    }
  }

  private func update(_ id: String, _ body: (inout Mail) -> Void) {
    if let index = mails.firstIndex(where: { $0.id == id }) {
      body(&mails[index])
      try? database?.saveMessage(mails[index])
    }
    if let index = searchResults?.firstIndex(where: { $0.id == id }) { body(&searchResults![index]) }
  }

  /// Saves an unsent reply on the email (encrypted, on this iPhone only).
  func saveDraft(_ text: String, for mail: Mail) {
    guard mails.contains(where: { $0.id == mail.id }) else { return }
    update(mail.id) { $0.draft = text }
  }

  // MARK: Snooze

  /// The minute a date falls in, so the clock changes (and the list recomputes) once a minute.
  private static func minute(_ date: Date) -> Date {
    Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
  }

  func isSnoozed(_ mail: Mail) -> Bool { mail.snoozedUntil.map { $0 > now } ?? false }

  /// Refreshes the snooze clock; snoozed mail whose time has passed returns to the Inbox.
  func refreshClock() {
    let current = Self.minute(Date())
    guard current != now else { return }
    now = current
    // Counts and lists are cached against the revision; a snooze ending changes both.
    if mails.contains(where: { $0.snoozedUntil != nil }) { listRevision &+= 1 }
  }

  /// Hides an email from the Inbox until `date` (nil returns it now). Saved on this iPhone only: the
  /// Mac's cloud snooze service isn't wired on iPhone, so snoozes don't sync to the Mac yet.
  func snooze(_ mail: Mail, until date: Date?) {
    guard !mail.id.hasPrefix("local-") else { return }
    let date = date.flatMap { $0 > Date() ? $0 : nil }
    update(mail.id) { $0.snoozedUntil = date }
    listRevision &+= 1
    guard let date else { MobileSnoozeNotifier.cancel([mail.id]); return }
    guard !auth.isSample else { return }
    let sender = SnoozeNotice.senderName(of: mail), subject = mail.subject
    Task {
      snoozeNotificationsAllowed = await MobileSnoozeNotifier.schedule(
        mailID: mail.id, sender: sender, subject: subject, account: auth.email ?? "", at: date)
    }
  }

  /// Archiving or trashing a snoozed email ends its snooze and its pending notification.
  private func endSnooze(_ id: String) {
    guard mails.first(where: { $0.id == id })?.snoozedUntil != nil else { return }
    update(id) { $0.snoozedUntil = nil }
    MobileSnoozeNotifier.cancel([id])
  }

  // MARK: Trash and send, with Undo

  /// Moves to Trash after a five-second Undo window; nothing reaches Gmail before it ends.
  func trash(_ mail: Mail) { trash([mail]) }

  /// Moves emails to Trash after one five-second Undo window for all of them (as on the Mac);
  /// nothing reaches Gmail before it ends.
  func trash(_ batch: [Mail]) {
    let ids = batch.map(\.id).filter { !$0.hasPrefix("local-") }
    guard !ids.isEmpty else { return }
    hiddenIDs.formUnion(ids)
    let title = ids.count == 1 ? "Moved to Trash" : "Moved \(ids.count) emails to Trash"
    let store = database
    schedule(PendingAction(title: title), seconds: 5) { [weak self] in
      guard let self else { return }
      if self.auth.isSample {
        for id in ids {
          self.update(id) { $0.labels.insert("TRASH"); $0.labels.remove("INBOX") }
          self.endSnooze(id)
        }
        self.hiddenIDs.subtract(ids)
        return
      }
      // The Undo window is over: from here the move is queued like a label change. Offline or rate
      // limited, the emails stay hidden and it goes through later; a definitive refusal restores them.
      guard store != nil, self.database === store else { return }
      self.queuedTrash.formUnion(ids)
      self.persistQueue()
      self.flushQueued(immediately: true)
      // Leaving the app or signing out waits for the first attempt, as before.
      await self.flushTask?.value
    } cancel: { [weak self] in
      self?.hiddenIDs.subtract(ids)
    }
  }

  // MARK: Several emails at once (two-finger selection)

  func archive(_ batch: [Mail]) {
    let inbox = batch.filter { $0.labels.contains("INBOX") }
    changeMany(inbox, add: [], remove: ["INBOX"])
    inbox.forEach { endSnooze($0.id) }
  }
  func setRead(_ batch: [Mail], _ read: Bool) {
    changeMany(batch.filter { $0.isUnread == read }, add: read ? [] : ["UNREAD"], remove: read ? ["UNREAD"] : [])
  }
  /// Flags all of them, or removes the flag when every one is already flagged.
  func toggleStar(_ batch: [Mail]) {
    let flag = !batch.allSatisfy(\.isStarred)
    changeMany(batch.filter { $0.isStarred != flag }, add: flag ? ["STARRED"] : [], remove: flag ? [] : ["STARRED"])
  }

  /// One label change for many emails: applied on the phone first, then queued for Gmail (one batch
  /// request per distinct change). Offline, it waits; if Gmail refuses an email, that email gets its
  /// labels back and the failure is said once.
  private func changeMany(_ batch: [Mail], add: Set<String>, remove: Set<String>) {
    let ids = batch.map(\.id).filter { !$0.hasPrefix("local-") }
    guard !ids.isEmpty else { return }
    if ids.count == 1, let mail = batch.first { change(mail, add: add, remove: remove); return }
    for id in ids { update(id) { $0.labels.formUnion(add); $0.labels.subtract(remove) } }
    if auth.isSample { return }
    queueEdit(ids, add: add, remove: remove)
  }

  /// Sends after a four-second Undo window (as on the Mac). `onUndo` gets the draft back.
  func send(to: String, cc: String, subject: String, body: String, reply: Mail?, attachments: [OutgoingAttachment] = [],
            onUndo: @escaping @MainActor () -> Void) throws {
    guard let from = auth.email else { throw CoveError.message("Sign in with Google to send mail.") }
    // Validate now, so a bad address or too many files is reported before the composer closes.
    try OutgoingAttachment.validate(attachments)
    _ = try GmailClient.rawMessage(from: from, to: to, subject: subject, body: body,
                                   replyMessageID: reply?.messageID, cc: cc)
    schedule(PendingAction(title: "Sending…"), seconds: 4) { [weak self] in
      guard let self else { return }
      do {
        let token = try await self.auth.token()
        _ = try await self.gmail.send(token: token, from: from, to: to, subject: subject, body: body, reply: reply, cc: cc,
                                      attachments: attachments)
        if let reply { self.update(reply.id) { $0.draft = "" } }
        await self.sync()
      } catch {
        self.error = "Your email wasn’t sent. " + error.localizedDescription
        onUndo()
      }
    } cancel: {
      onUndo()
    }
  }

  func undoPending() {
    pendingTask?.cancel()
    pendingTask = nil
    pendingCommit = nil
    pending = nil
    let cancel = pendingCancel
    pendingCancel = nil
    cancel?()
  }

  private func schedule(_ action: PendingAction, seconds: Double, commit: @escaping @MainActor () async -> Void,
                        cancel: @escaping @MainActor () -> Void) {
    commitPendingNow()
    pending = action
    pendingCommit = commit
    pendingCancel = cancel
    pendingTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.commitPendingNow()
    }
  }

  /// A new action, closing the account or leaving the app completes the waiting one immediately.
  @discardableResult
  func commitPendingNow() -> Task<Void, Never>? {
    pendingTask?.cancel()
    pendingTask = nil
    guard let commit = pendingCommit else { return nil }
    pendingCommit = nil
    pendingCancel = nil
    pending = nil
    // Leaving the app must not cut a Send or Trash short: ask iOS for time to finish it.
    let background = UIApplication.shared.beginBackgroundTask(withName: "Cove pending change")
    return Task {
      await commit()
      if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
    }
  }

  /// Finishes a waiting Send or Trash before the account goes away (sign-out).
  func finishPending() async {
    await commitPendingNow()?.value
  }
}
#endif
