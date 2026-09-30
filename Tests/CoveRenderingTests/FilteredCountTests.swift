import Foundation
import XCTest

@testable import Cove
@testable import CoveCore

private final class CountHTTP: HTTPTransport, @unchecked Sendable {
  var listQueries: [String] = []
  var fetched: [String] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let object: [String: Any]
    if request.url!.lastPathComponent == "messages" {
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      listQueries.append(items.first { $0.name == "q" }?.value ?? "")
      object = ["messages": [["id": "existing"], ["id": "n1"], ["id": "n2"]]]
    } else {
      let id = request.url!.lastPathComponent
      fetched.append(id)
      object = ["id": id, "threadId": "t-\(id)", "labelIds": ["INBOX"], "internalDate": "1790000000000",
        "payload": ["mimeType": "text/plain", "headers": [["name": "Subject", "value": "ICE notice \(id)"], ["name": "From", "value": "ICE <alerts@ice.example>"]],
          "body": ["data": Data("Notice body".utf8).base64URL]]]
    }
    return (try JSONSerialization.data(withJSONObject: object),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor
final class FilteredCountTests: XCTestCase {
  func testSenderAndDateCountUsesTheModelsGmailSearchAndCountsExactly() async throws {
    XCTAssertEqual(MailboxQuestion.parse("how many emails from ICE on the last week?"), .unsupportedCount)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    let existing = Mail(id: "existing", sender: "ICE", senderEmail: "alerts@ice.example", subject: "Local copy", body: "Cached", labels: ["INBOX"], draft: "Keep me")
    try db.saveMailSnapshot([existing], historyID: "cursor")
    let http = CountHTTP()
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http),
      gmailTokenProvider: { "t" }, syncClock: { Date() })
    var prompts: [AIPrompt] = []
    let result = try await store.countMatchingMail("how many emails from ICE on the last week?", history: "") { prompt in
      prompts.append(prompt)
      return "`from:ICE newer_than:7d`"
    }
    XCTAssertEqual(prompts.count, 1)
    XCTAssertEqual(http.listQueries, ["(from:ICE newer_than:7d) -in:trash -in:spam -in:drafts"])
    XCTAssertTrue(result.answer.text.hasPrefix("3 emails match “from:ICE newer_than:7d”"), result.answer.text)
    XCTAssertEqual(Set(result.examples.map(\.id)), ["existing", "n1", "n2"])
    XCTAssertEqual(Set(http.fetched), ["n1", "n2"], "Stored emails are reused, not downloaded again")
    XCTAssertEqual(store.mails.first { $0.id == "existing" }?.draft, "Keep me")
    XCTAssertEqual(try db.load(String.self, key: "gmailHistoryID"), "cursor")
  }
}
