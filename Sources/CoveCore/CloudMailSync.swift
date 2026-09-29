import CryptoKit
import Foundation

/// The opt-in pilot mirrors one Mac's recent downloaded mail. Mobile is a read-only consumer.
/// Explicit DTOs prevent drafts, attachments, credentials and local-only state entering the wire format.
public struct CloudMailRecord: Codable, Equatable, Sendable {
  public struct Metadata: Codable, Equatable, Sendable {
    public var sender: String
    public var senderEmail: String
    public var to: String
    public var subject: String
    public var replyTo: String?
    public var messageID: String
    public var decision: Decision?
  }
  public struct Body: Codable, Equatable, Sendable {
    public var text: String
    public var html: String?
    public var truncated: Bool
  }
  public var id: String
  public var threadID: String
  public var receivedAt: String
  public var labels: [String]
  public var metadata: Metadata
  public var body: Body

  public init?(_ mail: Mail, now: Date = Date()) {
    guard !mail.id.isEmpty, mail.id.count <= 128,
      mail.id.allSatisfy({ $0.isASCII && $0.isHexDigit }),
      mail.date >= now.addingTimeInterval(-30 * 86400), mail.date <= now.addingTimeInterval(86400),
      mail.labels.isDisjoint(with: ["DRAFT", "TRASH", "SPAM"])
    else { return nil }
    func bounded(_ value: String, _ bytes: Int) -> String {
      guard value.utf8.count > bytes else { return value }
      // Drop any partial trailing UTF-8 scalar rather than creating invalid text.
      var data = Data(value.utf8.prefix(bytes))
      while String(data: data, encoding: .utf8) == nil { data.removeLast() }
      return String(decoding: data, as: UTF8.self)
    }
    id = mail.id; threadID = bounded(mail.threadID, 128)
    receivedAt = ISO8601DateFormatter().string(from: mail.date)
    labels = Array(mail.labels.sorted().prefix(100)).map { bounded($0, 128) }
    var decision = mail.decision
    if var d = decision {
      d.excerpt = d.excerpt.map { bounded($0, 6000) }; d.model = bounded(d.model, 128)
      if [d.confidence, d.needsReply, d.urgent].allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
        decision = d
      } else { decision = nil }
    }
    metadata = Metadata(sender: bounded(mail.sender, 2048), senderEmail: bounded(mail.senderEmail, 2048),
      to: bounded(mail.to, 2048), subject: bounded(mail.subject, 2048),
      replyTo: mail.replyTo.map { bounded($0, 2048) }, messageID: bounded(mail.messageID, 2048), decision: decision)
    let plain = bounded(mail.body, 48000)
    let html = mail.htmlBody.map { bounded($0, 96000) }
    body = Body(text: plain, html: html, truncated: plain != mail.body || html != mail.htmlBody)
    // Escaped control characters can expand sixfold in JSON. Bound the actual wire size too.
    while (try? JSONEncoder().encode(self).count) ?? Int.max > 200000 {
      body.text = bounded(body.text, body.text.utf8.count / 2)
      body.html = body.html.map { bounded($0, $0.utf8.count / 2) }
      body.truncated = true
    }
  }
  public var fingerprint: String {
    get throws {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
  }
  public static func recent(_ mails: [Mail], now: Date = Date()) -> [CloudMailRecord] {
    Array(mails.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
      .lazy.compactMap { CloudMailRecord($0, now: now) }.prefix(1000))
  }
}

public struct CloudMirrorState: Codable, Sendable {
  public var enabled = false
  public var accountID: UUID?
  public var revision: String?
  public var fingerprints: [String: String] = [:]
  public var lastSync: Date?
  public init() {}
}
public struct CloudConnection: Codable, Sendable {
  public let accountID: UUID
  public let revision: String
}
public struct CloudChangePage: Decodable, Sendable {
  public struct Change: Decodable, Sendable {
    public let id: String
    public let deleted: Bool
  }
  public let accountID: UUID
  public let cursor: String
  public let hasMore: Bool
  public let messages: [Change]
}
public struct CloudMailBatch: Encodable, Sendable {
  public var accountID: UUID
  public var requestID: UUID
  public var baseRevision: String
  public var messages: [CloudMailRecord]
  public var deletedIDs: [String]
  public init(accountID: UUID, requestID: UUID = UUID(), baseRevision: String,
              messages: [CloudMailRecord], deletedIDs: [String]) {
    self.accountID = accountID; self.requestID = requestID; self.baseRevision = baseRevision
    self.messages = messages; self.deletedIDs = deletedIDs
  }
}
public struct CloudSyncFailure: LocalizedError {
  public let code: String
  public init(code: String) { self.code = code }
  public var errorDescription: String? {
    switch code {
    case "authentication_required": return "Reconnect Google for cloud sync. This account must be included in the private pilot."
    case "cloud_not_connected", "connection_changed": return "The cloud copy was disconnected. Enable cloud sync again to reconnect."
    case "revision_conflict": return "The cloud copy changed. Retry sync; use one Mac as the uploader during this pilot."
    case "snooze_conflict": return "A reminder changed on another device. Choose its snooze time again, or Return to inbox, to resolve it."
    case "snooze_storage_limit": return "The cloud pilot’s reminder storage is full. This reminder is saved only on this Mac."
    case "pilot_storage_limit": return "The cloud pilot has reached its storage limit. Remove the cloud copy before starting a new mirror."
    case "rate_limited": return "Cloud sync is taking a short break. Try again in a minute."
    default: return "Cloud sync couldn’t finish. Your mail is still on this Mac. Try again."
    }
  }
}
public struct CloudMailClient {
  public let baseURL: URL
  private struct Failure: Decodable { let error: String }
  private let transport: HTTPTransport
  public init(baseURL: URL, transport: HTTPTransport = LiveHTTP()) throws {
    guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
      baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
      baseURL.path.isEmpty || baseURL.path == "/" else {
      throw CoveError.message("Cloud sync needs a secure Cove server address.")
    }
    self.baseURL = baseURL; self.transport = transport
  }
  func request<T: Decodable>(_ path: String, method: String = "GET", token: String,
                                    body: Data? = nil, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
    var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.queryItems = query }
    var r = URLRequest(url: components.url!)
    r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 45
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await transport.data(for: r)
    guard (200..<300).contains(response.statusCode) else {
      let code = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "temporarily_unavailable"
      throw CloudSyncFailure(code: code)
    }
    return try JSONDecoder().decode(type, from: data)
  }
  public func connect(token: String) async throws -> CloudConnection {
    try await request("v1/connection", method: "POST", token: token,
      body: Data(#"{"consentVersion":"cloud-mail-v1"}"#.utf8), as: CloudConnection.self)
  }
  public func connection(token: String) async throws -> CloudConnection {
    try await request("v1/connection", token: token, as: CloudConnection.self)
  }
  public func changes(accountID: UUID, after: String, token: String) async throws -> CloudChangePage {
    try await request("v1/messages/changes", token: token,
      query: [URLQueryItem(name: "accountID", value: accountID.uuidString), URLQueryItem(name: "after", value: after)],
      as: CloudChangePage.self)
  }
  public func upload(_ batch: CloudMailBatch, token: String) async throws -> String {
    struct Result: Decodable { let revision: String }
    return try await request("v1/messages/batch", method: "POST", token: token,
      body: JSONEncoder().encode(batch), as: Result.self).revision
  }
  public func remove(accountID: UUID, token: String) async throws {
    struct Result: Decodable { let deleted: Bool }
    let _: Result = try await request("v1/connection", method: "DELETE", token: token,
      body: JSONEncoder().encode(["accountID": accountID.uuidString]), as: Result.self)
  }
  public func snoozes(accountID: UUID, after: String, token: String) async throws -> CloudSnoozePage {
    try await request("v1/snoozes/changes", token: token,
      query: [URLQueryItem(name: "accountID", value: accountID.uuidString), URLQueryItem(name: "after", value: after)],
      as: CloudSnoozePage.self)
  }
  public func uploadSnooze(_ upload: CloudSnoozeUpload, accountID: UUID, token: String) async throws -> String {
    struct Body: Encodable {
      let accountID: UUID; let requestID: UUID; let baseRevision: String; let threadID: String; let wakeAt: String?
      enum CodingKeys: CodingKey { case accountID, requestID, baseRevision, threadID, wakeAt }
      func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountID, forKey: .accountID); try c.encode(requestID, forKey: .requestID)
        try c.encode(baseRevision, forKey: .baseRevision); try c.encode(threadID, forKey: .threadID)
        // An explicit null cancels; omission must never mean an accidental cancellation.
        try c.encode(wakeAt, forKey: .wakeAt)
      }
    }
    struct Result: Decodable { let revision: String }
    return try await request("v1/snoozes/\(upload.intent.id)", method: "PUT", token: token,
      body: JSONEncoder().encode(Body(accountID: accountID, requestID: upload.intent.requestID,
        baseRevision: upload.baseRevision, threadID: upload.intent.threadID, wakeAt: upload.intent.wakeAt)), as: Result.self).revision
  }
}
