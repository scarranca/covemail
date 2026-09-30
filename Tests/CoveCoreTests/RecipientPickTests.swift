import XCTest

@testable import CoveCore

final class RecipientPickTests: XCTestCase {
  private let marthas = [
    MailContact(email: "martha@gigstack.io", name: "Martha Salazar", record: nil, messages: []),
    MailContact(email: "mpcrico@icloud.com", name: "Martha Cayetano Rico", record: nil, messages: []),
  ]
  func testShortAnswersToWhichOnePickTheRightPerson() {
    XCTAssertEqual(RecipientResolver.pick(from: marthas, reply: "@gigstack one")?.email, "martha@gigstack.io")
    XCTAssertEqual(RecipientResolver.pick(from: marthas, reply: "the icloud one")?.email, "mpcrico@icloud.com")
    XCTAssertEqual(RecipientResolver.pick(from: marthas, reply: "Salazar")?.email, "martha@gigstack.io")
    XCTAssertEqual(RecipientResolver.pick(from: marthas, reply: "la de Rico")?.email, "mpcrico@icloud.com")
    XCTAssertEqual(RecipientResolver.pick(from: marthas, reply: "the first one")?.email, "martha@gigstack.io")
    XCTAssertEqual(RecipientResolver.pick(from: marthas, reply: "2")?.email, "mpcrico@icloud.com")
    XCTAssertEqual(RecipientResolver.pick(from: marthas, reply: "MPCRICO@icloud.com")?.email, "mpcrico@icloud.com")
    XCTAssertNil(RecipientResolver.pick(from: marthas, reply: "Martha"), "Still ambiguous: ask again rather than guess")
    XCTAssertNil(RecipientResolver.pick(from: marthas, reply: "what’s the weather"))
  }
}
