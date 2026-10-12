import XCTest
@testable import CoveCore

final class InlineImageMailTests: XCTestCase {
  func testInlineMIMEHasAlternativeRelatedCIDAndOrdinaryFile() throws {
    var image = OutgoingAttachment(filename: "photo.png", data: Data([1, 2, 3]))
    image.inline = true
    let file = OutgoingAttachment(filename: "notes.txt", data: Data("notes".utf8))
    let body = "Before <script> & 👋\n" + image.bodyToken + "\nAfter"
    let message = try GmailClient.mimeMessage(from: "a@example.com", to: "b@example.com", subject: "Inline",
      body: body, replyMessageID: "<original@example.com>", attachments: [image, file])
    // The mobile preflight uses rawMessage before scheduling its Undo Send action.
    XCTAssertFalse(try GmailClient.rawMessage(from: "a@example.com", to: "b@example.com", subject: "Inline",
      body: body, attachments: [image, file]).isEmpty)
    let raw = String(decoding: message, as: UTF8.self)
    for type in ["mixed", "alternative", "related"] { XCTAssertTrue(raw.contains("multipart/" + type)) }
    XCTAssertTrue(raw.contains("Content-ID: <\(image.contentID)>"))
    XCTAssertEqual(raw.components(separatedBy: "Content-Disposition: inline;").count, 2)
    XCTAssertEqual(raw.components(separatedBy: "Content-Disposition: attachment;").count, 2)
    XCTAssertTrue(raw.contains("In-Reply-To: <original@example.com>"))
    let html = try decodedPart("text/html", raw)
    XCTAssertTrue(html.contains("Before &lt;script&gt; &amp; 👋\n<img src=\"cid:\(image.contentID)\""))
    XCTAssertTrue(html.contains("\nAfter"))
    XCTAssertFalse(html.contains("cove-inline:"))
    XCTAssertEqual(try decodedPart("text/plain", raw), "Before <script> & 👋\n[Image]\nAfter")
    try message.write(to: URL(fileURLWithPath: "/tmp/cove-inline.eml"))
  }

  func testDeletedImagesAreNotSentAndLegacyAttachmentsDecode() throws {
    var removed = OutgoingAttachment(filename: "gone.png", data: Data([9]))
    removed.inline = true
    let raw = String(decoding: try GmailClient.mimeMessage(from: "a@example.com", to: "b@example.com", subject: "s",
      body: "Kept", attachments: [removed]), as: UTF8.self)
    XCTAssertFalse(raw.contains("multipart"))
    XCTAssertFalse(raw.contains(removed.contentID))
    let old = #"{"id":"00000000-0000-0000-0000-000000000001","filename":"old.png","mimeType":"image/png","data":"AQID"}"#
    let decoded = try JSONDecoder().decode(OutgoingAttachment.self, from: Data(old.utf8))
    XCTAssertNil(decoded.inline)
    XCTAssertEqual(decoded.data, Data([1, 2, 3]))
  }

  func testMissingImageCannotSilentlySendAToken() throws {
    let image = OutgoingAttachment(filename: "missing.png", data: Data([1]))
    XCTAssertThrowsError(try GmailClient.mimeMessage(from: "a@example.com", to: "b@example.com", subject: "s", body: image.bodyToken))
  }

  private func decodedPart(_ mime: String, _ raw: String) throws -> String {
    let start = try XCTUnwrap(raw.range(of: "Content-Type: \(mime); charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"))
    let rest = raw[start.upperBound...]
    let end = try XCTUnwrap(rest.range(of: "\r\n--cove-"))
    let encoded = rest[..<end.lowerBound].replacingOccurrences(of: "\r\n", with: "")
    return String(decoding: try XCTUnwrap(Data(base64Encoded: encoded)), as: UTF8.self)
  }
}
