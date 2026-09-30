import XCTest

@testable import CoveCore

final class CoveCoreTests: XCTestCase {
  func testSQLitePersistsMailAndAccountState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("test.sqlite")
    var mail = Samples.mail[0]
    mail.draft = "A draft with unicode: café 🌊"
    mail.snoozedUntil = Date(timeIntervalSince1970: 2_000_000_000)
    do {
      let db = try Database(url: url)
      try db.saveMailSnapshot([mail])
      try db.save(Preferences(), key: "preferences")
    }
    let reopened = try Database(url: url)
    XCTAssertEqual(try reopened.loadMail(), [mail])
    XCTAssertNil(try reopened.load(String.self, key: "missing"))
    try reopened.saveMailSnapshot([])
    XCTAssertEqual(try reopened.loadMail(), [])
  }
  func testGmailNestedMIMEAndLabels() throws {
    let body = Data("Hello café!\nPlease review.".utf8).base64URL
    let fixture: [String: Any] = [
      "id": "abc", "threadId": "thread", "labelIds": ["INBOX", "UNREAD", "STARRED"],
      "internalDate": "1700000000000",
      "payload": [
        "mimeType": "multipart/mixed",
        "headers": [
          ["name": "From", "value": "\"Maya Chen\" <maya@example.com>"],
          ["name": "Subject", "value": "Review"],
          ["name": "Message-ID", "value": "<abc@example.com>"],
        ],
        "parts": [
          [
            "mimeType": "multipart/alternative",
            "parts": [
              [
                "mimeType": "text/html",
                "body": ["data": Data("<p>HTML alternative</p>".utf8).base64URL],
              ], ["mimeType": "text/plain", "body": ["data": body]],
            ],
          ]
        ],
      ],
    ]
    let message = try JSONDecoder().decode(
      GmailMessage.self, from: JSONSerialization.data(withJSONObject: fixture)
    ).mail()
    XCTAssertEqual(message.body, "Hello café!\nPlease review.")
    XCTAssertEqual(message.sender, "Maya Chen")
    XCTAssertEqual(message.senderEmail, "maya@example.com")
    XCTAssertTrue(message.isUnread)
    XCTAssertTrue(message.isStarred)
    XCTAssertEqual(message.date, Date(timeIntervalSince1970: 1_700_000_000))
  }
  func testHTMLFallbackDoesNotIncludeScripts() throws {
    XCTAssertEqual(
      GmailMessage.stripHTML(
        "<style>bad</style><script>alert('no')</script><p>Hello &amp; goodbye</p>"),
      "Hello & goodbye")
  }
  func testSendEncodingAndHeaderInjection() throws {
    let raw = try GmailClient.rawMessage(
      from: "me@example.com", to: "maya@example.com", subject: "Re: Website 🌊",
      body: "Hi Maya,\nCafé",
      replyMessageID: "<original@example.com>")
    let decoded = String(data: try XCTUnwrap(Data(base64URL: raw)), encoding: .utf8)!
    XCTAssertTrue(decoded.contains("In-Reply-To: <original@example.com>\r\n"))
    XCTAssertTrue(decoded.contains("Subject: =?UTF-8?B?"))
    XCTAssertTrue(decoded.contains(Data("Hi Maya,\nCafé".utf8).base64EncodedString()))
    XCTAssertThrowsError(
      try GmailClient.rawMessage(
        from: "me@example.com", to: "a@example.com\r\nBcc: victim@example.com", subject: "hello",
        body: "body"))
    XCTAssertThrowsError(
      try GmailClient.rawMessage(
        from: "me@example.com", to: "a@example.com", subject: "hello\nBcc: victim@example.com",
        body: "body"))
    XCTAssertThrowsError(
      try GmailClient.rawMessage(
        from: "me@example.com", to: "a@example.com", subject: "hello", body: "body",
        replyMessageID: "id\r\nBcc: victim@example.com"))
  }
  func testJevConfidenceGateAndSourceExcerpt() throws {
    let json = """
      {"model":"jev-1.13.0","answers":{"category":{"choice":"Work","confidence":0.4},"reply":{"noul":0.92},"urgent":{"noul":0.12},"excerpt":{"choice":"1","confidence":0.9}}}
      """
    let response = try JSONDecoder().decode(JevClient.Response.self, from: Data(json.utf8))
    let decision = try JevClient.decision(response, passages: ["Hi", "Please review by Friday."])
    XCTAssertEqual(decision.category, .other)
    XCTAssertEqual(decision.excerpt, "Please review by Friday.")
    XCTAssertEqual(decision.needsReply, 0.92)
    let invalid = json.replacingOccurrences(of: "0.92", with: "1.2")
    XCTAssertThrowsError(
      try JevClient.decision(
        JSONDecoder().decode(JevClient.Response.self, from: Data(invalid.utf8)), passages: []))
  }
  func testJevRequestMatchesPublishedContract() async throws {
    let transport = MockHTTP { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      XCTAssertEqual(body["model"] as? String, "jev-latest")
      let questions = body["questions"] as! [String: [String: Any]]
      XCTAssertEqual(questions["category"]?["type"] as? String, "choice")
      XCTAssertEqual(questions["reply"]?["type"] as? String, "noul")
      XCTAssertNotNil(questions["category"]?["criteria"])
      return Data(
        "{\"model\":\"jev-latest\",\"answers\":{\"category\":{\"choice\":\"Work\",\"confidence\":0.9},\"reply\":{\"noul\":0.8},\"urgent\":{\"noul\":0.7}}}"
          .utf8)
    }
    let decision = try await JevClient(transport: transport).classify(
      Samples.mail[0], key: "test-key", preferences: Preferences())
    XCTAssertEqual(decision.category, .work)
  }
  func testHTTPFailureDoesNotExposeResponseBody() async throws {
    let transport = MockHTTP(status: 401) { _ in Data("secret private message".utf8) }
    do {
      _ = try await checked(
        URLRequest(url: URL(string: "https://gmail.googleapis.com/test")!), transport: transport)
      XCTFail("Expected authentication error")
    } catch {
      XCTAssertFalse(error.localizedDescription.contains("secret"))
      XCTAssertTrue(error.localizedDescription.contains("401"))
    }
  }
  func testGmailPaginationAndSendPayload() async throws {
    let transport = MockHTTP { request in
      if request.url!.path.hasSuffix("/messages") {
        XCTAssertTrue(request.url!.absoluteString.contains("pageToken=next-page"))
        return Data("{\"messages\":[],\"nextPageToken\":\"page-three\"}".utf8)
      }
      XCTAssertTrue(request.url!.path.hasSuffix("/messages/send"))
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      XCTAssertEqual(body["threadId"] as? String, "sample-thread-0")
      XCTAssertNotNil(body["raw"])
      return Data("{\"id\":\"sent-id\"}".utf8)
    }
    let client = GmailClient(transport: transport)
    let page = try await client.page(token: "token", pageToken: "next-page")
    XCTAssertEqual(page.next, "page-three")
    let sentID = try await client.send(
      token: "token", from: "me@example.com", to: "maya@example.com", subject: "Re: review",
      body: "Hello",
      reply: Samples.mail[0])
    XCTAssertEqual(sentID, "sent-id")
  }
  func testCalendarAllDayAndCancelledEvents() throws {
    let allDay = Data(
      "{\"id\":\"event123\",\"summary\":\"Launch\",\"start\":{\"date\":\"2026-09-21\"},\"end\":{\"date\":\"2026-09-22\"}}"
        .utf8)
    let event = try JSONDecoder().decode(GoogleCalendarClient.Event.self, from: allDay).local()
    XCTAssertEqual(event?.allDay, true)
    XCTAssertEqual(event?.googleID, "event123")
    XCTAssertEqual(event?.title, "Launch")
    let cancelled = Data("{\"id\":\"cancelled\",\"status\":\"cancelled\"}".utf8)
    XCTAssertNil(try JSONDecoder().decode(GoogleCalendarClient.Event.self, from: cancelled).local())
  }
  func testCalendarPaginationAndCreate() async throws {
    let event =
      "{\"id\":\"event123\",\"summary\":\"Review\",\"start\":{\"dateTime\":\"2026-09-21T11:00:00-07:00\"},\"end\":{\"dateTime\":\"2026-09-21T12:00:00-07:00\"}}"
    let transport = MockHTTP { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer calendar-token")
      if request.httpMethod == "POST" {
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(payload["summary"] as? String, "Review")
        XCTAssertNil(payload["attendees"], "Creating a focus block must not invite anyone")
        return Data(event.utf8)
      }
      if request.url!.absoluteString.contains("pageToken=second") {
        return Data("{\"items\":[\(event)]}".utf8)
      }
      return Data("{\"items\":[],\"nextPageToken\":\"second\"}".utf8)
    }
    let client = GoogleCalendarClient(transport: transport)
    let events = try await client.events(
      token: "calendar-token", from: Date(), to: Date().addingTimeInterval(86400))
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].end.timeIntervalSince(events[0].start), 3600)
    let created = try await client.create(
      token: "calendar-token", title: "Review", start: events[0].start, end: events[0].end)
    XCTAssertEqual(created.id, "google-event123")
  }

}
struct MockHTTP: HTTPTransport {
  var status = 200
  var respond: (URLRequest) throws -> Data
  init(status: Int = 200, respond: @escaping (URLRequest) throws -> Data) {
    self.status = status
    self.respond = respond
  }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (
      try respond(request),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
}
