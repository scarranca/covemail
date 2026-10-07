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
    case inbox, starred, sent, drafts, all
    var id: String { rawValue }
    var title: String {
      switch self {
      case .inbox: "Inbox"
      case .starred: "Flagged"
      case .sent: "Sent"
      case .drafts: "Drafts"
      case .all: "Archive"
      }
    }
    var systemImage: String {
      switch self {
      case .inbox: "tray"
      case .starred: "flag"
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

  private(set) var mails: [Mail] = []
  var folder: Folder = .inbox
  var inboxTab: InboxSplit = .important
  /// The Inbox's Unread filter (as on the Mac).
  var unreadOnly = false
  var splitInbox: Bool {
    didSet { UserDefaults.standard.set(splitInbox, forKey: "mail.splitInbox") }
  }
  private(set) var syncing = false
  private(set) var loadingOlder = false
  private(set) var hasOlder = true
  /// Quiet progress, such as Gmail asking Cove to slow down. Never an alert.
  private(set) var status: String?
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
  private var labelEdits: [String: (add: Set<String>, remove: Set<String>)] = [:]
  private var hiddenIDs: Set<String> = []
  private var pendingTask: Task<Void, Never>?
  private var pendingCommit: (@MainActor () async -> Void)?
  private var pendingCancel: (@MainActor () -> Void)?
  /// Emails older than this stay in the encrypted store unless starred, drafted or in the Inbox.
  private let windowStart = Calendar.current.date(byAdding: .day, value: -MobileMailbox.historyDays, to: Date()) ?? .distantPast
  /// How much history the phone keeps loaded and downloads in the background: 90 days or about 600 emails,
  /// whichever comes first. Contacts, search, suggestions and voice learning all read this mail.
  static let historyDays = 90
  static let historyLimit = 600
  /// Quiet progress of the background history download, for Settings and Contacts.
  private(set) var historyStatus: String?
  private(set) var downloadingHistory = false

  init(auth: MobileAuth) {
    self.auth = auth
    splitInbox = UserDefaults.standard.object(forKey: "mail.splitInbox") as? Bool ?? true
  }

  // MARK: Opening

  /// Opens (or reopens) the signed-in account's encrypted store and shows what it already has.
  func openIfNeeded() {
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
    do {
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
      database = db
      openEmail = email
      mails = try db.loadMail(since: windowStart)
      historyID = try db.load(String.self, key: "gmailHistoryID")
      nextPage = try db.load(String.self, key: "gmailNextPage")
      pendingIDs = try db.load(Set<String>.self, key: "gmailPendingIDs") ?? []
      let version = try db.load(Int.self, key: "mailDecodingVersion") ?? 0
      if version < GmailMessage.decodingVersion { historyID = nil }
      hasOlder = nextPage?.isEmpty == false || mails.isEmpty
    } catch {
      self.error = error.localizedDescription
    }
  }

  func close() {
    commitPendingNow()
    database = nil
    openEmail = nil
    mails = []
    historyID = nil
    nextPage = nil
    labelEdits = [:]
    searchResults = nil
  }

  // MARK: What's shown

  var visible: [Mail] {
    mails.sorted { $0.date > $1.date }.filter { mail in
      guard !hiddenIDs.contains(mail.id), mail.labels.isDisjoint(with: ["TRASH", "SPAM"]) else { return false }
      switch folder {
      case .inbox:
        guard mail.labels.contains("INBOX") else { return false }
        if unreadOnly && !mail.isUnread { return false }
        return !splitInbox || InboxSplit.split(mail) == inboxTab
      case .starred: return mail.isStarred
      case .sent: return mail.labels.contains("SENT")
      case .drafts: return mail.labels.contains("DRAFT") || !mail.draft.isEmpty
      case .all: return !mail.labels.contains("INBOX") && !mail.labels.contains("DRAFT") && !mail.labels.contains("SENT")
      }
    }
  }

  func unreadCount(_ tab: InboxSplit) -> Int {
    mails.filter { $0.labels.contains("INBOX") && $0.isUnread && !hiddenIDs.contains($0.id) && InboxSplit.split($0) == tab }.count
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

  func sync() async {
    guard !syncing, !auth.isSample, let database else { return }
    syncing = true
    defer { syncing = false }
    do {
      let token = try await auth.token()
      let result: GmailSyncResult
      do {
        result = try await gmail.synchronize(
          token: token, cached: mails, historyID: historyID, refreshContent: historyID == nil && !mails.isEmpty,
          storedIDs: (try? database.storedMessageIDs()) ?? [], pendingIDs: pendingIDs)
      } catch let failure as HTTPFailure where failure.isRateLimited {
        status = "Gmail asked Cove to slow down. Mail will finish updating shortly."
        return
      }
      guard self.database === database else { return }
      try apply(result, keepsAll: false)
      pendingIDs = result.pendingIDs
      try database.save(pendingIDs, key: "gmailPendingIDs")
      status = result.pendingIDs.isEmpty ? nil : "Catching up on mail…"
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Loads the next page of older mail when the end of the list appears.
  func loadOlder() async {
    do { try await loadOlderPage() } catch { self.error = error.localizedDescription }
  }

  /// One page (50) of older mail. Emails already stored come back as labels only, so walking pages
  /// Cove already has is cheap. Returns false when there was nothing to load.
  @discardableResult
  private func loadOlderPage() async throws -> Bool {
    guard !loadingOlder, !syncing, hasOlder, let database, let next = nextPage, !next.isEmpty else { return false }
    loadingOlder = true
    defer { loadingOlder = false }
    let token = try await auth.token()
    let page = try await gmail.page(token: token, pageToken: next, cachedIDs: (try? database.storedMessageIDs()) ?? [])
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
    mails.filter { !hiddenIDs.contains($0.id) && $0.labels.contains("INBOX") && $0.labels.isDisjoint(with: ["TRASH", "SPAM"]) }
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

  /// People to suggest while typing an address: name or address contains the text, most emailed first.
  func contactSuggestions(_ text: String, excluding: Set<String> = [], limit: Int = 5) -> [MailContact] {
    let query = MailSearchIndex.fold(text.trimmingCharacters(in: .whitespaces))
    guard !query.isEmpty else { return [] }
    return ContactDirectory.build(mails: allLoaded, records: [], accountEmail: auth.email ?? "")
      .filter { !excluding.contains($0.email) && MailSearchIndex.fold($0.name + " " + $0.email).contains(query) }
      .sorted { $0.messages.count > $1.messages.count }
      .prefix(limit).map { $0 }
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
  func archive(_ mail: Mail) { change(mail, add: [], remove: ["INBOX"]) }
  func moveToInbox(_ mail: Mail) { change(mail, add: ["INBOX"], remove: []) }

  private func change(_ mail: Mail, add: Set<String>, remove: Set<String>) {
    let id = mail.id
    guard !id.hasPrefix("local-") else { return }
    update(id) { $0.labels.formUnion(add); $0.labels.subtract(remove) }
    if auth.isSample { return }
    var edit = labelEdits[id] ?? (add: [], remove: [])
    edit.add.formUnion(add); edit.add.subtract(remove)
    edit.remove.formUnion(remove); edit.remove.subtract(add)
    labelEdits[id] = edit
    Task {
      do {
        let token = try await auth.token()
        try await gmail.modify(id: id, token: token, add: Array(add), remove: Array(remove))
        labelEdits[id] = nil
      } catch {
        // Gmail didn't take it: put the labels back and say so.
        labelEdits[id] = nil
        update(id) { $0.labels.subtract(add); $0.labels.formUnion(remove) }
        self.error = "Couldn’t update Gmail. " + error.localizedDescription
      }
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
    schedule(PendingAction(title: title), seconds: 5) { [weak self] in
      guard let self else { return }
      var failed = 0
      for id in ids {
        if self.auth.isSample {
          self.update(id) { $0.labels.insert("TRASH"); $0.labels.remove("INBOX") }
          continue
        }
        do {
          let token = try await self.auth.token()
          try await self.gmail.trash(id: id, token: token)
          self.update(id) { $0.labels.insert("TRASH"); $0.labels.remove("INBOX") }
        } catch {
          failed += 1
        }
      }
      if failed > 0 {
        self.error = failed == ids.count ? "Couldn’t move the emails to Trash." : "\(failed) of \(ids.count) emails couldn’t be moved to Trash."
      }
      self.hiddenIDs.subtract(ids)
    } cancel: { [weak self] in
      self?.hiddenIDs.subtract(ids)
    }
  }

  // MARK: Several emails at once (two-finger selection)

  func archive(_ batch: [Mail]) { changeMany(batch.filter { $0.labels.contains("INBOX") }, add: [], remove: ["INBOX"]) }
  func setRead(_ batch: [Mail], _ read: Bool) {
    changeMany(batch.filter { $0.isUnread == read }, add: read ? [] : ["UNREAD"], remove: read ? ["UNREAD"] : [])
  }
  /// Flags all of them, or removes the flag when every one is already flagged.
  func toggleStar(_ batch: [Mail]) {
    let flag = !batch.allSatisfy(\.isStarred)
    changeMany(batch.filter { $0.isStarred != flag }, add: flag ? ["STARRED"] : [], remove: flag ? [] : ["STARRED"])
  }

  /// One label change for many emails: applied on the phone first, then one Gmail batch request.
  /// If Gmail refuses, every email gets its labels back and the failure is said once.
  private func changeMany(_ batch: [Mail], add: Set<String>, remove: Set<String>) {
    let ids = batch.map(\.id).filter { !$0.hasPrefix("local-") }
    guard !ids.isEmpty else { return }
    if ids.count == 1, let mail = batch.first { change(mail, add: add, remove: remove); return }
    for id in ids {
      update(id) { $0.labels.formUnion(add); $0.labels.subtract(remove) }
      var edit = labelEdits[id] ?? (add: [], remove: [])
      edit.add.formUnion(add); edit.add.subtract(remove)
      edit.remove.formUnion(remove); edit.remove.subtract(add)
      labelEdits[id] = edit
    }
    if auth.isSample { for id in ids { labelEdits[id] = nil }; return }
    Task {
      do {
        let token = try await auth.token()
        for start in stride(from: 0, to: ids.count, by: 1000) {
          try await gmail.batchModify(ids: Array(ids[start..<min(ids.count, start + 1000)]), token: token,
                                      add: Array(add), remove: Array(remove))
        }
        for id in ids { labelEdits[id] = nil }
      } catch {
        for id in ids {
          labelEdits[id] = nil
          update(id) { $0.labels.subtract(add); $0.labels.formUnion(remove) }
        }
        self.error = "Couldn’t update \(ids.count) emails in Gmail. " + error.localizedDescription
      }
    }
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
