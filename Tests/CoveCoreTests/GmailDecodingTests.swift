import XCTest

@testable import CoveCore

final class GmailDecodingTests: XCTestCase {
  private func mail(
    part: [String: Any], replyTo: String? = nil, snippet: String = "Truncated preview"
  ) throws -> Mail {
    var headers = [["name": "From", "value": "Notifications <notifications@example.com>"]]
    if let replyTo { headers.append(["name": "Reply-To", "value": replyTo]) }
    let fixture: [String: Any] = [
      "id": "message", "threadId": "thread", "snippet": snippet,
      "payload": ["mimeType": "multipart/mixed", "headers": headers, "parts": [part]],
    ]
    return try JSONDecoder().decode(
      GmailMessage.self, from: JSONSerialization.data(withJSONObject: fixture)
    ).mail()
  }

  func testDeclaredLatin1CharsetDecodesEntireNestedBody() throws {
    let body = "Café résumé - not UTF-8"
    let bytes = try XCTUnwrap(body.data(using: .isoLatin1))
    let decoded = try mail(part: [
      "mimeType": "multipart/alternative",
      "parts": [
        [
          "mimeType": "text/plain",
          "headers": [["name": "content-type", "value": "text/plain; CHARSET = \"ISO-8859-1\""]],
          "body": ["data": bytes.base64URL],
        ]
      ],
    ])
    XCTAssertEqual(decoded.body, body)
  }

  func testDeclaredWindows1252CharsetDecodesHTMLBeforeStrippingTags() throws {
    let html = "<p>“Your café booking” costs €20.</p><p>Complete details follow.</p>"
    let bytes = try XCTUnwrap(html.data(using: .windowsCP1252))
    let decoded = try mail(part: [
      "mimeType": "text/html",
      "headers": [["name": "Content-Type", "value": "text/html; charset=windows-1252"]],
      "body": ["data": bytes.base64URL],
    ])
    XCTAssertEqual(decoded.body, "“Your café booking” costs €20.\nComplete details follow.")
  }

  func testUnknownCharsetPreservesBodyInsteadOfReturningSnippet() throws {
    let decoded = try mail(part: [
      "mimeType": "text/plain",
      "headers": [["name": "Content-Type", "value": "text/plain; charset=unknown-encoding"]],
      "body": [
        "data": (Data("Start ".utf8) + Data([0xFF]) + Data(" complete ending".utf8)).base64URL
      ],
    ])
    XCTAssertEqual(decoded.body, "Start � complete ending")
  }

  func testMislabeledUTF8RequiresCorroboratingNonASCIISnippet() throws {
    let body = "Hace unos días volvió el café del barrio. Todos los detalles siguen aquí."
    for charset in ["iso-8859-1", "windows-1252"] {
      let decoded = try mail(
        part: [
          "mimeType": "multipart/alternative",
          "parts": [
            [
              "mimeType": "text/plain",
              "headers": [["name": "Content-Type", "value": "text/plain; charset=\(charset)"]],
              "body": ["data": Data(body.utf8).base64URL],
            ]
          ],
        ], snippet: "Hace unos días volvió el café del barrio.")
      XCTAssertEqual(decoded.body, body, charset)
    }
  }

  func testHTMLCorroborationNormalizesMarkupEntitiesAndWhitespace() throws {
    let html =
      "<p>Hace unos días <strong>volvió</strong> el café &amp; el té.</p><p>Más detalles.</p>"
    let decoded = try mail(
      part: [
        "mimeType": "text/html",
        "headers": [["name": "Content-Type", "value": "text/html; charset=ISO-8859-1"]],
        "body": ["data": Data(html.utf8).base64URL],
      ], snippet: "Hace unos días\n volvió el café &amp; el té.")
    XCTAssertEqual(decoded.body, "Hace unos días volvió el café & el té.\nMás detalles.")
  }

  // Since the mojibake repair: UTF-8 bytes under a Latin-1 header read correctly even without a
  // corroborating snippet (real Latin-1 accents are never valid UTF-8 runs).
  func testUTF8UnderALatin1HeaderReadsCorrectlyWithoutASnippet() throws {
    let body = "Plain opening. Hace unos días volvió el café del barrio."
    let bytes = Data(body.utf8)
    let declared = body
    for snippet in ["", "Otros días con texto diferente", "Plain opening.", "días"] {
      let decoded = try mail(
        part: [
          "mimeType": "text/plain",
          "headers": [["name": "Content-Type", "value": "text/plain; charset=iso-8859-1"]],
          "body": ["data": bytes.base64URL],
        ], snippet: snippet)
      XCTAssertEqual(decoded.body, declared, snippet)
    }
  }

  /// The deliberate trade-off: text that spells mojibake on purpose is repaired too. That is far rarer
  /// than mail whose accents arrive broken ("botÃ³n"), which Cove now always fixes.
  func testLiteralMojibakeIsRepairedLikeBrokenText() throws {
    let body = "The literal characters Ã© describe mojibake in this example."
    let bytes = try XCTUnwrap(body.data(using: .isoLatin1))
    XCTAssertNotNil(
      String(data: bytes, encoding: .utf8), "These genuine legacy bytes are ambiguous")
    let decoded = try mail(
      part: [
        "mimeType": "text/plain",
        "headers": [["name": "Content-Type", "value": "text/plain; charset=iso-8859-1"]],
        "body": ["data": bytes.base64URL],
      ], snippet: "The literal characters Ã© describe mojibake")
    XCTAssertEqual(decoded.body, "The literal characters é describe mojibake in this example.")
  }

  func testCorroboratingSnippetCannotOverrideOtherDeclaredCharsets() throws {
    let body = "Hace unos días volvió el café del barrio."
    let bytes = Data(body.utf8)
    let decoded = try mail(
      part: [
        "mimeType": "text/plain",
        "headers": [["name": "Content-Type", "value": "text/plain; charset=iso-8859-2"]],
        "body": ["data": bytes.base64URL],
      ], snippet: body)
    XCTAssertEqual(decoded.body, String(data: bytes, encoding: .isoLatin2))
    XCTAssertNotEqual(decoded.body, body)
  }

  func testReplyToOverridesSenderAndPreservesDisplayName() throws {
    let recipient = "\"Customer Support\" <support@example.com>"
    let decoded = try mail(
      part: ["mimeType": "text/plain", "body": ["data": Data("Hello".utf8).base64URL]],
      replyTo: recipient)
    XCTAssertEqual(decoded.senderEmail, "notifications@example.com")
    XCTAssertEqual(decoded.replyRecipient, recipient)
    let raw = try GmailClient.rawMessage(
      from: "me@example.com", to: decoded.replyRecipient, subject: "Re: Hello", body: "Hi")
    let mime = try XCTUnwrap(String(data: XCTUnwrap(Data(base64URL: raw)), encoding: .utf8))
    XCTAssertTrue(mime.contains("\r\nTo: \(recipient)\r\n"))
  }

  func testReplyToDoesNotBypassHeaderInjectionValidation() throws {
    let decoded = try mail(
      part: ["mimeType": "text/plain"],
      replyTo: "support@example.com\r\nBcc: other@example.com")
    XCTAssertThrowsError(
      try GmailClient.rawMessage(
        from: "me@example.com", to: decoded.replyRecipient, subject: "Reply", body: "Hello"))
  }

  func testReplyRecipientFallsBackAndOldCachedMessagesStillDecode() throws {
    var original = Samples.mail[0]
    original.replyTo = "   "
    XCTAssertEqual(original.replyRecipient, original.senderEmail)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "replyTo")
    let restored = try JSONDecoder().decode(
      Mail.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(restored.replyTo)
    XCTAssertEqual(restored.replyRecipient, original.senderEmail)
    original.replyTo = "support@example.com"
    XCTAssertEqual(
      try JSONDecoder().decode(Mail.self, from: JSONEncoder().encode(original)).replyRecipient,
      "support@example.com")
  }
}
