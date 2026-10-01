import CoveCore
import XCTest
@testable import Cove

/// The core promise of 0.1.55: a sync can't undo a change that is still on its way to Gmail, and a change
/// Gmail refuses is never re-applied, even when other changes to the same email are queued.
@MainActor final class LabelEditInFlightTests: XCTestCase {
  private func store(_ transport: HTTPTransport) throws -> AppStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    try database.save("100", key: "gmailHistoryID")
    try database.save(GmailMessage.decodingVersion, key: "mailDecodingVersion")
    return try AppStore(database: database, accountEmail: "me@example.com", gmail: GmailClient(transport: transport),
                        gmailTokenProvider: { "t" }, syncClock: Date.init)
  }
  private let mail = Mail(id: "m1", sender: "Acme", senderEmail: "a@acme.example", subject: "Invoice", body: "b",
                          labels: ["INBOX", "UNREAD"])

  func testSyncDuringAnInFlightArchiveKeepsItArchived() async throws {
    let gmail = HeldGmail()
    let store = try store(gmail)
    store.mails = [mail]
    let archive = Task { await store.archive(mail) }
    while await !gmail.modifyArrived { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(store.mails[0].labels.contains("INBOX"), "archived on screen at once")

    // Gmail hasn't applied it yet, so this sync's history still puts the email in the Inbox.
    await gmail.setHistory(.inboxAgain)
    await store.sync()
    XCTAssertFalse(store.mails[0].labels.contains("INBOX"), "the sync can't undo an archive still in flight")

    await gmail.release()
    await archive.value
    XCTAssertFalse(store.mails[0].labels.contains("INBOX"))

    // A later sync, after Gmail has it: nothing to re-apply any more, and the archive stays.
    await gmail.setHistory(.quiet)
    await store.sync()
    XCTAssertFalse(store.mails[0].labels.contains("INBOX"))
    var stale = [mail]
    store.reapplyLabelEdits(to: &stale, since: 0)
    XCTAssertTrue(stale[0].labels.contains("INBOX"), "delivered and seen by a sync: the record is gone")
  }

  func testARefusedChangeIsNotReappliedWhenAnotherIsQueued() async throws {
    let store = try store(RefuseStarGmail())
    store.mails = [mail]
    let start = store.labelEditRevision
    async let star: Void = store.modify(mail, add: ["STARRED"])
    async let archive: Void = store.modify(mail, remove: ["INBOX"])
    _ = await (star, archive)
    XCTAssertEqual(store.mails[0].labels, ["UNREAD"], "the refused star is undone, the archive stays")
    var stale = [mail]
    store.reapplyLabelEdits(to: &stale, since: start)
    XCTAssertEqual(stale[0].labels, ["UNREAD"], "only the archive is ever re-applied, never the refused star")
  }
}

private actor HeldGmail: HTTPTransport {
  enum History { case inboxAgain, quiet }
  private var history = History.quiet
  private var waiting: CheckedContinuation<Void, Never>?
  private(set) var modifyArrived = false
  private var released = false
  func setHistory(_ value: History) { history = value }
  func release() { released = true; waiting?.resume(); waiting = nil }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url!.path
    var body: [String: Any] = [:]
    if path.hasSuffix("/modify") {
      modifyArrived = true
      if !released { await withCheckedContinuation { waiting = $0 } }
      body = ["id": "m1", "labelIds": ["UNREAD"]]
    } else if path.hasSuffix("/history") {
      if history == .inboxAgain {
        let change: [String: Any] = ["message": ["id": "m1"], "labelIds": ["INBOX"]]
        body = ["historyId": "200", "history": [["labelsAdded": [change]]]]
      } else {
        body = ["historyId": "201"]
      }
    }
    let data = try JSONSerialization.data(withJSONObject: body)
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (data, response)
  }
}

private struct RefuseStarGmail: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let starring = request.httpBody.map { String(decoding: $0, as: UTF8.self).contains("STARRED") } ?? false
    return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: starring ? 400 : 200, httpVersion: nil, headerFields: nil)!)
  }
}
