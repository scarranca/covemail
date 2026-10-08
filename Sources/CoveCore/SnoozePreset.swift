import Foundation

/// The snooze choices offered on every platform, like Superhuman's: a few named moments, each a real
/// local time computed from `now`, never a relative offset the user has to work out.
public enum SnoozePreset: String, CaseIterable, Codable, Sendable, Identifiable {
  case laterToday, thisEvening, tomorrowMorning, thisWeekend, nextWeek

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .laterToday: "Later today"
    case .thisEvening: "This evening"
    case .tomorrowMorning: "Tomorrow morning"
    case .thisWeekend: "This weekend"
    case .nextWeek: "Next week"
    }
  }

  /// The single-key shortcut shown beside the preset in menus (H opens the menu first).
  public var key: String {
    switch self {
    case .laterToday: "1"
    case .thisEvening: "2"
    case .tomorrowMorning: "3"
    case .thisWeekend: "4"
    case .nextWeek: "5"
    }
  }

  /// Mornings are 9:00, evenings 18:00, local time.
  public static let morningHour = 9
  public static let eveningHour = 18

  /// When this preset returns the email, or nil when that moment is already too close (within 30
  /// minutes) or in the past, so menus can hide it.
  public func date(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
    var calendar = calendar
    calendar.locale = calendar.locale ?? .current
    let today = calendar.startOfDay(for: now)
    func at(_ hour: Int, _ day: Date) -> Date? { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) }
    func nextWeekday(_ weekday: Int, from day: Date, allowingToday: Bool) -> Date? {
      let current = calendar.component(.weekday, from: day)
      var ahead = (weekday - current + 7) % 7
      if ahead == 0 && !allowingToday { ahead = 7 }
      return calendar.date(byAdding: .day, value: ahead, to: day)
    }
    let result: Date?
    switch self {
    case .laterToday:
      // Three hours on, rounded up to the next quarter hour, as long as it is still today.
      let raw = now.addingTimeInterval(3 * 3600)
      let minute = calendar.component(.minute, from: raw)
      let rounded = calendar.date(byAdding: .minute, value: (15 - minute % 15) % 15, to: raw)
        .flatMap { calendar.date(bySetting: .second, value: 0, of: $0) } ?? raw
      result = calendar.isDate(rounded, inSameDayAs: now) ? rounded : nil
    case .thisEvening:
      result = at(Self.eveningHour, today)
    case .tomorrowMorning:
      result = calendar.date(byAdding: .day, value: 1, to: today).flatMap { at(Self.morningHour, $0) }
    case .thisWeekend:
      // Saturday morning; on a weekend day it means the next one.
      let weekday = calendar.component(.weekday, from: now)
      let isWeekend = calendar.isDateInWeekend(now)
      result = nextWeekday(7, from: today, allowingToday: false).flatMap { saturday in
        isWeekend && weekday == 7 ? calendar.date(byAdding: .day, value: 7, to: today).flatMap { at(Self.morningHour, $0) }
          : at(Self.morningHour, saturday)
      }
    case .nextWeek:
      result = nextWeekday(2, from: today, allowingToday: false).flatMap { at(Self.morningHour, $0) }
    }
    guard let result, result.timeIntervalSince(now) >= 30 * 60 else { return nil }
    return result
  }

  /// The presets worth offering right now, in menu order, with their dates.
  public static func available(from now: Date = Date(), calendar: Calendar = .current) -> [(preset: SnoozePreset, date: Date)] {
    let all = allCases.compactMap { preset in preset.date(from: now, calendar: calendar).map { (preset: preset, date: $0) } }
    // "Later today" after "This evening" reads backwards; late in the afternoon the evening is enough.
    guard let later = all.first(where: { $0.preset == .laterToday }), let evening = all.first(where: { $0.preset == .thisEvening }),
      later.date >= evening.date else { return all }
    return all.filter { $0.preset != .laterToday }
  }

  /// A short description of a snooze time for menus and toasts: "Today 3:15 PM", "Tomorrow 9:00 AM",
  /// "Sat 9:00 AM", "Oct 21, 9:00 AM".
  public static func describe(_ date: Date, from now: Date = Date(), calendar: Calendar = .current) -> String {
    let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone))
    if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
      return "Tomorrow \(time)"
    }
    if let week = calendar.date(byAdding: .day, value: 6, to: now), date < week {
      return date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)) + " \(time)"
    }
    return date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()) + ", \(time)"
  }
}
