import CoveCore
import XCTest

@testable import Cove

/// GoogleAuth with an in-memory Keychain and isolated defaults: never touches the real Keychain.
@MainActor final class GoogleAuthAccountsTests: XCTestCase {
  private enum FakeError: Error { case unavailable }
  private var items: [String: String] = [:]
  private var defaults: UserDefaults!
  /// Names whose saves silently drop (simulates a write that doesn't read back).
  private var droppedSaves: Set<String> = []

  private let first = GoogleAccountSession(
    email: "first@example.com", clientID: "client-1", clientSecret: "fake-secret-1",
    refreshToken: "fake-refresh-1", calendarConnected: true, tasksConnected: false)
  private let second = GoogleAccountSession(
    email: "second@example.com", clientID: "client-2", clientSecret: "fake-secret-2",
    refreshToken: "fake-refresh-2", calendarConnected: false, tasksConnected: true)

  override func setUp() {
    super.setUp()
    items = [:]
    droppedSaves = []
    defaults = UserDefaults(suiteName: "Cove.GoogleAuthAccountsTests." + UUID().uuidString)!
  }

  private func makeAuth() -> GoogleAuth {
    GoogleAuth(
      storage: .init(
        read: { [unowned self] in self.items[$0] },
        save: { [unowned self] value, name in
          if !self.droppedSaves.contains(name) { self.items[name] = value }
        },
        delete: { [unowned self] in self.items[$0] = nil },
        defaults: defaults))
  }

  private func json(_ session: GoogleAccountSession) -> String {
    String(decoding: try! JSONEncoder().encode(session), as: UTF8.self)
  }

  private func stored(_ email: String) -> GoogleAccountSession? {
    items[AccountRoster.sessionKey(for: email)].flatMap {
      try? JSONDecoder().decode(GoogleAccountSession.self, from: Data($0.utf8))
    }
  }

  private func pending(_ session: GoogleAccountSession) -> GoogleAuth.PendingConnection {
    .init(session: session, accessToken: "fake-access", expiration: Date().addingTimeInterval(3600))
  }

  // MARK: Migration

  func testLegacySessionMovesToItsAccountEntry() throws {
    items["googleAccountSession"] = json(first)
    defaults.set("first@example.com", forKey: "accountEmail")

    let auth = makeAuth()
    XCTAssertEqual(try auth.restorableAccountEmail(), "first@example.com")
    XCTAssertEqual(stored("first@example.com"), first)
    XCTAssertNil(items["googleAccountSession"])
    XCTAssertEqual(auth.accounts, ["first@example.com"])
    XCTAssertEqual(defaults.string(forKey: "accountEmail"), "first@example.com")

    // Idempotent: a fresh instance finds nothing to move and keeps everything.
    let again = makeAuth()
    XCTAssertEqual(again.accounts, ["first@example.com"])
    XCTAssertEqual(stored("first@example.com"), first)
  }

  func testLegacyIsKeptWhenTheNewEntryDoesNotReadBack() throws {
    let legacy = json(first)
    items["googleAccountSession"] = legacy
    defaults.set("first@example.com", forKey: "accountEmail")
    droppedSaves = [AccountRoster.sessionKey(for: "first@example.com")]

    let auth = makeAuth()
    XCTAssertThrowsError(try auth.migrateLegacySessionIfNeeded())
    XCTAssertEqual(items["googleAccountSession"], legacy)
    XCTAssertEqual(AccountRoster.emails(defaults), [])

    // A later attempt that succeeds completes the move.
    droppedSaves = []
    try auth.migrateLegacySessionIfNeeded()
    XCTAssertNil(items["googleAccountSession"])
    XCTAssertEqual(stored("first@example.com"), first)
  }

  func testCorruptLegacyIsLeftUntouched() throws {
    items["googleAccountSession"] = "{not json"
    defaults.set("first@example.com", forKey: "accountEmail")
    let auth = makeAuth()
    try auth.migrateLegacySessionIfNeeded()
    XCTAssertEqual(items["googleAccountSession"], "{not json")
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(auth.accounts, [])
  }

  func testRosterIsRebuiltFromActiveAccountEntry() {
    items[AccountRoster.sessionKey(for: "first@example.com")] = json(first)
    defaults.set("first@example.com", forKey: "accountEmail")
    XCTAssertEqual(makeAuth().accounts, ["first@example.com"])
  }

  // MARK: Several accounts

  func testCommittingASecondAccountKeepsTheFirst() throws {
    let auth = makeAuth()
    try auth.commit(pending(first))
    try auth.commit(pending(second))

    XCTAssertEqual(stored("first@example.com"), first)
    XCTAssertEqual(stored("second@example.com"), second)
    XCTAssertEqual(auth.accounts, ["first@example.com", "second@example.com"])
    XCTAssertEqual(auth.activeEmail, "second@example.com")
    XCTAssertFalse(defaults.bool(forKey: "calendarConnected"))
    XCTAssertTrue(defaults.bool(forKey: "tasksConnected"))
    XCTAssertEqual(try auth.restorableAccountEmail(), "second@example.com")
  }

  func testCommitRepairsACorruptEntryForTheSameAccount() throws {
    items[AccountRoster.sessionKey(for: "first@example.com")] = "{corrupt"
    let auth = makeAuth()
    try auth.commit(pending(first))
    XCTAssertEqual(stored("first@example.com"), first)
  }

  func testActivateSwitchesAccountAndFlagsWithoutTouchingSessions() throws {
    let auth = makeAuth()
    try auth.commit(pending(first))
    try auth.commit(pending(second))
    let before = items

    try auth.activate(email: "FIRST@example.com")
    XCTAssertEqual(auth.activeEmail, "first@example.com")
    XCTAssertTrue(defaults.bool(forKey: "calendarConnected"))
    XCTAssertFalse(defaults.bool(forKey: "tasksConnected"))
    XCTAssertEqual(try auth.restorableAccountEmail(), "first@example.com")
    XCTAssertEqual(items, before)

    try auth.activate(email: "second@example.com")
    XCTAssertEqual(try auth.restorableAccountEmail(), "second@example.com")
  }

  func testActivateUnknownAccountThrowsAndKeepsTheActiveOne() throws {
    let auth = makeAuth()
    try auth.commit(pending(first))
    XCTAssertThrowsError(try auth.activate(email: "nobody@example.com")) { error in
      XCTAssertEqual((error as? CoveError).map { "\($0)" }?.contains("nobody@example.com"), true)
    }
    items[AccountRoster.sessionKey(for: "broken@example.com")] = "{corrupt"
    XCTAssertThrowsError(try auth.activate(email: "broken@example.com"))
    XCTAssertEqual(auth.activeEmail, "first@example.com")
    XCTAssertEqual(try auth.restorableAccountEmail(), "first@example.com")
  }

  func testKeychainReadErrorIsNotReportedAsSignInAgain() throws {
    let lockedKey = AccountRoster.sessionKey(for: "second@example.com")
    items[lockedKey] = json(second)
    let auth = GoogleAuth(
      storage: .init(
        read: { [unowned self] name in
          if name == lockedKey { throw FakeError.unavailable }
          return self.items[name]
        },
        save: { [unowned self] in self.items[$1] = $0 },
        delete: { [unowned self] in self.items[$0] = nil },
        defaults: defaults))
    try auth.commit(pending(first))
    XCTAssertThrowsError(try auth.activate(email: "second@example.com")) { error in
      XCTAssertTrue(error is FakeError)
    }
    XCTAssertEqual(auth.activeEmail, "first@example.com")
    XCTAssertEqual(items[lockedKey], json(second))
  }

  func testDisconnectSignsOutOnlyTheActiveAccount() throws {
    let auth = makeAuth()
    try auth.commit(pending(first))
    try auth.commit(pending(second))

    try auth.disconnect()
    XCTAssertNil(stored("second@example.com"))
    XCTAssertEqual(stored("first@example.com"), first)
    XCTAssertEqual(auth.accounts, ["first@example.com"])
    XCTAssertNil(auth.activeEmail)
    XCTAssertNil(defaults.object(forKey: "calendarConnected"))
    XCTAssertNil(defaults.object(forKey: "tasksConnected"))
    XCTAssertNil(try auth.restorableAccountEmail())

    try auth.activate(email: "first@example.com")
    XCTAssertEqual(try auth.restorableAccountEmail(), "first@example.com")
  }

  func testDisconnectRemovesACorruptActiveEntryAndUnmigratableLegacy() throws {
    items[AccountRoster.sessionKey(for: "first@example.com")] = "{corrupt"
    items["googleAccountSession"] = "{also corrupt"
    items[AccountRoster.sessionKey(for: "second@example.com")] = json(second)
    defaults.set("first@example.com", forKey: "accountEmail")
    AccountRoster.add("first@example.com", defaults)
    AccountRoster.add("second@example.com", defaults)

    try makeAuth().disconnect()
    XCTAssertEqual(Array(items.keys), [AccountRoster.sessionKey(for: "second@example.com")])
    XCTAssertEqual(AccountRoster.emails(defaults), ["second@example.com"])
  }

  func testSessionNamesStayInTheLoginKeychain() {
    XCTAssertFalse(HardenedSecrets.protects(AccountRoster.sessionKey(for: "first@example.com")))
    XCTAssertFalse(HardenedSecrets.protects(GoogleAuth.legacySessionName))
  }
}
