import Foundation

extension GmailClient {
  /// The Gmail query for people whose name or address matches `text` in From, To or Cc, across all mail.
  /// Returns nil when nothing searchable remains after removing Gmail operator characters.
  static func peopleQuery(_ text: String) -> String? {
    let cleaned = text.unicodeScalars.map { scalar -> Character in
      CharacterSet(charactersIn: "\"(){}:<>,;").contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
        ? " " : Character(scalar)
    }
    let term = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard term.count >= 2, term.utf8.count <= 200 else { return nil }
    let value = term.contains(" ") ? "\"\(term)\"" : term
    return "{from:\(value) to:\(value) cc:\(value)} -in:spam -in:trash"
  }

  /// People the user wrote to or heard from whose name or address contains `text`, found by searching
  /// all of Gmail (not only mail downloaded to this device), like Gmail's own To field. Reads headers
  /// only (From, To, Cc), never bodies; the most frequent matches come first. A suggestion is not worth
  /// waiting for, so rate limits and errors are not retried (callers show local matches instead).
  public func people(matching text: String, token: String, accountEmail: String, messages limit: Int = 12)
    async throws -> [MailContact]
  {
    guard let query = Self.peopleQuery(text) else { return [] }
    struct Entry: Decodable { let id: String }
    struct Results: Decodable { let messages: [Entry]? }
    struct Header: Decodable { let name: String; let value: String }
    struct Payload: Decodable { let headers: [Header]? }
    struct Metadata: Decodable { let internalDate: String?; let payload: Payload? }
    let list = try JSONDecoder().decode(Results.self, from: await request("messages", token: token, query: [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "maxResults", value: String(min(20, max(1, limit)))),
    ], retries: 0))
    let ids = (list.messages ?? []).map(\.id)
    // Interactive: the user is waiting, so the headers are read together rather than paced.
    let headers = try await withThrowingTaskGroup(of: (Date, [Header])?.self) { group in
      for id in ids {
        group.addTask {
          try Task.checkCancellation()
          do {
            let data = try await request("messages/\(id)", token: token, query: [
              URLQueryItem(name: "format", value: "metadata"),
              URLQueryItem(name: "metadataHeaders", value: "From"),
              URLQueryItem(name: "metadataHeaders", value: "To"),
              URLQueryItem(name: "metadataHeaders", value: "Cc"),
              URLQueryItem(name: "fields", value: "internalDate,payload/headers"),
            ], retries: 0)
            let message = try JSONDecoder().decode(Metadata.self, from: data)
            let date = Date(timeIntervalSince1970: (Double(message.internalDate ?? "") ?? 0) / 1000)
            return (date, message.payload?.headers ?? [])
          } catch let error as HTTPFailure where error.statusCode == 404 { return nil }
        }
      }
      var values: [(Date, [Header])] = []
      for try await value in group { if let value { values.append(value) } }
      return values
    }
    return Self.people(in: headers.map { date, headers in
      (date, headers.filter { ["from", "to", "cc"].contains($0.name.lowercased()) }.map(\.value))
    }, matching: text, accountEmail: accountEmail)
  }

  /// Matching participants from header values, most frequent then most recent first.
  static func people(in messages: [(date: Date, headers: [String])], matching text: String, accountEmail: String)
    -> [MailContact]
  {
    let own = ContactDirectory.normalizedEmail(accountEmail)
    let terms = MailSearchIndex.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
    var found: [String: (name: String, count: Int, last: Date)] = [:]
    for message in messages {
      var seen = Set<String>()
      for header in message.headers {
        for person in ContactDirectory.addresses(header) {
          let email = ContactDirectory.normalizedEmail(person.email)
          guard email != own, ContactDirectory.isValidEmail(email), seen.insert(email).inserted else { continue }
          let name = person.name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'").union(.whitespacesAndNewlines))
          let folded = MailSearchIndex.fold(name + " " + email)
          guard !terms.isEmpty, terms.allSatisfy({ folded.contains($0) }) else { continue }
          var entry = found[email] ?? (name: email, count: 0, last: .distantPast)
          if entry.name == email, !name.isEmpty { entry.name = name }
          entry.count += 1
          entry.last = max(entry.last, message.date)
          found[email] = entry
        }
      }
    }
    return found.sorted { lhs, rhs in
      lhs.value.count != rhs.value.count ? lhs.value.count > rhs.value.count : lhs.value.last > rhs.value.last
    }.map { MailContact(email: $0.key, name: $0.value.name, record: nil, messages: []) }
  }
}

extension ContactDirectory {
  /// Suggestions for an address field: people from downloaded mail first (best match, then most emailed),
  /// then people Gmail found beyond it, without duplicates or addresses already chosen. This folds `local`
  /// on every call: for the whole directory, build a `ContactSearchIndex` once and ask it instead.
  public static func suggestions(_ text: String, local: [MailContact], remote: [MailContact],
                                 excluding: Set<String> = [], limit: Int = 6) -> [MailContact] {
    ContactSearchIndex(local).suggestions(text, remote: remote, excluding: excluding, limit: limit)
  }
}
