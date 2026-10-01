import Foundation

/// User-maintained address-book fields. Stored in the active account's local database.
public struct ContactRecord: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var email: String
  public var company: String
  public var phone: String
  public var group: String
  public var notes: String
  public var isFavorite: Bool

  public init(
    id: String = UUID().uuidString, name: String = "", email: String = "",
    company: String = "", phone: String = "", group: String = "", notes: String = "",
    isFavorite: Bool = false
  ) {
    self.id = id
    self.name = name
    self.email = email
    self.company = company
    self.phone = phone
    self.group = group
    self.notes = notes
    self.isFavorite = isFavorite
  }
}

public struct MailContact: Identifiable, Equatable, Sendable {
  public var id: String { email }
  public let email: String
  public let name: String
  public let record: ContactRecord?
  public let messages: [Mail]
  public var lastMessage: Date? { messages.first?.date }
  public var initials: String {
    let pieces = name.split(whereSeparator: { $0.isWhitespace })
    return pieces.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
  }
  public var recentConversations: [Mail] {
    var seen = Set<String>()
    return messages.filter { seen.insert($0.threadID.isEmpty ? $0.id : $0.threadID).inserted }
  }
  public func messageCount(since cutoff: Date, through now: Date) -> Int {
    messages.filter { $0.date >= cutoff && $0.date <= now }.count
  }
}

public enum ContactDirectory {
  public static func normalizedEmail(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  public static func isValidGroup(_ text: String) -> Bool {
    !["all contacts", "favorites"].contains(
      text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  /// Accept one ordinary mailbox address; reject headers, lists, and control characters.
  public static func isValidEmail(_ text: String) -> Bool {
    let value = normalizedEmail(text)
    guard !value.isEmpty, value.utf8.count <= 254,
      !value.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
      })
    else { return false }
    return value.range(
      of: #"^[^@<>(),;:\"\\]+@[^@<>(),;:\"\\]+\.[^@<>(),;:\"\\]+$"#, options: .regularExpression)
      != nil
  }

  public static func build(mails: [Mail], records: [ContactRecord], accountEmail: String)
    -> [MailContact]
  {
    let own = normalizedEmail(accountEmail)
    var names: [String: String] = [:]
    var byEmail: [String: [Mail]] = [:]
    var saved: [String: ContactRecord] = [:]
    for record in records {
      let email = normalizedEmail(record.email)
      guard isValidEmail(email) else { continue }
      saved[email] = record
      byEmail[email] = []
    }
    var seenIDs = Set<String>()
    for mail in mails.sorted(by: { $0.date > $1.date }) {
      guard mail.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"]),
        seenIDs.insert(mail.id).inserted
      else { continue }
      let outgoing = normalizedEmail(mail.senderEmail) == own || mail.labels.contains("SENT")
      let participants =
        outgoing ? addresses(mail.to) : [(name: mail.sender, email: mail.senderEmail)]
      var seenParticipants = Set<String>()
      for participant in participants {
        let email = normalizedEmail(participant.email)
        guard email != own, isValidEmail(email), seenParticipants.insert(email).inserted else {
          continue
        }
        byEmail[email, default: []].append(mail)
        let name = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if names[email] == nil || names[email] == email {
          names[email] = name.isEmpty ? email : name
        }
      }
    }
    return byEmail.map { email, messages in
      let record = saved[email]
      let preferredName = record?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return MailContact(
        email: email, name: preferredName.isEmpty ? (names[email] ?? email) : preferredName,
        record: record, messages: messages)
    }.sorted { lhs, rhs in
      let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
      return order == .orderedSame ? lhs.email < rhs.email : order == .orderedAscending
    }
  }

  /// Split recipient lists without treating a comma inside a quoted display name as a separator.
  public static func addresses(_ header: String) -> [(name: String, email: String)] {
    var chunks: [String] = []
    var current = ""
    var quoted = false
    var escaped = false
    var angleDepth = 0
    for character in header {
      if escaped {
        current.append(character)
        escaped = false
        continue
      }
      if character == "\\" && quoted {
        escaped = true
        current.append(character)
        continue
      }
      if character == "\"" { quoted.toggle() }
      if !quoted {
        if character == "<" { angleDepth += 1 }
        if character == ">" { angleDepth = max(0, angleDepth - 1) }
        if (character == "," || character == ";") && angleDepth == 0 {
          chunks.append(current)
          current = ""
          continue
        }
      }
      current.append(character)
    }
    chunks.append(current)
    return chunks.map { raw in
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      // The address is the final angle-addr; a quoted display name may itself contain "<".
      if let start = text.lastIndex(of: "<"), let end = text.lastIndex(of: ">"), start < end {
        let name = String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (name, String(text[text.index(after: start)..<end]))
      }
      return (text, text)
    }
  }
}

extension ContactDirectory {
  /// Who a name refers to in the open thread: a participant whose name or address matches it, otherwise
  /// the only participant outside the user's own domain ("Manuel" in a thread with one customer).
  /// nil when that isn't clear, so Cove searches the name as typed instead of guessing.
  public static func participant(named name: String, in mails: [Mail], accountEmail: String) -> (name: String, email: String)? {
    let me = accountEmail.lowercased()
    let myDomain = me.split(separator: "@").last.map(String.init) ?? ""
    var people: [(name: String, email: String)] = []
    for mail in mails {
      for person in [(name: mail.sender, email: mail.senderEmail)] + addresses(mail.to) + addresses(mail.cc ?? "") {
        let email = person.email.lowercased()
        guard email.contains("@"), email != me, !people.contains(where: { $0.email == email }) else { continue }
        people.append((person.name, email))
      }
    }
    let terms = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    guard !terms.isEmpty else { return nil }
    let matches = people.filter { person in
      let text = (person.name + " " + person.email).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      return terms.allSatisfy { text.contains($0) }
    }
    if matches.count == 1 { return matches[0] }
    if !matches.isEmpty { return nil }
    let outside = people.filter { !myDomain.isEmpty && !$0.email.hasSuffix("@" + myDomain) }
    return outside.count == 1 ? outside[0] : nil
  }
}
