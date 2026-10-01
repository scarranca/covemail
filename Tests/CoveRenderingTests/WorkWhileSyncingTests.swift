import XCTest
@testable import Cove
@testable import CoveCore

/// Actions stay available during a sync, and a sync that read Gmail before the action can't undo it.
@MainActor final class WorkWhileSyncingTests: XCTestCase {
  private func store() throws -> AppStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = try AppStore(database: Database(url: directory.appendingPathComponent("mail.sqlite")),
      accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "t" }, syncClock: Date.init)
    store.isSample = true
    return store
  }

  func testArchiveDuringSyncIsInstantAndASyncResultCantUndoIt() async throws {
    let store = try store()
    let mail = Mail(id: "m1", sender: "Acme", senderEmail: "a@acme.example", subject: "Invoice", body: "b", labels: ["INBOX", "UNREAD"])
    store.mails = [mail]
    store.syncing = true                                   // a long catch-up is running
    let syncStarted = store.labelEditRevision
    await store.archive(mail)
    XCTAssertFalse(store.busy, "archiving doesn't lock the app")
    XCTAssertEqual(store.mails.first?.labels, ["UNREAD"], "the change shows at once")

    // The sync read Gmail before the archive, so its copy still says INBOX.
    var stale = [mail]
    store.reapplyLabelEdits(to: &stale, since: syncStarted)
    XCTAssertEqual(stale.first?.labels, ["UNREAD"], "the user's archive wins over the older sync result")

    // A later sync, started after Gmail had the change, no longer needs it re-applied.
    store.pruneLabelEdits(through: store.labelEditRevision)
    var fresh = [mail]
    store.reapplyLabelEdits(to: &fresh, since: store.labelEditRevision)
    XCTAssertEqual(fresh.first?.labels, ["INBOX", "UNREAD"], "nothing left to re-apply once Gmail has it")
  }

  func testLaterChangesToTheSameEmailWinInOrder() async throws {
    let store = try store()
    let mail = Mail(id: "m1", sender: "Acme", senderEmail: "a@acme.example", subject: "Invoice", body: "b", labels: ["INBOX"])
    store.mails = [mail]
    let start = store.labelEditRevision
    await store.modify(mail, add: ["STARRED"])
    await store.modify(mail, remove: ["STARRED"])
    await store.modify(mail, add: ["Label_9"])
    var stale = [mail]
    store.reapplyLabelEdits(to: &stale, since: start)
    XCTAssertEqual(stale.first?.labels, ["INBOX", "Label_9"])
    XCTAssertEqual(store.mails.first?.labels, ["INBOX", "Label_9"])
  }

  func testWhenGmailRefusesOnlyThatChangeIsUndone() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AppStore(database: Database(url: directory.appendingPathComponent("mail.sqlite")),
      accountEmail: "me@example.com", gmail: GmailClient(transport: RefusingHTTP()), gmailTokenProvider: { "t" }, syncClock: Date.init)
    let mail = Mail(id: "m1", sender: "Acme", senderEmail: "a@acme.example", subject: "Invoice", body: "b", labels: ["INBOX", "STARRED"])
    store.mails = [mail]
    let start = store.labelEditRevision
    await store.archive(mail)
    XCTAssertEqual(store.mails.first?.labels, ["INBOX", "STARRED"], "back as it was")
    XCTAssertNotNil(store.error, "the user is told")
    var stale = [mail]
    stale[0].labels = ["INBOX"]
    store.reapplyLabelEdits(to: &stale, since: start)
    XCTAssertEqual(stale.first?.labels, ["INBOX"], "a refused change is never re-applied over a sync")
  }
}

private struct RefusingHTTP: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
  }
}
