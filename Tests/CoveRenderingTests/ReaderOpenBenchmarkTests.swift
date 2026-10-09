import CoveCore
import XCTest
@testable import Cove

/// S6: what opening one email costs the mailbox. Every change to `mails` redraws every view observing the
/// store (list, reader, Home), so the reader's open sequence should change it as few times as it can.
/// Prints a BENCH line the speed audit quotes.
@MainActor final class ReaderOpenBenchmarkTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

  /// A newsletter stored by an older Cove (no unsubscribe headers kept), with two earlier messages of its
  /// conversation stored but not loaded, opened unread: the reader's whole open sequence, in its order.
  func testOpeningAnEmailChangesTheMailboxAsFewTimesAsPossible() async throws {
    // SwiftUI doesn't promise whether the reader's onAppear or its conversation's task runs first.
    let readFirst = try await open(conversationFirst: false)
    let conversationFirst = try await open(conversationFirst: true)
    XCTAssertLessThanOrEqual(readFirst, 2)
    XCTAssertLessThanOrEqual(conversationFirst, 3)
  }

  private func open(conversationFirst: Bool) async throws -> Int {
    let gmail = OpenHTTP()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoveOpen-" + UUID().uuidString)
    directories.append(directory)
    let database = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    let conversation = try await GmailClient(transport: gmail).thread(id: "t1", token: "x")
    var anchor = try XCTUnwrap(conversation.first { $0.id == "n3" })
    anchor.unsubscribe = nil
    try database.saveMessage(anchor)
    try database.save("100", key: "gmailHistoryID")
    try database.save(GmailMessage.decodingVersion, key: "mailDecodingVersion")
    let store = try AppStore(database: database, accountEmail: "me@example.com", gmail: GmailClient(transport: gmail),
                             gmailTokenProvider: { "x" }, syncClock: Date.init)
    try database.storeArchived(conversation.filter { $0.id != "n3" })
    XCTAssertEqual(store.mails.map(\.id), ["n3"])
    store.screen = "mail"
    store.select(anchor)
    await gmail.resetCount()

    let before = store.mailsRevision
    // ReaderView.onAppear, ReaderView .task(id:), ReaderConversation .task.
    let thread = conversationFirst ? Task { store.includeStoredThread(of: anchor); try? await store.refreshReaderThread(anchor) } : nil
    let read = Task { await store.markViewed(anchor) }
    let tasks = Task { await store.checkForTasks(anchor) }
    let unsubscribe = Task { await store.loadUnsubscribeIfNeeded(for: anchor) }
    let later = conversationFirst ? nil : Task { store.includeStoredThread(of: anchor); try? await store.refreshReaderThread(anchor) }
    await thread?.value; await later?.value
    await read.value; await tasks.value; await unsubscribe.value
    await store.awaitLabelDeliveries()
    let changes = store.mailsRevision - before
    let requests = await gmail.requests
    print("BENCH open an email (unread newsletter, 2 stored thread messages, \(conversationFirst ? "conversation" : "reader") first): \(changes) mailbox changes, \(requests.count) Gmail requests \(requests)")

    let opened = try XCTUnwrap(store.mails.first { $0.id == "n3" })
    XCTAssertFalse(opened.isUnread)
    XCTAssertNotNil(opened.unsubscribe, "the unsubscribe option is known after opening")
    XCTAssertEqual(Set(store.mails.map(\.id)), ["n1", "n2", "n3"], "the whole stored conversation is loaded")
    return changes
  }
}

private actor OpenHTTP: HTTPTransport {
  private(set) var requests: [String] = []
  func resetCount() { requests = [] }
  private static func message(_ id: String, minutes: Double, unread: Bool) -> [String: Any] {
    let body = Data("Issue \(id): this week's notes.".utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return [
      "id": id, "threadId": "t1", "internalDate": String(Int64((1_700_000_000 + minutes * 60) * 1000)),
      "labelIds": unread ? ["INBOX", "UNREAD"] : ["INBOX"],
      "payload": [
        "mimeType": "text/plain",
        "headers": [["name": "Subject", "value": "Weekly notes"], ["name": "From", "value": "News <news@list.example>"],
                    ["name": "List-ID", "value": "<weekly.list.example>"],
                    ["name": "List-Unsubscribe", "value": "<https://list.example/u>"],
                    ["name": "List-Unsubscribe-Post", "value": "List-Unsubscribe=One-Click"]],
        "body": ["data": body],
      ],
    ]
  }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    requests.append(url.pathComponents.suffix(2).joined(separator: "/"))
    let body: [String: Any]
    if url.path.contains("/threads/") {
      body = ["id": "t1", "messages": [Self.message("n1", minutes: 0, unread: false), Self.message("n2", minutes: 10, unread: false),
                                       Self.message("n3", minutes: 20, unread: true)]]
    } else if url.lastPathComponent == "modify" {
      body = ["id": "n3"]
    } else if url.lastPathComponent == "n3" {
      body = ["id": "n3", "payload": ["headers": [["name": "List-Unsubscribe", "value": "<https://list.example/u>"],
                                                   ["name": "List-Unsubscribe-Post", "value": "List-Unsubscribe=One-Click"]]]]
    } else {
      XCTFail("Unexpected endpoint \(url.path)"); throw URLError(.badURL)
    }
    return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
