import CSQLite
import CoveCore
import XCTest

@testable import Cove

@MainActor
final class ThreadAnswerTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() {
    directories.forEach { try? FileManager.default.removeItem(at: $0) }
    directories = []
    super.tearDown()
  }
  private func fixture(_ http: ThreadAnswerHTTP) throws -> (AppStore, Database, Mail) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(directory)
    let db = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    let mail = Mail(
      id: "m1", threadID: "thread1", sender: "Maya", senderEmail: "maya@example.com",
      subject: "Launch", body: "Cached request", draft: "Unsent reply")
    try db.saveMailSnapshot([mail], historyID: "100", nextPage: "next", updatesPagination: true)
    let store = try AppStore(
      database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http),
      gmailTokenProvider: { "fixture" }, syncClock: { Date() }, jev: JevClient(transport: http),
      jevKeyProvider: { "fixture" })
    return (store, db, mail)
  }
  func testLiveThreadFetchPersistsNewSourcesAndPreservesDraftAndSyncCursor() async throws {
    let http = ThreadAnswerHTTP()
    let (store, db, mail) = try fixture(http)
    let answer = try await store.answer("Which dates?", mail: mail, scope: .thread)
    XCTAssertEqual(Set(answer.passages.map { $0.mail.id }), ["m1", "m2"])
    XCTAssertTrue(answer.source.contains("Gmail thread refreshed"))
    XCTAssertTrue(answer.source.contains("2 of 2"))
    XCTAssertEqual(try db.loadMail().first { $0.id == "m1" }?.draft, "Unsent reply")
    XCTAssertEqual(try db.loadMail().first { $0.id == "m2" }?.body, "The review is on Thursday.")
    XCTAssertEqual(try db.load(String.self, key: "gmailHistoryID"), "100")
    XCTAssertEqual(try db.load(String.self, key: "gmailNextPage"), "next")
    let sent = await http.modelPayloads
    XCTAssertEqual(sent.count, 1)
    XCTAssertFalse(String(data: sent[0], encoding: .utf8)!.contains("Unsent reply"))
    XCTAssertFalse(String(data: sent[0], encoding: .utf8)!.contains("SECRET DRAFT"))
    XCTAssertFalse(store.busy)
  }
  func testDraftEditedDuringThreadRefreshSurvivesMerge() async throws {
    let started = expectation(description: "Gmail request")
    let http = ThreadAnswerHTTP(started: started)
    let (store, db, mail) = try fixture(http)
    let operation = Task { try await store.answer("When?", mail: mail, scope: .thread) }
    await fulfillment(of: [started], timeout: 2)
    store.saveReply(id: mail.id, text: "New unsent reply")
    await http.release()
    _ = try await operation.value
    XCTAssertEqual(store.mails.first { $0.id == mail.id }?.draft, "New unsent reply")
    XCTAssertEqual(try db.loadMail().first { $0.id == mail.id }?.draft, "New unsent reply")
  }
  func testOfflineThreadFallbackIsExplicitAndOnlyUsesDownloadedMessages() async throws {
    let http = ThreadAnswerHTTP(gmailStatus: 503)
    let (store, _, mail) = try fixture(http)
    let answer = try await store.answer("What?", mail: mail, scope: .thread)
    XCTAssertTrue(answer.source.contains("Downloaded thread only"))
    XCTAssertTrue(answer.source.contains("Gmail refresh unavailable"))
    XCTAssertEqual(answer.passages.map { $0.mail.id }, [mail.id])
    XCTAssertEqual(answer.passages.first?.text, "Cached request")
  }
  func testCancellationDoesNotPersistFetchOrCallJev() async throws {
    let started = expectation(description: "Gmail request")
    let http = ThreadAnswerHTTP(started: started)
    let (store, db, mail) = try fixture(http)
    let operation = Task { try await store.answer("What?", mail: mail, scope: .thread) }
    await fulfillment(of: [started], timeout: 2)
    operation.cancel()
    await http.release()
    do {
      _ = try await operation.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(try db.loadMail().map(\.id), [mail.id])
    let requests = await http.modelPayloads
    XCTAssertTrue(requests.isEmpty)
    XCTAssertFalse(store.busy)
  }
  func testStorageFailureStopsBeforeModelAndKeepsCachedMail() async throws {
    let http = ThreadAnswerHTTP()
    let (store, db, mail) = try fixture(http)
    var handle: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(directories.last!.appendingPathComponent("mail.sqlite").path, &handle), SQLITE_OK
    )
    defer { sqlite3_close(handle) }
    XCTAssertEqual(
      sqlite3_exec(
        handle,
        "CREATE TRIGGER fail_mail BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT,'test failure'); END;",
        nil, nil, nil), SQLITE_OK)
    do {
      _ = try await store.answer("What?", mail: mail, scope: .thread)
      XCTFail("Expected storage failure")
    } catch { XCTAssertFalse(error is CancellationError) }
    XCTAssertEqual(store.mails.map(\.id), [mail.id])
    XCTAssertEqual(try db.loadMail().first?.draft, "Unsent reply")
    let requests = await http.modelPayloads
    XCTAssertTrue(requests.isEmpty)
    XCTAssertFalse(store.busy)
  }
  func testNoMatchesAndModelFailureDoNotProduceSourceCards() async throws {
    let (store, _, mail) = try fixture(ThreadAnswerHTTP(matches: false))
    let answer = try await store.answer("Unknown?", mail: mail, scope: .thread)
    XCTAssertTrue(answer.passages.isEmpty)
    XCTAssertTrue(answer.text.contains("no confident matching passage"))
    let (failedStore, _, failedMail) = try fixture(ThreadAnswerHTTP(modelStatus: 503))
    do {
      _ = try await failedStore.answer("Question", mail: failedMail, scope: .thread)
      XCTFail("Expected model failure")
    } catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
    XCTAssertFalse(failedStore.busy)
  }
  func testSampleThreadNeverFetchesGmailOrCallsJev() async throws {
    let http = ThreadAnswerHTTP()
    let (store, _, mail) = try fixture(http)
    store.isSample = true
    let answer = try await store.answer("Question", mail: mail, scope: .thread)
    XCTAssertTrue(answer.source.contains("no Jev request"))
    XCTAssertTrue(answer.text.contains("preview"))
    let count = await http.gmailRequests
    let payloads = await http.modelPayloads
    XCTAssertEqual(count, 0)
    XCTAssertTrue(payloads.isEmpty)
  }
}

private actor ThreadAnswerHTTP: HTTPTransport {
  let gmailStatus: Int
  let modelStatus: Int
  let matches: Bool
  let started: XCTestExpectation?
  private var pending: CheckedContinuation<Void, Never>?
  private(set) var gmailRequests = 0
  private(set) var modelPayloads: [Data] = []
  init(
    gmailStatus: Int = 200, modelStatus: Int = 200, matches: Bool = true,
    started: XCTestExpectation? = nil
  ) {
    self.gmailStatus = gmailStatus
    self.modelStatus = modelStatus
    self.matches = matches
    self.started = started
  }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    let status: Int
    if request.url?.host == "gmail.googleapis.com" {
      gmailRequests += 1
      XCTAssertEqual(request.httpMethod, "GET")
      if let started {
        await withCheckedContinuation { continuation in
          pending = continuation
          started.fulfill()
        }
      }
      func message(_ id: String, _ body: String, _ labels: [String]) -> [String: Any] {
        [
          "id": id, "threadId": "thread1", "labelIds": labels,
          "internalDate": id == "m1" ? "1000" : "2000",
          "payload": [
            "mimeType": "text/plain",
            "headers": [
              ["name": "From", "value": "\(id)@example.com"],
              ["name": "Subject", "value": "Launch"],
            ],
            "body": ["data": Data(body.utf8).base64URL],
          ],
        ]
      }
      data = try JSONSerialization.data(withJSONObject: [
        "id": "thread1",
        "messages": [
          message("m1", "Please approve by Friday.", ["INBOX"]),
          message("m2", "The review is on Thursday.", ["SENT"]),
          message("draft", "SECRET DRAFT", ["DRAFT"]),
        ],
      ])
      status = gmailStatus
    } else {
      modelPayloads.append(request.httpBody!)
      let payload = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      let questions = try XCTUnwrap(payload["questions"] as? [String: Any])
      let answers = questions.mapValues { _ in
        ["choice": matches ? "0" : "none", "confidence": 0.95] as [String: Any]
      }
      data = try JSONSerialization.data(withJSONObject: ["model": "fixture", "answers": answers])
      status = modelStatus
    }
    return (
      data,
      try XCTUnwrap(
        HTTPURLResponse(
          url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
    )
  }
  func release() {
    pending?.resume()
    pending = nil
  }
}
