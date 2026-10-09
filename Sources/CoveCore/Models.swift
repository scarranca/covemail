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
  // How to leave this mailing list, from its List-Unsubscribe headers. Nil when there is none or not read yet.
  public var unsubscribe: MailUnsubscribe?
  // The user's Important/Other vote for this email; local state kept across Gmail syncs.
  public var inboxVote: InboxSplit?
  // Whether Jev found a commitment or request in this email; checked once, kept across syncs.
  public var taskCheck: MailTaskCheck?
  /// First ~240 characters of the body on one line (whitespace runs collapsed). Computed, never stored;
  /// scans only the start of the body so long emails cost the same as short ones.
  public var preview: String {
    var output = ""
    var pendingSpace = false
    var scanned = 0, length = 0
    for character in body {
      scanned += 1
      if character.isWhitespace || character.isNewline { pendingSpace = !output.isEmpty; if scanned > 4_000 { break }; continue }
      if pendingSpace {
        if length + 1 >= 240 { break }  // a separator with no room for the next character
        output.append(" "); length += 1; pendingSpace = false
      }
      output.append(character)
      length += 1
      if length >= 240 { break }
    }
    return output
  }
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
  // Optional so older preferences decode; nil means the split Inbox is on.
  public var splitInbox: Bool?
  // Lowercased sender address → the tab the user always wants for that sender.
  public var inboxSenderRules: [String: InboxSplit]?
  /// The From address for new emails when Gmail has more than one (send-as aliases). nil = the account's.
  public var defaultSender: String?
  /// Who the user is and what they're working on (About you). Optional so older preferences decode.
  public var personal: PersonalContext?
  public var splitsInbox: Bool { splitInbox ?? true }
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
  /// Files Google attached to the event: Gemini notes, transcripts, recordings, shared docs.
  public var files: [CalendarFile]?
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
/// A file on a Google Calendar event. Cove links to it; reading a Doc's text would need Google Drive access.
public struct CalendarFile: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case notes, transcript, recording, file }
  public var title: String
  public var url: String
  public var mimeType: String?
  public init(title: String, url: String, mimeType: String? = nil) {
    self.title = title; self.url = url; self.mimeType = mimeType
  }
  public var kind: Kind {
    let name = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    if mimeType?.hasPrefix("video/") == true || name.contains("recording") || name.contains("grabacion") { return .recording }
    if name.contains("transcript") || name.contains("transcripcion") { return .transcript }
    if name.contains("gemini") || name.contains("notes by") || name.contains("notas") { return .notes }
    return .file
  }
  /// Only Google's own file links open from Cove.
  public var safeURL: URL? {
    guard let url = URL(string: url), url.scheme == "https", let host = url.host,
      host == "drive.google.com" || host == "docs.google.com" else { return nil }
    return url
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

extension Preferences {
  /// A memory as the user typed it: one line, bounded. Email text never becomes a memory.
  public static func sanitizedMemory(_ text: String) -> String? {
    let line = text.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return nil }
    return String(line.prefix(200))
  }
  /// About you and saved memories for every writing and assistant prompt, or nil when both are off or
  /// empty. Each is the user's own words, never facts from email.
  public var memoryPrompt: String? {
    var parts: [String] = []
    if let about = personal?.promptText { parts.append(about) }
    let lines = useMemories ? Array(memories.compactMap(Self.sanitizedMemory).prefix(30)) : []
    if !lines.isEmpty {
      parts.append("The user's saved memories (their own notes about themselves and their preferences, not facts from email; follow them when relevant):\n"
        + lines.map { "- " + $0 }.joined(separator: "\n"))
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }
}
