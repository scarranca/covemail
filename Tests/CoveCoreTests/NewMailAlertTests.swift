import XCTest
@testable import CoveCore

final class NewMailAlertTests: XCTestCase {
  private func mail(_ sender: String = "Maya Chen", _ email: String = "maya@studio.example", labels: Set<String> = ["INBOX", "UNREAD"],
                    bulk: Bool = false) -> Mail {
    Mail(id: "m1", threadID: "t1", sender: sender, senderEmail: email, subject: "Final sign-off", body: "Private body text",
         labels: labels, isBulkOrAutomated: bulk)
  }

  func testShowsSenderAndSubjectNeverBody() throws {
    let alert = try XCTUnwrap(NewMailAlert.make(for: mail(), accountEmail: "me@example.com", scope: .inbox, showPreview: true))
    XCTAssertEqual(alert.title, "Maya Chen")
    XCTAssertEqual(alert.body, "Final sign-off")
    XCTAssertFalse(alert.title.contains("Private") || alert.body.contains("Private") || alert.subtitle.contains("Private"))
    XCTAssertEqual(alert.mailID, "m1")
    XCTAssertEqual(alert.threadID, "t1")
  }

  func testHiddenPreviewNamesNobody() throws {
    let alert = try XCTUnwrap(NewMailAlert.make(for: mail(), accountEmail: "me@example.com", scope: .inbox, showPreview: false))
    XCTAssertEqual(alert.title, "New email")
    XCTAssertFalse(alert.body.contains("Maya") || alert.body.contains("sign-off"))
  }

  func testSkipsOwnReadMutedAndNonInboxMail() {
    XCTAssertNil(NewMailAlert.make(for: mail("Me", "Me@Example.com"), accountEmail: "me@example.com", scope: .inbox, showPreview: true))
    XCTAssertNil(NewMailAlert.make(for: mail(labels: ["INBOX"]), accountEmail: "me@example.com", scope: .inbox, showPreview: true))
    XCTAssertNil(NewMailAlert.make(for: mail(labels: ["UNREAD"]), accountEmail: "me@example.com", scope: .inbox, showPreview: true))
    XCTAssertNil(NewMailAlert.make(for: mail(labels: ["INBOX", "UNREAD", "SPAM"]), accountEmail: "me@example.com", scope: .inbox, showPreview: true))
    XCTAssertNil(NewMailAlert.make(for: mail(), accountEmail: "me@example.com", scope: .inbox, showPreview: true, muted: ["maya@studio.example"]))
  }

  func testImportantOnlyFollowsInboxSplitUnlessAlwaysNotify() {
    let newsletter = mail("Weekly", "news@letter.example", bulk: true)
    XCTAssertNil(NewMailAlert.make(for: newsletter, accountEmail: "me@example.com", scope: .important, showPreview: true))
    XCTAssertNotNil(NewMailAlert.make(for: newsletter, accountEmail: "me@example.com", scope: .inbox, showPreview: true))
    XCTAssertNotNil(NewMailAlert.make(for: newsletter, accountEmail: "me@example.com", scope: .important, showPreview: true,
                                      important: ["news@letter.example"]))
  }

  func testWatchRenewsOnlyNearExpiryAndKeepsTheCursor() async throws {
    let settings = PushSettings(defaults: UserDefaults(suiteName: "cove-watch-test-\(UUID().uuidString)")!)
    settings.enabled = true
    settings.cursor = "500"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calls = 0
    let fake: (String) async throws -> GmailPush.Watch = { _ in
      calls += 1
      return GmailPush.Watch(historyId: "900", expiration: String(Int((now.timeIntervalSince1970 + 7 * 86_400) * 1000)))
    }
    settings.watchExpires = now.addingTimeInterval(5 * 86_400)
    let early = try await GmailPush.renewIfNeeded(token: "t", settings: settings, now: now, watch: fake)
    XCTAssertFalse(early)
    XCTAssertEqual(calls, 0)
    settings.watchExpires = now.addingTimeInterval(2 * 86_400)
    let due = try await GmailPush.renewIfNeeded(token: "t", settings: settings, now: now, watch: fake)
    XCTAssertTrue(due)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(settings.cursor, "500", "renewing never moves the cursor past unnotified mail")
    XCTAssertEqual(settings.watchExpires, now.addingTimeInterval(7 * 86_400))
    settings.enabled = false
    settings.watchExpires = nil
    let off = try await GmailPush.renewIfNeeded(token: "t", settings: settings, now: now, watch: fake)
    XCTAssertFalse(off)
  }
}
