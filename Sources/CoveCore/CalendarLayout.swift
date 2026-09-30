import Foundation

public struct EventPlacement: Identifiable {
  public var id: String { event.id }
  public var event: LocalEvent
  public var startMinute: Double
  public var endMinute: Double
  public var column: Int
  public var columns: Int
}
public enum CalendarDisplayMode: String, CaseIterable {
  case workweek, week, month
  public var title: String {
    switch self { case .workweek: return "Workweek"; case .week: return "Week"; case .month: return "Month" }
  }
  public func range(containing day: Date, calendar: Calendar = .current) -> DateInterval {
    let start = self == .month
      ? CalendarAgenda.monthDays(containing: day, calendar: calendar).first!
      : CalendarAgenda.weekStart(containing: day, calendar: calendar)
    return DateInterval(start: start, end: calendar.date(byAdding: .day, value: self == .month ? 42 : 7, to: start)!)
  }
  public func moved(_ amount: Int, from day: Date, calendar: Calendar = .current) -> Date {
    // Month navigation starts on day one so January 31 -> February -> March never skips a month.
    let start = self == .month ? calendar.dateInterval(of: .month, for: day)!.start : day
    return calendar.date(byAdding: self == .month ? .month : .day,
                         value: self == .month ? amount : amount * 7, to: start) ?? day
  }
}

public enum CalendarLayout {
  /// Leave one hour of context above now or a selected timed event; never continuously follow the clock.
  public static func scrollHour(now: Date, selected: LocalEvent? = nil, on day: Date,
                                calendar: Calendar = .current) -> Int {
    if let selected, selected.allDay != true {
      if selected.start < calendar.startOfDay(for: day) { return 0 }
      return max(0, calendar.component(.hour, from: selected.start) - 1)
    }
    return max(0, calendar.component(.hour, from: now) - 1)
  }

  public static let agendaDividerWidth = 12.0

  /// Preserve the grid's usable width while keeping the agenda inside its readable bounds.
  public static func agendaWidth(preferred: Double, available: Double) -> Double {
    let preferred = preferred.isFinite ? preferred : 280
    let available = available.isFinite ? max(0, available) : 816
    let maximum = min(480, max(240, available - 340 - agendaDividerWidth))
    return min(maximum, max(240, preferred))
  }

  /// Aligns the current-time marker with the wall-clock hours in the grid, including DST days.
  public static func currentTimeMinute(on day: Date, now: Date, calendar: Calendar = .current)
    -> Double?
  {
    guard calendar.isDate(day, inSameDayAs: now) else { return nil }
    let components = calendar.dateComponents([.hour, .minute], from: now)
    return Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
  }

  public static func arrange(_ events: [LocalEvent], on day: Date, calendar: Calendar = .current)
    -> [EventPlacement]
  {
    let day = calendar.startOfDay(for: day)
    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
    func minute(_ date: Date) -> Double {
      if date <= day { return 0 }
      if date >= next { return 1440 }
      return Double(
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
    }
    let sorted = events.filter {
      $0.allDay != true && $0.start < next && $0.end > day && $0.end > $0.start
    }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    var output: [EventPlacement] = []
    var cluster: [EventPlacement] = []
    var columnEnds: [Date] = []
    var clusterEnd = Date.distantPast
    func flush() {
      output += cluster.map {
        var item = $0
        item.columns = columnEnds.count
        return item
      }
      cluster = []
      columnEnds = []
    }
    for event in sorted {
      if event.start >= clusterEnd && !cluster.isEmpty { flush() }
      let column = columnEnds.firstIndex { $0 <= event.start } ?? columnEnds.count
      if column == columnEnds.count {
        columnEnds.append(event.end)
      } else {
        columnEnds[column] = event.end
      }
      cluster.append(
        EventPlacement(
          event: event, startMinute: minute(event.start), endMinute: minute(event.end),
          column: column, columns: 1))
      clusterEnd = max(clusterEnd, event.end)
    }
    flush()
    return output
  }
}

/// Pointer geometry for creating, moving and resizing events in the day grid. Everything snaps to
/// 15 minutes, stays within the day, and keeps at least 15 minutes of duration.
public enum CalendarDrag {
  public static let snap = 15.0
  public static let defaultMinutes = 60.0

  public static func snapped(_ minutes: Double) -> Double { (minutes / snap).rounded() * snap }

  /// The snapped minute of day at a vertical position in the 24-hour grid.
  public static func minute(atY y: Double, hourHeight: Double) -> Double {
    min(max(snapped(y / hourHeight * 60), 0), 1440)
  }

  /// A new event's span from a press at `startY` released at `endY` (either direction). A click
  /// without dragging proposes the default hour starting at the slot that was clicked.
  public static func creation(fromY startY: Double, toY endY: Double, hourHeight: Double)
    -> (start: Double, end: Double)
  {
    let first = min(max((min(startY, endY) / hourHeight * 60 / snap).rounded(.down) * snap, 0), 1440 - snap)
    let last = min(max((max(startY, endY) / hourHeight * 60 / snap).rounded(.up) * snap, 0), 1440)
    if abs(endY - startY) < hourHeight / 12 { return (first, min(first + defaultMinutes, 1440)) }
    return (first, max(last, first + snap))
  }

  /// Moves an event by a pointer translation, keeping its duration. Days are whole columns.
  public static func moved(
    start: Date, end: Date, translationX: Double, translationY: Double, columnWidth: Double,
    hourHeight: Double, dayRange: ClosedRange<Int> = -6...6, calendar: Calendar = .current
  ) -> (start: Date, end: Date) {
    let days = columnWidth > 0 ? min(max(Int((translationX / columnWidth).rounded()), dayRange.lowerBound), dayRange.upperBound) : 0
    let day = calendar.startOfDay(for: start)
    let startMinute = start.timeIntervalSince(day) / 60
    let duration = end.timeIntervalSince(start) / 60
    let newStart = min(max(snapped(startMinute + translationY / hourHeight * 60), 0), max(0, 1440 - min(duration, 1440)))
    let targetDay = calendar.date(byAdding: .day, value: days, to: day) ?? day
    let begin = targetDay.addingTimeInterval(newStart * 60)
    return (begin, begin.addingTimeInterval(duration * 60))
  }

  /// A new end after dragging the bottom edge; never shorter than 15 minutes or past midnight.
  public static func resizedEnd(start: Date, end: Date, translationY: Double, hourHeight: Double,
                                calendar: Calendar = .current) -> Date {
    let day = calendar.startOfDay(for: start)
    let startMinute = start.timeIntervalSince(day) / 60
    let endMinute = snapped(end.timeIntervalSince(day) / 60 + translationY / hourHeight * 60)
    return day.addingTimeInterval(min(max(endMinute, startMinute + snap), 1440) * 60)
  }
}

extension LocalEvent {
  /// Timed events Cove may reschedule: local ones, or Google events the user organizes.
  /// Invitations belong to their organizer and stay put.
  public var canReschedule: Bool {
    allDay != true && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (googleID == nil || isOrganizer == true)
  }
  /// Whether moving this event changes other people's calendars.
  public var hasOtherGuests: Bool { attendees?.contains { $0.isSelf != true } == true }
}
