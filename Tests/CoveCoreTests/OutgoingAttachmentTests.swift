import XCTest

@testable import CoveCore

final class OutgoingAttachmentTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_800_000_000)

  private func message(_ files: [OutgoingAttachment]) throws -> String {
    String(decoding: try GmailClient.mimeMessage(from: "me@example.com", to: "ana@example.com", subject: "Plan",
      body: "Hola Ana", replyMessageID: "<a@example.com>", date: date, attachments: files), as: UTF8.self)
  }

  func testWithoutAttachmentsTheMessageIsTheSingleTextPartAsBefore() throws {
    let text = try message([])
    XCTAssertTrue(text.contains("Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\nIn-Reply-To: <a@example.com>"))
    XCTAssertFalse(text.contains("multipart"))
    XCTAssertEqual(try GmailClient.rawMessage(from: "me@example.com", to: "ana@example.com", subject: "Plan", body: "Hola Ana",
      replyMessageID: "<a@example.com>", date: date), Data(text.utf8).base64URL)
  }

  func testFilesBecomeMultipartMixedAndRoundTripExactly() throws {
    let pdf = Data((0..<5_000).map { UInt8($0 % 251) })
    let files = [OutgoingAttachment(filename: "Propuesta año.pdf", data: pdf),
                 OutgoingAttachment(filename: "notes.txt", data: Data("línea".utf8))]
    let text = try message(files)
    let boundary = try XCTUnwrap(text.range(of: #"boundary="([^"]+)""#, options: .regularExpression).map {
      String(text[$0].dropFirst(10).dropLast()) })
    XCTAssertTrue(text.contains("Content-Type: multipart/mixed; boundary=\"\(boundary)\""))
    XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
    let parts = text.components(separatedBy: "--\(boundary)\r\n").dropFirst().map { $0.components(separatedBy: "\r\n--\(boundary)").first! }
    XCTAssertEqual(parts.count, 3)
    XCTAssertTrue(parts[0].hasPrefix("Content-Type: text/plain"))
    func decoded(_ part: String) -> Data? {
      let body = part.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
      return Data(base64Encoded: body.replacingOccurrences(of: "\r\n", with: ""))
    }
    XCTAssertEqual(decoded(parts[0]), Data("Hola Ana".utf8))
    XCTAssertEqual(decoded(parts[1]), pdf)
    XCTAssertEqual(decoded(parts[2]), Data("línea".utf8))
    XCTAssertTrue(parts[1].contains("Content-Type: application/pdf; name=\"Propuesta a_o.pdf\""))
    XCTAssertTrue(parts[1].contains("filename*=UTF-8''Propuesta%20a%C3%B1o.pdf"))
    XCTAssertTrue(parts[2].hasPrefix("Content-Type: text/plain; name=\"notes.txt\""))
    // The outer message has no single-part transfer encoding.
    let header = text.components(separatedBy: "\r\n\r\n")[0]
    XCTAssertFalse(header.contains("Content-Transfer-Encoding"))
  }

  func testNamesCannotBreakHeadersAndTheLimitIsEnforced() throws {
    let sneaky = OutgoingAttachment(filename: "a\r\nBcc: x@example.com\".pdf", data: Data([1]))
    XCTAssertEqual(sneaky.filename, "aBcc: x@example.com.pdf")
    XCTAssertFalse(try message([sneaky]).contains("\r\nBcc:"))
    let big = OutgoingAttachment(filename: "big.bin", data: Data(count: OutgoingAttachment.totalLimit))
    let small = OutgoingAttachment(filename: "small.bin", data: Data(count: 10))
    XCTAssertThrowsError(try message([big, small]))
    let added = OutgoingAttachment.adding([small, big], to: [])
    XCTAssertEqual(added.files.map(\.filename), ["small.bin"])
    XCTAssertTrue(added.problem?.contains("big.bin") == true)
  }

  func testUploadSendKeepsTheThreadAndNeverRetriesAServerError() async throws {
    let http = UploadHTTP(status: 200)
    let gmail = GmailClient(transport: http)
    var reply = Mail(id: "m1", threadID: "t9", sender: "Ana", senderEmail: "ana@example.com", subject: "Plan", body: "", date: date)
    reply.messageID = "<a@example.com>"
    let id = try await gmail.send(token: "t", from: "me@example.com", to: "ana@example.com", subject: "Re: Plan", body: "Adjunto",
      reply: reply, attachments: [OutgoingAttachment(filename: "a.pdf", data: Data([1, 2, 3]))])
    XCTAssertEqual(id, "sent-1")
    let requests = await http.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart")
    let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
    XCTAssertTrue(type.hasPrefix("multipart/related; boundary="))
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    XCTAssertTrue(body.contains("Content-Type: application/json; charset=UTF-8\r\n\r\n{\"threadId\":\"t9\"}"))
    XCTAssertTrue(body.contains("Content-Type: message/rfc822\r\n\r\nFrom: me@example.com"))

    let failing = UploadHTTP(status: 500)
    do {
      _ = try await GmailClient(transport: failing).send(token: "t", from: "me@example.com", to: "ana@example.com", subject: "x",
        body: "x", attachments: [OutgoingAttachment(filename: "a.pdf", data: Data([1]))])
      XCTFail("expected failure")
    } catch {}
    let attempts = await failing.requests.count
    XCTAssertEqual(attempts, 1, "a send is never repeated after a server error")
  }
}

private actor UploadHTTP: HTTPTransport {
  let status: Int
  var requests: [URLRequest] = []
  init(status: Int) { self.status = status }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let body = status == 200 ? #"{"id":"sent-1"}"# : #"{"error":{"code":500,"message":"backend"}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
