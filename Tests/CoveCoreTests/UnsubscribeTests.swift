import CoveCore
import XCTest

final class UnsubscribeTests: XCTestCase {
  func testOneClickNeedsBothHeadersAndHTTPS() throws {
    let both = try XCTUnwrap(MailUnsubscribe.parse(
      header: "<mailto:leave@news.example?subject=Remove%20me>,\r\n <https://news.example/u?id=1>",
      post: "List-Unsubscribe=One-Click"))
    XCTAssertEqual(both.kind, .oneClick)
    XCTAssertEqual(both.oneClick?.absoluteString, "https://news.example/u?id=1")
    XCTAssertEqual(both.mailto, "leave@news.example")
    XCTAssertEqual(both.mailSubject, "Remove me")

    let noPost = try XCTUnwrap(MailUnsubscribe.parse(header: "<https://news.example/u?id=1>"))
    XCTAssertEqual(noPost.kind, .web, "without List-Unsubscribe-Post it is only a page to open")
    XCTAssertNil(noPost.oneClick)

    let mailOnly = try XCTUnwrap(MailUnsubscribe.parse(header: "<mailto:leave@news.example>"))
    XCTAssertEqual(mailOnly.kind, .email)
    XCTAssertEqual(mailOnly.mailSubject, "unsubscribe")
  }

  func testUnsafeOrEmptyEntriesAreIgnored() {
    XCTAssertNil(MailUnsubscribe.parse(header: ""))
    XCTAssertNil(MailUnsubscribe.parse(header: "<http://news.example/u>", post: "List-Unsubscribe=One-Click"))
    XCTAssertNil(MailUnsubscribe.parse(header: "<javascript:alert(1)>"))
    XCTAssertNil(MailUnsubscribe.parse(header: "<mailto:a@x.example,b@y.example>"))
  }

  func testOneClickPostsOnlyTheStandardBody() async throws {
    let transport = RecordingHTTP(status: 202)
    try await UnsubscribeClient(transport: transport).oneClick(URL(string: "https://news.example/u?id=1")!)
    let recorded = await transport.last
    let request = try XCTUnwrap(recorded)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    XCTAssertEqual(request.httpBody.map { String(decoding: $0, as: UTF8.self) }, "List-Unsubscribe=One-Click")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

    await XCTAssertThrowsErrorAsync { try await UnsubscribeClient(transport: RecordingHTTP(status: 500)).oneClick(URL(string: "https://news.example/u")!) }
  }
}

private actor RecordingHTTP: HTTPTransport {
  let status: Int
  var last: URLRequest?
  init(status: Int) { self.status = status }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    last = request
    return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

private func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
  do { try await body(); XCTFail("Expected an error", file: file, line: line) } catch {}
}
