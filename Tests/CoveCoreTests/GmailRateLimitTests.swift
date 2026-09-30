import Foundation
import XCTest

@testable import CoveCore

private actor ScriptedHTTP: HTTPTransport {
  var responses: [(Int, String)]
  var calls = 0
  init(_ responses: [(Int, String)]) { self.responses = responses }
  nonisolated func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await next(request)
  }
  private func next(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    calls += 1
    let (status, body) = responses.isEmpty ? (200, "{}") : responses.removeFirst()
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

final class GmailRateLimitTests: XCTestCase {
  private let rateLimited = #"{"error":{"code":403,"message":"User-rate limit exceeded <secret@example.com>","errors":[{"reason":"rateLimitExceeded"}],"status":"PERMISSION_DENIED"}}"#
  private let noScope = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#

  func testRateLimitedReadsAreRetriedUntilGmailAccepts() async throws {
    let http = ScriptedHTTP([(403, rateLimited), (429, "{}"), (200, #"{"emailAddress":"me@example.com"}"#)])
    let address = try await GmailClient(transport: http).profile(token: "t")
    XCTAssertEqual(address, "me@example.com")
    let calls = await http.calls
    XCTAssertEqual(calls, 3)
  }

  func testPersistentRateLimitStopsWithAClearMessageAndNoProviderText() async throws {
    let http = ScriptedHTTP(Array(repeating: (403, rateLimited), count: 10))
    do {
      _ = try await GmailClient(transport: http).profile(token: "t")
      XCTFail("Expected rate limit")
    } catch let failure as HTTPFailure {
      XCTAssertTrue(failure.isRateLimited)
      XCTAssertEqual(failure.reason, "rateLimitExceeded")
      XCTAssertTrue(failure.message.contains("Gmail is limiting"))
      XCTAssertFalse(failure.message.contains("secret"))
    }
    let calls = await http.calls
    XCTAssertEqual(calls, 6)
  }

  func testServerErrorsAreNotRetriedForWritesButPermissionsExplainReconnect() async throws {
    let send = ScriptedHTTP([(503, "{}"), (200, "{}")])
    do {
      _ = try await GmailClient(transport: send).request("messages/send", token: "t", method: "POST", body: ["raw": "x"])
      XCTFail("Expected failure")
    } catch let failure as HTTPFailure { XCTAssertEqual(failure.statusCode, 503) }
    let sendCalls = await send.calls
    XCTAssertEqual(sendCalls, 1)

    let scope = ScriptedHTTP([(403, noScope)])
    do {
      _ = try await GmailClient(transport: scope).profile(token: "t")
      XCTFail("Expected failure")
    } catch let failure as HTTPFailure {
      XCTAssertTrue(failure.isMissingPermission)
      XCTAssertTrue(failure.message.contains("Reconnect"))
    }
    let scopeCalls = await scope.calls
    XCTAssertEqual(scopeCalls, 1)
  }

  func testReasonParserKeepsOnlyIdentifierTokens() {
    XCTAssertEqual(providerReason(Data(#"{"error":{"status":"<script>alert(1)</script>"}}"#.utf8)), nil)
    XCTAssertEqual(providerReason(Data("not json".utf8)), nil)
    XCTAssertEqual(providerReason(Data(#"{"error":{"status":"RESOURCE_EXHAUSTED"}}"#.utf8)), "RESOURCE_EXHAUSTED")
  }
}
