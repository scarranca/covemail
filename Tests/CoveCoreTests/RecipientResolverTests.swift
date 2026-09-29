import XCTest

@testable import CoveCore

final class RecipientResolverTests: XCTestCase {
  private func contact(_ name: String, _ email: String, days: Double = 0) -> MailContact {
    MailContact(email: email, name: name, record: nil,
      messages: [Mail(id: email, sender: name, senderEmail: email, subject: "S", body: "B", date: Date(timeIntervalSince1970: days * 86_400))])
  }

  func testExactAccentInsensitiveAndFirstNameMatches() {
    let contacts = [contact("Alberto Díaz", "alberto@example.com"), contact("Maya Chen", "maya@example.com"),
      contact("Me", "me@example.com")]
    guard case .resolved(let people) = RecipientResolver.resolve(["alberto diaz", "Maya"], contacts: contacts,
      question: "intro Alberto and Maya", accountEmail: "me@example.com") else { return XCTFail() }
    XCTAssertEqual(people.map(\.email), ["alberto@example.com", "maya@example.com"])
  }

  func testAmbiguousAndMissingNamesAskInsteadOfGuessing() {
    let contacts = [contact("Ana López", "ana.l@example.com", days: 1), contact("Ana Ruiz", "ana.r@example.com", days: 2)]
    let ambiguous = RecipientResolver.resolve(["Ana"], contacts: contacts, question: "email Ana", accountEmail: "me@example.com")
    guard case .ambiguous(_, let candidates) = ambiguous else { return XCTFail() }
    XCTAssertEqual(candidates.map(\.email), ["ana.r@example.com", "ana.l@example.com"])
    XCTAssertTrue(ambiguous.clarification?.contains("ana.l@example.com") == true)
    XCTAssertEqual(RecipientResolver.resolve(["Luis"], contacts: contacts, question: "email Luis", accountEmail: "me@example.com"),
      .missing(name: "Luis"))
  }

  func testAddressesOnlyWhenTypedByUserOrAlreadyKnown() {
    let contacts = [contact("Maya Chen", "maya@example.com")]
    guard case .resolved(let typed) = RecipientResolver.resolve(["luis@example.com"], contacts: contacts,
      question: "intro Maya and luis@example.com", accountEmail: "me@example.com") else { return XCTFail() }
    XCTAssertEqual(typed.map(\.email), ["luis@example.com"])
    // A model-invented address that the user never typed is rejected.
    XCTAssertEqual(RecipientResolver.resolve(["luis.garcia@company.com"], contacts: contacts,
      question: "intro Maya and Luis", accountEmail: "me@example.com"), .missing(name: "luis.garcia@company.com"))
    XCTAssertEqual(RecipientResolver.resolve(["me@example.com"], contacts: contacts,
      question: "email me@example.com", accountEmail: "me@example.com"), .missing(name: "me@example.com"))
  }
}
