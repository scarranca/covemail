import XCTest

@testable import CoveCore

final class AccountRosterTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: "Cove.AccountRosterTests." + UUID().uuidString)!
  }

  func testAddKeepsOrderAndIgnoresCaseDuplicates() {
    XCTAssertEqual(AccountRoster.emails(defaults), [])
    AccountRoster.add("first@example.com", defaults)
    AccountRoster.add("second@example.com", defaults)
    AccountRoster.add("FIRST@example.com", defaults)
    AccountRoster.add("", defaults)
    XCTAssertEqual(AccountRoster.emails(defaults), ["first@example.com", "second@example.com"])
    XCTAssertEqual(defaults.stringArray(forKey: "accounts.roster"), ["first@example.com", "second@example.com"])
  }

  func testRemoveIsCaseInsensitiveAndKeepsTheRest() {
    for email in ["a@example.com", "b@example.com", "c@example.com"] { AccountRoster.add(email, defaults) }
    AccountRoster.remove("B@EXAMPLE.COM", defaults)
    XCTAssertEqual(AccountRoster.emails(defaults), ["a@example.com", "c@example.com"])
    AccountRoster.remove("missing@example.com", defaults)
    XCTAssertEqual(AccountRoster.emails(defaults), ["a@example.com", "c@example.com"])
    AccountRoster.remove("a@example.com", defaults)
    AccountRoster.remove("c@example.com", defaults)
    XCTAssertEqual(AccountRoster.emails(defaults), [])
  }

  func testSessionKeyIsCaseInsensitiveHexDigest() {
    let key = AccountRoster.sessionKey(for: "Person@Example.com")
    XCTAssertEqual(key, AccountRoster.sessionKey(for: "person@example.com"))
    XCTAssertNotEqual(key, AccountRoster.sessionKey(for: "other@example.com"))
    XCTAssertTrue(key.hasPrefix("googleAccountSession."))
    let hex = key.dropFirst("googleAccountSession.".count)
    XCTAssertEqual(hex.count, 64)
    XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) })
    XCTAssertFalse(key.contains("person"))
  }
}
