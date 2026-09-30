import XCTest

@testable import CoveCore

final class CalendarDragTests: XCTestCase {
  private let hour = 80.0
  private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }
  private func at(_ day: Int, _ minute: Double) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!.addingTimeInterval(minute * 60)
  }

  func testCreationSnapsToQuarterHoursInEitherDirectionAndClickProposesAnHour() {
    // 9:07 → 10:52 becomes 9:00 → 11:00.
    let drag = CalendarDrag.creation(fromY: 9 * hour + 9, toY: 10 * hour + 69, hourHeight: hour)
    XCTAssertEqual(drag.start, 540); XCTAssertEqual(drag.end, 660)
    let upward = CalendarDrag.creation(fromY: 10 * hour + 69, toY: 9 * hour + 9, hourHeight: hour)
    XCTAssertEqual(upward.start, 540); XCTAssertEqual(upward.end, 660)
    let click = CalendarDrag.creation(fromY: 14 * hour + 30, toY: 14 * hour + 32, hourHeight: hour)
    XCTAssertEqual(click.start, 855); XCTAssertEqual(click.end, 915)
    let lateClick = CalendarDrag.creation(fromY: 24 * hour - 2, toY: 24 * hour - 2, hourHeight: hour)
    XCTAssertEqual(lateClick.start, 1425); XCTAssertEqual(lateClick.end, 1440)
  }

  func testMoveKeepsDurationSnapsAndCrossesDays() {
    let (start, end) = (at(23, 600), at(23, 645))  // Wed 10:00–10:45
    // Right by 1.4 columns and down 50 minutes (snaps to 45): Thu 10:45–11:30.
    let moved = CalendarDrag.moved(start: start, end: end, translationX: 1.4 * 200, translationY: 50 * hour / 60,
                                   columnWidth: 200, hourHeight: hour, calendar: calendar)
    XCTAssertEqual(moved.start, at(24, 645)); XCTAssertEqual(moved.end, at(24, 690))
    // Dragging far above the day clamps to midnight rather than leaving the day.
    let top = CalendarDrag.moved(start: start, end: end, translationX: 0, translationY: -20 * hour,
                                 columnWidth: 200, hourHeight: hour, calendar: calendar)
    XCTAssertEqual(top.start, at(23, 0)); XCTAssertEqual(top.end, at(23, 45))
    let bottom = CalendarDrag.moved(start: start, end: end, translationX: 0, translationY: 20 * hour,
                                    columnWidth: 200, hourHeight: hour, calendar: calendar)
    XCTAssertEqual(bottom.end, at(24, 0))
  }

  func testResizeSnapsAndKeepsAQuarterHourMinimum() {
    let (start, end) = (at(23, 600), at(23, 660))
    XCTAssertEqual(CalendarDrag.resizedEnd(start: start, end: end, translationY: 38, hourHeight: hour, calendar: calendar), at(23, 690))
    XCTAssertEqual(CalendarDrag.resizedEnd(start: start, end: end, translationY: -200, hourHeight: hour, calendar: calendar), at(23, 615))
    XCTAssertEqual(CalendarDrag.resizedEnd(start: start, end: end, translationY: 5000, hourHeight: hour, calendar: calendar), at(24, 0))
  }

  func testOnlyOwnTimedEventsCanBeRescheduled() {
    var local = LocalEvent(title: "Focus", start: at(23, 600), end: at(23, 660))
    XCTAssertTrue(local.canReschedule)
    local.allDay = true
    XCTAssertFalse(local.canReschedule)
    var invite = LocalEvent(title: "Board", start: at(23, 600), end: at(23, 660))
    invite.googleID = "abc"; invite.isOrganizer = false
    XCTAssertFalse(invite.canReschedule)
    invite.isOrganizer = true
    XCTAssertTrue(invite.canReschedule)
    invite.attendees = [CalendarAttendee(email: "me@example.com", isSelf: true)]
    XCTAssertFalse(invite.hasOtherGuests)
    invite.attendees?.append(CalendarAttendee(email: "guest@example.com"))
    XCTAssertTrue(invite.hasOtherGuests)
  }
}
