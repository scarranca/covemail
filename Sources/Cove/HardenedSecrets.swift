import CoveCore
import Foundation
import LocalAuthentication
import Security

/// Extra protection for AI provider and TypeSafe keys only. When the build is signed with a
/// keychain-access-groups entitlement, these keys move to the data-protection keychain: readable
/// only while this Mac is unlocked, never synchronized, and optionally gated by Touch ID. Without
/// that entitlement (ad-hoc/QA builds) nothing changes and the legacy login-keychain item is kept.
/// Google sign-in and mailbox keys are deliberately not handled here.
enum HardenedSecrets {
  struct Backend {
    var copy: ([String: Any]) -> (OSStatus, Data?)
    var add: ([String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus

    static let system = Backend(
      copy: { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
      },
      add: { SecItemAdd($0 as CFDictionary, nil) },
      delete: { SecItemDelete($0 as CFDictionary) })
  }

  static var backend = Backend.system
  static var defaults = UserDefaults.standard
  private static var probed: Bool?
  /// One context for all reads, so a Touch ID confirmation is reused for up to five minutes.
  private(set) static var authentication = makeContext()
  private static func makeContext() -> LAContext {
    let context = LAContext()
    context.localizedReason = "use your AI key in Cove"
    context.touchIDAuthenticationAllowableReuseDuration = 300
    return context
  }
  private static let presenceKey = "security.aiKeysRequireTouchID"
  static let lockedMessage = "Your AI key is locked right now (your Mac is locked, or Touch ID couldn’t be shown). Cove will use it when you’re back."

  static func protects(_ name: String) -> Bool { name.hasPrefix("aiProvider.") || name == "typesafeKey" }
  static var protectedNames: [String] { AIProvider.allCases.map(\.keyName) + ["typesafeKey"] }

  /// Probed once per launch with a throwaway item; -34018 means the entitlement is missing.
  static func dataProtectionAvailable(service: String) -> Bool {
    if let probed { return probed }
    let item = base(service: service, name: "__cove_dp_probe")
    _ = backend.delete(item)
    var add = item
    add[kSecValueData as String] = Data("probe".utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = backend.add(add)
    _ = backend.delete(item)
    probed = status == errSecSuccess
    return probed!
  }
  static func resetProbe() { probed = nil }

  static var requireUserPresence: Bool {
    get { defaults.bool(forKey: presenceKey) }
    set { defaults.set(newValue, forKey: presenceKey) }
  }
  /// Touch ID only takes effect on a hardened build.
  static func userPresenceActive(service: String) -> Bool {
    requireUserPresence && dataProtectionAvailable(service: service)
  }

  static func read(
    _ name: String, service: String, legacy: () throws -> String?, legacyDelete: (() throws -> Void)? = nil
  ) throws -> String? {
    if dataProtectionAvailable(service: service) {
      var query = base(service: service, name: name)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      query[kSecUseAuthenticationContext as String] = authentication
      let (status, data) = backend.copy(query)
      switch status {
      case errSecSuccess:
        if let data, let value = String(data: data, encoding: .utf8) { return value }
      case errSecItemNotFound: break
      case errSecInteractionNotAllowed:
        // The Mac is locked, or Touch ID can't be shown right now (Cove isn't in front): not an
        // error to alert about. Background work tries again on the next sync.
        throw CoveError.message(lockedMessage)
      case errSecUserCanceled, errSecAuthFailed:
        authentication = makeContext()
        throw CoveError.message("Touch ID wasn’t confirmed, so Cove didn’t use your AI key.")
      default:
        throw CoveError.message("Keychain could not read your AI key (\(status)).")
      }
    }
    let value = try legacy()
    // On a hardened build, a key still in the login keychain moves to protected storage when first used.
    if let value, let legacyDelete, dataProtectionAvailable(service: service) {
      try? save(value, name: name, service: service, legacySave: {}, legacyDelete: legacyDelete)
    }
    return value
  }

  static func save(
    _ value: String, name: String, service: String,
    legacySave: () throws -> Void, legacyDelete: () throws -> Void
  ) throws {
    guard dataProtectionAvailable(service: service) else { return try legacySave() }
    let item = base(service: service, name: name)
    _ = backend.delete(item)
    var add = item
    add[kSecValueData as String] = Data(value.utf8)
    if requireUserPresence,
      let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil)
    {
      add[kSecAttrAccessControl as String] = access
    } else {
      add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }
    guard backend.add(add) == errSecSuccess else { return try legacySave() }
    // Confirm the protected copy exists (attributes only, so no Touch ID prompt) before
    // removing the older login-keychain copy.
    var check = item
    check[kSecReturnAttributes as String] = true
    let context = LAContext()
    context.interactionNotAllowed = true
    check[kSecUseAuthenticationContext as String] = context
    guard backend.copy(check).0 == errSecSuccess else { return try legacySave() }
    try? legacyDelete()
  }

  static func delete(_ name: String, service: String) throws {
    guard dataProtectionAvailable(service: service) else { return }
    let status = backend.delete(base(service: service, name: name))
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CoveError.message("Keychain could not remove your AI key (\(status)).")
    }
  }

  /// Re-saves existing keys after the Touch ID preference changes. Reading may ask for Touch ID once.
  static func reprotect(service: String, read: (String) throws -> String?, save: (String, String) throws -> Void) throws {
    for name in protectedNames {
      if let value = try read(name) { try save(value, name) }
    }
  }

  private static func base(service: String, name: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: name, kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
    ]
  }
}
