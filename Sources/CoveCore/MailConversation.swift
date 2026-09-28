import Foundation

public enum MailConversation {
  /// Continuing a sent message addresses its recipients, including messages sent from aliases.
  public static func replyRecipient(for mail: Mail, accountEmail: String) -> String {
    if mail.labels.contains("SENT") || mail.senderEmail.caseInsensitiveCompare(accountEmail) == .orderedSame {
      return mail.to.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return mail.replyRecipient
  }

  public static func messages(in cached: [Mail], anchor: Mail) -> [Mail] {
    guard !anchor.threadID.isEmpty, !anchor.labels.contains("DRAFT") else { return [anchor] }
    var unique: [String: Mail] = [anchor.id: anchor]
    for mail in cached where mail.threadID == anchor.threadID {
      guard mail.id == anchor.id || mail.labels.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"]) else { continue }
      unique[mail.id] = mail
    }
    return unique.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
  }
}
