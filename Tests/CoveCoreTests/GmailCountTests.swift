import Foundation
import XCTest

@testable import CoveCore

private final class PagedHTTP: HTTPTransport, @unchecked Sendable {
  var queries: [String] = []
  let pages: [String]
  init(_ pages: [String]) { self.pages = pages }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    queries.append(items.first { $0.name == "q" }?.value ?? "")
    let token = items.first { $0.name == "pageToken" }?.value
    let body = token == nil ? pages[0] : pages[Int(token!)!]
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

final class GmailCountTests: XCTestCase {
  func testCountsEveryPageExactlyWithoutDownloadingContent() async throws {
    let http = PagedHTTP([
      #"{"messages":[{"id":"a"},{"id":"b"},{"id":"c"}],"nextPageToken":"1"}"#,
      #"{"messages":[{"id":"d"},{"id":"a"}]}"#,
    ])
    let result = try await GmailClient(transport: http).countMatches(query: "from:ice newer_than:7d", token: "t")
    XCTAssertEqual(result.count, 4)
    XCTAssertFalse(result.capped)
    XCTAssertEqual(result.newestIDs, ["a", "b", "c", "d"])
    XCTAssertEqual(http.queries.first, "(from:ice newer_than:7d) -in:trash -in:spam -in:drafts")
    XCTAssertEqual(http.queries.count, 2)
  }

  func testLargeResultsStopAtTheCap() async throws {
    let http = PagedHTTP([
      #"{"messages":[{"id":"a"},{"id":"b"},{"id":"c"}],"nextPageToken":"1"}"#,
      #"{"messages":[{"id":"d"}],"nextPageToken":"0"}"#,
    ])
    let result = try await GmailClient(transport: http).countMatches(query: "label:x", token: "t", cap: 3)
    XCTAssertEqual(result.count, 3)
    XCTAssertTrue(result.capped)
    XCTAssertEqual(http.queries.count, 1)
  }
}
