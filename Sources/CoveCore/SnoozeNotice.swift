import Foundation

/// What the "back in your inbox" notification says. One pure place for both platforms, so the content
/// rule (sender and subject only, never the body) and the identifier format are tested once.
public enum SnoozeNotice {
  public static let identifierPrefix = "snooze."
  public static let title = "Back in your inbox"

  /// One pending request per email, so rescheduling replaces and cancelling is exact.
  public static func identifier(mailID: String) -> String { identifierPrefix + mailID }

  /// The email a snooze notification identifier belongs to, or nil for any other notification.
  public static func mailID(fromIdentifier identifier: String) -> String? {
    guard identifier.hasPrefix(identifierPrefix) else { return nil }
    let id = String(identifier.dropFirst(identifierPrefix.count))
    return id.isEmpty ? nil : id
  }

  /// "Sender · Subject". The email's body never goes into a notification.
  public static func body(sender: String, subject: String) -> String {
    [sender, subject.isEmpty ? "(No subject)" : subject].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// The sender as shown in the notification: the name, else the address.
  public static func senderName(of mail: Mail) -> String { mail.sender.isEmpty ? mail.senderEmail : mail.sender }

  /// The emails that should have a pending notification: snoozed past `now`, still in the Inbox.
  public static func pending(in mails: [Mail], now: Date = Date()) -> [Mail] {
    mails.filter { mail in
      guard let until = mail.snoozedUntil, until > now else { return false }
      return mail.labels.contains("INBOX") && mail.labels.isDisjoint(with: ["TRASH", "SPAM"])
    }
  }
}
