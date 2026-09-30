import CoveCore
import XCTest

final class CustomAgentBlueprintTests: XCTestCase {
  func testADescriptionBecomesAValidatedDraftAgent() throws {
    var base = CustomAgent(); base.name = "old"
    let reply = """
    ```json
    {"name":"Finance","instructions":"Invoices and bills from suppliers. Ignore receipts.","rules":[
      {"when":"A supplier says a payment is overdue","action":"labelAndDraft","label":"Finance / Invoices","reply":"Say I'll look into it."},
      {"when":"An invoice asks me to pay","action":"label","label":"Finance / Invoices","reply":""},
      {"when":"","action":"label","label":"X"},
      {"when":"Anything","action":"delete","label":"Trash"}
    ],"notify":true,"note":""}
    ```
    """
    let result = try CustomAgentBlueprint.agent(from: reply, keeping: base)
    XCTAssertEqual(result.agent.id, base.id, "rebuilding keeps the agent being edited")
    XCTAssertEqual(result.agent.status, .draft)
    XCTAssertEqual(result.agent.name, "Finance")
    XCTAssertEqual(result.agent.rules?.count, 2, "empty and unsupported rules are dropped")
    XCTAssertEqual(result.agent.rules?.first?.action, .labelAndDraft)
    XCTAssertTrue(result.agent.notifies)
    XCTAssertNil(result.note)
    XCTAssertNoThrow(try result.agent.validated())
    XCTAssertEqual(result.agent.plan.first?.does, "File it under Finance / Invoices and draft a reply for you to review")
  }

  func testReservedLabelsDowngradeOrDropTheRule() throws {
    let reply = #"{"name":"Stars","instructions":"x","rules":[{"when":"From my boss","action":"labelAndDraft","label":"STARRED","reply":"Thanks!"},{"when":"Newsletters","action":"label","label":"Inbox","reply":""}],"note":"Agents can't archive."}"#
    let result = try CustomAgentBlueprint.agent(from: reply)
    XCTAssertEqual(result.agent.rules?.map(\.action), [.draftReply])
    XCTAssertEqual(result.note, "Agents can't archive.")
  }

  func testNothingUsableAsksForMore() {
    XCTAssertThrowsError(try CustomAgentBlueprint.agent(from: "sorry"))
    XCTAssertThrowsError(try CustomAgentBlueprint.agent(from: #"{"name":"x","rules":[]}"#))
  }
}
