import CoveCore
import XCTest
@testable import Cove

/// 0.1.69 (E1–E4): a label change made offline stays made and reaches Gmail later, even across a quit;
/// Gmail's definitive answers are handled once and quietly where they can be; background failures never
/// turn into an alert every two minutes.
@MainActor final class DurableLabelEditTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

  private let mail = Mail(id: "m1", sender: "Acme", senderEmail: "a@acme.example", subject: "Invoice", body: "b",
                          labels: ["INBOX"])

  private func databaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoveDurable-" + UUID().uuidString)
    directories.append(directory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("mail.sqlite")
  }
  private func store(_ gmail: ScriptedGmail, url: URL? = nil, seed: Bool = true, clock: TestClock = TestClock(),
                     token: @escaping () async throws -> String = { "t" }) throws -> (AppStore, Database) {
    let url = url ?? databaseURL()
    let database = try Database(url: url)
    if seed {
      try database.saveMessage(mail)
      try database.save("100", key: "gmailHistoryID")
      try database.save(GmailMessage.decodingVersion, key: "mailDecodingVersion")
    }
    let store = try AppStore(database: database, accountEmail: "me@example.com", gmail: GmailClient(transport: gmail),
                             gmailTokenProvider: token, syncClock: { clock.date })
    store.labelRetryDelays = [.seconds(600)]
    return (store, database)
  }
  private func current(_ store: AppStore) -> Mail? { store.mails.first { $0.id == "m1" } }

  // MARK: E1

  func testOfflineArchiveStaysArchivedAndIsDeliveredWhenTheConnectionIsBack() async throws {
    let gmail = ScriptedGmail()
    let (store, database) = try store(gmail)
    await gmail.set(offline: true)
    await store.archive(mail)
    XCTAssertEqual(current(store)?.labels, [], "archived at once, and it stays archived offline")
    XCTAssertEqual(try database.loadMail().first?.labels, [])
    XCTAssertNil(store.error, "offline is not an error")
    XCTAssertEqual(store.connectionIssue?.offline, true)
    XCTAssertEqual(store.pendingLabelChanges, 1)
    XCTAssertEqual(try database.load([QueuedLabelChange].self, key: AppStore.labelQueueKey)?.count, 1, "saved with the mailbox")

    // Still offline: the two-minute check fails quietly and the archive survives a stale result later.
    await store.sync(interactive: false)
    XCTAssertEqual(current(store)?.labels, [])

    await gmail.set(offline: false)
    await gmail.set(history: .inboxAgain)            // Gmail hasn't got it yet: history still says INBOX
    await store.sync(interactive: false)
    await store.awaitLabelDeliveries()
    XCTAssertEqual(current(store)?.labels, [], "a sync can't undo a change still waiting for Gmail")
    let modifies = await gmail.modifies
    XCTAssertEqual(modifies.count, 2, "one failed attempt, then delivered after the sync proved the connection")
    XCTAssertEqual(modifies.last?.remove, ["INBOX"])
    XCTAssertEqual(store.pendingLabelChanges, 0)
    XCTAssertNil(store.connectionIssue)
    XCTAssertNil(try database.load([QueuedLabelChange].self, key: AppStore.labelQueueKey))
  }

  func testTheRetryTimerDeliversWithoutWaitingForASync() async throws {
    let gmail = ScriptedGmail()
    let (store, _) = try store(gmail)
    store.labelRetryDelays = [.milliseconds(50)]
    await gmail.set(offline: true)
    await store.modify(mail, add: ["STARRED"])
    await gmail.set(offline: false)
    for _ in 0..<100 where store.pendingLabelChanges > 0 { try await Task.sleep(for: .milliseconds(20)) }
    await store.awaitLabelDeliveries()
    XCTAssertEqual(store.pendingLabelChanges, 0)
    XCTAssertEqual(current(store)?.labels, ["INBOX", "STARRED"])
  }

  func testQueuedChangesSurviveQuittingAndAreSentWhenTheMailboxOpensAgain() async throws {
    let gmail = ScriptedGmail()
    let url = databaseURL()
    let (first, _) = try store(gmail, url: url)
    await gmail.set(offline: true)
    await first.archive(mail)
    await first.modify(mail, add: ["STARRED"])
    XCTAssertEqual(first.pendingLabelChanges, 2)

    // "Quit" and open the same mailbox again, still offline: the changes are back, in order.
    let (second, database) = try store(gmail, url: url, seed: false)
    await second.awaitLabelDeliveries()
    XCTAssertEqual(second.pendingLabelChanges, 2)
    XCTAssertEqual(current(second)?.labels, ["STARRED"], "saved with the change applied")

    await gmail.set(offline: false)
    await gmail.set(history: .inboxAgain)
    await second.sync(interactive: false)
    await second.awaitLabelDeliveries()
    XCTAssertEqual(current(second)?.labels, ["STARRED"], "replayed changes are protected from a stale sync too")
    XCTAssertEqual(second.pendingLabelChanges, 0)
    let delivered = await gmail.modifies.suffix(2).map(\.body)
    XCTAssertEqual(delivered, [["addLabelIds": [], "removeLabelIds": ["INBOX"]], ["addLabelIds": ["STARRED"], "removeLabelIds": []]],
                   "delivered in the order the user made them")
    XCTAssertNil(try database.load([QueuedLabelChange].self, key: AppStore.labelQueueKey))
  }

  func testUndoOfAnArchiveWaitingOfflineCancelsItWithoutWaitingForGmail() async throws {
    let gmail = ScriptedGmail()
    let (store, database) = try store(gmail)
    await gmail.set(offline: true)
    let start = store.labelEditRevision
    await store.archive(mail)
    XCTAssertNotNil(store.triageUndo)
    let started = Date()
    await store.undoLastTriage()
    XCTAssertLessThan(Date().timeIntervalSince(started), 1, "Undo doesn't wait for the connection")
    XCTAssertEqual(current(store)?.labels, ["INBOX"])
    XCTAssertEqual(store.pendingLabelChanges, 0, "nothing is left to send")
    XCTAssertNil(try database.load([QueuedLabelChange].self, key: AppStore.labelQueueKey))
    var stale = [mail]; stale[0].labels = []
    store.reapplyLabelEdits(to: &stale, since: start)
    XCTAssertEqual(stale[0].labels, [], "neither the archive nor its undo is re-applied over a sync")

    await gmail.set(offline: false)
    await store.sync(interactive: false)
    await store.awaitLabelDeliveries()
    let modifies = await gmail.modifies.count
    XCTAssertEqual(modifies, 1, "only the first (failed) attempt ever went out")
  }

  func testUndoAfterATimeoutIsSentRatherThanCancelled() async throws {
    let gmail = ScriptedGmail()
    let (store, _) = try store(gmail)
    await gmail.set(modifyFailure: .timedOut)        // the archive may have reached Gmail
    await store.archive(mail)
    XCTAssertEqual(store.pendingLabelChanges, 1)
    await store.undoLastTriage()
    XCTAssertEqual(current(store)?.labels, ["INBOX"])
    XCTAssertEqual(store.pendingLabelChanges, 2, "the reversal is queued after it, so Gmail ends where the user did")
    await gmail.set(modifyFailure: nil)
    store.retryQueuedLabelChanges()
    await store.awaitLabelDeliveries()
    let sent = await gmail.modifies.suffix(2).map(\.body)
    XCTAssertEqual(sent, [["addLabelIds": [], "removeLabelIds": ["INBOX"]], ["addLabelIds": ["INBOX"], "removeLabelIds": []]])
    XCTAssertEqual(current(store)?.labels, ["INBOX"])
  }

  func testATokenThatCantBeReadRightNowKeepsTheChange() async throws {
    let gmail = ScriptedGmail()
    var locked = true
    let (store, _) = try store(gmail) {
      if locked { throw CoveError.message("Keychain could not be read (-25308).") }
      return "t"
    }
    await store.archive(mail)
    XCTAssertEqual(current(store)?.labels, [], "nothing reached Gmail, so nothing is undone")
    XCTAssertEqual(store.pendingLabelChanges, 1)
    XCTAssertNil(store.error)
    XCTAssertFalse(store.googleSignInNeeded, "a locked Keychain isn't a revoked sign-in")
    locked = false
    store.retryQueuedLabelChanges()
    await store.awaitLabelDeliveries()
    XCTAssertEqual(store.pendingLabelChanges, 0)
  }

  func testAPageLoadsOfflineTagClearsWhenGmailAnswersAgain() async throws {
    let gmail = ScriptedGmail()
    let (store, _) = try store(gmail)
    store.gmailLabels = [GmailLabel(id: "finance", name: "Finance", type: "user")]
    store.chooseFolder("label:finance")
    await gmail.set(offline: true)
    await store.loadLabelMail()
    XCTAssertNotNil(store.connectionIssue)
    XCTAssertNil(store.error)
    await gmail.set(offline: false)
    await store.loadLabelMail()
    XCTAssertNil(store.connectionIssue, "a successful Gmail answer clears the stale tag")
  }

  // MARK: E2 and definitive answers

  func testAnEmailDeletedInGmailIsRemovedQuietly() async throws {
    let gmail = ScriptedGmail()
    let (store, database) = try store(gmail)
    await gmail.set(modifyStatus: 404)
    await store.archive(mail)
    XCTAssertNil(current(store), "gone from the list")
    XCTAssertTrue(try database.loadMail().isEmpty, "and from this Mac")
    XCTAssertNil(store.error, "no alert for an email deleted elsewhere")
    XCTAssertEqual(store.pendingLabelChanges, 0)
  }

  func testADefinitiveRefusalRevertsOnlyThatChangeAndSaysSo() async throws {
    let gmail = ScriptedGmail()
    let (store, database) = try store(gmail)
    await gmail.set(modifyStatus: 400)
    await store.archive(mail)
    XCTAssertEqual(current(store)?.labels, ["INBOX"], "back as it was")
    XCTAssertEqual(try database.loadMail().first?.labels, ["INBOX"])
    XCTAssertTrue(store.error?.contains("back as it was") == true)
    XCTAssertEqual(store.pendingLabelChanges, 0)
    XCTAssertNil(try database.load([QueuedLabelChange].self, key: AppStore.labelQueueKey))
  }

  func testAServerErrorOnAWriteIsNeverRetried() async throws {
    let gmail = ScriptedGmail()
    let (store, _) = try store(gmail)
    store.labelRetryDelays = [.milliseconds(20)]
    await gmail.set(modifyStatus: 503)
    await store.archive(mail)
    try await Task.sleep(for: .milliseconds(150))
    let modifies = await gmail.modifies.count
    XCTAssertEqual(modifies, 1, "a label change that failed on Gmail's side is never sent again automatically")
    XCTAssertEqual(current(store)?.labels, ["INBOX"])
    XCTAssertNotNil(store.error, "the user acted just now, so they are told")
  }

  func testA401GetsOneFreshTokenAndRetries() async throws {
    let gmail = ScriptedGmail()
    let (store, _) = try store(gmail)
    await gmail.set(rejectedTokens: ["t"])
    var refreshes = 0
    store.gmailTokenRefresh = { refreshes += 1; return "fresh" }
    await store.archive(mail)
    XCTAssertEqual(refreshes, 1)
    let tokens = await gmail.modifies.map(\.token)
    XCTAssertEqual(tokens, ["t", "fresh"])
    XCTAssertEqual(current(store)?.labels, [])
    XCTAssertEqual(store.pendingLabelChanges, 0)
    XCTAssertFalse(store.googleSignInNeeded)
  }

  func testARevokedSignInKeepsTheChangeAndAsksOnceToSignIn() async throws {
    let gmail = ScriptedGmail()
    let (store, _) = try store(gmail)
    await gmail.set(rejectedTokens: ["t", "fresh"])
    store.gmailTokenRefresh = { "fresh" }
    await store.archive(mail)
    XCTAssertTrue(store.googleSignInNeeded)
    XCTAssertNil(store.error, "one persistent sign-in tag, not an alert")
    XCTAssertEqual(current(store)?.labels, [], "the archive is kept for after signing in")
    XCTAssertEqual(store.pendingLabelChanges, 1)
  }

  // MARK: E3

  func testBackgroundSyncFailuresAreAStatusAndDoNotRepeat() async throws {
    let gmail = ScriptedGmail()
    let clock = TestClock()
    let (store, _) = try store(gmail, clock: clock)
    await gmail.set(historyStatus: 500)
    await store.pollMailbox()
    XCTAssertNil(store.error, "the two-minute check never alerts")
    XCTAssertEqual(store.status, "Couldn’t finish · retry when ready")

    var changes = 0
    withObservationTracking { _ = store.error; _ = store.status; _ = store.connectionIssue } onChange: { changes += 1 }
    clock.date.addTimeInterval(121)
    await store.pollMailbox()
    XCTAssertNil(store.error)
    XCTAssertEqual(store.status, "Couldn’t finish · retry when ready")
    XCTAssertEqual(changes, 0, "a second identical failure changes nothing anyone sees")

    // Offline: one tag that stays the same tag across failed checks.
    await gmail.set(offline: true)
    clock.date.addTimeInterval(121)
    await store.pollMailbox()
    let issue = try XCTUnwrap(store.connectionIssue)
    clock.date.addTimeInterval(121)
    await store.pollMailbox()
    XCTAssertEqual(store.connectionIssue?.id, issue.id)
    XCTAssertNil(store.error)

    // The user asking (⌘R) is told.
    await gmail.set(offline: false)
    await store.sync()
    XCTAssertNotNil(store.error, "an interactive sync that fails alerts")
  }

  func testARevokedSignInIsOneTagNotAnAlertEveryTwoMinutes() async throws {
    let gmail = ScriptedGmail()
    let clock = TestClock()
    var tokenRequests = 0
    let (store, _) = try store(gmail, clock: clock) {
      tokenRequests += 1
      throw CoveError.message("Connect Gmail to continue.")
    }
    await store.pollMailbox()
    XCTAssertTrue(store.googleSignInNeeded)
    XCTAssertNil(store.error)
    XCTAssertTrue(store.status.contains("Sign in"))
    XCTAssertEqual(tokenRequests, 1)

    clock.date.addTimeInterval(121)
    await store.pollMailbox()
    XCTAssertEqual(tokenRequests, 1, "background checks pause until the user signs in again")
    XCTAssertNil(store.error)

    await store.sync()
    let alert = try XCTUnwrap(store.error, "the user asking is told once")
    XCTAssertTrue(alert.contains("sign in"))
    var changes = 0
    withObservationTracking { _ = store.error } onChange: { changes += 1 }
    await store.sync()
    XCTAssertEqual(store.error, alert)
    XCTAssertEqual(changes, 0, "the same alert while it shows doesn't stack")
  }

  // MARK: E4

  func testTheSameErrorWhileShowingIsANoOp() {
    let store = AppStore.offlineFixture()
    store.error = "Couldn’t save"
    var changes = 0
    withObservationTracking { _ = store.error } onChange: { changes += 1 }
    store.error = "Couldn’t save"
    XCTAssertEqual(changes, 0)
    store.error = HTTPFailure.gmailRateLimitMessage
    XCTAssertEqual(store.error, "Couldn’t save", "a rate limit never replaces or opens an alert")
    store.error = nil
    XCTAssertEqual(changes, 1)
  }

  // MARK: S5

  func testLabelViewsAndOlderPagesDontWaitForABackgroundSync() async throws {
    let gmail = ScriptedGmail()
    let (store, _) = try store(gmail)
    store.gmailLabels = [GmailLabel(id: "finance", name: "Finance", type: "user")]
    store.syncing = true                                  // the two-minute check is running
    store.chooseFolder("label:finance")
    await store.loadLabelMail()
    XCTAssertTrue(store.mails.contains { $0.id == "f1" }, "a label view loads beside the sync")
    XCTAssertFalse(store.loadingLabelMail)
    XCTAssertTrue(store.syncing, "the background sync's own flag is untouched")

    store.chooseFolder("Inbox")
    store.nextPage = "older"
    await store.sync(older: true)
    XCTAssertTrue(store.mails.contains { $0.id == "o1" }, "reaching the list's end loads beside the sync")
    XCTAssertNil(store.nextPage)
    XCTAssertFalse(store.loadingOlderMail)
  }

  func testAnOlderPageLandingDuringASyncKeepsTheUsersChanges() async throws {
    let gmail = ScriptedGmail()
    let (store, database) = try store(gmail)
    await gmail.set(history: .inboxAgain)
    await gmail.pauseHistory()
    let sync = Task { await store.sync(interactive: false) }
    while await !gmail.historyWaiting { try await Task.sleep(for: .milliseconds(5)) }
    await store.archive(mail)                            // delivered while the sync's stale answer is pending
    store.nextPage = "older"
    await store.sync(older: true)                        // an older page lands mid-sync
    await gmail.releaseHistory()
    await sync.value
    XCTAssertEqual(current(store)?.labels, [], "the archive survives the stale sync result")
    XCTAssertTrue(store.mails.contains { $0.id == "o1" })
    XCTAssertEqual(try database.load(String.self, key: "gmailHistoryID"), "200", "the older page never rewinds the history cursor")
  }
}

final class TestClock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 2_000_000_000) }

extension AppStore {
  /// A store over a throwaway database with no network.
  static func offlineFixture() -> AppStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CoveFixture-\(UUID().uuidString)")
      .appendingPathComponent("mail.sqlite")
    return try! AppStore(database: Database(url: url), accountEmail: "me@example.com", gmail: GmailClient(),
                         gmailTokenProvider: { throw URLError(.notConnectedToInternet) }, syncClock: Date.init)
  }
}

actor ScriptedGmail: HTTPTransport {
  enum History { case quiet, inboxAgain }
  struct Modify { var token: String; var body: [String: [String]]; var remove: [String] { body["removeLabelIds"] ?? [] } }
  private(set) var modifies: [Modify] = []
  private var offline = false
  private var modifyStatus = 200
  private var historyStatus = 200
  private var history = History.quiet
  private var rejectedTokens: Set<String> = []
  private var holdHistory = false
  private var held: CheckedContinuation<Void, Never>?
  private(set) var historyWaiting = false
  func set(offline: Bool) { self.offline = offline }
  private var modifyFailure: URLError.Code?
  func set(modifyFailure: URLError.Code?) { self.modifyFailure = modifyFailure }
  func set(modifyStatus: Int) { self.modifyStatus = modifyStatus }
  func set(historyStatus: Int) { self.historyStatus = historyStatus }
  func set(history: History) { self.history = history }
  func set(rejectedTokens: Set<String>) { self.rejectedTokens = rejectedTokens }
  func pauseHistory() { holdHistory = true }
  func releaseHistory() { holdHistory = false; held?.resume(); held = nil }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("Bearer ".count))
    var status = 200
    var body: [String: Any] = [:]
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    switch url.lastPathComponent {
    case "modify":
      let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: [String]]) ?? [:]
      modifies.append(Modify(token: token, body: sent))
      if offline { throw URLError(.notConnectedToInternet) }
      if let modifyFailure { throw URLError(modifyFailure) }
      status = rejectedTokens.contains(token) ? 401 : modifyStatus
      body = ["id": "m1"]
    case "history":
      if offline { throw URLError(.notConnectedToInternet) }
      if holdHistory { historyWaiting = true; await withCheckedContinuation { held = $0 } }
      status = historyStatus
      body = history == .inboxAgain
        ? ["historyId": "200", "history": [["labelsAdded": [["message": ["id": "m1"], "labelIds": ["INBOX"]]]]]]
        : ["historyId": "201"]
    case "messages":
      if offline { throw URLError(.notConnectedToInternet) }
      let label = query.first { $0.name == "labelIds" }?.value
      body = ["messages": [["id": label == "finance" ? "f1" : "o1"]]]
    case "f1", "o1":
      let id = url.lastPathComponent
      body = ["id": id, "threadId": "t-\(id)", "internalDate": "1600000000000",
              "labelIds": id == "f1" ? ["finance"] : ["INBOX"],
              "payload": ["headers": [["name": "Subject", "value": "Page mail"]]]]
    default:
      XCTFail("Unexpected Gmail endpoint: \(url.path)")
      throw URLError(.badURL)
    }
    return (try JSONSerialization.data(withJSONObject: body),
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
