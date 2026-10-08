import Foundation
import XCTest
@testable import CoveCore

final class SnoozePresetTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }
  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  func testPresetsFromAWednesdayMorning() {
    let now = date(2026, 10, 7, 10, 20) // Wednesday
    XCTAssertEqual(SnoozePreset.laterToday.date(from: now, calendar: calendar), date(2026, 10, 7, 13, 30), "3 h on, next quarter hour")
    XCTAssertEqual(SnoozePreset.thisEvening.date(from: now, calendar: calendar), date(2026, 10, 7, 18))
    XCTAssertEqual(SnoozePreset.tomorrowMorning.date(from: now, calendar: calendar), date(2026, 10, 8, 9))
    XCTAssertEqual(SnoozePreset.thisWeekend.date(from: now, calendar: calendar), date(2026, 10, 10, 9), "Saturday")
    XCTAssertEqual(SnoozePreset.nextWeek.date(from: now, calendar: calendar), date(2026, 10, 12, 9), "Monday")
    XCTAssertEqual(SnoozePreset.available(from: now, calendar: calendar).map(\.preset), SnoozePreset.allCases)
  }

  func testPastOrTooNearMomentsAreHidden() {
    let evening = date(2026, 10, 7, 17, 45)
    XCTAssertNil(SnoozePreset.thisEvening.date(from: evening, calendar: calendar), "18:00 is within 30 minutes")
    XCTAssertNil(SnoozePreset.thisEvening.date(from: date(2026, 10, 7, 21), calendar: calendar), "already past")
    XCTAssertNil(SnoozePreset.laterToday.date(from: date(2026, 10, 7, 22), calendar: calendar), "3 h on would be tomorrow")
    XCTAssertEqual(SnoozePreset.available(from: date(2026, 10, 7, 22), calendar: calendar).map(\.preset),
                   [.tomorrowMorning, .thisWeekend, .nextWeek])
    // At 16:30, "Later today" would be 19:30, after "This evening": the evening is enough.
    XCTAssertEqual(SnoozePreset.available(from: date(2026, 10, 7, 16, 30), calendar: calendar).map(\.preset),
                   [.thisEvening, .tomorrowMorning, .thisWeekend, .nextWeek])
  }

  func testWeekendAndNextWeekFromTheWeekend() {
    let saturday = date(2026, 10, 10, 11)
    XCTAssertEqual(SnoozePreset.thisWeekend.date(from: saturday, calendar: calendar), date(2026, 10, 17, 9), "next Saturday")
    XCTAssertEqual(SnoozePreset.nextWeek.date(from: saturday, calendar: calendar), date(2026, 10, 12, 9))
    let sunday = date(2026, 10, 11, 11)
    XCTAssertEqual(SnoozePreset.thisWeekend.date(from: sunday, calendar: calendar), date(2026, 10, 17, 9))
    let monday = date(2026, 10, 12, 11)
    XCTAssertEqual(SnoozePreset.nextWeek.date(from: monday, calendar: calendar), date(2026, 10, 19, 9), "never today")
  }

  func testDescriptionsAreShortAndRelative() {
    let now = date(2026, 10, 7, 10)
    // Foundation puts a narrow no-break space before AM/PM; compare on plain spaces.
    func plain(_ date: Date) -> String {
      SnoozePreset.describe(date, from: now, calendar: calendar).replacingOccurrences(of: "\u{202F}", with: " ")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
    XCTAssertEqual(plain(date(2026, 10, 7, 13, 30)), "Today 1:30 PM")
    XCTAssertEqual(plain(date(2026, 10, 8, 9)), "Tomorrow 9:00 AM")
    XCTAssertEqual(plain(date(2026, 10, 10, 9)), "Sat 9:00 AM")
    XCTAssertEqual(plain(date(2026, 10, 21, 9)), "Oct 21, 9:00 AM")
  }
}
