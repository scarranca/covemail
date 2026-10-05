import XCTest
@testable import CoveCore

final class AgentBrainTests: XCTestCase {
  private func agent() -> CustomAgent {
    var agent = CustomAgent()
    agent.name = "Finance"
    agent.instructions = "Invoices and payment requests from suppliers."
    agent.rules = [CustomAgentRule(condition: "An invoice is attached or requested", labelName: "Finance / Invoices"),
                   CustomAgentRule(condition: "A payment is overdue", action: .labelAndDraft, labelName: "Finance / Overdue", replyInstructions: "Ask for details")]
    return agent
  }

  func testParsesStepsConfidenceAndReason() throws {
    let finance = agent()
    let decision = try AgentBrain.decision(from: #"{"choice":"step_2","confidence":0.92,"why":"The supplier says invoice 118 is 30 days late.","quote":"invoice 118 is now 30 days overdue"}"#,
                                           agent: finance, model: "claude")
    XCTAssertEqual(decision.outcome, .match)
    XCTAssertEqual(decision.ruleID, finance.rules?[1].id)
    XCTAssertEqual(decision.rule(for: finance)?.labelName, "Finance / Overdue")
    XCTAssertEqual(decision.reason, "The supplier says invoice 118 is 30 days late.")
    XCTAssertEqual(decision.excerpt, "invoice 118 is now 30 days overdue")
  }

  func testLowConfidenceOrWarningsBecomeReview() throws {
    XCTAssertEqual(try AgentBrain.decision(from: #"{"choice":"step_1","confidence":0.5,"why":"maybe"}"#, agent: agent(), model: "m").outcome, .review)
    XCTAssertEqual(try AgentBrain.decision(from: #"{"choice":"step_1","confidence":0.95,"why":"yes"}"#, agent: agent(), model: "m",
                                           warnings: ["Attachment unreadable"]).outcome, .review)
    let no = try AgentBrain.decision(from: #"{"choice":"noMatch","confidence":0.9,"why":"A newsletter."}"#, agent: agent(), model: "m")
    XCTAssertEqual(no.outcome, .noMatch)
    XCTAssertNil(no.ruleID)
  }

  func testRejectsUnknownStepsAndGarbage() {
    XCTAssertThrowsError(try AgentBrain.decision(from: #"{"choice":"step_9","confidence":1}"#, agent: agent(), model: "m"))
    XCTAssertThrowsError(try AgentBrain.decision(from: "I think it's an invoice", agent: agent(), model: "m"))
  }

  func testInstructionCarriesContextExamplesAndUntrustedRule() {
    var agent = agent()
    let mail = Mail(id: "1", sender: "Ana", senderEmail: "ana@supplier.example", subject: "Invoice 118", body: "Please pay.")
    agent.learn(CustomAgentExample(mail: mail, verdict: "Step 1: An invoice is attached or requested"))
    agent.learn(CustomAgentExample(mail: mail, verdict: "Not a match"))
    XCTAssertEqual(agent.examples?.count, 1, "a newer verdict on the same email replaces the old one")
    let text = AgentBrain.instruction(agent: agent, sender: "Sender: Ana.", about: "About the user: founder.")
    XCTAssertTrue(text.contains("step_2: A payment is overdue"))
    XCTAssertTrue(text.contains("→ Not a match"))
    XCTAssertTrue(text.contains("About the user: founder."))
    XCTAssertTrue(text.contains("untrusted evidence"))
  }

  func testSenderSummaryCountsHistory() {
    let mail = Mail(id: "new", sender: "Ana", senderEmail: "ana@supplier.example", subject: "Hi", body: "")
    let earlier = Mail(id: "a", sender: "Ana", senderEmail: "ana@supplier.example", subject: "Earlier", body: "",
                       date: Date().addingTimeInterval(-3 * 86_400))
    let sent = Mail(id: "b", sender: "Me", senderEmail: "me@example.com", to: "Ana <ana@supplier.example>", subject: "Re", body: "", labels: ["SENT"])
    let summary = AgentBrain.senderSummary(for: mail, in: [mail, earlier, sent], account: "me@example.com")
    XCTAssertTrue(summary.contains("1 earlier emails from them, 1 emails the user sent them"), summary)
    XCTAssertTrue(AgentBrain.senderSummary(for: mail, in: [mail], account: "me@example.com").contains("First email"))
  }
}
