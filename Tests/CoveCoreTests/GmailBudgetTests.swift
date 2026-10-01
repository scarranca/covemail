@testable import CoveCore
import XCTest

final class GmailBudgetTests: XCTestCase {
  func testCostsFollowGooglesPublishedTable() {
    XCTAssertEqual(GmailClient.quotaCost(path: "messages/abc", method: "GET"), 20)
    XCTAssertEqual(GmailClient.quotaCost(path: "messages", method: "GET"), 5)
    XCTAssertEqual(GmailClient.quotaCost(path: "history", method: "GET"), 2)
    XCTAssertEqual(GmailClient.quotaCost(path: "profile", method: "GET"), 1)
    XCTAssertEqual(GmailClient.quotaCost(path: "messages/abc/modify", method: "POST"), 5)
    XCTAssertEqual(GmailClient.quotaCost(path: "messages/batchModify", method: "POST"), 50)
    XCTAssertEqual(GmailClient.quotaCost(path: "messages/send", method: "POST"), 100)
    XCTAssertEqual(GmailClient.quotaCost(path: "messages/abc/trash", method: "POST"), 20)
    XCTAssertEqual(GmailClient.quotaCost(path: "messages/abc/attachments/x", method: "GET"), 20)
    XCTAssertEqual(GmailClient.quotaCost(path: "labels", method: "GET"), 1)
    XCTAssertEqual(GmailClient.quotaCost(path: "threads/abc", method: "GET"), 40)
  }

  func testBackgroundReadsWaitForBudgetAboveTheReserve() async throws {
    let pacer = GmailPacer(spacing: { 0 })
    // Leave just under what one background read needs above the reserve: it waits for the refill
    // (6,000 units a minute is 100 a second), while a user's action could still spend right away.
    let target = GmailPacer.reserve + 20 - 15
    await pacer.spend(await pacer.remaining() - target)
    let started = ContinuousClock.now
    try await pacer.waitForBulk(cost: 20)
    let waited = ContinuousClock.now - started
    XCTAssertGreaterThanOrEqual(waited, .milliseconds(100), "about 15 units at 100 per second")
    XCTAssertLessThan(waited, .seconds(2))
  }

  func testAfterGmailSaysSlowDownEverythingPauses() async throws {
    let pacer = GmailPacer(spacing: { 0 }, reserve: 0)
    await pacer.slowDown(for: 0.3)
    let left = await pacer.remaining()
    XCTAssertLessThanOrEqual(left, 1, "the budget is treated as spent")
    let started = ContinuousClock.now
    try await pacer.waitForBulk(cost: 1)
    XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(280))
  }

  func testLabelChangesReplayInOrderOnTheStoredCopy() {
    var change = GmailLabelChange()
    change.add(["Label_1", "STARRED"])
    change.remove(["STARRED", "INBOX"])
    change.add(["INBOX"])
    let mail = Mail(id: "a", sender: "S", senderEmail: "s@x.example", subject: "Hi", body: "b", labels: ["INBOX", "UNREAD"])
    var result = GmailSyncResult(historyID: "2")
    result.labelChanges = ["a": change]
    XCTAssertEqual(result.applying(to: [mail]).first?.labels, ["INBOX", "UNREAD", "Label_1"])
  }
}
