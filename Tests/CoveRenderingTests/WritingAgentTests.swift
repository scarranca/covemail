import CoveCore
import XCTest
@testable import Cove

@MainActor final class WritingAgentTests: XCTestCase {
  func testToolsFeedEvidenceAndEnvelopeIntoDraftWithoutChangingMail() async throws {
    let mail = Mail(id: "source", sender: "Maya", senderEmail: "maya@example.com", subject: "Launch", body: "Review on Friday.")
    var prompts: [AIPrompt] = []
    var searches: [String] = []
    var calendarCalls = 0
    var stages: [String] = []
    let agent = WritingAgent(complete: { prompt in
      prompts.append(prompt)
      return prompts.count == 1 ? #"{"tools":[{"name":"search_mail","query":"from:maya@example.com"},{"name":"calendar","from":"2026-09-24T00:00:00Z","to":"2026-09-26T00:00:00Z"}]}"# : "Hi Maya, could we confirm Friday?"
    }, search: { query in searches.append(query); return [mail] }, calendar: { from, to in
      calendarCalls += 1
      return [LocalEvent(title: "Launch review", start: from.addingTimeInterval(3600), end: from.addingTimeInterval(7200))]
    }, calendarAvailable: true)
    let result = try await agent.draft(instruction: "Propose time for Maya's review", draft: "", mails: [mail],
      envelope: "From: alias@example.com\nTo: maya@example.com\nSubject: Launch", useTools: true) { stages.append($0) }
    XCTAssertEqual(searches, ["from:maya@example.com"])
    XCTAssertEqual(calendarCalls, 1)
    XCTAssertEqual(prompts.count, 2)
    XCTAssertTrue(prompts[0].sourceMails.isEmpty, "Mail evidence cannot direct the lookup planner")
    XCTAssertTrue(prompts[1].user.contains("To: maya@example.com"))
    XCTAssertTrue(prompts[1].user.contains("alias@example.com"))
    XCTAssertTrue(prompts[1].dataMessage.contains("Launch review"))
    XCTAssertTrue(prompts[1].dataMessage.contains("Review on Friday."))
    XCTAssertFalse(prompts[1].system.contains("Review on Friday."))
    XCTAssertEqual(result.mails.map(\.id), ["source"])
    XCTAssertTrue(mail.isUnread, "Read-only tools do not mark mail read")
    XCTAssertEqual(stages, ["Finding the right context", "Looking up conversations", "Checking dates in Calendar", "Writing your suggestion"])
  }

  func testDisabledLookupsCallOnlyWriterAndNoTools() async throws {
    var completions = 0
    let agent = WritingAgent(complete: { _ in completions += 1; return "Draft" },
      search: { _ in XCTFail("Unexpected mail lookup"); return [] },
      calendar: { _, _ in XCTFail("Unexpected calendar lookup"); return [] }, calendarAvailable: false)
    _ = try await agent.draft(instruction: "Hello", draft: "", mails: [], envelope: "To: a@example.com", useTools: false) { _ in }
    XCTAssertEqual(completions, 1)
  }

  func testUnavailableCalendarDoesNotExecuteAndReportsMissingEvidence() async throws {
    var prompts: [AIPrompt] = []
    let agent = WritingAgent(complete: { p in
      prompts.append(p)
      return prompts.count == 1 ? #"{"tools":[{"name":"calendar","from":"2026-09-24T00:00:00Z","to":"2026-09-26T00:00:00Z"}]}"# : "Could you confirm availability?"
    }, search: { _ in [] }, calendar: { _, _ in XCTFail("No calendar permission"); return [] }, calendarAvailable: false)
    let result = try await agent.draft(instruction: "Find time", draft: "", mails: [], envelope: "", useTools: true) { _ in }
    XCTAssertEqual(result.activity, ["Calendar lookup unavailable"])
    XCTAssertTrue(prompts.last!.evidence.contains("failed"))
  }

  func testInvalidMutationPlanFailsBeforeAnyToolOrDraft() async throws {
    var completions = 0
    let agent = WritingAgent(complete: { _ in completions += 1; return #"{"tools":[{"name":"send_email","query":"x"}]}"# },
      search: { _ in XCTFail("Invalid plan executed"); return [] }, calendar: { _, _ in XCTFail("Invalid plan executed"); return [] }, calendarAvailable: true)
    do {
      _ = try await agent.draft(instruction: "Draft a reply to Maya's latest email", draft: "", mails: [], envelope: "", useTools: true) { _ in }
      XCTFail("Expected rejection")
    } catch { XCTAssertEqual(completions, 1) }
  }

  func testAccountCancellationFromToolNeverFallsThroughToWriter() async throws {
    var completions = 0
    let agent = WritingAgent(complete: { _ in
      completions += 1
      return #"{"tools":[{"name":"search_mail","query":"from:x@example.com"}]}"#
    }, search: { _ in throw CancellationError() }, calendar: { _, _ in [] }, calendarAvailable: false)
    do {
      _ = try await agent.draft(instruction: "Draft a reply to Maya's latest email", draft: "", mails: [], envelope: "", useTools: true) { _ in }
      XCTFail("Expected account cancellation")
    } catch is CancellationError {} catch { XCTFail("Wrong error") }
    XCTAssertEqual(completions, 1)
  }

  func testCancellationBetweenPlanAndToolsStopsExecution() async throws {
    let ready = expectation(description: "Plan ready")
    var continuePlan: CheckedContinuation<Void, Never>?
    var completions = 0
    let agent = WritingAgent(complete: { _ in
      completions += 1
      await withCheckedContinuation { continuePlan = $0; ready.fulfill() }
      return #"{"tools":[{"name":"search_mail","query":"from:x@example.com"}]}"#
    }, search: { _ in XCTFail("Cancelled search ran"); return [] }, calendar: { _, _ in []; }, calendarAvailable: false)
    let task = Task { try await agent.draft(instruction: "Draft a reply to Maya's latest email", draft: "", mails: [], envelope: "", useTools: true) { _ in } }
    await fulfillment(of: [ready], timeout: 1)
    task.cancel(); continuePlan?.resume()
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    XCTAssertEqual(completions, 1)
  }
  func testClarificationStopsBeforeToolsAndWriterAndPlannerExcludesPreferences() async throws {
    var completions = 0
    let agent = WritingAgent(complete: { p in
      completions += 1
      XCTAssertTrue(p.user.contains("Current user request:\nFind a free time"))
      XCTAssertFalse(p.user.contains("SECRET_PREFERENCE"))
      XCTAssertFalse(p.user.contains("UNTRUSTED_MAIL"))
      return #"{"tools":[],"clarification":"Which day should I check?"}"#
    }, search: { _ in XCTFail(); return [] }, calendar: { _, _ in XCTFail(); return [] }, calendarAvailable: true)
    do {
      _ = try await agent.draft(instruction: "Find a free time. SECRET_PREFERENCE", draft: "UNTRUSTED_MAIL", mails: [],
        envelope: "To: maya@example.com", useTools: true, userInstruction: "Find a free time") { _ in }
      XCTFail("Missing date should ask the user")
    } catch { XCTAssertEqual(error.localizedDescription, "Which day should I check?") }
    XCTAssertEqual(completions, 1)
  }

  func testFreshSearchEvidenceIsPrioritizedAndDuplicateCallsRunOnce() async throws {
    let context = (0..<20).map { Mail(id: "old-\($0)", sender: "Maya", senderEmail: "maya@example.com", subject: "Old", body: "Old context") }
    let found = Mail(id: "latest", sender: "Maya", senderEmail: "maya@example.com", subject: "New quote", body: "The new quote is 4200.")
    var completions = 0
    var searches = 0
    let agent = WritingAgent(complete: { p in
      completions += 1
      if completions == 1 {
        return #"{"tools":[{"name":"search_mail","query":"{from:maya@example.com to:maya@example.com}"},{"name":"search_mail","query":"{from:maya@example.com to:maya@example.com}"}]}"#
      }
      XCTAssertEqual(p.sourceMails.first?.id, "latest")
      XCTAssertTrue(p.evidence.contains("resultCount"))
      XCTAssertTrue(p.evidence.contains("New quote"))
      return "The quote is 4200."
    }, search: { _ in searches += 1; return [found] }, calendar: { _, _ in XCTFail(); return [] }, calendarAvailable: false)
    let result = try await agent.draft(instruction: "Find Maya's latest quote", draft: "", mails: context,
      envelope: "To: maya@example.com", useTools: true) { _ in }
    XCTAssertEqual(searches, 1)
    XCTAssertEqual(result.mails.count, 20)
    XCTAssertEqual(result.mails.first?.id, "latest")
    XCTAssertTrue(result.activity.first?.contains("from:maya@example.com") == true)
  }

}

@MainActor final class WritingSchedulingAgentTests: XCTestCase {
  let zone = TimeZone(identifier: "America/Los_Angeles")!
  let request = "Please ask to meet on my first tiem available tomorrow"
  let expected = "Thursday, September 24, 2026 at 10:00 AM PDT"
  func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  func testOmittedToolStillReadsCalendarAndCorrectsGenericOutputBeforeReturning() async throws {
    var prompts: [AIPrompt] = []
    var calendarReads = 0
    let agent = WritingAgent(complete: { p in
      prompts.append(p)
      if prompts.count == 1 { return #"{"tools":[]}"# }
      if prompts.count == 2 { return "Hi Martha, would you meet at my first available time?" }
      return "Hi Martha, would \(self.expected) work for a 30-minute meeting?"
    }, search: { _ in XCTFail("Unneeded search"); return [] }, calendar: { from, to in
      calendarReads += 1
      XCTAssertEqual(from, self.date("2026-09-24T07:00:00Z"))
      XCTAssertEqual(to, self.date("2026-09-25T07:00:00Z"))
      return [LocalEvent(title: "Private title never needed by writer", start: self.date("2026-09-24T16:00:00Z"), end: self.date("2026-09-24T17:00:00Z"))]
    }, calendarAvailable: true, now: date("2026-09-24T02:00:00Z"), timeZone: zone)
    let result = try await agent.draft(instruction: request, draft: "", mails: [], envelope: "To: martha@example.com", useTools: true) { _ in }
    XCTAssertEqual(calendarReads, 1)
    XCTAssertEqual(prompts.count, 3)
    XCTAssertTrue(result.text.contains(expected))
    XCTAssertTrue(prompts[1].user.contains(expected))
    XCTAssertFalse(prompts[1].dataMessage.contains("Private title"))
    XCTAssertTrue(result.activity.joined().contains("30-minute"))
    XCTAssertTrue(result.activity.joined().contains("09:00–17:00"))
  }
  func testGenericCalendarToolIsReplacedByDeterministicAvailabilityAndMoreThan40EventsStayComplete() async throws {
    var completions = 0
    var reads = 0
    let agent = WritingAgent(complete: { _ in
      completions += 1
      return completions == 1 ? #"{"tools":[{"name":"calendar","from":"2026-09-24T00:00:00Z","to":"2026-09-25T00:00:00Z"}]}"# : "Meet \(self.expected)?"
    }, search: { _ in [] }, calendar: { _, _ in
      reads += 1
      return (0..<60).map { _ in LocalEvent(title: "Busy", start: self.date("2026-09-24T16:00:00Z"), end: self.date("2026-09-24T17:00:00Z")) }
    }, calendarAvailable: true, now: date("2026-09-24T02:00:00Z"), timeZone: zone)
    let result = try await agent.draft(instruction: request, draft: "", mails: [], envelope: "", useTools: true) { _ in }
    XCTAssertEqual(reads, 1)
    XCTAssertTrue(result.text.contains(expected))
  }
  func testCalendarUnavailableDisabledIncompleteOrFullNeverProducesVagueDraft() async throws {
    for failure in ["unavailable", "disabled", "incomplete", "full", "cancel"] {
      var completions = 0
      let agent = WritingAgent(complete: { _ in completions += 1; return #"{"tools":[]}"# }, search: { _ in [] }, calendar: { from, to in
        if failure == "cancel" { throw CancellationError() }
        if failure == "incomplete" { throw CoveError.message("Calendar results are incomplete.") }
        return [LocalEvent(title: "Away", start: from, end: to)]
      }, calendarAvailable: failure != "unavailable", now: date("2026-09-24T02:00:00Z"), timeZone: zone)
      do {
        _ = try await agent.draft(instruction: request, draft: "Original", mails: [], envelope: "", useTools: failure != "disabled") { _ in }
        XCTFail("\(failure) produced a draft")
      } catch {
        XCTAssertLessThanOrEqual(completions, 1, "Writer must never run without verified slot")
        if failure == "cancel" { XCTAssertTrue(error is CancellationError) }
      }
    }
  }
  func testProviderThatStillOmitsTimeFailsAfterOneCorrection() async throws {
    var completions = 0
    let agent = WritingAgent(complete: { _ in completions += 1; return completions == 1 ? #"{"tools":[]}"# : "Let's meet at my first available time." }, search: { _ in [] }, calendar: { _, _ in [] }, calendarAvailable: true, now: date("2026-09-24T02:00:00Z"), timeZone: zone)
    do {
      _ = try await agent.draft(instruction: request, draft: "", mails: [], envelope: "", useTools: true) { _ in }
      XCTFail("Generic suggestion returned")
    } catch { XCTAssertTrue(error.localizedDescription.contains("verified meeting time")) }
    XCTAssertEqual(completions, 3)
  }
  func testRawRequestExcludesSavedSchedulingPreferencesFromIntentGuard() async throws {
    var completions = 0
    let agent = WritingAgent(complete: { _ in completions += 1; return "Thanks!" }, search: { _ in [] }, calendar: { _, _ in XCTFail(); return [] }, calendarAvailable: false)
    let result = try await agent.draft(instruction: "Say thanks. Saved preference: ask before scheduling my first available meeting", draft: "", mails: [], envelope: "", useTools: false, userInstruction: "Say thanks") { _ in }
    XCTAssertEqual(result.text, "Thanks!")
    XCTAssertEqual(completions, 1)
  }
}
