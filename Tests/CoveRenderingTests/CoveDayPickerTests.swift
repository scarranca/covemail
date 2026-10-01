import AppKit
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class CoveDayPickerTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
    calendar.firstWeekday = 1
    return calendar
  }

  func testWeeksStartOnTheFirstWeekdayAndCoverTheMonth() {
    let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
    let weeks = CoveDayPicker.weeks(of: october, calendar: calendar)
    XCTAssertEqual(weeks.count, 5)
    XCTAssertEqual(weeks[0].prefix(4).filter { $0 == nil }.count, 4, "Oct 1 2026 is a Thursday")
    XCTAssertEqual(weeks.flatMap { $0 }.compactMap { $0 }.count, 31)
    var monday = calendar; monday.firstWeekday = 2
    XCTAssertEqual(CoveDayPicker.weeks(of: october, calendar: monday)[0].filter { $0 == nil }.count, 3)
  }

  func testPickerRenders() throws {
    let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!
    let selected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
    let view = HStack(alignment: .top, spacing: 24) {
      CoveDayPicker(selection: selected, calendar: calendar, today: today) { _ in }
      CoveDayPicker(selection: nil, calendar: calendar, today: today) { _ in }
    }.padding(24).background(Color(white: 0.9))
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-day-picker.png"))
  }
}
