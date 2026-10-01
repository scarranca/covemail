import Foundation

/// A local-day scheduling request. Calendar reads must be complete before calling `firstSlot`.
public struct WritingAvailability: Equatable, Sendable {
  public let day: Date
  public let durationMinutes: Int
  public let startMinute: Int
  public let endMinute: Int
  public let timeZone: TimeZone
  public let slotCount: Int

  public init(day: String, durationMinutes: Int = 30, startMinute: Int = 540,
              endMinute: Int = 1020, timeZone: TimeZone, slotCount: Int = 1) throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard day.count == 10, let parsed = formatter.date(from: day), formatter.string(from: parsed) == day,
      (1...5).contains(slotCount), (5...480).contains(durationMinutes), (0..<1440).contains(startMinute),
      (1...1440).contains(endMinute), endMinute > startMinute,
      durationMinutes <= endMinute - startMinute else {
      throw CoveError.message("Choose a valid meeting date, duration, and time window.")
    }
    self.day = parsed
    self.durationMinutes = durationMinutes
    self.startMinute = startMinute
    self.endMinute = endMinute
    self.timeZone = timeZone
    self.slotCount = slotCount
  }

  public var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }
  public var dayRange: DateInterval { calendar.dateInterval(of: .day, for: day)! }
  public var dayString: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: day)
  }

  /// Uses wall-clock boundaries, so a daylight-saving transition is not treated as a 24-hour day.
  public func firstSlot(events: [LocalEvent], now: Date) throws -> DateInterval? {
    let range = dayRange
    // A zero-length event (a reminder, a pin) can't take time; only one ending before it starts is invalid.
    guard events.allSatisfy({ $0.blocksTime == false || $0.end >= $0.start }) else {
      throw CoveError.message("Calendar returned an invalid event. Availability could not be verified.")
    }
    func boundary(_ minute: Int) -> Date? {
      if minute == 1440 { return range.end }
      return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                           of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
    guard let start = boundary(startMinute), let end = boundary(endMinute), end > start else {
      throw CoveError.message("The selected meeting window is unavailable on this date.")
    }
    // Keep the earliest actual minute available; do not invent a 15-minute rounding preference.
    var cursor = max(start, now)
    let minuteFloor = calendar.dateInterval(of: .minute, for: cursor)!.start
    if minuteFloor < cursor { cursor = minuteFloor.addingTimeInterval(60) }
    let duration = Double(durationMinutes) * 60
    let busy = events.filter { $0.blocksTime != false && $0.end > cursor && $0.start < end }
      .sorted { $0.start < $1.start }
    for event in busy {
      if event.end <= cursor { continue }
      if min(event.start, end).timeIntervalSince(cursor) >= duration {
        return DateInterval(start: cursor, duration: duration)
      }
      cursor = max(cursor, event.end)
      let floor = calendar.dateInterval(of: .minute, for: cursor)!.start
      if floor < cursor { cursor = floor.addingTimeInterval(60) }
      if cursor >= end { return nil }
    }
    return end.timeIntervalSince(cursor) >= duration ? DateInterval(start: cursor, duration: duration) : nil
  }

  /// Earliest distinct, non-overlapping choices from a single complete calendar snapshot.
  public func slots(events: [LocalEvent], now: Date) throws -> [DateInterval] {
    var results: [DateInterval] = []
    var cursor = now
    while results.count < slotCount, let slot = try firstSlot(events: events, now: cursor) {
      results.append(slot)
      cursor = slot.end
    }
    return results
  }

  public func label(for slot: DateInterval) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
    return formatter.string(from: slot.start)
  }

  public var assumptions: String {
    func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    return "\(durationMinutes)-minute meeting; \(clock(startMinute))–\(clock(endMinute)) on \(dayString); \(timeZone.identifier). Checked primary Google Calendar and Cove local events only; other calendars and the recipient’s availability are not checked."
  }

  /// A conservative intent guard independent of provider planning. In particular, typos in
  /// 'time' must not turn a clear earliest-availability instruction into a generic invitation.
  public static func isAvailabilityRequest(_ instruction: String) -> Bool {
    let text = instruction.lowercased()
    let availability = text.contains("available") || text.contains("availability") || text.contains("free time") || text.contains("free slot")
    if text.range(of: #"\btime[ -]?slots?\b"#, options: .regularExpression) != nil { return true }
    return availability && ["meet", "schedule", "first", "earliest", "next", "find", "slot"].contains(where: text.contains)
  }

  /// Resolves common explicit dates if a provider omits the mandatory scheduling tool.
  /// Unresolved dates fail visibly instead of quietly drafting an ungrounded proposal.
  public static func fallback(instruction: String, now: Date, timeZone: TimeZone,
                              previous: WritingAvailability? = nil) throws -> WritingAvailability? {
    guard isAvailabilityRequest(instruction) || (previous != nil && isSchedulingFollowUp(instruction)) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let text = instruction.lowercased()
    let date: Date
    var explicitDay: String?
    if text.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil {
      date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    } else if text.range(of: #"\btoday\b"#, options: .regularExpression) != nil {
      date = calendar.startOfDay(for: now)
    } else if let match = text.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) {
      explicitDay = String(text[match])
      date = now
    } else if let previous {
      // Leave new natural-language dates to the planner; never silently reuse the old day.
      if text.range(of: #"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week|next month|instead on|september|october|november|december|january|february|march|april|may|june|july|august)\b"#, options: .regularExpression) != nil { return nil }
      date = previous.day
    } else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    var start = text.contains("evening") ? 1020 : (text.contains("afternoon") ? 720 : (text.contains("morning") ? 540 : previous?.startMinute ?? 540))
    var end = text.contains("evening") ? 1260 : (text.contains("morning") ? 720 : (text.contains("afternoon") ? 1020 : previous?.endMinute ?? 1020))
    for (word, isStart) in [("after", true), ("before", false)] {
      if let minute = clockConstraint(text, word: word) {
        if isStart { start = max(start, minute) } else { end = min(end, minute) }
      } else if text.range(of: "\\b" + word + "\\b", options: .regularExpression) != nil {
        // Never silently ignore 'after lunch' or an ambiguous 'after 2'.
        throw CoveError.message("Use a specific time such as ‘after 2 PM’ or ‘before 11 AM’ so Cove can check the right meeting window.")
      }
    }
    return try WritingAvailability(day: explicitDay ?? formatter.string(from: date),
      durationMinutes: requestedDuration(text) ?? previous?.durationMinutes ?? 30, startMinute: start, endMinute: end, timeZone: timeZone,
      slotCount: try requestedSlotCount(text) ?? previous?.slotCount ?? 1)
  }

  public static func isSchedulingFollowUp(_ instruction: String) -> Bool {
    let text = instruction.lowercased()
    return isAvailabilityRequest(text)
      || text.range(of: #"\b(slots?|timeslots?|times|options?|alternatives?|earlier|later|instead|morning|afternoon|evening|tomorrow|today|minutes?|hours?)\b"#, options: .regularExpression) != nil
  }

  public static func requestedSlotCount(_ instruction: String) throws -> Int? {
    let expression = try! NSRegularExpression(pattern: #"\b(\d+|one|two|three|four|five)\s+(?:time[ -]?)?(?:slots?|times?|options?|alternatives?)\b"#)
    let text = instruction.lowercased()
    guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text) else {
      return text.range(of: #"\b(first|earliest|next) available\b"#, options: .regularExpression) != nil ? 1 : nil
    }
    let word = String(text[range])
    guard let count = Int(word) ?? ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5][word], (1...5).contains(count) else {
      throw CoveError.message("Ask for between one and five meeting times at a time.")
    }
    return count
  }

  private static func clockConstraint(_ text: String, word: String) -> Int? {
    let expression = try! NSRegularExpression(pattern: "\\b" + word + #"\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#)
    guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let hours = Range(match.range(at: 1), in: text), let period = Range(match.range(at: 3), in: text),
      let hour = Int(text[hours]), (1...12).contains(hour) else { return nil }
    let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
    guard (0...59).contains(minute) else { return nil }
    return (hour % 12 + (text[period] == "pm" ? 12 : 0)) * 60 + minute
  }

  private static func requestedDuration(_ text: String) -> Int? {
    if text.range(of: #"\bhalf (an? )?hour\b"#, options: .regularExpression) != nil { return 30 }
    if text.range(of: #"\b(an?|one)[ -]+hour\b"#, options: .regularExpression) != nil { return 60 }
    if text.range(of: #"\btwo[ -]+hours?\b"#, options: .regularExpression) != nil { return 120 }
    let expression = try! NSRegularExpression(pattern: #"\b(\d{1,3})[ -]*(minutes?|mins?|hours?|hrs?)\b"#)
    guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let digits = Range(match.range(at: 1), in: text), let unit = Range(match.range(at: 2), in: text),
      let value = Int(text[digits]) else { return nil }
    return value * (text[unit].hasPrefix("h") ? 60 : 1)
  }
}
