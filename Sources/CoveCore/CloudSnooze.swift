import Foundation

public struct CloudSnooze: Codable, Equatable, Sendable {
  public var id: String
  public var threadID: String
  public var wakeAt: String?
  public var revision: String
  public init(id: String, threadID: String, wakeAt: String?, revision: String) {
    self.id = id; self.threadID = threadID; self.wakeAt = wakeAt; self.revision = revision
  }
  public var until: Date? {
    guard let wakeAt else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: wakeAt) ?? ISO8601DateFormatter().date(from: wakeAt)
  }
}

public struct CloudSnoozeIntent: Codable, Equatable, Sendable {
  public var requestID = UUID()
  public var id: String
  public var threadID: String
  public var wakeAt: String?
  public var until: Date? { CloudSnooze(id: id, threadID: threadID, wakeAt: wakeAt, revision: "0").until }
}

public struct CloudSnoozeUpload: Codable, Equatable, Sendable {
  public var intent: CloudSnoozeIntent
  public var baseRevision: String
}

/// Stored in the account's encrypted local database. Freeze the request before sending so a
/// lost response, restart, or newer local edit cannot change the meaning of a retry UUID.
public struct CloudSnoozeState: Codable, Sendable {
  public var accountID: UUID?
  public var cursor = "0"
  public var records: [String: CloudSnooze] = [:]
  public var pending: [String: CloudSnoozeIntent] = [:]
  public var uploading: CloudSnoozeUpload?
  public var conflicts: Set<String> = []
  public init() {}

  public mutating func set(_ mail: Mail, until: Date?) {
    guard Self.supports(mail) || (until == nil && !mail.id.isEmpty && mail.id.count <= 128
      && mail.id.allSatisfy({ $0.isASCII && $0.isHexDigit })) else { return }
    pending[mail.id] = CloudSnoozeIntent(id: mail.id, threadID: String(mail.threadID.prefix(128)),
      wakeAt: until.map { ISO8601DateFormatter().string(from: $0) })
    conflicts.remove(mail.id)
  }
  public static func supports(_ mail: Mail) -> Bool {
    !mail.id.isEmpty && mail.id.count <= 128 && mail.id.allSatisfy { $0.isASCII && $0.isHexDigit }
      && mail.labels.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"])
  }
  public mutating func cancelDeleted(_ ids: Set<String>) {
    for id in ids {
      let threadID = pending[id]?.threadID ?? records[id]?.threadID
      guard let threadID, pending[id]?.wakeAt != nil || (pending[id] == nil && records[id]?.wakeAt != nil) else { continue }
      pending[id] = CloudSnoozeIntent(id: id, threadID: threadID, wakeAt: nil)
      conflicts.remove(id)
    }
  }
  public mutating func connect(_ id: UUID) {
    guard accountID != id else { return }
    accountID = id; cursor = "0"; records = [:]; uploading = nil; conflicts = []
    // Local intents survive a connection reset; stale request IDs do not.
    for key in pending.keys { pending[key]?.requestID = UUID() }
  }
  public mutating func seed(_ mails: [Mail], now: Date = Date()) {
    for mail in mails where (mail.snoozedUntil ?? .distantPast) > now
      && records[mail.id] == nil && pending[mail.id] == nil {
      set(mail, until: mail.snoozedUntil)
    }
  }
  public mutating func beginUpload() -> CloudSnoozeUpload? {
    if let uploading { return uploading }
    guard let id = pending.keys.sorted().first(where: { !conflicts.contains($0) }), let intent = pending[id] else { return nil }
    let upload = CloudSnoozeUpload(intent: intent, baseRevision: records[id]?.revision ?? "0")
    uploading = upload
    return upload
  }
  public mutating func acknowledge(_ upload: CloudSnoozeUpload, revision: String) {
    let intent = upload.intent
    // A replay receipt can precede a more recent record already seen in the change feed.
    if (UInt64(records[intent.id]?.revision ?? "0") ?? 0) <= (UInt64(revision) ?? 0) {
      records[intent.id] = CloudSnooze(id: intent.id, threadID: intent.threadID, wakeAt: intent.wakeAt, revision: revision)
    }
    if pending[intent.id]?.requestID == intent.requestID { pending.removeValue(forKey: intent.id) }
    uploading = nil
  }
  public func applying(to mail: Mail) -> Mail {
    var mail = mail
    if let intent = pending[mail.id] { mail.snoozedUntil = intent.until }
    else if let record = records[mail.id] { mail.snoozedUntil = record.until }
    return mail
  }
}

public struct CloudSnoozePage: Decodable, Sendable {
  public let accountID: UUID
  public let cursor: String
  public let hasMore: Bool
  public let snoozes: [CloudSnooze]
}
