import CoveCore
import XCTest
@testable import Cove

@MainActor final class MailSearchSpeedTests: XCTestCase {
  private func store(_ count: Int) throws -> AppStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveSpeed-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(database: Database(url: root.appendingPathComponent("m.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "x" }, syncClock: Date.init)
    let body = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor. ", count: 60)
    store.mails = (0..<count).map { Mail(id: "m\($0)", sender: "Sender \($0 % 300)", senderEmail: "s\($0 % 300)@example.com",
      subject: "Subject number \($0)", body: body + ($0 % 97 == 0 ? " Renovación trimestral" : ""), date: Date(timeIntervalSince1970: Double($0)),
      labels: ["INBOX"]) }
    store.chooseFolder("Inbox")
    return store
  }

  func testSearchIsAccentAndCaseInsensitiveAndMatchesWordsInAnyOrder() throws {
    let store = try store(300)
    for query in ["renovacion", "RENOVACIÓN", "trimestral renovación", "s5@example.com"] {
      store.search = query
      XCTAssertFalse(store.visible.isEmpty, query)
    }
    store.search = "renovacion"
    XCTAssertEqual(store.visible.count, 4)
    store.search = "renovacion missingword"
    XCTAssertTrue(store.visible.isEmpty)
  }

  func testVisibleIsComputedOncePerStateAndFastOnFiveThousandEmails() throws {
    let store = try store(5_000)
    store.search = ""
    _ = store.visible
    var timings: [String] = []
    for term in ["q", "qu", "renov", "renovacion", "renovacion trimestral"] {
      store.search = term
      let before = store.visibleComputations
      let start = CFAbsoluteTimeGetCurrent()
      let first = store.visible
      for _ in 0..<5 { XCTAssertEqual(store.visible.count, first.count) }
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      XCTAssertEqual(store.visibleComputations - before, 1, "one filter pass per keystroke state")
      timings.append("'\(term)' \(first.count) results \(String(format: "%.1f", ms)) ms")
    }
    print("SEARCH TIMINGS (6 reads each): " + timings.joined(separator: " · "))
    // Changing mail invalidates the cache.
    let before = store.visibleComputations
    store.mails[0].subject = "Renovación trimestral"
    _ = store.visible
    XCTAssertEqual(store.visibleComputations - before, 1)
  }
}
