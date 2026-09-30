import CoveCore
import XCTest

final class CustomAgentTemplateTests: XCTestCase {
  func testEveryTemplateIsAValidAgentThatStartsAsADraft() throws {
    XCTAssertEqual(Set(CustomAgentTemplate.all.map(\.id)).count, CustomAgentTemplate.all.count)
    for template in CustomAgentTemplate.all {
      let agent = try template.make().validated()
      XCTAssertEqual(agent.status, .draft, template.id)
      XCTAssertNotEqual(template.make().id, template.make().id, "each use is a new agent")
    }
    XCTAssertTrue(CustomAgentTemplate.all.contains { $0.drafts })
    XCTAssertTrue(CustomAgentTemplate.all.contains { $0.labels })
  }
}
