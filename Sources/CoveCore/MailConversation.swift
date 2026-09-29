import Foundation

public enum MailConversation {
  /// Continuing a sent message addresses its recipients, including messages sent from aliases.
  public static func replyRecipient(for mail: Mail, accountEmail: String) -> String {
    if mail.labels.contains("SENT") || mail.senderEmail.caseInsensitiveCompare(accountEmail) == .orderedSame {
      return mail.to.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return mail.replyRecipient
  }

  /// Reply-all recipients, or nil when Cc is unknown (older snapshot) or nobody else was included.
  /// Addresses come from untrusted headers: each is validated, deduplicated and re-rendered.
  public static func replyAllRecipients(for mail: Mail, accountEmail: String) -> (to: String, cc: String)? {
    guard let cc = mail.cc else { return nil }
    let own = ContactDirectory.normalizedEmail(accountEmail)
    let sent = mail.labels.contains("SENT") || ContactDirectory.normalizedEmail(mail.senderEmail) == own
    let toList = sent
      ? recipients(mail.to, excluding: [own])
      : recipients(mail.replyRecipient, excluding: [own])
    var excluded = Set(toList.map(\.email)).union([own])
    var ccList: [(name: String, email: String)] = []
    for recipient in recipients((sent ? "" : mail.to + ",") + cc, excluding: excluded) {
      excluded.insert(recipient.email); ccList.append(recipient)
    }
    guard !toList.isEmpty, !ccList.isEmpty else { return nil }
    return (render(toList), render(ccList))
  }

  private static func recipients(_ header: String, excluding: Set<String>) -> [(name: String, email: String)] {
    var seen = excluding
    var result: [(name: String, email: String)] = []
    for (name, email) in ContactDirectory.addresses(header) {
      let normalized = ContactDirectory.normalizedEmail(email)
      guard ContactDirectory.isValidEmail(normalized), seen.insert(normalized).inserted else { continue }
      let safeName = name.rangeOfCharacter(from: CharacterSet(charactersIn: "\",;<>\\").union(.newlines).union(.controlCharacters)) == nil
        && ContactDirectory.normalizedEmail(name) != normalized ? name.trimmingCharacters(in: .whitespaces) : ""
      result.append((safeName, normalized))
    }
    return result
  }

  private static func render(_ list: [(name: String, email: String)]) -> String {
    list.map { $0.name.isEmpty ? $0.email : "\($0.name) <\($0.email)>" }.joined(separator: ", ")
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
