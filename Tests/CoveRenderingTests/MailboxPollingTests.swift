import CoveCore
import XCTest

@testable import Cove

@MainActor
final class MailboxPollingTests: XCTestCase {
  private var directories: [URL] = []

  override func tearDown() {
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    directories = []
    super.tearDown()
  }

  private func fixture() throws -> (AppStore, Database, PollingHTTP, PollingClock) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(directory)
    let database = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    try database.save("100", key: "gmailHistoryID")
    try database.save(GmailMessage.decodingVersion, key: "mailDecodingVersion")
    let transport = PollingHTTP()
    let clock = PollingClock()
    let store = try AppStore(
      database: database, accountEmail: "me@example.com", gmail: GmailClient(transport: transport),
      gmailTokenProvider: { "fixture-token" }, syncClock: { clock.date })
    return (store, database, transport, clock)
  }

  func testPausingBackgroundSyncStillAllowsManualSyncAndResumes() async throws {
    let (store, _, transport, clock) = try fixture()
    let previous = store.backgroundSyncEnabled
    defer { store.backgroundSyncEnabled = previous }
    store.backgroundSyncEnabled = false
    await store.pollMailbox()
    let paused = await transport.historyRequests
    XCTAssertEqual(paused, 0)
    await store.sync()
    let manual = await transport.historyRequests
    XCTAssertEqual(manual, 1)
    clock.date.addTimeInterval(120)
    await store.pollMailbox()
    let stillPaused = await transport.historyRequests
    XCTAssertEqual(stillPaused, 1)
    store.backgroundSyncEnabled = true
    await store.pollMailbox()
    let resumed = await transport.historyRequests
    XCTAssertEqual(resumed, 2)
  }

  func testNewMailIsFetchedAndPersistedWithAutomaticJevDisabled() async throws {
    let (store, database, transport, clock) = try fixture()
    XCTAssertFalse(store.preferences.autoClassify)
    await store.pollMailbox()

    let message = try XCTUnwrap(store.mails.first)
    XCTAssertEqual(message.id, "new-message")
    XCTAssertEqual(message.subject, "New mail without AI")
    XCTAssertNil(message.decision)
    XCTAssertNil(store.error)
    XCTAssertEqual(store.lastSync, clock.date)
    XCTAssertEqual(try database.loadMail().first?.id, message.id)
    XCTAssertEqual(try database.load(String.self, key: "gmailHistoryID"), "101")
    let count = await transport.historyRequests
    XCTAssertEqual(count, 1)
  }

  func testManualSyncDelaysNextAutomaticCheckWithoutJev() async throws {
    let (store, _, transport, clock) = try fixture()
    await store.sync()
    clock.date.addTimeInterval(119)
    await store.pollMailbox()
    let beforeDue = await transport.historyRequests
    XCTAssertEqual(beforeDue, 1)

    clock.date.addTimeInterval(1)
    await store.pollMailbox()
    let atDue = await transport.historyRequests
    XCTAssertEqual(atDue, 2)
  }

  func testBusySampleAndDisconnectedChecksDoNotConsumeTheNextPoll() async throws {
    let (store, _, transport, _) = try fixture()
    store.syncing = true                      // a sync already running: the poll doesn't start another
    await store.pollMailbox()
    store.syncing = false
    store.isSample = true
    await store.pollMailbox()
    store.isSample = false
    store.entered = false
    await store.pollMailbox()
    let excludedCount = await transport.historyRequests
    XCTAssertEqual(excludedCount, 0)

    store.entered = true
    await store.pollMailbox()
    let connectedCount = await transport.historyRequests
    XCTAssertEqual(connectedCount, 1)
  }

  func testFailedAttemptWaitsTwoMinutesBeforeRetryingAndPreservesCursor() async throws {
    let (store, database, transport, clock) = try fixture()
    await transport.setOffline(true)
    await store.pollMailbox()
    XCTAssertNil(store.error, "Offline polling must not open an alert")
    XCTAssertNotNil(store.connectionIssue)
    XCTAssertNil(store.lastSync)
    XCTAssertEqual(try database.load(String.self, key: "gmailHistoryID"), "100")

    clock.date.addTimeInterval(30)
    await store.pollMailbox()
    let earlyCount = await transport.historyRequests
    XCTAssertEqual(earlyCount, 1)

    await transport.setOffline(false)
    clock.date.addTimeInterval(90)
    await store.pollMailbox()
    let recoveredCount = await transport.historyRequests
    XCTAssertEqual(recoveredCount, 2)
    XCTAssertNil(store.connectionIssue, "Successful retry clears the tag")
    XCTAssertEqual(store.mails.first?.id, "new-message")
  }

  func testClockMovingBackwardsDoesNotFreezePolling() async throws {
    let (store, _, transport, clock) = try fixture()
    await store.pollMailbox()
    clock.date.addTimeInterval(-3_600)
    await store.pollMailbox()
    await store.pollMailbox()
    let count = await transport.historyRequests
    XCTAssertEqual(count, 2)
  }

  func testOlderPageDoesNotDelayCheckingForNewMail() async throws {
    let (store, _, transport, clock) = try fixture()
    await store.pollMailbox()
    clock.date.addTimeInterval(119)
    store.nextPage = "older-page"
    await store.sync(older: true)
    clock.date.addTimeInterval(1)
    await store.pollMailbox()
    let count = await transport.historyRequests
    XCTAssertEqual(count, 2)
    let olderPages = await transport.olderPages
    XCTAssertEqual(olderPages, 1)
  }
}

private final class PollingClock {
  var date = Date(timeIntervalSince1970: 2_000_000_000)
}

private actor PollingHTTP: HTTPTransport {
  private(set) var historyRequests = 0
  private(set) var olderPages = 0
  private var offline = false
  func setOffline(_ value: Bool) { offline = value }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try XCTUnwrap(request.url)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    let response: [String: Any]
    switch url.lastPathComponent {
    case "history":
      historyRequests += 1
      if offline { throw URLError(.notConnectedToInternet) }
      response = historyRequests == 1 || historyRequests == 2
        ? ["historyId": "101", "history": [["messagesAdded": [["message": ["id": "new-message"]]]]]]
        : ["historyId": "101"]
    case "new-message":
      response = [
        "id": "new-message", "threadId": "new-thread", "labelIds": ["INBOX", "UNREAD"],
        "payload": ["headers": [["name": "Subject", "value": "New mail without AI"]]],
      ]
    case "messages":
      olderPages += 1
      XCTAssertEqual(
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
          $0.name == "pageToken"
        }?.value, "older-page")
      response = ["messages": []]
    default:
      XCTFail("Unexpected Gmail endpoint: \(url.path)")
      throw URLError(.badURL)
    }
    return (
      try JSONSerialization.data(withJSONObject: response),
      try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    )
  }
}
