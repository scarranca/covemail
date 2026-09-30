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
      }
      values[mail.id] = mail
    }
    for (id, labels) in labels { values[id]?.labels = labels }
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
  /// Their Jev decision, draft and snooze are kept; results `keepsLoaded` rejects are written back
  /// as archive (untracked), and remote deletions remove their local copies.
  public func merging(
    into live: [Mail], store: Database?, keepsLoaded: (Mail) -> Bool = { _ in true }
  ) throws -> [Mail] {
    guard let store else { return applying(to: live) }
    let liveIDs = Set(live.map(\.id))
    let touched = Set(messages.map(\.id)).union(labels.keys).union(deletedIDs).subtracting(liveIDs)
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
  private struct Change: Decodable { let message: MessageReference }
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
    var changed: Set<String> = []
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
      for record in page.history ?? [] {
        for change in (record.messagesAdded ?? []) + (record.labelsAdded ?? [])
          + (record.labelsRemoved ?? [])
        {
          delta.changed.insert(change.message.id)
        }
        for change in record.messagesDeleted ?? [] { delta.deleted.insert(change.message.id) }
      }
      delta.cursor = page.historyId
      pageToken = page.nextPageToken
    } while pageToken != nil
    delta.changed.subtract(delta.deleted)
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
    let ids = ids.sorted()
    for start in stride(from: 0, to: ids.count, by: 5) {
      let batch = Array(ids[start..<min(start + 5, ids.count)])
      let updates = try await withThrowingTaskGroup(of: MessageUpdate.self) { group in
        for id in batch {
          group.addTask { try await update(id: id, token: token, cached: cachedIDs.contains(id)) }
        }
        var values: [MessageUpdate] = []
        for try await update in group { values.append(update) }
        return values
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
  public func synchronize(
    token: String, cached: [Mail], historyID: String?, refreshContent: Bool = false,
    storedIDs: Set<String> = []
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
        return try await fetchUpdates(
          ids: delta.changed, cachedIDs: storedIDs, token: token,
          into: GmailSyncResult(deletedIDs: delta.deleted, historyID: delta.cursor))
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
    return try await fetchUpdates(
      ids: cachedIDs.subtracting(fetchedIDs), cachedIDs: knownIDs,
      token: token, into: result)
  }
}
