import Foundation

/// Gmail push for new-mail notifications. The device itself asks Gmail to publish changes to Cove's
/// Pub/Sub topic (`users.watch`, with its own token), so Cove's server never holds a Gmail credential.
/// Gmail's notification names only the address and a history ID; the device's notification
/// extension reads what is new with `newInboxMessages` and decides what to show (`NewMailAlert`).
public enum GmailPush {
  public static let topic = "projects/cove-mail-20260922/topics/gmail-push"

  public struct Watch: Decodable, Equatable, Sendable {
    public let historyId: String
    /// Milliseconds since 1970, as Gmail returns it. Watches last about a week and must be renewed.
    public let expiration: String
    public var expires: Date? { Double(expiration).map { Date(timeIntervalSince1970: $0 / 1000) } }
  }

  /// Starts (or renews) Gmail's notifications for changes to the Inbox.
  public static func watch(token: String, client: GmailClient = GmailClient()) async throws -> Watch {
    try JSONDecoder().decode(Watch.self, from: await client.request(
      "watch", token: token, method: "POST",
      body: ["topicName": topic, "labelIds": ["INBOX"], "labelFilterBehavior": "include"]))
  }

  /// Gmail's watch lasts about seven days. Renew once fewer than `margin` remain (or when unknown).
  public static func needsRenewal(expires: Date?, now: Date = Date(), margin: TimeInterval = 3 * 86_400) -> Bool {
    guard let expires else { return true }
    return expires.timeIntervalSince(now) < margin
  }

  /// Renews the watch when it's close to expiring and records the new expiry. The history cursor is
  /// only set when there is none, so renewing never skips mail that hasn't been notified yet.
  /// Called by the app when it becomes active, by the notification extension on every new-mail push,
  /// and by the background refresh, so the watch stays alive without the app being opened.
  @discardableResult
  public static func renewIfNeeded(token: String, settings: PushSettings, now: Date = Date(),
                                   watch: (String) async throws -> Watch = { try await GmailPush.watch(token: $0) }) async throws -> Bool {
    guard settings.enabled, needsRenewal(expires: settings.watchExpires, now: now) else { return false }
    let result = try await watch(token)
    settings.watchExpires = result.expires
    if settings.cursor == nil { settings.cursor = result.historyId }
    return true
  }

  /// Stops Gmail's notifications for this account (when the user turns notifications off).
  public static func stop(token: String, client: GmailClient = GmailClient()) async throws {
    _ = try await client.request("stop", token: token, method: "POST", body: [:])
  }

  public struct NewMail: Equatable, Sendable {
    /// Messages added to the Inbox since the cursor, oldest first.
    public var ids: [String]
    public var cursor: String
  }

  /// Messages added to the Inbox after `cursor`. Gmail answers 404 when the cursor is too old;
  /// then there is nothing reliable to report and the caller starts again from `latest`.
  public static func newInboxMessages(token: String, after cursor: String, client: GmailClient = GmailClient()) async throws -> NewMail {
    struct Page: Decodable {
      struct Record: Decodable {
        struct Added: Decodable { struct Message: Decodable { let id: String; let labelIds: [String]? }; let message: Message }
        let messagesAdded: [Added]?
      }
      let history: [Record]?
      let historyId: String
      let nextPageToken: String?
    }
    var result = NewMail(ids: [], cursor: cursor)
    var pageToken: String?
    var pages = 0
    repeat {
      var query = [URLQueryItem(name: "startHistoryId", value: cursor), URLQueryItem(name: "historyTypes", value: "messageAdded"),
                   URLQueryItem(name: "labelId", value: "INBOX"), URLQueryItem(name: "maxResults", value: "100")]
      if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      let page = try JSONDecoder().decode(Page.self, from: await client.request("history", token: token, query: query))
      for record in page.history ?? [] {
        for added in record.messagesAdded ?? [] {
          let labels = Set(added.message.labelIds ?? [])
          // Drafts and the user's own sent mail are never "new mail".
          guard labels.contains("INBOX"), labels.isDisjoint(with: ["DRAFT", "SENT", "SPAM", "TRASH"]),
                !result.ids.contains(added.message.id) else { continue }
          result.ids.append(added.message.id)
        }
      }
      result.cursor = page.historyId
      pageToken = page.nextPageToken
      pages += 1
    } while pageToken != nil && pages < 5
    return result
  }
}

/// What a new-mail notification shows, decided on the device from the email itself.
public struct NewMailAlert: Equatable, Sendable {
  public enum Scope: String, Codable, Sendable, CaseIterable { case important, inbox }
  public var title: String
  public var subtitle: String
  public var body: String
  public var threadID: String
  public var mailID: String

  /// Nil when this email shouldn't notify: the user's own mail, Other-tab mail under "Important only",
  /// a muted sender, or mail that has already left the Inbox or been read elsewhere.
  public static func make(for mail: Mail, accountEmail: String, scope: Scope, showPreview: Bool,
                          muted: Set<String> = [], important: Set<String> = []) -> NewMailAlert? {
    let sender = ContactDirectory.normalizedEmail(mail.senderEmail)
    guard mail.labels.contains("INBOX"), mail.isUnread, mail.labels.isDisjoint(with: ["SENT", "DRAFT", "SPAM", "TRASH"]),
          sender != ContactDirectory.normalizedEmail(accountEmail), !muted.contains(sender) else { return nil }
    if scope == .important && !important.contains(sender) && InboxSplit.split(mail) != .important { return nil }
    let name = mail.sender.isEmpty ? mail.senderEmail : mail.sender
    guard showPreview else {
      return NewMailAlert(title: "New email", subtitle: "", body: "Open Cove to read it.", threadID: mail.threadID, mailID: mail.id)
    }
    // Sender and subject only: the email's text never appears on the lock screen.
    return NewMailAlert(title: name, subtitle: "", body: mail.subject.isEmpty ? "(No subject)" : mail.subject,
                        threadID: mail.threadID, mailID: mail.id)
  }
}
