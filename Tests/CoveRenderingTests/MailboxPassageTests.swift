import CoveCore
import XCTest

@testable import Cove

@MainActor
final class MailboxPassageTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() {
    directories.forEach { try? FileManager.default.removeItem(at: $0) }
    directories = []
    super.tearDown()
  }
  private func fixture(_ http: MailboxPassageHTTP) throws -> (AppStore, Database) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(directory)
    let db = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    let first = Mail(
      id: "one", threadID: "first-thread", sender: "Maya", senderEmail: "maya@example.com",
      subject: "Website launch", body: "The website launch is Friday.", draft: "SECRET UNSENT")
    let second = Mail(
      id: "two", threadID: "another-thread", sender: "Alex", senderEmail: "alex@example.com",
      subject: "Launch review", body: "Please review the website on Thursday.", labels: ["SENT"])
    let draft = Mail(
      id: "draft", sender: "Me", senderEmail: "me@example.com",
      subject: "SECRET DRAFT SUBJECT", body: "SECRET DRAFT BODY", labels: ["DRAFT"])
    // Stored mail loads newest first; give the fixture that order explicitly.
    let now = Date()
    let dated = [first, second, draft].enumerated().map { index, mail -> Mail in
      var mail = mail; mail.date = now.addingTimeInterval(-Double(index) * 60); return mail
    }
    try db.saveMailSnapshot(
      dated, historyID: "100", nextPage: "next", updatesPagination: true)
    let store = try AppStore(
      database: db, accountEmail: "me@example.com",
      gmail: GmailClient(transport: http), gmailTokenProvider: { "fixture" }, syncClock: { Date() },
      jev: JevClient(transport: http), jevKeyProvider: { "fixture" })
    return (store, db)
  }

  func testDownloadedScopeUsesOneJevCallAndLeavesMailAndCursorUntouched() async throws {
    let http = MailboxPassageHTTP()
    let (store, db) = try fixture(http)
    let before = try db.loadMail()
    let answer = try await store.answerDownloadedMail("When is the website launch?")
    XCTAssertEqual(Set(answer.passages.map { $0.mail.id }), ["one", "two"])
    XCTAssertEqual(Set(answer.passages.map { $0.mail.threadID }).count, 2)
    XCTAssertTrue(answer.source.contains("Downloaded mail only"))
    XCTAssertTrue(answer.source.contains("2 of 2"))
    XCTAssertEqual(try db.loadMail(), before)
    XCTAssertEqual(try db.load(String.self, key: "gmailHistoryID"), "100")
    XCTAssertEqual(try db.load(String.self, key: "gmailNextPage"), "next")
    let payloads = await http.payloads
    XCTAssertEqual(payloads.count, 1)
    XCTAssertFalse(String(data: payloads[0], encoding: .utf8)!.contains("SECRET"))
    XCTAssertFalse(store.busy)
  }

  func testSampleAndEmptyMailboxesNeverCallProviders() async throws {
    let http = MailboxPassageHTTP()
    let (store, _) = try fixture(http)
    store.isSample = true
    let sample = try await store.answerDownloadedMail("Launch?")
    XCTAssertTrue(sample.text.contains("preview"))
    XCTAssertTrue(sample.source.contains("no Jev request"))
    store.mails = []
    store.isSample = false
    let empty = try await store.answerDownloadedMail("Launch?")
    XCTAssertTrue(empty.passages.isEmpty)
    XCTAssertTrue(empty.source.contains("no text sent to Jev"))
    let payloads = await http.payloads
    XCTAssertTrue(payloads.isEmpty)
  }

  func testNoMatchIsLimitedToCheckedTextAndFailurePropagates() async throws {
    let (store, _) = try fixture(MailboxPassageHTTP(matches: false))
    let answer = try await store.answerDownloadedMail("Unknown serial number?")
    XCTAssertTrue(answer.passages.isEmpty)
    XCTAssertTrue(answer.text.contains("does not mean the answer is absent from Gmail"))
    let (failed, _) = try fixture(MailboxPassageHTTP(status: 503))
    do {
      _ = try await failed.answerDownloadedMail("Launch?")
      XCTFail("Expected model failure")
    } catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
  }

  func testCancelledModelResponseIsNotPublished() async throws {
    let started = expectation(description: "model request")
    let http = MailboxPassageHTTP(started: started)
    let (store, db) = try fixture(http)
    let before = try db.loadMail()
    let operation = Task { try await store.answerDownloadedMail("Launch?") }
    await fulfillment(of: [started], timeout: 2)
    operation.cancel()
    await http.release()
    do {
      _ = try await operation.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(try db.loadMail(), before)
  }

  func testSourceTrashedOrChangedDuringRequestCannotBecomeAnAnswerCard() async throws {
    let started = expectation(description: "model request")
    let http = MailboxPassageHTTP(started: started)
    let (store, _) = try fixture(http)
    let operation = Task { try await store.answerDownloadedMail("Launch?") }
    await fulfillment(of: [started], timeout: 2)
    store.mails[0].labels.insert("TRASH")
    store.mails[1].body = "Re-decoded content without the previous passage."
    await http.release()
    let answer = try await operation.value
    XCTAssertTrue(answer.passages.isEmpty)
    XCTAssertTrue(answer.text.contains("No confident matching passage is available"))
  }
}

private actor MailboxPassageHTTP: HTTPTransport {
  let matches: Bool
  let status: Int
  let started: XCTestExpectation?
  private var pending: CheckedContinuation<Void, Never>?
  private(set) var payloads: [Data] = []
  init(matches: Bool = true, status: Int = 200, started: XCTestExpectation? = nil) {
    self.matches = matches
    self.status = status
    self.started = started
  }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTAssertEqual(request.url?.host, "api.typesafe.ai", "Downloaded scope must not fetch Gmail")
    XCTAssertEqual(request.httpMethod, "POST")
    let body = try XCTUnwrap(request.httpBody)
    payloads.append(body)
    if let started {
      await withCheckedContinuation { continuation in
        pending = continuation
        started.fulfill()
      }
    }
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let questions = try XCTUnwrap(json["questions"] as? [String: Any])
    let answers = questions.mapValues { _ in
      ["choice": matches ? "0" : "none", "confidence": 0.95] as [String: Any]
    }
    return (
      try JSONSerialization.data(withJSONObject: ["model": "fixture", "answers": answers]),
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
