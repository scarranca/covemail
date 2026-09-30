import CSQLite
import CoveCore
import XCTest

@testable import Cove

@MainActor
final class SendWorkflowTests: XCTestCase {
  private var directories: [URL] = []

  override func tearDown() {
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    directories = []
    super.tearDown()
  }

  private func fixture(_ http: SendHTTP) throws -> (AppStore, Database, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(directory)
    let url = directory.appendingPathComponent("mail.sqlite")
    let database = try Database(url: url)
    let store = try AppStore(
      database: database, accountEmail: "me@example.com", gmail: GmailClient(transport: http),
      gmailTokenProvider: { "fixture-token" }, syncClock: { Date() })
    return (store, database, url)
  }

  private func draft(in store: AppStore) throws -> String {
    store.newDraft()
    let id = try XCTUnwrap(store.composeID)
    store.saveComposition(id: id, to: "friend@example.com", subject: "Hello", body: "Café 🌊")
    return id
  }

  func testAliasChoicePersistsAndIsUsedInActualSendHeaders() async throws {
    let http = SendHTTP(aliases: ["work@example.com"])
    let (store, database, _) = try fixture(http)
    let id = try draft(in: store)
    let available = try await store.sendingAddresses()
    XCTAssertEqual(available, ["me@example.com", "work@example.com"])
    store.saveComposition(id: id, to: "friend@example.com", subject: "Hello", body: "Café 🌊", from: "work@example.com")
    XCTAssertEqual(try database.loadMail().first?.senderEmail, "work@example.com")
    let success = await store.send(to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id, from: "work@example.com")
    XCTAssertTrue(success)
    let messages = try database.loadMail()
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.senderEmail, "work@example.com")
    let requests = await http.requests
    XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["sendAs", "sendAs", "send"])
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
    let raw = try XCTUnwrap(Data(base64URL: XCTUnwrap(payload["raw"] as? String)))
    XCTAssertTrue(String(decoding: raw, as: UTF8.self).hasPrefix("From: work@example.com\r\n"))
  }

  func testRemovedAliasNeverSendsOrDiscardsDraft() async throws {
    let http = SendHTTP(aliases: [])
    let (store, database, _) = try fixture(http)
    let id = try draft(in: store)
    store.saveComposition(id: id, to: "friend@example.com", subject: "Hello", body: "Café 🌊", from: "removed@example.com")
    let success = await store.send(to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id, from: "removed@example.com")
    XCTAssertFalse(success)
    XCTAssertTrue(store.error?.contains("no longer available") == true)
    XCTAssertEqual(try database.loadMail().first?.senderEmail, "removed@example.com")
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.httpMethod, "GET")
  }

  func testSenderChangedDuringSendKeepsNewerDraft() async throws {
    let started = expectation(description: "Sending alias")
    let http = SendHTTP(started: started, aliases: ["work@example.com"])
    let (store, database, _) = try fixture(http)
    let id = try draft(in: store)
    store.saveComposition(id: id, to: "friend@example.com", subject: "Hello", body: "Café 🌊", from: "work@example.com")
    let task = Task { await store.send(to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id, from: "work@example.com") }
    await fulfillment(of: [started], timeout: 2)
    store.saveComposition(id: id, to: "friend@example.com", subject: "Hello", body: "Café 🌊", from: "me@example.com")
    await http.release()
    let success = await task.value
    XCTAssertTrue(success)
    XCTAssertEqual(try database.loadMail().first { $0.id == id }?.senderEmail, "me@example.com")
    XCTAssertTrue(store.status.contains("newer draft kept"))
  }

  func testSuccessfulSendReplacesDraftDurablyWithSubmittedContent() async throws {
    let http = SendHTTP()
    let (store, _, url) = try fixture(http)
    let id = try draft(in: store)
    let success = await store.send(
      to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id)
    XCTAssertTrue(success)
    XCTAssertFalse(store.busy)
    XCTAssertEqual(store.status, "Email sent")
    XCTAssertNil(store.error)
    let stored = try Database(url: url).loadMail()
    XCTAssertEqual(stored.count, 1)
    XCTAssertEqual(stored[0].id, "gmail-sent")
    XCTAssertEqual(stored[0].senderEmail, "me@example.com")
    XCTAssertEqual(stored[0].to, "friend@example.com")
    XCTAssertEqual(stored[0].body, "Café 🌊")
    XCTAssertEqual(stored[0].labels, ["SENT"])
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].httpMethod, "POST")
    XCTAssertEqual(requests[0].url?.path, "/gmail/v1/users/me/messages/send")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
    let raw = try XCTUnwrap(Data(base64URL: XCTUnwrap(payload["raw"] as? String)))
    let mime = try XCTUnwrap(String(data: raw, encoding: .utf8))
    XCTAssertTrue(mime.hasPrefix("From: me@example.com\r\nDate: "))
    XCTAssertTrue(mime.contains("To: friend@example.com\r\n"))
    XCTAssertTrue(mime.contains(Data("Café 🌊".utf8).base64EncodedString()))
  }

  func testRejectedSendPreservesDraftAndDoesNotCreateSentMessage() async throws {
    let http = SendHTTP(status: 403)
    let (store, database, _) = try fixture(http)
    let id = try draft(in: store)
    let before = try database.loadMail()
    let success = await store.send(
      to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id)
    XCTAssertFalse(success)
    XCTAssertFalse(store.busy)
    XCTAssertTrue(store.error?.contains("403") == true)
    XCTAssertEqual(try database.loadMail(), before)
    XCTAssertEqual(store.mails, before)
  }

  func testUncertainSendPreservesDraftAndTellsUserToCheckSent() async throws {
    for http in [SendHTTP(networkError: .timedOut), SendHTTP(status: 503)] {
      let (store, database, _) = try fixture(http)
      let id = try draft(in: store)
      let success = await store.send(
        to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id)
      XCTAssertFalse(success)
      XCTAssertTrue(store.error?.contains("Check Sent in Gmail before trying again") == true)
      XCTAssertEqual(store.status, "Send unconfirmed · check Gmail Sent before retrying")
      XCTAssertEqual(try database.loadMail().first?.id, id)
      let count = await http.requests.count
      XCTAssertEqual(count, 1, "The app must not automatically retry an uncertain send")
    }
  }

  func testSendKeepsCompositionEditedWhileRequestIsInFlightAndRejectsDuplicateClick() async throws {
    let started = expectation(description: "Gmail request started")
    let http = SendHTTP(started: started)
    let (store, database, _) = try fixture(http)
    let id = try draft(in: store)
    let task = Task {
      await store.send(to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id)
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertTrue(store.busy)
    store.saveComposition(id: id, to: "other@example.com", subject: "Follow-up", body: "New text")
    let duplicate = await store.send(
      to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id)
    XCTAssertFalse(duplicate)
    await http.release()
    let success = await task.value
    XCTAssertTrue(success)
    let saved = try database.loadMail()
    XCTAssertEqual(saved.first { $0.id == id }?.body, "New text")
    XCTAssertEqual(saved.first { $0.id == id }?.to, "other@example.com")
    XCTAssertEqual(saved.first { $0.id == "gmail-sent" }?.body, "Café 🌊")
    XCTAssertTrue(store.status.contains("newer draft kept"))
    let count = await http.requests.count
    XCTAssertEqual(count, 1)
  }

  func testReplySendKeepsNewerReplyAndOriginalMessage() async throws {
    let started = expectation(description: "Reply request started")
    let http = SendHTTP(started: started)
    let (store, database, _) = try fixture(http)
    var original = Samples.mail[0]
    original.draft = "Submitted reply"
    original.messageID = "<source@example.com>"
    original.replyTo = "Support <support@example.com>"
    store.mails = [original]
    try database.saveMailSnapshot(store.mails)
    let task = Task { [original] in
      await store.send(
        to: original.replyRecipient, subject: "Re: Launch", body: "Submitted reply", reply: original)
    }
    await fulfillment(of: [started], timeout: 2)
    store.saveReply(id: original.id, text: "A newer reply")
    await http.release()
    let success = await task.value
    XCTAssertTrue(success)
    let saved = try database.loadMail()
    XCTAssertEqual(saved.first { $0.id == original.id }?.draft, "A newer reply")
    XCTAssertEqual(saved.first { $0.id == original.id }?.body, original.body)
    XCTAssertEqual(saved.first { $0.id == "gmail-sent" }?.to, original.replyRecipient)
    XCTAssertEqual(saved.first { $0.id == "gmail-sent" }?.threadID, original.threadID)
  }

  func testUnchangedReplyIsClearedOnlyAfterSuccessfulSend() async throws {
    let (store, database, _) = try fixture(SendHTTP())
    var original = Samples.mail[0]
    original.draft = "Submitted reply"
    store.mails = [original]
    try database.saveMailSnapshot(store.mails)
    let success = await store.send(
      to: original.replyRecipient, subject: "Re: Launch", body: original.draft, reply: original)
    XCTAssertTrue(success)
    XCTAssertEqual(try database.loadMail().first { $0.id == original.id }?.draft, "")
    XCTAssertEqual(store.mails.count, 2)
  }

  func testInvalidRecipientMakesNoRequestAndSampleSendStaysLocal() async throws {
    let http = SendHTTP()
    let (store, database, _) = try fixture(http)
    let id = try draft(in: store)
    let invalid = await store.send(
      to: "friend@example.com\r\nBcc: other@example.com", subject: "Hello", body: "Café 🌊", draftID: id)
    XCTAssertFalse(invalid)
    XCTAssertEqual(try database.loadMail().first?.id, id)
    store.isSample = true
    let sample = await store.send(
      to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id)
    XCTAssertTrue(sample)
    XCTAssertTrue(try database.loadMail().first?.id.hasPrefix("local-sent-") == true)
    let count = await http.requests.count
    XCTAssertEqual(count, 0)
  }

  func testAcceptedSendWithStorageFailureDoesNotInviteResend() async throws {
    let (store, database, url) = try fixture(SendHTTP())
    let id = try draft(in: store)
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    defer { sqlite3_close(handle) }
    XCTAssertEqual(sqlite3_exec(handle,
      "CREATE TRIGGER fail_snapshot BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT,'test failure'); END;",
      nil, nil, nil), SQLITE_OK)
    let success = await store.send(
      to: "friend@example.com", subject: "Hello", body: "Café 🌊", draftID: id)
    XCTAssertTrue(success, "Gmail already accepted this send")
    XCTAssertTrue(store.error?.contains("Gmail sent the message") == true)
    XCTAssertTrue(store.error?.contains("Don’t send it again") == true)
    XCTAssertEqual(store.status, "Email sent · local save failed")
    XCTAssertEqual(store.mails.first?.id, "gmail-sent")
    XCTAssertEqual(try database.loadMail().first?.id, id, "Failed storage transaction preserves the previous snapshot")
  }
}

private actor SendHTTP: HTTPTransport {
  let status: Int
  let networkError: URLError.Code?
  let started: XCTestExpectation?
  let aliases: [String]
  private var pending: CheckedContinuation<Void, Never>?
  private(set) var requests: [URLRequest] = []

  init(status: Int = 200, networkError: URLError.Code? = nil, started: XCTestExpectation? = nil, aliases: [String] = []) {
    self.status = status
    self.networkError = networkError
    self.started = started
    self.aliases = aliases
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if request.url?.lastPathComponent == "sendAs" {
      return (try JSONSerialization.data(withJSONObject: ["sendAs": aliases.map {
        ["sendAsEmail": $0, "verificationStatus": "accepted"]
      }]), try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
        httpVersion: nil, headerFields: nil)))
    }
    if let started {
      await withCheckedContinuation { continuation in
        pending = continuation
        started.fulfill()
      }
    }
    if let networkError { throw URLError(networkError) }
    return (
      Data(#"{"id":"gmail-sent"}"#.utf8),
      try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
        httpVersion: nil, headerFields: nil)))
  }

  func release() {
    pending?.resume()
    pending = nil
  }
}
