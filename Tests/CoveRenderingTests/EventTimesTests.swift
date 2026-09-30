import XCTest
@testable import Cove

final class EventTimesTests: XCTestCase {
  func testChoicesAreQuarterHoursAndEndsShowTheLength() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 16, minute: 15))!
    let starts = EventTimes.starts(on: day, calendar: calendar)
    XCTAssertEqual(starts.count, 96)
    XCTAssertEqual(starts.first?.date, calendar.startOfDay(for: day))
    let ends = EventTimes.ends(after: day)
    XCTAssertEqual(ends.first?.date, day.addingTimeInterval(900))
    XCTAssertTrue(ends.first?.label.hasSuffix("15 min") == true)
    XCTAssertEqual(EventTimes.duration(from: day, to: day.addingTimeInterval(3600)), "1 hr")
    XCTAssertEqual(EventTimes.duration(from: day, to: day.addingTimeInterval(5400)), "1.5 hr")
    XCTAssertEqual(EventTimes.duration(from: day, to: day.addingTimeInterval(2700)), "45 min")
  }
}
