import XCTest
import CoveCore
@testable import Cove

/// Sign-in codes on the Mac: only fresh arrivals, once each, never the user's own or older mail.
@MainActor final class SignInCodeNoticeTests: XCTestCase {
  func testAnnouncesAFreshCodeOnceInTheMenuBarAndANotification() throws {
    let now = Date()
    let db = try Database(url: FileManager.default.temporaryDirectory.appendingPathComponent("CoveCodes-" + UUID().uuidString + "/test.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: BackfillHTTP()),
                             gmailTokenProvider: { "test-token" }, syncClock: { now })
    let notifier = RecordingNotifier()
    store.agentNotifier = notifier
    let menuBar = SignInCodeMenuBar.shared
    menuBar.installsStatusItem = false
    defer { menuBar.clear() }
    func code(_ id: String, minutesAgo: Double, from email: String = "no-reply@linear.example", digits: String) -> Mail {
      Mail(id: id, threadID: id, sender: "Linear", senderEmail: email, subject: "Your Linear sign-in code",
           body: "Enter this code to sign in: \(digits)", date: now.addingTimeInterval(-minutesAgo * 60), labels: ["INBOX", "UNREAD"])
    }
    store.announceSignInCodes(in: [code("old", minutesAgo: 40, digits: "111222"), code("mine", minutesAgo: 1, from: "me@example.com", digits: "333444")])
    XCTAssertEqual(notifier.codes, [], "an expired code and the user's own email are never announced")
    XCTAssertNil(menuBar.current)

    store.announceSignInCodes(in: [code("a", minutesAgo: 3, digits: "482913"), code("b", minutesAgo: 1, digits: "905114")])
    XCTAssertEqual(notifier.codes, ["905114"], "the newest code wins")
    XCTAssertEqual(menuBar.current?.code, "905114")
    store.announceSignInCodes(in: [code("b", minutesAgo: 1, digits: "905114")])
    XCTAssertEqual(notifier.codes, ["905114"], "a code is offered once")
  }
}
