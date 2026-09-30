import XCTest

@testable import CoveCore

final class TaskContextTests: XCTestCase {
  private let now = Date()
  private func mail(_ id: String, from name: String, _ email: String, subject: String, body: String = "", daysAgo: Double, thread: String? = nil) -> Mail {
    Mail(id: id, threadID: thread ?? id, sender: name, senderEmail: email, subject: subject, body: body,
         date: now.addingTimeInterval(-daysAgo * 86_400), labels: ["INBOX"])
  }

  func testNamesInATaskFindThePersonAndTheirLatestEmails() {
    let mails = [
      mail("1", from: "Millet Ramírez", "millet@uisr.io", subject: "Plan for our account", daysAgo: 1),
      mail("2", from: "Millet Ramírez", "millet@uisr.io", subject: "Invoice question", daysAgo: 5),
      mail("3", from: "Sebastián López", "sebastianlopez@ebombo.com", subject: "Q3 report", daysAgo: 2),
      mail("4", from: "Millet Ramírez", "millet@uisr.io", subject: "Re: Plan for our account", daysAgo: 0.5, thread: "1"),
    ]
    let contacts = ContactDirectory.build(mails: mails, records: [], accountEmail: "me@example.com")
    XCTAssertEqual(TaskContext.keywords("Call Millet about the plan"), ["millet", "plan"])
    let people = TaskContext.people(for: "Call Millet", contacts: contacts)
    XCTAssertEqual(people.map(\.email), ["millet@uisr.io"])
    XCTAssertEqual(TaskContext.people(for: "Llamar a millet", contacts: contacts).first?.email, "millet@uisr.io", "Case and language don't matter")
    XCTAssertEqual(TaskContext.people(for: "Send Sebastian the report", contacts: contacts).first?.email, "sebastianlopez@ebombo.com", "Accents don't matter")
    let related = TaskContext.mails(for: "Call Millet", people: people, in: mails)
    XCTAssertEqual(related.map(\.id), ["4", "2"], "Newest first, one per conversation")
    XCTAssertTrue(TaskContext.people(for: "Call", contacts: contacts).isEmpty)
  }

  func testWithoutAPersonKeywordsFindTheEmails() {
    let mails = [
      mail("a", from: "Porkbun", "support@porkbun.com", subject: "Your domain covemail.xyz renews soon", body: "Renewal on Oct 20", daysAgo: 3),
      mail("b", from: "Maya", "maya@example.com", subject: "Lunch", body: "domain experts", daysAgo: 1),
    ]
    XCTAssertEqual(TaskContext.mails(for: "Renew the covemail domain", people: [], in: mails).map(\.id), ["a"], "Every keyword must match")
    XCTAssertTrue(TaskContext.mails(for: "Call", people: [], in: mails).isEmpty)
  }

  func testUpcomingMeetingsWithThePerson() {
    let mails = [mail("1", from: "Millet Ramírez", "millet@uisr.io", subject: "Plan", daysAgo: 1)]
    let people = TaskContext.people(for: "Call Millet", contacts: ContactDirectory.build(mails: mails, records: [], accountEmail: "me@example.com"))
    var sync = LocalEvent(title: "Account sync", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000))
    sync.attendees = [CalendarAttendee(email: "Millet@uisr.io")]
    let named = LocalEvent(title: "Coffee with Millet", start: now.addingTimeInterval(3 * 86_400), end: now.addingTimeInterval(3 * 86_400 + 1_800))
    let past = LocalEvent(title: "Millet kickoff", start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-80_000))
    let other = LocalEvent(title: "Dentist", start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(7_200))
    XCTAssertEqual(TaskContext.events(for: people, in: [other, named, past, sync], now: now).map(\.title), ["Account sync", "Coffee with Millet"])
  }
}
