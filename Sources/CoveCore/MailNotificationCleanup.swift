import Foundation

/// A delivered mail alert, independent of Apple's notification types so reconciliation is testable.
public struct DeliveredMailAlert: Sendable {
  public var identifier: String
  public var mailID: String
  public var account: String?

  public init(identifier: String, mailID: String, account: String?) {
    self.identifier = identifier
    self.mailID = mailID
    self.account = account
  }
}

public enum MailNotificationCleanup {
  /// Checks current labels, not a historical removal: a read/archive may already have been undone.
  /// Legacy alerts have no account tag; they belong to the single account this device registered.
  /// Only a confirmed read, non-Inbox state, or 404 removes an alert. Failures leave it for next time.
  public static func removals(for alerts: [DeliveredMailAlert], account: String, token: String,
                              changedIDs: Set<String>? = nil, client: GmailClient = GmailClient()) async throws -> [String] {
    let candidates = alerts.filter {
      ($0.account == nil || $0.account?.lowercased() == account.lowercased())
        && (changedIDs == nil || changedIDs!.contains($0.mailID))
    }
    var removed: Set<String> = []
    for id in Set(candidates.map(\.mailID)).sorted() {
      try Task.checkCancellation()
      switch try await client.update(id: id, token: token, cached: true) {
      case .deleted: removed.insert(id)
      case .labels(_, let labels):
        if !labels.isSuperset(of: ["INBOX", "UNREAD"]) || !labels.isDisjoint(with: ["TRASH", "SPAM"]) {
          removed.insert(id)
        }
      case .full: break
      }
    }
    try Task.checkCancellation()
    return candidates.filter { removed.contains($0.mailID) }.map(\.identifier)
  }
}

#if os(iOS)
import UserNotifications

/// Shared by the notification extension, foreground app and Background App Refresh.
public enum MobileNotificationCleanup {
  public static func reconcile(token: String, account: String, changedIDs: Set<String>? = nil) async throws {
    let settings = PushSettings.shared
    guard settings.enabled, !settings.sample, settings.accountEmail == account else { return }
    let center = UNUserNotificationCenter.current()
    let delivered = await center.deliveredNotifications()
    let alerts = delivered.compactMap { notification -> DeliveredMailAlert? in
      let content = notification.request.content
      guard ["cove.new-mail", "cove.sign-in-code"].contains(content.categoryIdentifier),
            let id = content.userInfo["mailID"] as? String else { return nil }
      return DeliveredMailAlert(identifier: notification.request.identifier, mailID: id,
                                account: content.userInfo["accountEmail"] as? String)
    }
    let ids = try await MailNotificationCleanup.removals(for: alerts, account: account, token: token, changedIDs: changedIDs)
    // Sign-out/account switching can happen while Gmail is responding.
    guard settings.enabled, settings.accountEmail == account else { return }
    center.removeDeliveredNotifications(withIdentifiers: ids)
    let expired = delivered.filter {
      let taggedAccount = $0.request.content.userInfo["accountEmail"] as? String
      return (taggedAccount == nil || taggedAccount?.lowercased() == account.lowercased())
        && $0.request.content.categoryIdentifier == "cove.sign-in-code" && Date().timeIntervalSince($0.date) > 600
    }.map(\.request.identifier)
    center.removeDeliveredNotifications(withIdentifiers: expired + settings.placeholders)
  }
}
#endif
