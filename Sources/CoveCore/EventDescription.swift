import Foundation

/// An event described in plain words ("lunch with Maya Friday at 1, add a Meet"), as the writing model
/// read it. Nothing is created from it: it only fills the event editor for the user to review.
public struct EventDescription: Equatable, Sendable {
  public var title: String
  public var start: Date?
  public var end: Date?
  /// Names or addresses as the user wrote them; Cove matches names to contacts before inviting.
  public var guests: [String]
  public var meet: Bool
  /// Set when the model couldn't tell the day or time.
  public var question: String?

  public static func parse(_ reply: String, now: Date, timeZone: TimeZone) throws -> EventDescription {
    let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    struct Payload: Decodable {
      var title: String?; var start: String?; var end: String?; var guests: [String]?; var meet: Bool?; var question: String?
    }
    guard let open = cleaned.firstIndex(of: "{"), let close = cleaned.lastIndex(of: "}"), open < close,
      let payload = try? JSONDecoder().decode(Payload.self, from: Data(cleaned[open...close].utf8))
    else { throw CoveError.message("Cove couldn’t read that description. Try rephrasing it.") }
    let clock = ISO8601DateFormatter()
    clock.timeZone = timeZone
    var start = payload.start.flatMap { $0.isEmpty ? nil : clock.date(from: $0) }
    var end = payload.end.flatMap { $0.isEmpty ? nil : clock.date(from: $0) }
    if let first = start, end == nil || end! <= first { end = first.addingTimeInterval(1_800) }
    // A start that already passed (more than a few minutes ago) is a misread, not an event to create.
    if let first = start, first < now.addingTimeInterval(-300) { start = nil; end = nil }
    if let first = start, let last = end, last.timeIntervalSince(first) > 14 * 86_400 { end = first.addingTimeInterval(3_600) }
    let title = (payload.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let guests = (payload.guests ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let question = payload.question?.trimmingCharacters(in: .whitespacesAndNewlines)
    return EventDescription(
      title: String(title.prefix(200)), start: start, end: end, guests: Array(guests.prefix(20)),
      meet: payload.meet == true,
      question: start == nil ? ((question?.isEmpty == false ? question : nil) ?? "What day and time?") : nil)
  }
}
