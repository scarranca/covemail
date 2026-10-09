import CoveCore
import XCTest
@testable import Cove

/// Baseline numbers for the Mac store with a realistic mailbox: how long the list takes to rebuild, and
/// what an autosave while typing costs. Printed timings are what the speed audit quotes; the asserts
/// are about behavior (an autosave must not rebuild the list), with loose time bounds.
@MainActor final class MailboxSpeedBenchmarkTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

  private func store(_ mails: [Mail]) throws -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoveSpeed-" + UUID().uuidString)
    directories.append(dir)
    let store = try AppStore(database: Database(url: dir.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "x" }, syncClock: Date.init)
    store.isSample = true; store.screen = "mail"
    store.mails = mails
    store.chooseFolder("Inbox")
    return store
  }

  private static func synthetic(_ count: Int) -> [Mail] {
    let paragraph = String(repeating: "Thanks for the update. Let's review the figures on Thursday and confirm the plan. ", count: 60)
    return (0..<count).map { index in
      var mail = Mail(id: "m\(index)", sender: "Sender \(index % 300)", senderEmail: "s\(index % 300)@example.com",
        subject: "Subject \(index) about the quarterly plan", body: paragraph,
        date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 90),
        labels: index % 3 == 0 ? ["INBOX", "UNREAD"] : index % 3 == 1 ? ["INBOX"] : ["SENT"], isBulkOrAutomated: index % 5 == 0)
      mail.threadID = "t\(index / 2)"
      return mail
    }
  }

  func testListRebuildAndAutosaveCosts() throws {
    let store = try store(Self.synthetic(4_000))
    // A full rebuild: switching the inbox tab changes the key.
    var rebuildMS = 0.0
    for round in 0..<10 {
      store.chooseInboxTab(round % 2 == 0 ? .other : .important)
      let started = Date()
      _ = store.visible
      rebuildMS += Date().timeIntervalSince(started) * 1000
    }
    print("BENCH list rebuild (4,000 emails, inbox tab): \(String(format: "%.1f", rebuildMS / 10)) ms")
    XCTAssertLessThan(rebuildMS / 10, 2_000)

    // Typing a reply: every autosave changes the mailbox, but the list must not be rebuilt.
    let open = try XCTUnwrap(store.visible.first)
    store.select(open)
    // The first letter of a reply gives the row its "Draft ready" badge, which is a real list change.
    store.saveReply(id: open.id, text: "T")
    _ = store.visible
    let before = store.visibleComputations
    let started = Date()
    for keystroke in 0..<20 {
      store.saveReply(id: open.id, text: String(repeating: "Typing a reply. ", count: keystroke + 1))
      _ = store.visible
    }
    let autosaveMS = Date().timeIntervalSince(started) * 1000 / 20
    print("BENCH autosave + list read: \(String(format: "%.2f", autosaveMS)) ms")
    XCTAssertEqual(store.visibleComputations, before, "an autosave patches the cached list instead of rebuilding it")
    XCTAssertEqual(store.visible.first?.draft, String(repeating: "Typing a reply. ", count: 20), "the list shows the current draft")
    XCTAssertEqual(store.mail(id: open.id)?.draft, String(repeating: "Typing a reply. ", count: 20))
    XCTAssertLessThan(autosaveMS, 200)

    // Clearing the draft changes the "Draft ready" badge and the Drafts folder: that rebuilds.
    store.saveReply(id: open.id, text: "")
    _ = store.visible
    XCTAssertEqual(store.visibleComputations, before + 1)
  }
}
