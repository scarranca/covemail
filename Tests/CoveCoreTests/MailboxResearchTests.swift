import XCTest

@testable import CoveCore

final class MailboxResearchTests: XCTestCase {
  private func mail(_ n: Int) -> Mail {
    Mail(id: "m\(n)", sender: "Angel Hub", senderEmail: "team@angelhub.example", subject: "Update \(n)",
      body: "Angel Hub update number \(n).", date: Date(timeIntervalSince1970: Double(n) * 1_000))
  }

  func testBroadenStripsOperatorsBracesAndQuotes() {
    XCTAssertEqual(MailboxResearch.broaden(#"{from:"angel hub" to:"angel hub"}"#), "angel hub")
    XCTAssertEqual(MailboxResearch.broaden(#"subject:(demo day) after:2026/01/01 -in:spam"#), "demo day")
    XCTAssertNil(MailboxResearch.broaden("after:2026/01/01"))
  }

  func testNotesMapBatchCitationsToGlobalEmails() {
    let notes = MailboxResearch.notes("- Demo day moved to Oct 14 [2]\n- Fee is $500 [1][3]\n- ignored [9]\nintro text", offset: 20, count: 3)
    XCTAssertEqual(notes.map(\.text), ["Demo day moved to Oct 14", "Fee is $500", "ignored"])
    XCTAssertEqual(notes.map(\.sources), [[21], [20, 22], []])
    XCTAssertTrue(MailboxResearch.notes("NONE", offset: 0, count: 5).isEmpty)
  }

  func testLargeQuestionReadsAllMatchesInBatchesAndAnswersFromMostCitedEmails() async throws {
    let all = (1...45).map(mail)
    var prompts: [AIPrompt] = []
    var progress: [String] = []
    let research = MailboxResearch(liveSearch: true, complete: { prompt in
      prompts.append(prompt)
      if prompt.system.contains("Translate the user's request") { return #"{from:"angel hub" to:"angel hub"}"# }
      if prompt.system.contains("Extract only facts") { return "- Something relevant [1]\n- Also [2]" }
      return #"{"summary":"Answer","primary":null,"checks":[]}"#
    }, find: { query in
      // The topic-as-person query finds nothing; the broadened one finds everything.
      query.contains("from:") ? .init(mails: [], estimatedTotal: 0) : .init(mails: all.shuffled(), estimatedTotal: 60, hasMore: true)
    })
    let outcome = try await research.run("summarize everything about angel hub", progress: { progress.append($0) })
    XCTAssertEqual(outcome.queries, [#"{from:"angel hub" to:"angel hub"}"#, "angel hub"])
    XCTAssertEqual(outcome.read.count, 45)
    XCTAssertEqual(Set(outcome.read.map(\.body)), Set(all.map(\.body)), "read keeps full bodies for saving")
    XCTAssertEqual(prompts.filter { $0.system.contains("Extract only facts") }.count, 3, "45 emails → 3 batches")
    XCTAssertLessThanOrEqual(outcome.sourceMails.count, 20)
    XCTAssertEqual(outcome.sourceMails.count, 6, "each batch cited its first two emails")
    XCTAssertTrue(outcome.partial, "Gmail reported more matches than were read")
    XCTAssertTrue(outcome.summary.hasPrefix("Read 45 of about 60 matching emails (partial)"))
    let final = try XCTUnwrap(prompts.last)
    XCTAssertTrue(final.evidence.contains("Findings from 45 matching emails"))
    XCTAssertTrue(final.evidence.contains("Something relevant ["))
    // Only final source numbers appear; batch-global numbers never leak.
    let pattern = try NSRegularExpression(pattern: #"\[(\d+)\]"#)
    let evidence = final.evidence
    let cited = Set(pattern.matches(in: evidence, range: NSRange(evidence.startIndex..., in: evidence)).compactMap {
      Range($0.range(at: 1), in: evidence).flatMap { Int(evidence[$0]) } })
    XCTAssertTrue(cited.isSubset(of: Set(1...outcome.sourceMails.count)), "\(cited)")
    XCTAssertTrue(progress.contains { $0.contains("Reading emails 41–45 of 45") })
  }

  func testSmallAndEmptyResults() async throws {
    var calls = 0
    let small = MailboxResearch(liveSearch: false, complete: { _ in calls += 1; return "{}" },
      find: { _ in .init(mails: (1...5).map(self.mail), estimatedTotal: 5) })
    let outcome = try await small.run("angel hub", progress: { _ in })
    XCTAssertEqual(calls, 1, "Up to 20 emails are answered in one pass")
    XCTAssertEqual(outcome.sourceMails.count, 5)
    XCTAssertFalse(outcome.partial)
    XCTAssertEqual(outcome.summary, "Read all 5 matching emails")

    let empty = MailboxResearch(liveSearch: true, complete: { _ in "zzzqqq" }, find: { _ in .init(mails: [], estimatedTotal: 0) })
    let none = try await empty.run("nothing", progress: { _ in })
    XCTAssertNil(none.generated)
    XCTAssertEqual(none.summary, "No matching emails · searched: “zzzqqq”")
  }

  func testOverlongFindingsAreMarkedPartialAndStayWithinEvidenceLimit() async throws {
    var final: AIPrompt?
    let long = String(repeating: "detail ", count: 40)
    let research = MailboxResearch(liveSearch: false, complete: { prompt in
      if prompt.system.contains("Extract only facts") { return (1...20).map { "- \(long) [\($0)]" }.joined(separator: "\n") }
      final = prompt; return "{}"
    }, find: { _ in .init(mails: (1...100).map(self.mail), estimatedTotal: 100) })
    let outcome = try await research.run("everything", history: String(repeating: "h", count: 5_000), progress: { _ in })
    XCTAssertTrue(outcome.partial)
    let evidence = try XCTUnwrap(final?.evidence)
    XCTAssertFalse(evidence.contains("PARTIAL LOOKUP RESULTS"), "never reaches AIPrompt's truncation marker")
    XCTAssertTrue(evidence.contains("Findings from 100 matching emails"))
  }

  func testGmailResearchPaginatesAndReusesStoredMail() async throws {
    let http = PagingHTTP()
    let stored = ["a": mail(1)]
    let results = try await GmailClient(transport: http).research(query: "angel hub", token: "t", limit: 150, stored: stored)
    XCTAssertEqual(results.estimatedTotal, 240)
    XCTAssertTrue(results.hasMore == false || results.mails.count == 150)
    XCTAssertEqual(results.mails.count, 150)
    let paths = await http.paths
    XCTAssertEqual(paths.filter { $0 == "messages" }.count, 2, "two list pages")
    XCTAssertFalse(paths.contains("a"), "stored mail isn't downloaded again")
  }
}

private actor PagingHTTP: HTTPTransport {
  var paths: [String] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url!.lastPathComponent
    paths.append(path)
    let object: [String: Any]
    if path == "messages" {
      let second = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "pageToken" }
      let ids = second ? (100..<150).map { "x\($0)" } : ["a"] + (1..<100).map { "x\($0)" }
      object = ["messages": ids.map { ["id": $0] }, "resultSizeEstimate": 240] .merging(second ? [:] : ["nextPageToken": "p2"]) { a, _ in a }
    } else {
      object = ["id": path, "threadId": path, "labelIds": ["INBOX"], "internalDate": "1000",
        "payload": ["mimeType": "text/plain", "headers": [["name": "From", "value": "A <a@example.com>"]],
          "body": ["data": Data("hi".utf8).base64URL]]]
    }
    return (try JSONSerialization.data(withJSONObject: object),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
