import XCTest
@testable import CoveCore

final class PersonalContextTests: XCTestCase {
  func testPromptIsBoundedLabeledAndOffWhenDisabled() throws {
    var context = PersonalContext()
    XCTAssertNil(context.promptText)
    context.name = "Santiago"
    context.role = "Founder"
    context.company = "gigstack"
    context.projects = [.init(name: "Cove", detail: "calm Gmail client")]
    context.notes = (0..<40).map { "Note \($0) " + String(repeating: "x", count: 300) }
    context.signature = "Best,\nSantiago"
    let text = try XCTUnwrap(context.promptText)
    XCTAssertTrue(text.hasPrefix("About the user, in their own words"))
    XCTAssertTrue(text.contains("Who: Santiago, Founder, gigstack"))
    XCTAssertTrue(text.contains("Working on: Cove — calm Gmail client"))
    XCTAssertTrue(text.contains("Signs emails as: Best, / Santiago"))
    XCTAssertLessThanOrEqual(text.utf8.count, 2_500)
    context.enabled = false
    XCTAssertNil(context.promptText)
  }

  func testRememberAndForgetCommands() {
    XCTAssertEqual(PersonalContext.command(in: "Remember that I'm in Mexico City."), .remember("I'm in Mexico City"))
    XCTAssertEqual(PersonalContext.command(in: "recuerda que mi jefa es Ana"), .remember("mi jefa es Ana"))
    XCTAssertEqual(PersonalContext.command(in: "Forget Mexico"), .forget("Mexico"))
    XCTAssertNil(PersonalContext.command(in: "What needs my attention?"))
    var context = PersonalContext()
    XCTAssertEqual(context.apply(.remember("I'm in Mexico City")), ["I'm in Mexico City"])
    XCTAssertEqual(context.apply(.remember("i'm in mexico city")), [])
    XCTAssertEqual(context.apply(.forget("méxico")), ["I'm in Mexico City"])
    XCTAssertTrue(context.notes.isEmpty)
  }

  func testSuggestionFillsOnlyEmptyFields() throws {
    var context = PersonalContext()
    context.name = "Santiago Carrancá"
    context.projects = [.init(name: "Cove")]
    let merged = try context.merging(suggestion: """
      {"name":"Someone Else","role":"CEO","company":"gigstack","about":"Builds invoicing software.",
       "signature":"Saludos,\\nSantiago","projects":[{"name":"cove","detail":"dup"},{"name":"Invoices API","detail":"v2 launch"}]}
      """)
    XCTAssertEqual(merged.name, "Santiago Carrancá")
    XCTAssertEqual(merged.role, "CEO")
    XCTAssertEqual(merged.projects.map(\.name), ["Cove", "Invoices API"])
    XCTAssertThrowsError(try context.merging(suggestion: "no json here"))
  }
}
