import Foundation

public enum MailCategory: String, Codable, CaseIterable, Sendable {
  case people = "People"
  case work = "Work"
  case purchases = "Purchases"
  case newsletters = "Newsletters"
  case updates = "Updates"
  case other = "Other"
}
public struct Decision: Codable, Equatable, Sendable {
  public var category: MailCategory
  public var confidence: Double
  public var needsReply: Double
  public var urgent: Double
  public var excerpt: String?
  public var model: String
  public init(
    category: MailCategory, confidence: Double, needsReply: Double, urgent: Double,
    excerpt: String? = nil, model: String
  ) {
    self.category = category
    self.confidence = confidence
    self.needsReply = needsReply
    self.urgent = urgent
    self.excerpt = excerpt
    self.model = model
  }
}
public struct Mail: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var threadID: String
  public var sender: String
  public var senderEmail: String
  public var replyTo: String?
  public var to: String
  // "" means Gmail sent no Cc header; nil means a snapshot saved before Cc was stored.
  public var cc: String?
  public var subject: String
  public var body: String
  // Optional for older snapshots and plain-text-only email. Keep body for search and Jev.
  public var htmlBody: String?
  public var date: Date
  public var labels: Set<String>
  public var messageID: String
  public var decision: Decision?
  public var snoozedUntil: Date?
  public var draft: String
  // Optional for snapshots saved before attachment support was introduced.
  public var attachments: [MailAttachment]?
  public var availableAttachments: [MailAttachment] { attachments ?? [] }
  // Header-derived bulk/automation signal. Nil means an older snapshot needs a content refresh.
  public var isBulkOrAutomated: Bool?
  public var isUnread: Bool { labels.contains("UNREAD") }
  public var isStarred: Bool { labels.contains("STARRED") }
  public var replyRecipient: String {
    guard let replyTo, !replyTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return senderEmail
    }
    return replyTo.trimmingCharacters(in: .whitespaces)
  }
  /// Describe the effective reply destination, including Reply-To overrides.
  public var replyAddressLooksUnmonitored: Bool {
    let recipient = replyRecipient.lowercased()
    let address = recipient.split(separator: "<").last.map(String.init) ?? recipient
    let localPart = address.split(separator: "@").first.map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply"].contains(localPart ?? "")
  }
  public var isPriority: Bool {
    (decision?.needsReply ?? 0) >= 0.65 || (decision?.urgent ?? 0) >= 0.65
      || labels.contains("IMPORTANT")
  }
  public var initials: String {
    sender.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
  }
  public init(
    id: String = UUID().uuidString, threadID: String = "", sender: String, senderEmail: String,
    to: String = "", subject: String, body: String, date: Date = Date(),
    labels: Set<String> = ["INBOX", "UNREAD"], messageID: String = "", decision: Decision? = nil,
    snoozedUntil: Date? = nil, draft: String = "", replyTo: String? = nil,
    attachments: [MailAttachment]? = nil, htmlBody: String? = nil, isBulkOrAutomated: Bool? = nil,
    cc: String? = nil
  ) {
    self.cc = cc
    self.id = id
    self.threadID = threadID
    self.sender = sender
    self.senderEmail = senderEmail
    self.replyTo = replyTo
    self.to = to
    self.subject = subject
    self.body = body
    self.htmlBody = htmlBody
    self.date = date
    self.labels = labels
    self.messageID = messageID
    self.decision = decision
    self.snoozedUntil = snoozedUntil
    self.draft = draft
    self.attachments = attachments
    self.isBulkOrAutomated = isBulkOrAutomated
  }
}
public struct MailAttachment: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var filename: String
  public var mimeType: String
  public var byteCount: Int?
  public var attachmentID: String?
  public var data: String?
  // MIME Content-ID without surrounding angle brackets; absent in older snapshots.
  public var contentID: String?

  public init(
    id: String, filename: String, mimeType: String, byteCount: Int? = nil,
    attachmentID: String? = nil, data: String? = nil, contentID: String? = nil
  ) {
    self.id = id
    self.filename = filename
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.attachmentID = attachmentID
    self.data = data
    self.contentID = contentID
  }
}
public struct Preferences: Codable, Sendable {
  public var voice = "Warm"
  public var signoff = "Best,"
  public var instructions: [String] = ["Ask before committing to deadlines or meetings."]
  public var memories: [String] = []
  public var useMemories = true
  // Optional so mailboxes saved before dismissal support continue to decode.
  public var ignoredKeepInTouch: Set<String>?
  public var autoClassify = false
  public var autoClassifySince: Date?
  // Optional so mailboxes saved before voice learning continue to decode.
  public var voiceProfile: VoiceProfile?
  public init() {}
}
public enum LocalCalendar: String, Codable, CaseIterable, Sendable {
  case work, personal, focus

  public var title: String {
    switch self {
    case .work: return "Work"
    case .personal: return "Personal"
    case .focus: return "Focus time"
    }
  }
}
public struct LocalEvent: Codable, Identifiable, Sendable {
  public var id = UUID().uuidString
  public var title: String
  public var start: Date
  public var end: Date
  public var mailID: String?
  public var googleID: String?
  public var allDay: Bool?
  public var webURL: String?
  public var meetURL: String?
  // Absent in older caches; conservatively treat those events as busy.
  public var blocksTime: Bool?
  public var details: String?
  public var location: String?
  public var attendees: [CalendarAttendee]?
  public var isOrganizer: Bool?
  public var organizerName: String?
  public var organizerEmail: String?
  public var recurringEventID: String?
  public var ownResponse: String? { attendees?.first(where: { $0.isSelf == true })?.response }
  public var isPendingInvitation: Bool { googleID != nil && isOrganizer != true && ownResponse == "needsAction" }
  // Older local events belong to Personal; Google events keep their remote source.
  public var localCalendar: LocalCalendar?
  public var effectiveLocalCalendar: LocalCalendar { localCalendar ?? .personal }
  public var calendarTitle: String {
    googleID == nil ? effectiveLocalCalendar.title + " · On this Mac" : "Google · primary"
  }
  public init(
    title: String, start: Date, end: Date, mailID: String? = nil,
    localCalendar: LocalCalendar? = nil
  ) {
    self.title = title
    self.start = start
    self.end = end
    self.mailID = mailID
    self.localCalendar = localCalendar
  }
}
public struct CalendarAttendee: Codable, Sendable {
  public var name: String?
  public var email: String?
  public var response: String?
  public var isSelf: Bool?
  public init(name: String? = nil, email: String? = nil, response: String? = nil, isSelf: Bool? = nil) {
    self.name = name; self.email = email; self.response = response; self.isSelf = isSelf
  }
}

public enum CalendarRSVP: String, CaseIterable, Sendable {
  case accepted, tentative, declined
  public var title: String { switch self { case .accepted: "Accept"; case .tentative: "Maybe"; case .declined: "Decline" } }
  public var confirmation: String { switch self { case .accepted: "Accepted"; case .tentative: "Maybe"; case .declined: "Declined" } }
}
public enum CoveError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    switch self {
    case .message(let text): return text
    }
  }
}
