import XCTest
@testable import CoveCore

final class SnoozeNoticeTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func mail(_ id: String, until: Date?, labels: Set<String> = ["INBOX"]) -> Mail {
    Mail(id: id, sender: "A", senderEmail: "a@example.com", subject: "S", body: "secret body",
         date: now, labels: labels, snoozedUntil: until)
  }

  func testIdentifierRoundTripsAndRejectsOthers() {
    let id = SnoozeNotice.identifier(mailID: "18f3a")
    XCTAssertEqual(id, "snooze.18f3a")
    XCTAssertEqual(SnoozeNotice.mailID(fromIdentifier: id), "18f3a")
    XCTAssertNil(SnoozeNotice.mailID(fromIdentifier: "cove-agent-18f3a"))
    XCTAssertNil(SnoozeNotice.mailID(fromIdentifier: "snooze."))
  }

  func testBodyIsSenderAndSubjectOnly() {
    XCTAssertEqual(SnoozeNotice.body(sender: "Ana", subject: "Budget"), "Ana · Budget")
    XCTAssertEqual(SnoozeNotice.body(sender: "Ana", subject: ""), "Ana · (No subject)")
    XCTAssertFalse(SnoozeNotice.body(sender: "A", subject: "S").contains("secret"))
    XCTAssertEqual(SnoozeNotice.title, "Back in your inbox")
  }

  func testPendingIsFutureSnoozedInboxMailOnly() {
    let later = now.addingTimeInterval(3600)
    let list = [
      mail("future", until: later),
      mail("past", until: now.addingTimeInterval(-60)),
      mail("none", until: nil),
      mail("archived", until: later, labels: []),
      mail("trash", until: later, labels: ["INBOX", "TRASH"]),
    ]
    XCTAssertEqual(SnoozeNotice.pending(in: list, now: now).map(\.id), ["future"])
  }

  /// A Gmail sync must not forget a snooze made on the phone.
  func testSyncMergeKeepsSnooze() {
    let until = now.addingTimeInterval(86_400)
    let cached = [mail("m1", until: until)]
    let result = GmailSyncResult(messages: [mail("m1", until: nil)], historyID: "1")
    XCTAssertEqual(result.applying(to: cached).first?.snoozedUntil, until)
  }
}
