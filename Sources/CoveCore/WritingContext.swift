import Foundation

public enum WritingContext {
  public static func recipients(_ header: String) -> [String] {
    Array(Set(ContactDirectory.addresses(header).map { ContactDirectory.normalizedEmail($0.email) }
      .filter { ContactDirectory.isValidEmail($0) })).sorted()
  }
  public static func recentMail(to header: String, mails: [Mail]) -> [Mail] {
    let people = Set(recipients(header))
    guard !people.isEmpty else { return [] }
    return Array(mails.filter {
      $0.labels.isDisjoint(with: ["SPAM", "TRASH", "DRAFT"])
        && (people.contains(ContactDirectory.normalizedEmail($0.senderEmail))
            || !people.isDisjoint(with: recipients($0.to)))
    }.sorted { $0.date > $1.date }.prefix(6))
  }
}

public struct WritingToolCall: Decodable, Equatable, Sendable {
  public enum Name: String, Decodable, Sendable { case searchMail = "search_mail", calendar, findAvailability = "find_availability" }
  public let name: Name
  public let query: String?
  public let from: String?
  public let to: String?
  public let day: String?
  public let durationMinutes: Int?
  public let startMinute: Int?
  public let endMinute: Int?
  public let slotCount: Int?
  public func availability(timeZone: TimeZone) throws -> WritingAvailability {
    guard let day else { throw CoveError.message("Choose a date to check availability.") }
    return try WritingAvailability(day: day, durationMinutes: durationMinutes ?? 30,
      startMinute: startMinute ?? 540, endMinute: endMinute ?? 1020, timeZone: timeZone, slotCount: slotCount ?? 1)
  }
  public func dateRange() throws -> DateInterval {
    let formatter = ISO8601DateFormatter()
    guard let from, let to, let start = formatter.date(from: from), let end = formatter.date(from: to),
      end > start, end.timeIntervalSince(start) <= 31 * 86_400 else {
      throw CoveError.message("Calendar lookups need a valid range of up to 31 days.")
    }
    return DateInterval(start: start, end: end)
  }
}

public struct WritingToolPlan: Decodable, Sendable {
  public let tools: [WritingToolCall]
  public let clarification: String?
  public static func parse(_ text: String) throws -> WritingToolPlan {
    guard text.utf8.count <= 8_000 else { throw CoveError.message("The context request was too large.") }
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    let plan = try JSONDecoder().decode(Self.self, from: Data(cleaned.utf8))
    if let question = plan.clarification {
      guard plan.tools.isEmpty, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        question.utf8.count <= 500 else { throw CoveError.message("Invalid clarification request.") }
    }
    guard plan.tools.count <= 3 else { throw CoveError.message("Too many context lookups requested.") }
    for call in plan.tools {
      switch call.name {
      case .searchMail:
        guard let q = call.query, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          q.utf8.count <= 1_000, !q.contains(where: \.isNewline) else {
          throw CoveError.message("Invalid mail context query.")
        }
      case .calendar: _ = try call.dateRange()
      case .findAvailability: _ = try call.availability(timeZone: TimeZone(secondsFromGMT: 0)!)
      }
    }
    guard plan.tools.filter({ $0.name == .findAvailability }).count <= 1 else {
      throw CoveError.message("Choose one meeting date at a time.")
    }
    return plan
  }
}

extension WritingToolPlan {
  /// Whether a writing request could need a mail or calendar lookup. Wording, tone, length and
  /// translation requests don't, so the planning call is skipped and the draft arrives in one call.
  public static func mightNeedLookup(_ request: String) -> Bool {
    let text = request.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let signals = [
      "find", "search", "look up", "lookup", "latest", "last email", "last message", "conversation", "thread", "previous",
      "earlier", "what did", "when did", "who said", "mention", "meeting", "meet", "calendar", "schedule", "available",
      "availability", "free", "busy", "slot", "today", "tomorrow", "next week", "this week", "monday", "tuesday",
      "wednesday", "thursday", "friday", "saturday", "sunday", "attach", "invoice number", "propose", "time", "date",
      "when", "busca", "encuentra", "propon", "hora", "fecha", "cuando",
      "ultimo", "conversacion", "hilo", "anterior", "reunion", "junta", "calendario", "agenda", "disponib", "libre",
      "manana", "hoy", "semana", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo",
    ]
    return signals.contains { text.contains($0) }
  }
}
