#if os(iOS)
import CoveCore
import Foundation
import Security

/// Cove's secrets on iPhone: the Google session, the mailbox encryption key and AI API keys.
/// Items stay on this device (`ThisDeviceOnly`) and are readable after the first unlock, so a
/// background refresh can open the mailbox.
enum MobileKeychain {
  static let service = "ai.cove.ios"

  private static func query(_ name: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: name]
  }

  static func read(_ name: String) throws -> String? {
    var item = query(name)
    item[kSecReturnData as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(item as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw CoveError.message("Keychain could not be read (\(status)).")
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// Saves or replaces a value.
  static func save(_ value: String, name: String) throws {
    let data = Data(value.utf8)
    let update = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw CoveError.message("Keychain could not save (\(update)).") }
    try insert(value, name: name)
  }

  /// Adds a value only when none exists. Used for the mailbox key, which must never be replaced.
  static func insert(_ value: String, name: String) throws {
    var item = query(name)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecValueData as String] = Data(value.utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw CoveError.message("Keychain could not save (\(status)).")
    }
  }

  static func delete(_ name: String) throws {
    let status = SecItemDelete(query(name) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CoveError.message("Keychain could not remove the item (\(status)).")
    }
  }
}
#endif
