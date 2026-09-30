import XCTest
@testable import CoveCore

final class WritingContextTests: XCTestCase {
  func testRecipientContextIncludesIncomingAndOutgoingExcludesDraftSpamAndOtherPeople() {
    let input = [
      Mail(id: "in", sender: "Maya", senderEmail: "maya@example.com", subject: "A", body: "Incoming"),
      Mail(id: "out", sender: "Me", senderEmail: "alias@example.com", to: "Maya <maya@example.com>", subject: "B", body: "Outgoing", labels: ["SENT"]),
      Mail(id: "other", sender: "Other", senderEmail: "other@example.com", subject: "C", body: "Other"),
      Mail(id: "draft", sender: "Me", senderEmail: "me@example.com", to: "maya@example.com", subject: "D", body: "Draft", labels: ["DRAFT"])
    ]
    XCTAssertEqual(Set(WritingContext.recentMail(to: "\"Chen, Maya\" <MAYA@example.com>", mails: input).map(\.id)), ["in", "out"])
    XCTAssertTrue(WritingContext.recentMail(to: "not yet an address", mails: input).isEmpty)
  }
  func testToolPlansRejectMutationTooManyCallsAndUnboundedDates() {
    for text in [
      #"{"tools":[{"name":"send_mail"}]}"#,
      #"{"tools":[{"name":"calendar","from":"2026-01-01T00:00:00Z","to":"2027-01-01T00:00:00Z"}]}"#,
      #"{"tools":[{"name":"calendar","from":"tomorrow","to":"Friday"}]}"#,
      #"{"tools":[{"name":"search_mail","query":""}]}"#,
      #"{"tools":[{"name":"search_mail","query":"a"},{"name":"search_mail","query":"b"},{"name":"search_mail","query":"c"},{"name":"search_mail","query":"d"}]}"#
    ] { XCTAssertThrowsError(try WritingToolPlan.parse(text)) }
  }
  func testCalendarLookupRejectsIncompletePagination() async throws {
    var requests = 0
    let calendar = GoogleCalendarClient(transport: MockHTTP { _ in
      requests += 1
      return Data("{\"items\":[],\"nextPageToken\":\"page-\(requests)\"}".utf8)
    })
    do {
      _ = try await calendar.events(token: "synthetic", from: Date(), to: Date().addingTimeInterval(86400), maxPages: 2)
      XCTFail("Incomplete calendar must not establish availability")
    } catch { XCTAssertEqual(requests, 2) }
  }

  func testTruncatedLookupEvidenceIsExplicitlyPartial() throws {
    let prompt = try AIPrompt(intent: .write, instruction: "Draft", mails: [], evidence: String(repeating: "event ", count: 4000))
    XCTAssertTrue(prompt.evidence.hasPrefix("PARTIAL LOOKUP RESULTS"))
    XCTAssertLessThan(prompt.evidence.utf8.count, 12_100)
  }
  func testClarificationHasNoToolsAndIsBounded() throws {
    let plan = try WritingToolPlan.parse(#"{"tools":[],"clarification":"Which day should I check?"}"#)
    XCTAssertEqual(plan.clarification, "Which day should I check?")
    for input in [
      #"{"tools":[],"clarification":" "}"#,
      #"{"tools":[{"name":"search_mail","query":"a"}],"clarification":"Which person?"}"#,
      "{\"tools\":[],\"clarification\":\"" + String(repeating: "a", count: 501) + "\"}"
    ] { XCTAssertThrowsError(try WritingToolPlan.parse(input)) }
  }

}

final class WritingLookupSignalTests: XCTestCase {
  func testWordingRequestsSkipLookupsButSearchAndScheduleDoNot() {
    for request in ["Make this warmer", "shorter please", "translate to English", "hazlo más formal", "fix the grammar",
                    "feel free to shorten this", "one more try, sometimes it's too long"] {
      XCTAssertFalse(WritingToolPlan.mightNeedLookup(request), request)
    }
    for request in ["Find Maya's latest email", "suggest times tomorrow", "when are you free", "propose a time", "¿cuándo es la reunión?", "mention the meeting", "busca el último correo"] {
      XCTAssertTrue(WritingToolPlan.mightNeedLookup(request), request)
    }
  }
}
