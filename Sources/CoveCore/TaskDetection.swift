import Foundation

/// Jev's verdict on whether an email holds a follow-up task. Stored on the email so it is billed once.
public struct MailTaskCheck: Codable, Equatable, Sendable {
  public var found: Bool
  public var confidence: Double
  public var checkedAt: Date
  /// Google Task ids already created from this email.
  public var createdTaskIDs: [String]?
  public init(found: Bool, confidence: Double, checkedAt: Date = Date(), createdTaskIDs: [String]? = nil) {
    self.found = found; self.confidence = confidence; self.checkedAt = checkedAt; self.createdTaskIDs = createdTaskIDs
  }
}

public struct TaskSuggestion: Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var title: String
  public var due: Date?
  public var notes: String
  public init(title: String, due: Date? = nil, notes: String = "") {
    self.title = title; self.due = due; self.notes = notes
  }
}

public enum TaskDetection {
  /// Marketing, sales, newsletters and automated mail never reach Jev or a model.
  public static func eligible(_ mail: Mail, accountEmail: String, senderRules: [String: InboxSplit] = [:]) -> Bool {
    guard mail.labels.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"]), !mail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    // The user's own sent mail is checked for promises they made.
    if mail.labels.contains("SENT") || mail.senderEmail.caseInsensitiveCompare(accountEmail) == .orderedSame { return true }
    if mail.isBulkOrAutomated == true { return false }
    if let category = mail.decision?.category, [.newsletters, .updates, .purchases].contains(category) { return false }
    return InboxSplit.split(mail, senderRules: senderRules) == .important
  }

  /// Instructions for Jev's yes/no gate.
  public static let gateInstructions = """
    Match emails that contain a concrete follow-up task: either a commitment the writer makes to do something later \
    ("I'll add this to your account", "I will send the contract tomorrow"), or a request asking the reader to do \
    something specific ("can you send the report by Friday?"). Do not match newsletters, marketing, sales outreach, \
    automated notifications, receipts, completed actions, or vague pleasantries like "let's catch up".
    """

  /// Parses the model's JSON strictly: at most 5 tasks, bounded titles, only valid dates.
  public static func suggestions(from reply: String, calendar: Calendar = .current) -> [TaskSuggestion] {
    let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    struct Payload: Decodable {
      struct Item: Decodable { let title: String?; let due: String?; let notes: String? }
      let tasks: [Item]?
    }
    guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"),
      let payload = try? JSONDecoder().decode(Payload.self, from: Data(cleaned[start...end].utf8))
    else { return [] }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    var seen = Set<String>()
    return (payload.tasks ?? []).compactMap { item -> TaskSuggestion? in
      let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
      guard !title.isEmpty, seen.insert(title.lowercased()).inserted else { return nil }
      let due = item.due.flatMap { value -> Date? in
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
      }
      return TaskSuggestion(title: String(title.prefix(120)), due: due,
                            notes: String((item.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
    }.prefix(5).map { $0 }
  }

  /// Task notes link back to the email, so it can be opened from Google Tasks on any device.
  public static func notes(for suggestion: TaskSuggestion, mail: Mail) -> String {
    var lines: [String] = []
    if !suggestion.notes.isEmpty { lines.append(suggestion.notes) }
    lines.append("From: \(mail.sender.isEmpty ? mail.senderEmail : mail.sender) · \(mail.subject.isEmpty ? "(No subject)" : mail.subject)")
    if !mail.threadID.isEmpty { lines.append("https://mail.google.com/mail/u/0/#all/\(mail.threadID)") }
    return lines.joined(separator: "\n")
  }
  /// The Gmail thread a task was created from, if its notes carry Cove's link.
  public static func threadID(inNotes notes: String?) -> String? {
    guard let notes, let range = notes.range(of: "https://mail.google.com/mail/u/0/#all/") else { return nil }
    let id = notes[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
    return id.isEmpty ? nil : String(id)
  }
}
