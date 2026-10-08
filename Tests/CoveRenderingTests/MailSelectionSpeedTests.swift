import CoveCore
import XCTest
@testable import Cove

/// Moving through mail must not re-filter and re-sort the whole mailbox, while the open email still stays
/// listed after it stops matching (marked read under Unread, or voted to the other tab).
@MainActor final class MailSelectionSpeedTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

  private func store(_ mails: [Mail]) throws -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoveSelect-" + UUID().uuidString)
    directories.append(dir)
    let store = try AppStore(database: Database(url: dir.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "x" }, syncClock: Date.init)
    store.isSample = true; store.screen = "mail"
    store.mails = mails
    store.chooseFolder("Inbox")
    return store
  }

  func testSelectionReusesTheListAndKeepsTheOpenEmailListed() throws {
    let mails = (0..<3_000).map { index in
      Mail(id: "m\(index)", sender: "Sender \(index)", senderEmail: "s\(index % 200)@example.com",
        subject: "Subject \(index)", body: "Body", date: Date(timeIntervalSince1970: Double(index) * 60),
        labels: index % 2 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"], isBulkOrAutomated: false)
    }
    let store = try store(mails)
    let list = store.visible
    XCTAssertFalse(list.isEmpty)
    let before = store.visibleComputations
    for mail in list.prefix(40) { store.select(mail); XCTAssertEqual(store.visible.count, list.count) }
    XCTAssertEqual(store.visibleComputations, before, "selection alone doesn't rebuild the list")

    // Under Unread, a read email that is open stays listed in date order until selection moves on.
    store.labelUnreadOnly = true
    let unread = store.visible
    let read = try XCTUnwrap(mails.first { !$0.isUnread && $0.date < unread[0].date && $0.date > unread[5].date })
    store.select(read)
    let withOpen = store.visible
    XCTAssertEqual(withOpen.count, unread.count + 1)
    let position = try XCTUnwrap(withOpen.firstIndex { $0.id == read.id })
    XCTAssertTrue(withOpen[position - 1].date > read.date && withOpen[position + 1].date < read.date)
    store.select(unread[3])
    XCTAssertFalse(store.visible.contains { $0.id == read.id })
  }
}
