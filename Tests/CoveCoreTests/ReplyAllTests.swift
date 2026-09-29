import XCTest

@testable import CoveCore

final class ReplyAllTests: XCTestCase {
  private func decoded(headers extra: [[String: String]]) throws -> Mail {
    let headers = [["name": "From", "value": "Maya Chen <maya@example.com>"]] + extra
    let fixture: [String: Any] = [
      "id": "m", "threadId": "t",
      "payload": ["mimeType": "text/plain", "headers": headers, "body": ["data": Data("Hi".utf8).base64URL]],
    ]
    return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: fixture)).mail()
  }

  func testCcIsDecodedAndMissingCcIsKnownEmpty() throws {
    let withCc = try decoded(headers: [["name": "Cc", "value": "\"Lee, Sam\" <sam@example.com>"]])
    XCTAssertEqual(withCc.cc, "\"Lee, Sam\" <sam@example.com>")
    XCTAssertEqual(try decoded(headers: []).cc, "")
    // Older snapshots without the field decode as unknown.
    let legacy = try JSONEncoder().encode(Mail(id: "old", sender: "A", senderEmail: "a@example.com", subject: "S", body: "B"))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
    object.removeValue(forKey: "cc")
    XCTAssertNil(try JSONDecoder().decode(Mail.self, from: JSONSerialization.data(withJSONObject: object)).cc)
  }

  func testIncomingReplyAllExcludesSelfDeduplicatesAndKeepsQuotedNames() {
    let mail = Mail(
      id: "m", sender: "Maya Chen", senderEmail: "maya@example.com",
      to: "Alex <ALEX@example.com>, \"Lee, Sam\" <sam@example.com>", subject: "S", body: "B",
      cc: "sam@example.com, Jo <jo@example.com>, not-an-address, maya@example.com")
    let result = MailConversation.replyAllRecipients(for: mail, accountEmail: "alex@example.com")
    XCTAssertEqual(result?.to, "maya@example.com")
    XCTAssertEqual(result?.cc, "sam@example.com, Jo <jo@example.com>")
  }

  func testReplyToReceivesReplyAndSenderIsNotAddedToCc() {
    let mail = Mail(
      id: "m", sender: "Maya", senderEmail: "maya@example.com", to: "alex@example.com, sam@example.com",
      subject: "S", body: "B", replyTo: "Team <team@example.com>", cc: "")
    let result = MailConversation.replyAllRecipients(for: mail, accountEmail: "alex@example.com")
    XCTAssertEqual(result?.to, "Team <team@example.com>")
    XCTAssertEqual(result?.cc, "sam@example.com")
  }

  func testSentMailKeepsOriginalRecipientsAndUnknownOrSoloCcHidesReplyAll() {
    let sent = Mail(
      id: "s", sender: "Alex", senderEmail: "alex@example.com", to: "maya@example.com",
      subject: "S", body: "B", labels: ["SENT"], cc: "sam@example.com, alex@example.com")
    let result = MailConversation.replyAllRecipients(for: sent, accountEmail: "alex@example.com")
    XCTAssertEqual(result?.to, "maya@example.com")
    XCTAssertEqual(result?.cc, "sam@example.com")
    var unknown = sent; unknown.cc = nil
    XCTAssertNil(MailConversation.replyAllRecipients(for: unknown, accountEmail: "alex@example.com"))
    let solo = Mail(id: "i", sender: "Maya", senderEmail: "maya@example.com", to: "alex@example.com",
      subject: "S", body: "B", cc: "")
    XCTAssertNil(MailConversation.replyAllRecipients(for: solo, accountEmail: "alex@example.com"))
  }

  func testUnsafeDisplayNamesAreDroppedAndCcHeaderIsValidated() throws {
    let mail = Mail(
      id: "m", sender: "Maya", senderEmail: "maya@example.com", to: "alex@example.com",
      subject: "S", body: "B", cc: "\"Evil\\\" <x>\" <sam@example.com>")
    XCTAssertEqual(MailConversation.replyAllRecipients(for: mail, accountEmail: "alex@example.com")?.cc, "sam@example.com")
    let raw = try GmailClient.rawMessage(
      from: "alex@example.com", to: "maya@example.com", subject: "Re: S", body: "Body",
      date: Date(timeIntervalSince1970: 0), cc: "sam@example.com, Jo <jo@example.com>")
    let mime = try XCTUnwrap(String(data: try XCTUnwrap(Data(base64URL: raw)), encoding: .utf8))
    XCTAssertTrue(mime.contains("\r\nTo: maya@example.com\r\nCc: sam@example.com, Jo <jo@example.com>\r\nSubject:"))
    let plain = try GmailClient.rawMessage(from: "alex@example.com", to: "maya@example.com", subject: "S", body: "B")
    XCTAssertFalse(try XCTUnwrap(String(data: try XCTUnwrap(Data(base64URL: plain)), encoding: .utf8)).contains("Cc:"))
    for cc in ["sam@example.com\r\nBcc: x@example.com", "no address"] {
      XCTAssertThrowsError(try GmailClient.rawMessage(
        from: "alex@example.com", to: "maya@example.com", subject: "S", body: "B", cc: cc))
    }
  }
}
