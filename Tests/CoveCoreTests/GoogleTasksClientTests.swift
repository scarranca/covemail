import CoveCore
import XCTest

final class GoogleTasksClientTests: XCTestCase {
  func testCompletedAsksForRecentlyFinishedTasksIncludingHiddenOnes() async throws {
    let transport = TasksFixtureHTTP(body: #"{"items":[{"id":"a","title":"Send contract","status":"completed","completed":"2026-09-29T18:04:11.000Z"},{"id":"b","title":"Open one","status":"needsAction"}]}"#)
    let since = Date(timeIntervalSince1970: 1_790_000_000)
    let tasks = try await GoogleTasksClient(transport: transport).completed(token: "t", since: since)
    XCTAssertEqual(tasks.map(\.id), ["a"], "only completed tasks are returned")
    XCTAssertNotNil(tasks.first?.completedAt)
    let recorded = await transport.last
    let items = URLComponents(url: try XCTUnwrap(recorded?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    XCTAssertEqual(value("showCompleted"), "true")
    XCTAssertEqual(value("showHidden"), "true")
    XCTAssertEqual(value("completedMin"), ISO8601DateFormatter().string(from: since))
  }
}

private actor TasksFixtureHTTP: HTTPTransport {
  let body: String
  var last: URLRequest?
  init(body: String) { self.body = body }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    last = request
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
