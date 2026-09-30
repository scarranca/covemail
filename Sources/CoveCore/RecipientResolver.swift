import Foundation

/// Matches names from a request to the user's own contacts. Addresses are never guessed:
/// a bare address is accepted only when the user typed it or it is already a known contact.
public enum RecipientResolver {
  public enum Resolution: Equatable {
    case resolved([MailContact])
    case ambiguous(name: String, candidates: [MailContact])
    case missing(name: String)

    /// A question for the user when a name couldn't be matched to exactly one contact.
    public var clarification: String? {
      switch self {
      case .resolved: return nil
      case .missing(let name):
        return "I couldn’t find “\(name)” in your contacts. Add their email address to your request, or save them in Contacts first."
      case .ambiguous(let name, let candidates):
        let options = candidates.map { "- \($0.name) <\($0.email)>" }.joined(separator: "\n")
        return "Which “\(name)” do you mean?\n\(options)\n\nReply with their email address or full name."
      }
    }
  }

  public static func resolve(_ names: [String], contacts: [MailContact], question: String, accountEmail: String)
    -> Resolution
  {
    let own = ContactDirectory.normalizedEmail(accountEmail)
    let people = contacts.filter { ContactDirectory.normalizedEmail($0.email) != own }
    var result: [MailContact] = []
    for raw in names.prefix(10) {
      let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { continue }
      if name.contains("@") {
        let email = ContactDirectory.normalizedEmail(name)
        guard ContactDirectory.isValidEmail(email), email != own,
          question.range(of: email, options: .caseInsensitive) != nil
            || people.contains(where: { $0.email == email })
        else { return .missing(name: name) }
        let known = people.first { $0.email == email }
        result.append(known ?? MailContact(email: email, name: email, record: nil, messages: []))
        continue
      }
      let query = fold(name)
      let exact = people.filter { fold($0.name) == query }
      let candidates: [MailContact]
      if !exact.isEmpty {
        candidates = exact
      } else {
        let tokens = query.split(separator: " ")
        candidates = people.filter { contact in
          let words = fold(contact.name).split(separator: " ")
          return tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
        }
      }
      let ranked = candidates.sorted { ($0.lastMessage ?? .distantPast) > ($1.lastMessage ?? .distantPast) }
      if ranked.count == 1 { result.append(ranked[0]); continue }
      if ranked.isEmpty { return .missing(name: name) }
      return .ambiguous(name: name, candidates: Array(ranked.prefix(5)))
    }
    var seen = Set<String>()
    let unique = result.filter { seen.insert($0.email).inserted }
    return unique.isEmpty ? .missing(name: names.first ?? "") : .resolved(unique)
  }

  /// Reads the user's answer to "Which Martha?": a full address, part of the address or domain
  /// ("@gigstack", "the icloud one"), a surname, or an ordinal ("the first one", "2"). Returns a
  /// candidate only when exactly one matches.
  public static func pick(from candidates: [MailContact], reply: String) -> MailContact? {
    guard !candidates.isEmpty else { return nil }
    let text = fold(reply)
    if let exact = candidates.first(where: { text.contains(ContactDirectory.normalizedEmail($0.email)) }) { return exact }
    let ordinals: [(Int, [String])] = [
      (0, ["first", "1st", "primero", "primera", "#1"]), (1, ["second", "2nd", "segundo", "segunda", "#2"]),
      (2, ["third", "3rd", "tercero", "tercera", "#3"]),
    ]
    let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    for (index, names) in ordinals where index < candidates.count {
      if names.contains(where: { words.contains($0) || text.contains($0) }) || (words == ["\(index + 1)"]) { return candidates[index] }
    }
    let filler: Set<String> = ["one", "the", "that", "this", "uno", "una", "que", "the", "please", "mean", "meant", "com", "with", "con", "email"]
    let tokens = words.filter { $0.count >= 3 && !filler.contains($0) }
    guard !tokens.isEmpty else { return nil }
    let matches = candidates.filter { candidate in
      let address = ContactDirectory.normalizedEmail(candidate.email)
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
      let name = fold(candidate.name).components(separatedBy: CharacterSet.alphanumerics.inverted)
      return tokens.contains { token in address.contains(token) || name.contains(token) }
    }
    return matches.count == 1 ? matches[0] : nil
  }

  /// Case- and accent-insensitive comparison, so "Alberto Diaz" matches "Alberto Díaz".
  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
  }
}
