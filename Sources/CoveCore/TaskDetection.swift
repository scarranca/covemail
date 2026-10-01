import Foundation

/// Jev's verdict on whether an email holds a follow-up task. Stored on the email so it is billed once.
public struct MailTaskCheck: Codable, Equatable, Sendable {
  public var found: Bool
  public var confidence: Double
  public var checkedAt: Date
  /// Google Task ids already created from this email.
  public var createdTaskIDs: [String]?
  /// The user said this email needs no task.
  public var dismissed: Bool?
  /// Found, and the user hasn't made a task from it or dismissed it yet.
  public var waiting: Bool { found && createdTaskIDs == nil && dismissed != true }
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
  /// A to-do to offer when the model found nothing specific in an email Jev flagged: the user can still
  /// keep track of it, and edit the title first.
  public static func fallback(for mail: Mail, accountEmail: String) -> TaskSuggestion {
    let sent = mail.labels.contains("SENT") || mail.senderEmail.caseInsensitiveCompare(accountEmail) == .orderedSame
    let subject = mail.subject.isEmpty ? "(No subject)" : mail.subject
    let recipient = mail.to.split(separator: ",").first.map {
      let value = $0.trimmingCharacters(in: .whitespaces)
      if let open = value.firstIndex(of: "<"), open > value.startIndex {
        return value[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
      }
      return value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    } ?? ""
    let person = sent ? recipient : (mail.sender.isEmpty ? mail.senderEmail : mail.sender)
    let title = person.isEmpty ? "Follow up: \(subject)" : (sent ? "Follow up with \(person): \(subject)" : "Reply to \(person): \(subject)")
    return TaskSuggestion(title: String(title.prefix(120)))
  }

  /// nil when the reply isn't the JSON asked for (so the caller can say so), [] when it found no tasks.
  public static func parsedSuggestions(from reply: String, calendar: Calendar = .current) -> [TaskSuggestion]? {
    let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end,
      (try? JSONSerialization.jsonObject(with: Data(cleaned[start...end].utf8))) is [String: Any]
    else { return nil }
    return suggestions(from: reply, calendar: calendar)
  }

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

/// Instant, offline quick-add: "Call Millet Friday" → title "Call Millet", due Friday.
public enum TaskQuickAdd {
  public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> (title: String, due: Date?) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ("", nil) }
    let lower = trimmed.lowercased()
    let start = calendar.startOfDay(for: now)
    // Common words first; NSDataDetector handles weekdays and explicit dates.
    let words: [(String, Int)] = [("today", 0), ("tonight", 0), ("tomorrow", 1), ("hoy", 0), ("mañana", 1), ("manana", 1)]
    for (word, offset) in words {
      if let range = lower.range(of: "\\b\(word)\\b", options: .regularExpression) {
        let title = (trimmed[..<range.lowerBound] + trimmed[range.upperBound...])
        return (clean(String(title)), calendar.date(byAdding: .day, value: offset, to: start))
      }
    }
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
      let match = detector.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
      let date = match.date, let range = Range(match.range, in: trimmed)
    {
      let title = clean(String(trimmed[..<range.lowerBound] + trimmed[range.upperBound...]))
      if !title.isEmpty { return (title, calendar.startOfDay(for: date)) }
    }
    return (trimmed, nil)
  }
  private static func clean(_ text: String) -> String {
    var value = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    for suffix in [" by", " on", " due", " para el", " el"] where value.lowercased().hasSuffix(suffix) {
      value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
    }
    return value
  }

  /// Steps from the model: 2–5 short lines, deduplicated.
  public static func steps(from reply: String) -> [String] {
    struct Payload: Decodable { let steps: [String]? }
    let cleaned = reply.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"),
      let payload = try? JSONDecoder().decode(Payload.self, from: Data(cleaned[start...end].utf8)) else { return [] }
    var seen = Set<String>()
    return (payload.steps ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(5).map { String($0.prefix(100)) }
  }

  public struct DayPick: Equatable, Sendable {
    public let id: String
    public let why: String
    public let minutes: Int
  }
  /// Today's picks, limited to real task ids, at most 3.
  public static func dayPlan(from reply: String, validIDs: Set<String>) -> [DayPick] {
    struct Payload: Decodable { struct Item: Decodable { let id: String?; let why: String?; let minutes: Int? }; let today: [Item]? }
    let cleaned = reply.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"),
      let payload = try? JSONDecoder().decode(Payload.self, from: Data(cleaned[start...end].utf8)) else { return [] }
    var seen = Set<String>()
    return (payload.today ?? []).compactMap { item -> DayPick? in
      guard let id = item.id, validIDs.contains(id), seen.insert(id).inserted else { return nil }
      let minutes = [15, 30, 60, 90].min { abs($0 - (item.minutes ?? 30)) < abs($1 - (item.minutes ?? 30)) } ?? 30
      return DayPick(id: id, why: String((item.why ?? "").prefix(90)), minutes: minutes)
    }.prefix(3).map { $0 }
  }
}

/// Finds the people and mail a task is about ("Call Millet" → Millet and your latest emails with
/// her). Runs locally over downloaded mail; no model or network.
public enum TaskContext {
  /// Verbs and filler that never identify who or what a task is about (English and Spanish).
  static let filler: Set<String> = [
    "call", "email", "mail", "send", "reply", "write", "follow", "followup", "check", "ask", "tell", "remind",
    "review", "update", "add", "make", "book", "schedule", "meet", "meeting", "with", "about", "the", "and",
    "for", "from", "this", "that", "back", "again", "today", "tomorrow", "next", "week", "please", "their",
    "his", "her", "our", "your", "llamar", "enviar", "mandar", "revisar", "responder", "escribir", "agendar",
    "con", "para", "sobre", "los", "las", "una", "del", "hoy", "manana",
  ]
  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
  /// The task's meaningful words, folded (case- and accent-insensitive).
  public static func keywords(_ title: String) -> [String] {
    var seen = Set<String>()
    return fold(title).components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 3 && !filler.contains($0) && seen.insert($0).inserted }
  }

  /// Contacts named in the task, by first name, last name, full name or address; best-known first.
  public static func people(for title: String, contacts: [MailContact], limit: Int = 2) -> [MailContact] {
    let words = Set(keywords(title))
    guard !words.isEmpty else { return [] }
    let folded = fold(title)
    return contacts.filter { contact in
      let names = fold(contact.name).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
      let local = fold(contact.email.split(separator: "@").first.map(String.init) ?? "")
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
      let fullName = fold(contact.name)
      return !Set(names + local).isDisjoint(with: words) || (fullName.count >= 5 && folded.contains(fullName))
    }
    .sorted { $0.messages.count != $1.messages.count ? $0.messages.count > $1.messages.count : ($0.lastMessage ?? .distantPast) > ($1.lastMessage ?? .distantPast) }
    .prefix(limit).map { $0 }
  }

  /// Latest emails with those people, or else emails mentioning every keyword. Newest first.
  public static func mails(for title: String, people: [MailContact], in mails: [Mail], excluding: Set<String> = [], limit: Int = 5) -> [Mail] {
    let usable = { (mail: Mail) in mail.labels.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"]) && !excluding.contains(mail.id) }
    if !people.isEmpty {
      var seen = Set<String>()
      return people.flatMap(\.messages).filter { usable($0) && seen.insert($0.threadID.isEmpty ? $0.id : $0.threadID).inserted }
        .sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }
    let words = keywords(title)
    guard !words.isEmpty else { return [] }
    var seen = Set<String>()
    return mails.filter { mail in
      guard usable(mail) else { return false }
      let text = fold(mail.subject + "\n" + mail.sender + "\n" + mail.senderEmail + "\n" + String(mail.body.prefix(4_000)))
      return words.allSatisfy { text.contains($0) }
    }.sorted { $0.date > $1.date }
      .filter { seen.insert($0.threadID.isEmpty ? $0.id : $0.threadID).inserted }
      .prefix(limit).map { $0 }
  }

  /// Upcoming events with those people (as guests) or naming them.
  public static func events(for people: [MailContact], in events: [LocalEvent], now: Date, days: Int = 30, limit: Int = 2) -> [LocalEvent] {
    guard !people.isEmpty else { return [] }
    let emails = Set(people.map { ContactDirectory.normalizedEmail($0.email) })
    let names = people.compactMap { fold($0.name).split(separator: " ").first.map(String.init) }.filter { $0.count >= 3 }
    let end = now.addingTimeInterval(Double(days) * 86_400)
    return events.filter { event in
      guard event.end > now, event.start < end else { return false }
      let guests = Set((event.attendees ?? []).compactMap { $0.email.map(ContactDirectory.normalizedEmail) })
      let title = fold(event.title)
      return !guests.isDisjoint(with: emails) || names.contains { title.contains($0) }
    }.sorted { $0.start < $1.start }.prefix(limit).map { $0 }
  }
}

/// How many tasks were finished each day, oldest first: the Tasks header draws these as dots.
public enum TaskMomentum {
  public static func daily(_ tasks: [GoogleTask], days: Int = 14, now: Date = Date(), calendar: Calendar = .current) -> [Int] {
    let today = calendar.startOfDay(for: now)
    var counts = Array(repeating: 0, count: days)
    for task in tasks where task.isCompleted {
      guard let at = task.completedAt else { continue }
      let day = calendar.dateComponents([.day], from: calendar.startOfDay(for: at), to: today).day ?? -1
      if (0..<days).contains(day) { counts[days - 1 - day] += 1 }
    }
    return counts
  }
  /// Emails where Jev found a promise or request that hasn't become a task yet, newest first.
  public static func waitingInMail(_ mails: [Mail], now: Date = Date(), within days: Int = 21) -> [Mail] {
    let since = now.addingTimeInterval(-Double(days) * 86_400)
    return mails.filter {
      $0.taskCheck?.waiting == true && $0.date >= since
        && $0.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"])
    }.sorted { $0.date > $1.date }
  }
}
