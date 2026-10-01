import CoveCore
import XCTest

final class TaskMomentumTests: XCTestCase {
  func testCountsFinishedTasksPerDayOldestFirst() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 17))!
    let formatter = ISO8601DateFormatter()
    func done(_ id: String, daysAgo: Int) -> GoogleTask {
      GoogleTask(id: id, title: id, status: "completed",
                 completed: formatter.string(from: now.addingTimeInterval(-Double(daysAgo) * 86_400)))
    }
    let counts = TaskMomentum.daily([done("a", daysAgo: 0), done("b", daysAgo: 0), done("c", daysAgo: 3),
                                     done("old", daysAgo: 40), GoogleTask(id: "open", title: "open")], now: now, calendar: calendar)
    XCTAssertEqual(counts.count, 14)
    XCTAssertEqual(counts.last, 2)
    XCTAssertEqual(counts[13 - 3], 1)
    XCTAssertEqual(counts.reduce(0, +), 3)
  }

  func testWaitingInMailSkipsCreatedSpamAndOldMail() {
    let now = Date()
    var found = Mail(id: "f", sender: "M", senderEmail: "m@x.example", subject: "Contract", body: "b", date: now)
    found.taskCheck = MailTaskCheck(found: true, confidence: 0.9)
    var created = found; created.id = "c"; created.taskCheck?.createdTaskIDs = ["t"]
    var spam = found; spam.id = "s"; spam.labels = ["SPAM"]
    var old = found; old.id = "o"; old.date = now.addingTimeInterval(-40 * 86_400)
    XCTAssertEqual(TaskMomentum.waitingInMail([found, created, spam, old], now: now).map(\.id), ["f"])
  }
}
