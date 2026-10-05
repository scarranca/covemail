import CoveCore
import Foundation
import Security
import UserNotifications

/// Turns Cove's content-free push ("New email") into the real notification. Cove's server only knows
/// that Gmail reported a change; this extension reads what is new with the iPhone's own Google sign-in
/// (shared Keychain) and decides what to show with the same rules as the app (`NewMailAlert`).
/// A push that brings nothing new (a read or archive elsewhere) becomes a quiet, passive placeholder
/// that the next run removes.
final class NotificationService: UNNotificationServiceExtension {
  private var handler: ((UNNotificationContent) -> Void)?
  private var fallback: UNMutableNotificationContent?
  private var work: Task<Void, Never>?

  override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    handler = contentHandler
    let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    fallback = content
    let history = (request.content.userInfo["cove"] as? [String: Any])?["historyID"] as? String
    work = Task {
      let result = await NewMail.content(base: content, requestID: request.identifier, pushHistory: history)
      self.finish(result)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    work?.cancel()
    // Out of time: say only that mail arrived, as the server sent it.
    if let fallback { finish(fallback) }
  }

  private func finish(_ content: UNNotificationContent) {
    guard let handler else { return }
    self.handler = nil
    handler(content)
  }
}

enum NewMail {
  /// New emails beyond the four read in one run.
  nonisolated(unsafe) private static var overflow = 0
  static func content(base: UNMutableNotificationContent, requestID: String, pushHistory: String?) async -> UNNotificationContent {
    let settings = PushSettings.shared
    let center = UNUserNotificationCenter.current()
    // Last run's quiet placeholders go away now.
    if !settings.placeholders.isEmpty {
      center.removeDeliveredNotifications(withIdentifiers: settings.placeholders)
      settings.placeholders = []
    }
    guard settings.enabled, let account = settings.accountEmail else { return placeholder(base, requestID) }
    do {
      let mails = settings.sample ? [sampleMail] : try await newMails(account: account, settings: settings, pushHistory: pushHistory)
      let alerts = mails.compactMap {
        NewMailAlert.make(for: $0, accountEmail: account, scope: settings.scope, showPreview: settings.showPreview,
                          muted: settings.muted, important: settings.alwaysNotify)
      }
      settings.notified += mails.map(\.id)
      guard let first = alerts.first else { return placeholder(base, requestID) }
      // More than one new email: the others become their own notifications in the same conversation group.
      for extra in alerts.dropFirst() {
        try? await center.add(UNNotificationRequest(identifier: extra.mailID, content: content(for: extra, base: UNMutableNotificationContent()), trigger: nil))
      }
      let shown = content(for: first, base: base)
      if overflow > 0 { shown.subtitle = "+\(overflow) more new \(overflow == 1 ? "email" : "emails")" }
      return shown
    } catch {
      // Couldn't read Gmail (offline, signed out): keep the server's generic text.
      base.threadIdentifier = "cove-mail"
      base.sound = .default
      return base
    }
  }

  private static func newMails(account: String, settings: PushSettings, pushHistory: String?) async throws -> [Mail] {
    let token = try await accessToken(for: account)
    guard let cursor = settings.cursor else {
      // No starting point yet: begin from this notification; the next one reports what's new.
      settings.cursor = pushHistory
      return []
    }
    let found: GmailPush.NewMail
    do {
      found = try await GmailPush.newInboxMessages(token: token, after: cursor)
    } catch let failure as HTTPFailure where failure.statusCode == 404 {
      settings.cursor = pushHistory
      return []
    }
    settings.cursor = found.cursor
    // Every new-mail push renews Gmail's week-long watch when it's close to expiring, so it never
    // lapses while mail keeps arriving (the cursor is untouched).
    _ = try? await GmailPush.renewIfNeeded(token: token, settings: settings)
    let already = Set(settings.notified)
    let fresh = found.ids.filter { !already.contains($0) }
    var mails: [Mail] = []
    // A burst reads the newest four; the first notification says how many more arrived.
    overflow = max(0, fresh.count - 4)
    for id in fresh.suffix(4) {
      if let mail = try await GmailClient().message(id: id, token: token) { mails.append(mail) }
    }
    return mails
  }

  /// A fresh Google access token from the app's saved session (shared Keychain group).
  private static func accessToken(for account: String) async throws -> String {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ai.cove.ios",
                                kSecAttrAccount as String: "googleAccountSession", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
          let session = try? JSONDecoder().decode(GoogleAccountSession.self, from: data),
          session.email.caseInsensitiveCompare(account) == .orderedSame
    else { throw CoveError.message("Not signed in") }
    return try await GoogleTokenClient().refresh(refreshToken: session.refreshToken, clientID: session.clientID, secret: "").access_token
  }

  private static func content(for alert: NewMailAlert, base: UNMutableNotificationContent) -> UNMutableNotificationContent {
    base.title = alert.title
    base.subtitle = alert.subtitle
    base.body = alert.body
    base.sound = .default
    base.threadIdentifier = "cove-thread-" + alert.threadID
    base.categoryIdentifier = "cove.new-mail"
    base.userInfo = ["mailID": alert.mailID, "threadID": alert.threadID]
    base.interruptionLevel = .active
    base.relevanceScore = 1
    return base
  }

  /// Nothing new to say: a passive entry with no sound or banner, removed by the next push.
  private static func placeholder(_ base: UNMutableNotificationContent, _ requestID: String) -> UNNotificationContent {
    base.title = "Cove"
    base.subtitle = ""
    base.body = "Your mail is up to date."
    base.sound = nil
    base.interruptionLevel = .passive
    base.relevanceScore = 0
    base.threadIdentifier = "cove-sync"
    PushSettings.shared.placeholders += [requestID]
    return base
  }

  private static var sampleMail: Mail {
    Mail(id: "sample-\(UUID().uuidString.prefix(8))", threadID: "sample", sender: "Maya Chen", senderEmail: "maya@studiofield.example",
         subject: "Website launch — final sign-off", body: "", labels: ["INBOX", "UNREAD"], isBulkOrAutomated: false)
  }
}
