import Foundation

extension GmailClient {
  /// Explicit, bounded Gmail search. This does not mark messages read or advance sync cursors.
  public func search(query: String, token: String, limit: Int = 20) async throws -> [Mail] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.utf8.count <= 2_000 else {
      throw CoveError.message("Enter a Gmail search of up to 2,000 bytes.")
    }
    let limit = min(20, max(1, limit))
    struct Entry: Decodable { let id: String }
    struct Results: Decodable { let messages: [Entry]? }
    let response = try await request("messages", token: token, query: [
      URLQueryItem(name: "q", value: "(\(query)) -in:trash -in:spam -in:drafts"),
      URLQueryItem(name: "maxResults", value: String(limit)),
      URLQueryItem(name: "includeSpamTrash", value: "false"),
    ])
    let entries = try JSONDecoder().decode(Results.self, from: response).messages ?? []
    var found: [Mail] = []
    var seen = Set<String>()
    for entry in entries.prefix(limit) where seen.insert(entry.id).inserted {
      try Task.checkCancellation()
      if let mail = try await message(id: entry.id, token: token),
        mail.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"])
      {
        found.append(mail)
      }
    }
    return found.sorted { $0.date > $1.date }
  }
}

extension GmailClient {
  public struct SearchResults: Sendable {
    public var mails: [Mail]
    /// Gmail's estimate of all matches (only shown when more pages exist).
    public var estimatedTotal: Int
    /// True when Gmail had more matching pages than were read.
    public var hasMore: Bool
  }
  /// Paginates up to `limit` matches (Spam, Trash and Drafts excluded). Messages already stored on this
  /// Mac are reused instead of downloaded again; new ones are fetched in small batches.
  public func research(query: String, token: String, limit: Int = 100, stored: [String: Mail] = [:])
    async throws -> SearchResults
  {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.utf8.count <= 2_000 else {
      throw CoveError.message("Enter a Gmail search of up to 2,000 bytes.")
    }
    let limit = min(200, max(1, limit))
    struct Entry: Decodable { let id: String }
    struct Page: Decodable { let messages: [Entry]?; let nextPageToken: String?; let resultSizeEstimate: Int? }
    var ids: [String] = []
    var seen = Set<String>()
    var estimate = 0
    var pageToken: String?
    repeat {
      try Task.checkCancellation()
      var items = [
        URLQueryItem(name: "q", value: "(\(query)) -in:trash -in:spam -in:drafts"),
        URLQueryItem(name: "maxResults", value: String(min(100, limit - ids.count))),
        URLQueryItem(name: "includeSpamTrash", value: "false"),
      ]
      if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      let page = try JSONDecoder().decode(Page.self, from: await request("messages", token: token, query: items))
      estimate = max(estimate, page.resultSizeEstimate ?? 0)
      for entry in page.messages ?? [] where seen.insert(entry.id).inserted { ids.append(entry.id) }
      pageToken = page.nextPageToken
    } while pageToken != nil && ids.count < limit
    var mails: [Mail] = []
    let missing = ids.filter { stored[$0] == nil }
    for start in stride(from: 0, to: missing.count, by: 5) {
      try Task.checkCancellation()
      let batch = Array(missing[start..<min(start + 5, missing.count)])
      let fetched = try await withThrowingTaskGroup(of: Mail?.self) { group in
        for id in batch { group.addTask { try await pacedBulk(); return try await message(id: id, token: token) } }
        var values: [Mail] = []
        for try await mail in group { if let mail { values.append(mail) } }
        return values
      }
      mails += fetched
    }
    mails += ids.compactMap { stored[$0] }
    let eligible = mails.filter { $0.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"]) }
    return SearchResults(mails: eligible.sorted { $0.date > $1.date }, estimatedTotal: max(estimate, eligible.count),
                         hasMore: pageToken != nil)
  }
}

extension GmailClient {
  public struct MatchCount: Sendable {
    /// Exact number of matching messages, unless `capped`.
    public var count: Int
    /// True when more than `cap` messages match; `count` is then the cap.
    public var capped: Bool
    /// Newest matches first (ids only), for showing a few examples.
    public var newestIDs: [String]
  }
  /// Counts every message matching a Gmail search by listing ids only (no content is downloaded).
  /// Trash, Spam and Drafts are excluded, like Gmail's own search.
  public func countMatches(query: String, token: String, cap: Int = 5_000) async throws -> MatchCount {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.utf8.count <= 2_000 else {
      throw CoveError.message("Enter a Gmail search of up to 2,000 bytes.")
    }
    struct Entry: Decodable { let id: String }
    struct Page: Decodable { let messages: [Entry]?; let nextPageToken: String? }
    var ids: [String] = []
    var seen = Set<String>()
    var pageToken: String?
    repeat {
      try Task.checkCancellation()
      var items = [
        URLQueryItem(name: "q", value: "(\(query)) -in:trash -in:spam -in:drafts"),
        URLQueryItem(name: "maxResults", value: "500"),
        URLQueryItem(name: "fields", value: "messages/id,nextPageToken"),
      ]
      if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      let page = try JSONDecoder().decode(Page.self, from: await request("messages", token: token, query: items))
      for entry in page.messages ?? [] where seen.insert(entry.id).inserted { ids.append(entry.id) }
      // A repeated page token would loop forever; stop rather than trust it.
      pageToken = page.nextPageToken == pageToken ? nil : page.nextPageToken
    } while pageToken != nil && ids.count < cap
    return MatchCount(count: min(ids.count, cap), capped: ids.count > cap || (pageToken != nil && ids.count >= cap),
                      newestIDs: Array(ids.prefix(5)))
  }
}
