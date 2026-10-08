import Foundation

extension GmailMessage {
  public static let decodingVersion = 5
}

public struct GmailSyncResult {
  public var messages: [Mail] = []
  public var labels: [String: Set<String>] = [:]
  public var deletedIDs: Set<String> = []
  public var historyID: String
  public var nextPage: String?
  public var resetsPagination = false
  /// Emails this sync didn't get to because Gmail asked Cove to slow down. They are saved and
  /// checked first on the next sync, so a long catch-up continues in batches instead of failing.
  public var pendingIDs: Set<String> = []
  /// Label changes Gmail's history reported for emails already on this Mac, applied without reading them
  /// again (a read costs 20 quota units; the history entry is already paid for).
  public var labelChanges: [String: GmailLabelChange] = [:]

  public init(
    messages: [Mail] = [], labels: [String: Set<String>] = [:],
    deletedIDs: Set<String> = [], historyID: String, nextPage: String? = nil,
    resetsPagination: Bool = false
  ) {
    self.messages = messages
    self.labels = labels
    self.deletedIDs = deletedIDs
    self.historyID = historyID
    self.nextPage = nextPage
    self.resetsPagination = resetsPagination
  }

  /// Merge only remote fields; edits made locally while a request was in flight survive.
  public func applying(to cached: [Mail]) -> [Mail] {
    var values = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
    for var mail in messages {
      if let previous = values[mail.id] {
        mail.decision = previous.decision
        if mail.body != previous.body, let excerpt = mail.decision?.excerpt,
          previous.body.contains(excerpt), !mail.body.contains(excerpt)
        {
          // A decoding repair may remove sender markup from a previously selected passage.
          // Keep the assessment, but only retain passage text corroborated by the refreshed body.
          let readable = GmailMessage.stripHTML(excerpt)
          mail.decision?.excerpt =
            !readable.isEmpty && mail.body.contains(readable) ? readable : nil
        }
        mail.draft = previous.draft
        mail.snoozedUntil = previous.snoozedUntil
        mail.taskCheck = previous.taskCheck
        mail.inboxVote = previous.inboxVote
      }
      values[mail.id] = mail
    }
    for (id, labels) in labels { values[id]?.labels = labels }
    let refreshed = Set(messages.map(\.id)).union(labels.keys)
    for (id, change) in labelChanges where !refreshed.contains(id) {
      values[id]?.labels.formUnion(change.added)
      values[id]?.labels.subtract(change.removed)
    }
    for id in deletedIDs {
      guard let previous = values.removeValue(forKey: id), !previous.draft.isEmpty else { continue }
      // A remotely deleted source must not destroy an unsent local reply.
      let recoveredID = "local-recovered-\(id)"
      if values[recoveredID] == nil {
        values[recoveredID] = Mail(
          id: recoveredID, sender: previous.sender, senderEmail: previous.senderEmail,
          to: previous.replyRecipient,
          subject: previous.subject.lowercased().hasPrefix("re:")
            ? previous.subject : "Re: \(previous.subject)",
          body: previous.draft, date: previous.date, labels: ["DRAFT"])
      }
    }
    return values.values.sorted { $0.date > $1.date }
  }

  /// Applies this result to the live mailbox without damaging stored emails that aren't loaded.
  /// Their Jev decision, draft, snooze and Inbox vote are kept; results `keepsLoaded` rejects are written back
  /// as archive (untracked), and remote deletions remove their local copies.
  public func merging(
    into live: [Mail], store: Database?, keepsLoaded: (Mail) -> Bool = { _ in true }
  ) throws -> [Mail] {
    guard let store else { return applying(to: live) }
    let liveIDs = Set(live.map(\.id))
    let touched = Set(messages.map(\.id)).union(labels.keys).union(labelChanges.keys).union(deletedIDs).subtracting(liveIDs)
    let archived = touched.isEmpty ? [] : try store.loadMessages(ids: touched)
    guard !archived.isEmpty else { return applying(to: live) }
    let archivedIDs = Set(archived.map(\.id))
    var loaded: [Mail] = []
    var stays: [Mail] = []
    for mail in applying(to: live + archived) {
      if archivedIDs.contains(mail.id), !keepsLoaded(mail) { stays.append(mail) } else { loaded.append(mail) }
    }
    try store.storeArchived(stays)
    try store.deleteMessages(ids: archivedIDs.intersection(deletedIDs))
    return loaded
  }
}

extension Database {
  /// Emails to add to the live mailbox for results the user asked for (search, cited sources):
  /// the stored copy when one exists, since it carries local state, otherwise the result itself.
  public func adopting(_ found: [Mail], live: Set<String>) throws -> [Mail] {
    var seen = live
    let candidates = found.filter { !$0.id.hasPrefix("local-") && seen.insert($0.id).inserted }
    let stored = Dictionary(uniqueKeysWithValues: try loadMessages(ids: candidates.map(\.id)).map { ($0.id, $0) })
    return candidates.map { stored[$0.id] ?? $0 }
  }
}

extension GmailClient {
  private struct MessageReference: Decodable { let id: String }
  private struct Change: Decodable { let message: MessageReference; let labelIds: [String]? }
  private struct HistoryRecord: Decodable {
    let messagesAdded: [Change]?
    let messagesDeleted: [Change]?
    let labelsAdded: [Change]?
    let labelsRemoved: [Change]?
  }
  private struct HistoryPage: Decodable {
    let history: [HistoryRecord]?
    let nextPageToken: String?
    let historyId: String
  }
  private struct HistoryDelta {
    var added: Set<String> = []
    var labelChanges: [String: GmailLabelChange] = [:]
    var deleted: Set<String> = []
    var cursor: String
  }
  private func history(token: String, after cursor: String) async throws -> HistoryDelta {
    var delta = HistoryDelta(cursor: cursor)
    var pageToken: String?
    repeat {
      var query = [
        URLQueryItem(name: "startHistoryId", value: cursor),
        URLQueryItem(name: "maxResults", value: "500"),
      ]
      if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      let page = try JSONDecoder().decode(
        HistoryPage.self,
        from: await request("history", token: token, query: query))
      // Records arrive oldest first; label changes are replayed in that order.
      for record in page.history ?? [] {
        for change in record.messagesAdded ?? [] { delta.added.insert(change.message.id) }
        for change in record.labelsAdded ?? [] {
          delta.labelChanges[change.message.id, default: GmailLabelChange()].add(Set(change.labelIds ?? []))
        }
        for change in record.labelsRemoved ?? [] {
          delta.labelChanges[change.message.id, default: GmailLabelChange()].remove(Set(change.labelIds ?? []))
        }
        for change in record.messagesDeleted ?? [] { delta.deleted.insert(change.message.id) }
      }
      delta.cursor = page.historyId
      pageToken = page.nextPageToken
    } while pageToken != nil
    delta.added.subtract(delta.deleted)
    for id in delta.deleted { delta.labelChanges[id] = nil }
    return delta
  }
  public func message(id: String, token: String) async throws -> Mail? {
    do {
      return try JSONDecoder().decode(
        GmailMessage.self,
        from: await request(
          "messages/\(id)", token: token,
          query: [URLQueryItem(name: "format", value: "full")])
      ).mail()
    } catch let error as HTTPFailure where error.statusCode == 404 { return nil }
  }
  /// Reads only the unsubscribe headers, for emails stored before Cove kept them.
  public func unsubscribe(id: String, token: String) async throws -> MailUnsubscribe? {
    struct Metadata: Decodable {
      struct Payload: Decodable { let headers: [GmailMessage.Header]? }
      let payload: Payload?
    }
    let metadata = try JSONDecoder().decode(Metadata.self, from: await request(
      "messages/\(id)", token: token, query: [
        URLQueryItem(name: "format", value: "metadata"),
        URLQueryItem(name: "metadataHeaders", value: "List-Unsubscribe"),
        URLQueryItem(name: "metadataHeaders", value: "List-Unsubscribe-Post"),
      ]))
    func header(_ name: String) -> String {
      metadata.payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value ?? ""
    }
    return MailUnsubscribe.parse(header: header("List-Unsubscribe"), post: header("List-Unsubscribe-Post"))
  }
  enum MessageUpdate: Sendable {
    case full(Mail)
    case labels(String, Set<String>)
    case deleted(String)
  }
  func update(id: String, token: String, cached: Bool) async throws -> MessageUpdate {
    if !cached {
      return try await message(id: id, token: token).map(MessageUpdate.full) ?? .deleted(id)
    }
    struct Metadata: Decodable { let labelIds: [String]? }
    do {
      let metadata = try JSONDecoder().decode(
        Metadata.self,
        from: await request(
          "messages/\(id)", token: token,
          query: [URLQueryItem(name: "format", value: "minimal")]))
      return .labels(id, Set(metadata.labelIds ?? []))
    } catch let error as HTTPFailure where error.statusCode == 404 { return .deleted(id) }
  }
  private func fetchUpdates(
    ids: Set<String>, cachedIDs: Set<String>, token: String,
    into result: GmailSyncResult
  ) async throws -> GmailSyncResult {
    var result = result
    // Newest first: Gmail ids grow with time, so a long catch-up fills recent mail before old mail.
    let ids = ids.sorted(by: >)
    // Three at a time, paced: a long catch-up stays under Gmail's per-user limits.
    for start in stride(from: 0, to: ids.count, by: 3) {
      let batch = Array(ids[start..<min(start + 3, ids.count)])
      let updates: [MessageUpdate]
      do {
        updates = try await withThrowingTaskGroup(of: MessageUpdate.self) { group in
        for id in batch {
          group.addTask {
            try await pacedBulk()
            return try await update(id: id, token: token, cached: cachedIDs.contains(id))
          }
        }
        var values: [MessageUpdate] = []
        for try await update in group { values.append(update) }
        return values
        }
      } catch let failure as HTTPFailure where failure.isRateLimited && start > 0 {
        // Keep what arrived; the rest is checked on the next sync. (A limit on the very first batch
        // still fails, so a sync that made no progress is reported rather than looping quietly.)
        result.pendingIDs = Set(ids[start...])
        return result
      }
      for update in updates {
        switch update {
        case .full(let mail): result.messages.append(mail)
        case .labels(let id, let labels): result.labels[id] = labels
        case .deleted(let id): result.deletedIDs.insert(id)
        }
      }
    }
    return result
  }
  /// `maxVerifications` bounds how many already-known emails one sync re-checks (the pending backlog,
  /// or every cached email after Gmail's history expired); the rest stay in `pendingIDs` for later
  /// syncs, newest first. New emails are always read. Nil (the Mac) checks everything at once.
  public func synchronize(
    token: String, cached: [Mail], historyID: String?, refreshContent: Bool = false,
    storedIDs: Set<String> = [], pendingIDs: Set<String> = [], maxVerifications: Int? = nil
  ) async throws
    -> GmailSyncResult
  {
    let cachedIDs = Set(cached.filter { !$0.id.hasPrefix("local-") }.map(\.id))
    // Stored but unloaded emails need only labels too; a full resync verifies loaded ones only.
    let storedIDs = cachedIDs.union(storedIDs.filter { !$0.hasPrefix("local-") })
    if let historyID, !refreshContent {
      let delta: HistoryDelta?
      do { delta = try await history(token: token, after: historyID) } catch let error
        as HTTPFailure where error.statusCode == 404
      { delta = nil }
      if let delta {
        // Only emails Cove doesn't have yet are read. Label changes on stored emails come from the
        // history itself, and new emails already stored (sent from Cove, for example) need nothing.
        let known = storedIDs.union(cachedIDs)
        let unknownLabelled = Set(delta.labelChanges.keys).subtracting(known)
        var result = GmailSyncResult(deletedIDs: delta.deleted, historyID: delta.cursor)
        result.labelChanges = delta.labelChanges.filter { known.contains($0.key) && !pendingIDs.contains($0.key) }
        guard let maxVerifications else {
          let reads = delta.added.subtracting(known).union(unknownLabelled).union(pendingIDs).subtracting(delta.deleted)
          return try await fetchUpdates(ids: reads, cachedIDs: storedIDs, token: token, into: result)
        }
        let fresh = delta.added.subtracting(known).union(unknownLabelled).subtracting(delta.deleted)
        let (now, later) = Self.split(pendingIDs.subtracting(fresh).subtracting(delta.deleted), first: maxVerifications)
        result = try await fetchUpdates(ids: fresh.union(now), cachedIDs: storedIDs, token: token, into: result)
        result.pendingIDs.formUnion(later)
        return result
      }
    }
    // Capture a baseline BEFORE reading messages, so concurrent changes are replayed next sync.
    struct Profile: Decodable { let historyId: String }
    let baseline = try JSONDecoder().decode(
      Profile.self, from: await request("profile", token: token))
    // Stored messages only need their labels; refreshContent is the one reason to reload bodies.
    let knownIDs = refreshContent ? [] : storedIDs
    let page = try await page(token: token, cachedIDs: knownIDs)
    let fetchedIDs = Set(page.messages.map(\.id)).union(page.labels.keys).union(page.deletedIDs)
    let result = GmailSyncResult(
      messages: page.messages, labels: page.labels, deletedIDs: page.deletedIDs,
      historyID: baseline.historyId, nextPage: page.next, resetsPagination: true)
    // Missing from a single page is not deletion: verify every previously cached remote ID.
    let unverified = cachedIDs.union(pendingIDs).subtracting(fetchedIDs)
    guard let maxVerifications else {
      return try await fetchUpdates(ids: unverified, cachedIDs: knownIDs, token: token, into: result)
    }
    let (now, later) = Self.split(unverified, first: maxVerifications)
    var bounded = try await fetchUpdates(ids: now, cachedIDs: knownIDs, token: token, into: result)
    bounded.pendingIDs.formUnion(later)
    return bounded
  }

  /// The newest `first` IDs (Gmail IDs grow with time) and the rest.
  static func split(_ ids: Set<String>, first: Int) -> (now: Set<String>, later: Set<String>) {
    let sorted = ids.sorted(by: >)
    return (Set(sorted.prefix(max(first, 0))), Set(sorted.dropFirst(max(first, 0))))
  }
}

/// What Gmail's history says happened to one email's labels, replayed in order.
public struct GmailLabelChange: Equatable, Sendable {
  public var added: Set<String> = []
  public var removed: Set<String> = []
  public init(added: Set<String> = [], removed: Set<String> = []) { self.added = added; self.removed = removed }
  mutating func add(_ ids: Set<String>) { added.formUnion(ids); removed.subtract(ids) }
  mutating func remove(_ ids: Set<String>) { removed.formUnion(ids); added.subtract(ids) }
}
