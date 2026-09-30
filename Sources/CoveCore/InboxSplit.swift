import Foundation

/// The two Inbox tabs. Membership is deterministic and explainable; the user's vote always wins.
public enum InboxSplit: String, Codable, CaseIterable, Sendable {
  case important
  case other

  public var title: String { self == .important ? "Important" : "Other" }
  public var opposite: InboxSplit { self == .important ? .other : .important }

  /// Why an email landed in its tab, in the order the rules are checked.
  public enum Reason: Equatable, Sendable {
    case vote, senderRule, jevPriority, bulkHeaders, notificationSender, jevCategory, standard

    public var explanation: String {
      switch self {
      case .vote: return "You moved this email."
      case .senderRule: return "You chose a tab for this sender."
      case .jevPriority: return "Jev found it needs a reply or is urgent."
      case .bulkHeaders: return "Sent in bulk or automatically."
      case .notificationSender: return "Sent from a notification address."
      case .jevCategory: return "Jev filed it as a newsletter, update or purchase."
      case .standard: return "Personal mail stays in Important."
      }
    }
  }

  /// Sender local parts that only send notifications. Kept short so the rule stays explainable.
  static let notificationLocalParts: Set<String> = [
    "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
    "notifications", "notification", "notify", "newsletter", "newsletters", "mailer-daemon",
  ]
  static let otherCategories: Set<MailCategory> = [.newsletters, .updates, .purchases]

  /// Lowercased bare address used as the sender-rule key.
  public static func senderKey(_ address: String) -> String {
    var value = address
    if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close {
      value = String(value[value.index(after: open)..<close])
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Gmail's own `IMPORTANT` label is deliberately ignored: Gmail applies it to many newsletters.
  public static func classify(_ mail: Mail, senderRules: [String: InboxSplit] = [:]) -> (split: InboxSplit, reason: Reason) {
    if let vote = mail.inboxVote { return (vote, .vote) }
    if !senderRules.isEmpty, let rule = senderRules[senderKey(mail.senderEmail)] { return (rule, .senderRule) }
    if let decision = mail.decision, decision.needsReply >= 0.65 || decision.urgent >= 0.65 {
      return (.important, .jevPriority)
    }
    if mail.isBulkOrAutomated == true { return (.other, .bulkHeaders) }
    let key = senderKey(mail.senderEmail)
    if let at = key.firstIndex(of: "@"), notificationLocalParts.contains(String(key[..<at])) {
      return (.other, .notificationSender)
    }
    if let category = mail.decision?.category, otherCategories.contains(category) { return (.other, .jevCategory) }
    return (.important, .standard)
  }

  public static func split(_ mail: Mail, senderRules: [String: InboxSplit] = [:]) -> InboxSplit {
    classify(mail, senderRules: senderRules).split
  }
}
