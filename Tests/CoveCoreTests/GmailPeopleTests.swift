import Foundation
import XCTest
@testable import CoveCore

final class GmailPeopleTests: XCTestCase {
  func testQuerySearchesFromToAndCcWithoutGmailOperators() {
    XCTAssertEqual(GmailClient.peopleQuery("maya"), "{from:maya to:maya cc:maya} -in:spam -in:trash")
    XCTAssertEqual(GmailClient.peopleQuery("  Maya   Chen "),
      #"{from:"Maya Chen" to:"Maya Chen" cc:"Maya Chen"} -in:spam -in:trash"#)
    // Operators and quotes typed into the field can't change the search.
    XCTAssertEqual(GmailClient.peopleQuery(#"a"} OR in:anywhere ("#),
      #"{from:"a OR in anywhere" to:"a OR in anywhere" cc:"a OR in anywhere"} -in:spam -in:trash"#)
    XCTAssertNil(GmailClient.peopleQuery("m"))
    XCTAssertNil(GmailClient.peopleQuery("\"()"))
  }

  func testFindsPeopleBeyondDownloadedMailFromHeadersOnly() async throws {
    let transport = PeopleHTTP { request in
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
      let items = components.queryItems ?? []
      switch components.path {
      case "/gmail/v1/users/me/messages":
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "{from:Ana to:Ana cc:Ana} -in:spam -in:trash")
        return (200, Data(#"{"messages":[{"id":"a"},{"id":"b"},{"id":"gone"}]}"#.utf8))
      case "/gmail/v1/users/me/messages/a":
        XCTAssertEqual(items.first { $0.name == "format" }?.value, "metadata")
        return (200, Data(#"{"internalDate":"2000","payload":{"headers":[{"name":"From","value":"Me <me@example.com>"},{"name":"To","value":"\"Ana Ruiz\" <ana@acme.com>, Bo <bo@acme.com>"},{"name":"Cc","value":"anabel@example.org"}]}}"#.utf8))
      case "/gmail/v1/users/me/messages/b":
        return (200, Data(#"{"internalDate":"1000","payload":{"headers":[{"name":"From","value":"Ana Ruiz <ANA@acme.com>"},{"name":"To","value":"me@example.com"},{"name":"Subject","value":"ignored"}]}}"#.utf8))
      default:
        return (404, Data(#"{"error":{"code":404}}"#.utf8))
      }
    }
    let people = try await GmailClient(transport: transport)
      .people(matching: "Ana", token: "fixture", accountEmail: "me@example.com")
    XCTAssertEqual(people.map(\.email), ["ana@acme.com", "anabel@example.org"])
    XCTAssertEqual(people.first?.name, "Ana Ruiz")
    XCTAssertTrue(people.allSatisfy { $0.messages.isEmpty })
  }

  func testRateLimitedLookupFailsAtOnceInsteadOfRetrying() async {
    let calls = Counter()
    let transport = PeopleHTTP { _ in
      calls.increment()
      return (429, Data(#"{"error":{"code":429,"errors":[{"reason":"rateLimitExceeded"}]}}"#.utf8))
    }
    do {
      _ = try await GmailClient(transport: transport).people(matching: "ana", token: "x", accountEmail: "me@example.com")
      XCTFail("Expected a rate limit")
    } catch {}
    XCTAssertEqual(calls.value, 1)
  }

  func testSuggestionsPutDownloadedPeopleFirstThenGmailWithoutDuplicates() {
    let mail = Mail(id: "1", sender: "Maya Chen", senderEmail: "maya@example.com", subject: "", body: "",
                    date: Date(), labels: ["INBOX"], isBulkOrAutomated: false)
    let local = [
      MailContact(email: "maya@example.com", name: "Maya Chen", record: nil, messages: [mail, mail]),
      MailContact(email: "sam@example.com", name: "Sam Mayer", record: nil, messages: [mail, mail, mail]),
      MailContact(email: "lee@example.com", name: "Lee", record: nil, messages: [mail]),
    ]
    let remote = [
      MailContact(email: "maya@example.com", name: "Maya Chen", record: nil, messages: []),
      MailContact(email: "mayra@corp.com", name: "Mayra Diaz", record: nil, messages: []),
      MailContact(email: "zed@corp.com", name: "Zed", record: nil, messages: []),
    ]
    let found = ContactDirectory.suggestions("may", local: local, remote: remote)
    // A name that starts with the text beats a later word; Gmail adds people not downloaded here.
    XCTAssertEqual(found.map(\.email), ["maya@example.com", "sam@example.com", "mayra@corp.com"])
    XCTAssertEqual(ContactDirectory.suggestions("may", local: local, remote: remote, excluding: ["maya@example.com"])
      .map(\.email), ["sam@example.com", "mayra@corp.com"])
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private struct PeopleHTTP: HTTPTransport {
  let respond: @Sendable (URLRequest) -> (Int, Data)
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (status, data) = respond(request)
    return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
