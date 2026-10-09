import XCTest
@testable import CoveCore

final class LabelEditRetryTests: XCTestCase {
  func testNetworkClassCodes() {
    for code in GmailFailureKind.networkCodes {
      XCTAssertEqual(GmailFailureKind.classify(URLError(code)), .network, "\(code)")
    }
    XCTAssertEqual(GmailFailureKind.classify(URLError(.badURL)), .other)
    XCTAssertEqual(GmailFailureKind.classify(URLError(.cancelled)), .other)
  }

  func testNetworkErrorFoundThroughUnderlyingError() {
    let inner = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
    let outer = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: inner])
    XCTAssertEqual(GmailFailureKind.classify(outer), .network)
    XCTAssertEqual(GmailFailureKind.classify(NSError(domain: "Wrapper", code: 1)), .other)
  }

  func testHTTPStatusClasses() {
    func kind(_ code: Int, reason: String? = nil) -> GmailFailureKind {
      GmailFailureKind.classify(HTTPFailure(statusCode: code, message: "x", reason: reason))
    }
    XCTAssertEqual(kind(429), .rateLimited)
    XCTAssertEqual(kind(403, reason: "userRateLimitExceeded"), .rateLimited)
    XCTAssertEqual(kind(403, reason: "forbidden"), .refused)
    XCTAssertEqual(kind(404), .gone)
    XCTAssertEqual(kind(401), .unauthorized)
    XCTAssertEqual(kind(400), .refused)
    XCTAssertEqual(kind(500), .server)
    XCTAssertEqual(kind(503), .server)
  }

  func testOnlyNetworkAndRateLimitStayQueued() {
    XCTAssertTrue(GmailFailureKind.network.keepsQueued)
    XCTAssertTrue(GmailFailureKind.rateLimited.keepsQueued)
    for kind in [GmailFailureKind.gone, .unauthorized, .refused, .server, .other] {
      XCTAssertFalse(kind.keepsQueued, "\(kind)")
    }
  }

  func testBackoffScheduleIsCapped() {
    XCTAssertEqual(LabelEditRetry.delay(afterAttempts: 0), 5)
    XCTAssertEqual(LabelEditRetry.delay(afterAttempts: 1), 5)
    XCTAssertEqual(LabelEditRetry.delay(afterAttempts: 2), 30)
    XCTAssertEqual(LabelEditRetry.delay(afterAttempts: 3), 120)
    XCTAssertEqual(LabelEditRetry.delay(afterAttempts: 50), 120)
  }

  func testEditsCombineNewestWins() {
    var edit = PendingLabelEdit()
    edit.combine(add: [], remove: ["INBOX"])
    edit.combine(add: ["STARRED"], remove: [])
    XCTAssertEqual(edit, PendingLabelEdit(add: ["STARRED"], remove: ["INBOX"]))
    edit.combine(add: ["INBOX"], remove: ["STARRED"])
    XCTAssertEqual(edit, PendingLabelEdit(add: ["INBOX"], remove: ["STARRED"]))
  }

  func testEditsRoundTripThroughJSON() throws {
    let queue = ["a": PendingLabelEdit(add: ["UNREAD"], remove: ["INBOX"])]
    let back = try JSONDecoder().decode([String: PendingLabelEdit].self, from: JSONEncoder().encode(queue))
    XCTAssertEqual(back, queue)
  }
}
