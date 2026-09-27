import CoveCore
import Foundation
import XCTest
@testable import Cove

@MainActor final class CloudSnoozeTests: XCTestCase {
  private func fixture() throws -> (AppStore, Database, URL, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try Database(url: root.appendingPathComponent("mail.sqlite"), encryptionKey: Data(repeating: 7, count: 32), namespace: "snooze-fixture")
    let id = UUID()
    var cloud = CloudMirrorState(); cloud.enabled = true; cloud.accountID = id
    try db.save(cloud, key: "cloudMirror")
    try db.saveMailSnapshot([Mail(id: "abc", threadID: "thread", sender: "Fixture", senderEmail: "sender@example.com",
      subject: "Old mail", body: "Private fixture body", date: Date().addingTimeInterval(-90 * 86400), labels: ["INBOX"])])
    return (try restore(db), db, root, id)
  }
  private func restore(_ db: Database) throws -> AppStore {
    try AppStore(database: db, accountEmail: "fixture@example.com", gmail: GmailClient(),
      gmailTokenProvider: { "fixture" }, syncClock: { Date() })
  }
  private func client(_ server: SnoozeServer) throws -> CloudMailClient {
    try CloudMailClient(baseURL: URL(string: "https://sync.example.com")!, transport: SnoozeTransport { request in
      try await server.respond(request)
    })
  }
  func testOfflineQueueSurvivesRestartAndUploadsOldMailReminderWithoutEmailContent() async throws {
    let (store, db, root, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let until = Date(timeIntervalSince1970: 1_900_000_000)
    store.snooze(store.mails[0], until: until)
    XCTAssertTrue(store.status.contains("waiting for cloud"))
    XCTAssertEqual(try db.loadMail()[0].snoozedUntil, until)
    let restarted = try restore(db)
    let server = SnoozeServer(accountID: id)
    try await restarted.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    XCTAssertEqual(server.records["abc"]?.until, until)
    XCTAssertTrue(restarted.cloudSnoozes.pending.isEmpty)
    XCTAssertTrue(restarted.snoozeSyncDetail(for: restarted.mails[0]).contains("synced"))
    let body = try XCTUnwrap(server.uploads.first)
    XCTAssertEqual(Set(body.keys), ["accountID", "requestID", "baseRevision", "threadID", "wakeAt"])
    XCTAssertFalse(String(describing: body).contains("Private fixture body"))
    XCTAssertEqual(try db.load(CloudSnoozeState.self, key: "cloudSnoozes")?.records["abc"]?.until, until)
  }
  func testLostResponseRetriesIdenticalRequestAfterRestartThenSendsNewerCancellation() async throws {
    let (store, db, root, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let server = SnoozeServer(accountID: id); server.loseNextResponse = true
    store.snooze(store.mails[0], until: Date().addingTimeInterval(3600))
    do { try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false); XCTFail("Expected lost response") }
    catch { XCTAssertTrue(error is URLError) }
    XCTAssertNotNil(try db.load(CloudSnoozeState.self, key: "cloudSnoozes")?.uploading)
    let restarted = try restore(db)
    restarted.snooze(restarted.mails[0], until: nil)
    try await restarted.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    XCTAssertEqual(server.uploads.count, 3)
    XCTAssertEqual(server.uploads[0]["requestID"] as? String, server.uploads[1]["requestID"] as? String)
    XCTAssertEqual(server.uploads[0]["wakeAt"] as? String, server.uploads[1]["wakeAt"] as? String)
    XCTAssertTrue(server.uploads[2]["wakeAt"] is NSNull)
    XCTAssertNil(server.records["abc"]?.wakeAt)
    XCTAssertNil(restarted.mails[0].snoozedUntil)
    XCTAssertTrue(restarted.cloudSnoozes.pending.isEmpty)
  }
  func testRescheduleDuringUploadPreservesLatestIntent() async throws {
    let (store, _, root, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let server = SnoozeServer(accountID: id)
    let first = Date(timeIntervalSince1970: 1_900_000_000), second = Date(timeIntervalSince1970: 1_900_003_600)
    store.snooze(store.mails[0], until: first)
    server.duringNextUpload = { store.snooze(store.mails[0], until: second) }
    try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    XCTAssertEqual(server.uploads.count, 2)
    XCTAssertEqual(server.records["abc"]?.until, second)
    XCTAssertEqual(store.mails[0].snoozedUntil, second)
  }
  func testRemoteCancellationAppliesAndConflictRequiresNewUserIntent() async throws {
    let (store, _, root, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let server = SnoozeServer(accountID: id)
    store.snooze(store.mails[0], until: Date().addingTimeInterval(3600))
    try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    server.change(id: "abc", wakeAt: nil)
    try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    XCTAssertNil(store.mails[0].snoozedUntil)
    store.snooze(store.mails[0], until: Date().addingTimeInterval(7200))
    server.duringNextUpload = { server.change(id: "abc", wakeAt: "2030-01-01T09:00:00Z") }
    do { try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false); XCTFail("Expected conflict") }
    catch let error as CloudSyncFailure { XCTAssertEqual(error.code, "snooze_conflict") }
    XCTAssertTrue(store.cloudSnoozes.conflicts.contains("abc"))
    XCTAssertNotNil(store.cloudSnoozes.pending["abc"])
    store.snooze(store.mails[0], until: nil)
    try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    XCTAssertNil(server.records["abc"]?.wakeAt)
    XCTAssertTrue(store.cloudSnoozes.conflicts.isEmpty)
  }
  func testPauseDuringUploadKeepsUnacknowledgedIntentForSafeRetry() async throws {
    let (store, db, root, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let server = SnoozeServer(accountID: id)
    store.snooze(store.mails[0], until: Date().addingTimeInterval(3600))
    server.duringNextUpload = { store.pauseCloudSync() }
    do { try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false); XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(store.cloudMirror.enabled)
    XCTAssertNotNil(try db.load(CloudSnoozeState.self, key: "cloudSnoozes")?.uploading)
    XCTAssertNotNil(store.cloudSnoozes.pending["abc"])
    XCTAssertTrue(store.snoozeSyncDetail(for: store.mails[0]).contains("enable cloud sync"))
  }
  func testRemoteSnoozesForUncachedMailAndTrashCancellation() async throws {
    let (store, _, root, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let server = SnoozeServer(accountID: id)
    server.change(id: "fed", wakeAt: "2030-01-01T09:00:00Z")
    try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    var later = store.mails[0]; later.id = "fed"
    XCTAssertNotNil(store.cloudSnoozes.applying(to: later).snoozedUntil)
    store.snooze(store.mails[0], until: Date().addingTimeInterval(3600))
    try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    store.mails[0].labels = ["TRASH"]
    try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { "fixture" }, pace: false)
    XCTAssertNil(server.records["abc"]?.wakeAt)
    XCTAssertNotNil(server.records["fed"]?.wakeAt)
  }
  func testCloudOffDoesNotUploadAndSampleDoesNotQueue() async throws {
    let (store, _, root, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let server = SnoozeServer(accountID: id)
    store.pauseCloudSync()
    store.snooze(store.mails[0], until: Date().addingTimeInterval(3600))
    do { try await store.syncCloudSnoozes(client: client(server), accountID: id, token: { XCTFail("No token without consent"); return "fixture" }, pace: false); XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(server.requests, 0)
    XCTAssertNotNil(store.cloudSnoozes.pending["abc"])
    store.isSample = true
    let before = store.cloudSnoozes.pending["abc"]
    store.snooze(store.mails[0], until: Date().addingTimeInterval(7200))
    XCTAssertEqual(store.cloudSnoozes.pending["abc"], before)
  }
}

private struct SnoozeTransport: HTTPTransport {
  var handler: @MainActor (URLRequest) async throws -> (Int, Data)
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (code, data) = try await handler(request)
    return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
  }
}
@MainActor private final class SnoozeServer {
  let accountID: UUID
  var records: [String: CloudSnooze] = [:]
  var revision = 0
  var receipts: [String: String] = [:]
  var uploads: [[String: Any]] = []
  var requests = 0
  var loseNextResponse = false
  var duringNextUpload: (() -> Void)?
  init(accountID: UUID) { self.accountID = accountID }
  func change(id: String, wakeAt: String?) {
    revision += 1
    records[id] = CloudSnooze(id: id, threadID: "thread", wakeAt: wakeAt, revision: String(revision))
  }
  func respond(_ request: URLRequest) async throws -> (Int, Data) {
    requests += 1
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
    func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    if request.httpMethod == "GET" {
      let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }!.value!
      let changes = records.values.filter { Int($0.revision)! > Int(cursor)! }.sorted { Int($0.revision)! < Int($1.revision)! }
      let values: [[String: Any]] = changes.map { ["id": $0.id, "threadID": $0.threadID, "wakeAt": $0.wakeAt as Any? ?? NSNull(), "revision": $0.revision] }
      return (200, try json(["accountID": accountID.uuidString, "cursor": changes.last?.revision ?? cursor, "hasMore": false, "snoozes": values]))
    }
    XCTAssertEqual(request.httpMethod, "PUT")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    uploads.append(body)
    let id = request.url!.lastPathComponent
    let requestID = body["requestID"] as! String
    if let receipt = receipts[requestID] { return (200, try json(["revision": receipt])) }
    let callback = duringNextUpload; duringNextUpload = nil; callback?()
    if body["baseRevision"] as? String != (records[id]?.revision ?? "0") { return (409, try json(["error": "snooze_conflict"])) }
    change(id: id, wakeAt: body["wakeAt"] as? String)
    receipts[requestID] = String(revision)
    if loseNextResponse { loseNextResponse = false; throw URLError(.networkConnectionLost) }
    return (200, try json(["revision": String(revision)]))
  }
}
