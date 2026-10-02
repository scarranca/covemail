import CryptoKit
import Foundation

/// The Google accounts signed in on this Mac, in the order they were added. Only the (non-secret)
/// emails live here; each account's session is its own Keychain entry named by `sessionKey(for:)`.
public enum AccountRoster {
  static let defaultsKey = "accounts.roster"

  /// Keychain entry name for one account's session: "googleAccountSession." + lowercase-hex
  /// SHA-256 of the lowercased email.
  public static func sessionKey(for email: String) -> String {
    let digest = SHA256.hash(data: Data(email.lowercased().utf8))
    return "googleAccountSession." + digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Ordered list of signed-in account emails, stored in UserDefaults key "accounts.roster".
  public static func emails(_ defaults: UserDefaults = .standard) -> [String] {
    var seen = Set<String>()
    return (defaults.stringArray(forKey: defaultsKey) ?? []).filter {
      !$0.isEmpty && seen.insert($0.lowercased()).inserted
    }
  }

  /// Appends the email if it is not already present (case-insensitive); keeps the order.
  public static func add(_ email: String, _ defaults: UserDefaults = .standard) {
    guard !email.isEmpty else { return }
    var list = emails(defaults)
    guard !list.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) else { return }
    list.append(email)
    defaults.set(list, forKey: defaultsKey)
  }

  public static func remove(_ email: String, _ defaults: UserDefaults = .standard) {
    let list = emails(defaults).filter { $0.caseInsensitiveCompare(email) != .orderedSame }
    if list.isEmpty {
      defaults.removeObject(forKey: defaultsKey)
    } else {
      defaults.set(list, forKey: defaultsKey)
    }
  }
}
