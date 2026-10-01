import Foundation

public enum CalendarSearch {
  /// Search cached content only. Ongoing/upcoming events come first, then recent past events.
  public static func matches(_ events: [LocalEvent], query: String, now: Date) -> [LocalEvent] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    return events.filter { event in
      let guests = (event.attendees ?? []).flatMap { [$0.name ?? "", $0.email ?? ""] }
      let text = ([event.title, event.details ?? "", event.location ?? ""] + guests)
        .joined(separator: "\n")
      return terms.allSatisfy { text.localizedStandardContains($0) }
    }.sorted {
      let firstUpcoming = $0.end > now
      let secondUpcoming = $1.end > now
      if firstUpcoming != secondUpcoming { return firstUpcoming }
      if $0.start != $1.start { return firstUpcoming ? $0.start < $1.start : $0.start > $1.start }
      return $0.id < $1.id
    }
  }

  /// Events with a person: by address, the event's guests or organizer; by name, guests' names or the title.
  public static func with(_ person: String, in events: [LocalEvent]) -> [LocalEvent] {
    let wanted = person.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { return [] }
    if wanted.contains("@") {
      return events.filter { event in
        event.organizerEmail?.caseInsensitiveCompare(wanted) == .orderedSame
          || (event.attendees ?? []).contains { $0.email?.caseInsensitiveCompare(wanted) == .orderedSame }
      }
    }
    let terms = wanted.split(whereSeparator: \.isWhitespace).map(String.init)
    return events.filter { event in
      let text = ([event.title, event.organizerName ?? ""] + (event.attendees ?? []).flatMap { [$0.name ?? "", $0.email ?? ""] })
        .joined(separator: "\n")
      return terms.allSatisfy { text.localizedStandardContains($0) }
    }
  }
}
