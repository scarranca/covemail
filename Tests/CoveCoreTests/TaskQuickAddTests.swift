import XCTest

@testable import CoveCore

final class TaskQuickAddTests: XCTestCase {
  private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
  private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 11))!  // a Wednesday

  func testDatesAreReadFromTheTextAndRemovedFromTheTitle() {
    let tomorrow = TaskQuickAdd.parse("Send the contract tomorrow", now: now, calendar: calendar)
    XCTAssertEqual(tomorrow.title, "Send the contract")
    XCTAssertEqual(tomorrow.due, calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
    let spanish = TaskQuickAdd.parse("Llamar a Millet mañana", now: now, calendar: calendar)
    XCTAssertEqual(spanish.title, "Llamar a Millet")
    XCTAssertNotNil(spanish.due)
    let friday = TaskQuickAdd.parse("Call Millet by Friday", now: now, calendar: calendar)
    XCTAssertEqual(friday.title, "Call Millet")
    XCTAssertEqual(friday.due.map { calendar.component(.weekday, from: $0) }, 6)
    let plain = TaskQuickAdd.parse("Renew the domain", now: now, calendar: calendar)
    XCTAssertEqual(plain.title, "Renew the domain"); XCTAssertNil(plain.due)
    XCTAssertEqual(TaskQuickAdd.parse("   ").title, "")
  }

  func testStepsAndDayPlanAreBoundedToRealTasks() {
    let steps = TaskQuickAdd.steps(from: #"{"steps":["Open the admin panel","Find Millet's account","find millet's account","Add the plan","Email Millet","Check billing","Extra"]}"#)
    XCTAssertEqual(steps, ["Open the admin panel", "Find Millet's account", "Add the plan", "Email Millet", "Check billing"])
    XCTAssertTrue(TaskQuickAdd.steps(from: "no json").isEmpty)
    let plan = TaskQuickAdd.dayPlan(from: #"{"today":[{"id":"a","why":"Promised to Millet","minutes":25},{"id":"ghost","why":"x"},{"id":"a","why":"dup"},{"id":"b","why":"Overdue","minutes":200}]}"#,
                                    validIDs: ["a", "b"])
    XCTAssertEqual(plan.map(\.id), ["a", "b"], "Only real task ids, no duplicates")
    XCTAssertEqual(plan.map(\.minutes), [30, 90], "Durations snap to 15/30/60/90")
  }
}
