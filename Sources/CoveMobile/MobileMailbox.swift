#if os(iOS)
import CoveCore
import CryptoKit
import Foundation
import Observation

/// The open account's mail on iPhone. It uses the same encrypted per-email store, Gmail sync and merge
/// rules as the Mac (`Database`, `GmailClient.synchronize`, `GmailSyncResult.merging`), so local state
/// survives syncs. Label changes apply on the phone first, then go to Gmail; Trash and Send wait for an
/// Undo window before anything reaches Gmail.
@MainActor @Observable final class MobileMailbox {
  enum Folder: String, CaseIterable, Identifiable {
    case inbox, starred, sent, all
    var id: String { rawValue }
    var title: String {
      switch self {
      case .inbox: "Inbox"
      case .starred: "Starred"
      case .sent: "Sent"
      case .all: "All mail"
      }
    }
    var systemImage: String {
      switch self {
      case .inbox: "tray"
      case .starred: "star"
      case .sent: "paperplane"
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
  private let gmail = GmailClient()
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
  private let windowStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast

  init(auth: MobileAuth) {
    self.auth = auth
    splitInbox = UserDefaults.standard.object(forKey: "mail.splitInbox") as? Bool ?? true
  }

  // MARK: Opening

  /// Opens (or reopens) the signed-in account's encrypted store and shows what it already has.
  func openIfNeeded() {
    guard let email = auth.email, email != openEmail else { return }
    close()
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
    mails.filter { mail in
      guard !hiddenIDs.contains(mail.id), mail.labels.isDisjoint(with: ["TRASH", "SPAM"]) else { return false }
      switch folder {
      case .inbox:
        guard mail.labels.contains("INBOX") else { return false }
        return !splitInbox || InboxSplit.split(mail) == inboxTab
      case .starred: return mail.isStarred
      case .sent: return mail.labels.contains("SENT")
      case .all: return !mail.labels.contains("DRAFT")
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
    guard !syncing, let database else { return }
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
    guard !loadingOlder, !syncing, hasOlder, let database, let next = nextPage, !next.isEmpty else { return }
    loadingOlder = true
    defer { loadingOlder = false }
    do {
      let token = try await auth.token()
      let page = try await gmail.page(token: token, pageToken: next, cachedIDs: (try? database.storedMessageIDs()) ?? [])
      guard self.database === database else { return }
      try apply(GmailSyncResult(messages: page.messages, labels: page.labels, deletedIDs: page.deletedIDs,
                                historyID: historyID ?? "", nextPage: page.next, resetsPagination: true),
                keepsAll: true)
    } catch {
      self.error = error.localizedDescription
    }
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
    } catch {
      self.error = error.localizedDescription
    }
  }

  func clearSearch() { searchResults = nil }

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
  func trash(_ mail: Mail) {
    let id = mail.id
    hiddenIDs.insert(id)
    schedule(PendingAction(title: "Moved to Trash"), seconds: 5) { [weak self] in
      guard let self else { return }
      do {
        let token = try await self.auth.token()
        try await self.gmail.trash(id: id, token: token)
        self.update(id) { $0.labels.insert("TRASH"); $0.labels.remove("INBOX") }
      } catch {
        self.error = "Couldn’t move the email to Trash. " + error.localizedDescription
      }
      self.hiddenIDs.remove(id)
    } cancel: { [weak self] in
      self?.hiddenIDs.remove(id)
    }
  }

  /// Sends after a four-second Undo window (as on the Mac). `onUndo` gets the draft back.
  func send(to: String, cc: String, subject: String, body: String, reply: Mail?, onUndo: @escaping @MainActor () -> Void) throws {
    guard let from = auth.email else { throw CoveError.message("Sign in with Google to send mail.") }
    // Validate now, so a bad address is reported before the composer closes.
    _ = try GmailClient.rawMessage(from: from, to: to, subject: subject, body: body,
                                   replyMessageID: reply?.messageID, cc: cc)
    schedule(PendingAction(title: "Sending…"), seconds: 4) { [weak self] in
      guard let self else { return }
      do {
        let token = try await self.auth.token()
        _ = try await self.gmail.send(token: token, from: from, to: to, subject: subject, body: body, reply: reply, cc: cc)
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
  func commitPendingNow() {
    pendingTask?.cancel()
    pendingTask = nil
    guard let commit = pendingCommit else { return }
    pendingCommit = nil
    pendingCancel = nil
    pending = nil
    Task { await commit() }
  }
}
#endif
