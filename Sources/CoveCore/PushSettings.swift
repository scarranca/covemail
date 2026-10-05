import Foundation

/// New-mail notification settings and state shared by Cove for iPhone and its notification
/// extension through the App Group. Nothing here is secret: the Google session stays in the
/// Keychain; this holds choices, the Gmail history cursor and which emails already notified.
public final class PushSettings: @unchecked Sendable {
  public static let appGroup = "group.ai.cove"
  public static let shared = PushSettings(defaults: UserDefaults(suiteName: appGroup) ?? .standard)

  private let defaults: UserDefaults
  public init(defaults: UserDefaults) { self.defaults = defaults }

  private func key(_ name: String) -> String { "push." + name }

  public var enabled: Bool {
    get { defaults.bool(forKey: key("enabled")) }
    set { defaults.set(newValue, forKey: key("enabled")) }
  }
  public var scope: NewMailAlert.Scope {
    get { NewMailAlert.Scope(rawValue: defaults.string(forKey: key("scope")) ?? "") ?? .important }
    set { defaults.set(newValue.rawValue, forKey: key("scope")) }
  }
  /// Sender and subject on the notification (default), or only "New email".
  public var showPreview: Bool {
    get { defaults.object(forKey: key("preview")) as? Bool ?? true }
    set { defaults.set(newValue, forKey: key("preview")) }
  }
  /// The signed-in address the extension reads mail for.
  public var accountEmail: String? {
    get { defaults.string(forKey: key("account")) }
    set { defaults.set(newValue, forKey: key("account")) }
  }
  /// Gmail history ID up to which new mail has been considered.
  public var cursor: String? {
    get { defaults.string(forKey: key("cursor")) }
    set { defaults.set(newValue, forKey: key("cursor")) }
  }
  public var watchExpires: Date? {
    get { defaults.object(forKey: key("watchExpires")) as? Date }
    set { defaults.set(newValue, forKey: key("watchExpires")) }
  }
  /// Senders who never notify, and senders who always do (even under "Important only").
  public var muted: Set<String> {
    get { Set(defaults.stringArray(forKey: key("muted")) ?? []) }
    set { defaults.set(Array(newValue).sorted(), forKey: key("muted")) }
  }
  public var alwaysNotify: Set<String> {
    get { Set(defaults.stringArray(forKey: key("always")) ?? []) }
    set { defaults.set(Array(newValue).sorted(), forKey: key("always")) }
  }
  /// Emails that already notified (newest last, bounded), so a retried push never repeats one.
  public var notified: [String] {
    get { defaults.stringArray(forKey: key("notified")) ?? [] }
    set { defaults.set(Array(newValue.suffix(300)), forKey: key("notified")) }
  }
  /// Quiet "up to date" notifications left by pushes that brought nothing new; removed on the next run.
  public var placeholders: [String] {
    get { defaults.stringArray(forKey: key("placeholders")) ?? [] }
    set { defaults.set(Array(newValue.suffix(50)), forKey: key("placeholders")) }
  }
  /// Screenshot and design checks only: the extension shows a sample email instead of reading Gmail.
  public var sample: Bool {
    get { defaults.bool(forKey: key("sample")) }
    set { defaults.set(newValue, forKey: key("sample")) }
  }

  public func reset() {
    for name in ["enabled", "account", "cursor", "watchExpires", "notified", "placeholders"] {
      defaults.removeObject(forKey: key(name))
    }
  }
}
