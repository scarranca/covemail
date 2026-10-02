import CoveCore
import Security
import XCTest
@testable import Cove

@MainActor final class HardenedSecretsTests: XCTestCase {
  private var items: [String: Data] = [:]
  private var addStatus: OSStatus = errSecSuccess
  private var readbackStatus: OSStatus = errSecSuccess
  private var readStatus: OSStatus?
  private var added: [[String: Any]] = []

  override func setUp() {
    super.setUp()
    HardenedSecrets.resetProbe()
    HardenedSecrets.defaults = UserDefaults(suiteName: "Cove.HardenedSecretsTests." + UUID().uuidString)!
    HardenedSecrets.backend = .init(
      copy: { [unowned self] query in
        let name = query[kSecAttrAccount as String] as! String
        if query[kSecReturnAttributes as String] != nil { return (self.readbackStatus, nil) }
        if let readStatus = self.readStatus { return (readStatus, nil) }
        return self.items[name].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
      },
      add: { [unowned self] item in
        guard self.addStatus == errSecSuccess else { return self.addStatus }
        self.added.append(item)
        self.items[item[kSecAttrAccount as String] as! String] = item[kSecValueData as String] as? Data
        return errSecSuccess
      },
      delete: { [unowned self] query in
        self.items.removeValue(forKey: query[kSecAttrAccount as String] as! String) == nil ? errSecItemNotFound : errSecSuccess
      })
  }
  override func tearDown() {
    HardenedSecrets.backend = .system
    HardenedSecrets.defaults = .standard
    HardenedSecrets.resetProbe()
    super.tearDown()
  }

  func testLoginKeychainQueriesNeverReachProtectedItems() {
    // Regression (0.1.47): without this flag, deleting the old login-keychain copy on a hardened
    // build also deleted the protected copy just written, so keys were lost on first use.
    let query = Vault.legacyQuery("typesafeKey", service: "ai.cove.test")
    XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, false)
    XCTAssertEqual(query[kSecAttrAccount as String] as? String, "typesafeKey")
  }

  func testALockedKeyIsAQuietStatusNotAnAlert() throws {
    readStatus = errSecInteractionNotAllowed
    XCTAssertThrowsError(try HardenedSecrets.read("typesafeKey", service: "ai.cove.test", legacy: { nil })) { error in
      XCTAssertEqual((error as? CoveError)?.localizedDescription, HardenedSecrets.lockedMessage)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveLocked-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.error = HardenedSecrets.lockedMessage
    XCTAssertNil(store.error, "no alert for background work on a locked Mac")
    XCTAssertTrue(store.status.contains("AI paused"))
  }

  func testOnlyAIAndTypeSafeKeysAreHandled() {
    XCTAssertTrue(HardenedSecrets.protects("aiProvider.openAI"))
    XCTAssertTrue(HardenedSecrets.protects("typesafeKey"))
    XCTAssertFalse(HardenedSecrets.protects("googleAccountSession"))
    XCTAssertFalse(HardenedSecrets.protects("mailboxEncryptionKey.abc"))
  }

  func testWithoutEntitlementLegacyStorageIsKeptUnchanged() throws {
    addStatus = -34018
    var legacySaved = false, legacyDeleted = false
    try HardenedSecrets.save("sk-test", name: "aiProvider.openAI", service: "ai.cove.test",
      legacySave: { legacySaved = true }, legacyDelete: { legacyDeleted = true })
    XCTAssertTrue(legacySaved); XCTAssertFalse(legacyDeleted)
    XCTAssertEqual(try HardenedSecrets.read("aiProvider.openAI", service: "ai.cove.test", legacy: { "legacy" }), "legacy")
  }

  func testHardenedBuildMovesKeyOnlyAfterReadbackAndIsDeviceOnly() throws {
    var legacyDeleted = false
    try HardenedSecrets.save("sk-test", name: "aiProvider.openAI", service: "ai.cove.test",
      legacySave: { XCTFail("Protected copy succeeded") }, legacyDelete: { legacyDeleted = true })
    XCTAssertTrue(legacyDeleted)
    let item = try XCTUnwrap(added.last)
    XCTAssertEqual(item[kSecUseDataProtectionKeychain as String] as? Bool, true)
    XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, false)
    XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    XCTAssertEqual(try HardenedSecrets.read("aiProvider.openAI", service: "ai.cove.test", legacy: { nil }), "sk-test")
  }

  func testFailedReadbackKeepsTheLegacyCopy() throws {
    _ = HardenedSecrets.dataProtectionAvailable(service: "ai.cove.test")
    readbackStatus = errSecItemNotFound
    var legacySaved = false, legacyDeleted = false
    try HardenedSecrets.save("sk-test", name: "typesafeKey", service: "ai.cove.test",
      legacySave: { legacySaved = true }, legacyDelete: { legacyDeleted = true })
    XCTAssertTrue(legacySaved); XCTAssertFalse(legacyDeleted)
  }

  func testExistingLoginKeychainKeyMovesOnFirstReadOnHardenedBuild() throws {
    var legacyDeleted = false
    let value = try HardenedSecrets.read("typesafeKey", service: "ai.cove.test", legacy: { "ts-legacy" },
      legacyDelete: { legacyDeleted = true })
    XCTAssertEqual(value, "ts-legacy")
    XCTAssertEqual(items["typesafeKey"], Data("ts-legacy".utf8))
    XCTAssertTrue(legacyDeleted)
    addStatus = -34018; HardenedSecrets.resetProbe(); items = [:]
    var untouched = true
    _ = try HardenedSecrets.read("typesafeKey", service: "ai.cove.test", legacy: { "ts-legacy" },
      legacyDelete: { untouched = false })
    XCTAssertTrue(untouched, "Without the entitlement the login-keychain copy stays")
  }

  func testTouchIDConfirmationIsReusedAcrossReads() throws {
    items["aiProvider.openAI"] = Data("sk".utf8)
    var contexts: [ObjectIdentifier] = []
    let copy = HardenedSecrets.backend.copy
    HardenedSecrets.backend.copy = { query in
      if let context = query[kSecUseAuthenticationContext as String] as AnyObject? { contexts.append(ObjectIdentifier(context)) }
      return copy(query)
    }
    _ = try HardenedSecrets.read("aiProvider.openAI", service: "ai.cove.test", legacy: { nil })
    _ = try HardenedSecrets.read("aiProvider.openAI", service: "ai.cove.test", legacy: { nil })
    XCTAssertEqual(contexts.count, 2)
    XCTAssertEqual(contexts[0], contexts[1], "One LAContext lets Touch ID be reused for five minutes")
  }

  func testTouchIDUsesAccessControlAndCancellationNeverFallsBackToLegacy() throws {
    HardenedSecrets.requireUserPresence = true
    try HardenedSecrets.save("sk-test", name: "aiProvider.anthropic", service: "ai.cove.test",
      legacySave: {}, legacyDelete: {})
    XCTAssertNotNil(added.last?[kSecAttrAccessControl as String])
    XCTAssertTrue(HardenedSecrets.userPresenceActive(service: "ai.cove.test"))
    readStatus = errSecUserCanceled
    XCTAssertThrowsError(try HardenedSecrets.read("aiProvider.anthropic", service: "ai.cove.test", legacy: {
      XCTFail("A cancelled Touch ID prompt must not read another copy"); return nil
    }))
  }
}
