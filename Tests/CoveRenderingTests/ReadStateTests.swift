import CoveCore
import XCTest

@testable import Cove

@MainActor
final class ReadStateTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() {
    directories.forEach { try? FileManager.default.removeItem(at: $0) }
    super.tearDown()
  }
  private func fixture() throws -> (AppStore, Database, ReadStateHTTP, Mail) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(directory)
    let database = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    let mail = Mail(id: "opened", sender: "Fixture", senderEmail: "sender@example.com", subject: "Read me", body: "Fixture")
    try database.saveMessage(mail)
    try database.save("100", key: "gmailHistoryID")
    try database.save(GmailMessage.decodingVersion, key: "mailDecodingVersion")
    let transport = ReadStateHTTP()
    let store = try AppStore(database: database, accountEmail: "me@example.com",
      gmail: GmailClient(transport: transport), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    return (store, database, transport, mail)
  }

  func testOpeningPersistsReadAndUpdatesGmailEvenDuringAnotherOperation() async throws {
    let (store, database, transport, mail) = try fixture()
    store.busy = true
    await store.markViewed(mail)
    XCTAssertFalse(try XCTUnwrap(store.mails.first).isUnread)
    XCTAssertFalse(try XCTUnwrap(database.loadMail().first).isUnread)
    let requests = await transport.modifications
    XCTAssertEqual(requests, [["addLabelIds": [], "removeLabelIds": ["UNREAD"]]])
    await store.markViewed(mail)
    let repeats = await transport.modifications.count
    XCTAssertEqual(repeats, 1, "Reopening a read message must not make another Gmail request")
  }

  func testOfflineReadStaysReadAndReachesGmailWhenTheConnectionIsBack() async throws {
    let (store, database, transport, mail) = try fixture()
    store.labelRetryDelays = [.seconds(60)]
    await transport.setOffline(true)
    await store.markViewed(mail)
    XCTAssertFalse(try XCTUnwrap(store.mails.first).isUnread, "offline, the email stays read")
    XCTAssertFalse(try XCTUnwrap(database.loadMail().first).isUnread)
    XCTAssertNil(store.error)
    XCTAssertEqual(store.connectionIssue?.operation, "Marking email as read…")
    XCTAssertEqual(store.pendingLabelChanges, 1)
    // Back online, a sync whose history still says UNREAD neither undoes it nor waits for the retry timer.
    await transport.setOffline(false)
    await store.sync(interactive: false)
    await store.awaitLabelDeliveries()
    XCTAssertFalse(try XCTUnwrap(store.mails.first).isUnread)
    let requests = await transport.modifications
    XCTAssertEqual(requests.count, 2, "one failed attempt, one delivery")
    XCTAssertEqual(store.pendingLabelChanges, 0)
    XCTAssertNil(store.connectionIssue)
  }

  func testSampleOpeningStaysLocalAndExplicitMarkUnreadIsPreserved() async throws {
    let (store, database, transport, mail) = try fixture()
    store.isSample = true
    await store.markViewed(mail)
    XCTAssertFalse(try XCTUnwrap(database.loadMail().first).isUnread)
    let requests = await transport.modifications.count
    XCTAssertEqual(requests, 0)
    await store.modify(mail, add: ["UNREAD"])
    XCTAssertTrue(try XCTUnwrap(store.mails.first).isUnread)
  }

  func testStaleSyncCannotRestoreUnreadAfterOpening() async throws {
    let (store, database, transport, mail) = try fixture()
    await transport.pauseHistory()
    let sync = Task { await store.sync() }
    for _ in 0..<100 {
      if await transport.historyStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let started = await transport.historyStarted
    XCTAssertTrue(started)
    await store.markViewed(mail)
    await transport.releaseHistory()
    await sync.value
    XCTAssertFalse(try XCTUnwrap(store.mails.first).isUnread)
    XCTAssertFalse(try XCTUnwrap(database.loadMail().first).isUnread)
  }

  func testSyncStartedDuringPendingReadDoesNotUndoItsCompletedUpdate() async throws {
    let (store, _, transport, mail) = try fixture()
    await transport.pauseModification()
    let opening = Task { await store.markViewed(mail) }
    for _ in 0..<100 {
      if await transport.modifications.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    await transport.pauseHistory()
    let sync = Task { await store.sync() }
    for _ in 0..<100 {
      if await transport.historyStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    await transport.releaseModification()
    await opening.value
    await transport.releaseHistory()
    await sync.value
    XCTAssertFalse(try XCTUnwrap(store.mails.first).isUnread)
  }

  func testMarkUnreadWaitsForOpeningAndWinsTheRemoteUpdateOrder() async throws {
    let (store, database, transport, mail) = try fixture()
    await transport.pauseModification()
    let opening = Task { await store.markViewed(mail) }
    for _ in 0..<100 {
      if await transport.modifications.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let markUnread = Task { await store.modify(mail, add: ["UNREAD"]) }
    await transport.releaseModification()
    await opening.value
    await markUnread.value
    XCTAssertTrue(try XCTUnwrap(store.mails.first).isUnread)
    XCTAssertTrue(try XCTUnwrap(database.loadMail().first).isUnread)
    let requests = await transport.modifications
    XCTAssertEqual(requests.map { $0["removeLabelIds"] }, [["UNREAD"], []])
    XCTAssertEqual(requests.map { $0["addLabelIds"] }, [[], ["UNREAD"]])
  }

  func testSwitchingMailboxWhileMarkReadIsInFlightDoesNotChangeNewMailbox() async throws {
    let (store, _, transport, mail) = try fixture()
    await transport.pauseModification()
    let opening = Task { await store.markViewed(mail) }
    for _ in 0..<100 {
      if await transport.modifications.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    // Skip actual OAuth/Keychain access in this synthetic lifecycle exercise.
    store.isSample = true
    store.disconnect()
    store.mails = [mail]
    await transport.setOffline(true)
    await transport.releaseModification()
    await opening.value
    XCTAssertTrue(try XCTUnwrap(store.mails.first).isUnread)
    XCTAssertNil(store.error)
    XCTAssertFalse(store.entered)
  }

  func testDisconnectedReaderDoesNotTouchMessagesOrNetwork() async throws {
    let (store, _, transport, mail) = try fixture()
    store.entered = false
    await store.markViewed(mail)
    XCTAssertTrue(try XCTUnwrap(store.mails.first).isUnread)
    let requests = await transport.modifications.count
    XCTAssertEqual(requests, 0)
  }
}

private actor ReadStateHTTP: HTTPTransport {
  var modifications: [[String: [String]]] = []
  var historyStarted = false
  private var modificationContinuation: CheckedContinuation<Void, Never>?
  private var shouldPauseModification = false
  func pauseModification() { shouldPauseModification = true }
  func releaseModification() {
    shouldPauseModification = false
    modificationContinuation?.resume()
    modificationContinuation = nil
  }
  private var offline = false
  private var shouldPauseHistory = false
  private var historyContinuation: CheckedContinuation<Void, Never>?
  func setOffline(_ value: Bool) { offline = value }
  func pauseHistory() { shouldPauseHistory = true }
  func releaseHistory() { historyContinuation?.resume(); historyContinuation = nil }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try XCTUnwrap(request.url)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
    var response: [String: Any] = [:]
    switch url.lastPathComponent {
    case "modify":
      XCTAssertEqual(request.httpMethod, "POST")
      let body = try XCTUnwrap(request.httpBody)
      modifications.append(try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]]))
      if shouldPauseModification { await withCheckedContinuation { modificationContinuation = $0 } }
      if offline { throw URLError(.notConnectedToInternet) }
    case "history":
      historyStarted = true
      if shouldPauseHistory { await withCheckedContinuation { historyContinuation = $0 } }
      response = ["historyId": "101", "history": [["labelsAdded": [["message": ["id": "opened"], "labelIds": ["UNREAD"]]]]]]
    case "opened":
      response = ["id": "opened", "threadId": "thread", "labelIds": ["INBOX", "UNREAD"],
        "payload": ["headers": [["name": "Subject", "value": "Read me"]]]]
    default:
      XCTFail("Unexpected endpoint: \(url.path)")
      throw URLError(.badURL)
    }
    return (try JSONSerialization.data(withJSONObject: response),
      try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}
