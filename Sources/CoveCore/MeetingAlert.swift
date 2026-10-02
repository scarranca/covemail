import Foundation

/// The video call link for an event: Google Meet from Calendar, or a Zoom / Teams / Webex / Meet link
/// found in its location or description. Only https links on known meeting hosts are returned.
public enum MeetingLink {
  static let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "around.co"]

  public static func url(for event: LocalEvent) -> URL? {
    if let link = event.meetURL, let url = safe(link) { return url }
    for text in [event.location, event.details].compactMap({ $0 }) {
      guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { break }
      for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let url = match.url, let checked = safe(url.absoluteString) { return checked }
      }
    }
    return nil
  }

  static func safe(_ string: String) -> URL? {
    guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
      let host = url.host?.lowercased(),
      hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    else { return nil }
    return url
  }
}

/// What the menu bar shows about the next meeting.
public struct MeetingAlert: Sendable {
  public enum Level: Int, Comparable, Sendable {
    /// Later today: icon only.
    case later
    /// Starts within 10 minutes: the title and a countdown.
    case soon
    /// Starts within a minute, or started in the last 5: time to join.
    case now
    public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
  }
  public let event: LocalEvent
  public let level: Level
  /// Seconds until it starts (negative once it has started).
  public let startsIn: TimeInterval
  public let joinURL: URL?
  public let withGuests: Bool

  /// A real meeting (other people and a call link) about to start: the icon pulses.
  public var urgent: Bool { level == .now || (level == .soon && startsIn <= 120) }
  public var prominent: Bool { withGuests && joinURL != nil }

  public static let soonWindow: TimeInterval = 10 * 60
  public static let lateJoinWindow: TimeInterval = 5 * 60

  /// The next timed event the user is going to, within the next 12 hours, or one that started at most
  /// 5 minutes ago. All-day, declined and free ("transparent") events are skipped.
  public static func next(in events: [LocalEvent], now: Date) -> MeetingAlert? {
    let horizon = now.addingTimeInterval(12 * 3_600)
    let candidates = events.filter { event in
      event.allDay != true && event.blocksTime != false && event.ownResponse != "declined"
        && event.end > now && event.start <= horizon
        && event.start >= now.addingTimeInterval(-lateJoinWindow)
    }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    guard let event = candidates.first else { return nil }
    let startsIn = event.start.timeIntervalSince(now)
    let level: Level = startsIn <= 60 ? .now : startsIn <= soonWindow ? .soon : .later
    let guests = (event.attendees ?? []).contains { $0.isSelf != true && $0.response != "declined" }
    return MeetingAlert(event: event, level: level, startsIn: startsIn, joinURL: MeetingLink.url(for: event), withGuests: guests)
  }

  /// Short menu bar text: "Standup in 8m", "Join Standup", "Standup now".
  public func title(maxTitle: Int = 22) -> String? {
    let name = event.title.count > maxTitle ? String(event.title.prefix(maxTitle - 1)) + "…" : event.title
    switch level {
    case .later: return nil
    case .soon: return "\(name) in \(max(1, Int((startsIn / 60).rounded(.up))))m"
    case .now: return joinURL != nil ? "Join \(name)" : "\(name) now"
    }
  }
}
