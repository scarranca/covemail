import Foundation

/// The contact directory folded once (case and accents) for the To field. Ranking a keystroke then
/// compares bytes instead of folding every name and address again, which is what made typing in To lag
/// on large mailboxes. Build it off the main thread; it is immutable and `Sendable`.
public struct ContactSearchIndex: Sendable {
  struct Entry: Sendable {
    let contact: MailContact
    let name: [UInt8]
    let email: [UInt8]
  }
  /// Most emailed first, then most recent: the order ties are broken in within a rank.
  let entries: [Entry]
  /// Most recent first, for the empty To field.
  public let recent: [MailContact]

  public init(_ contacts: [MailContact]) {
    entries = contacts.sorted { lhs, rhs in
      if lhs.messages.count != rhs.messages.count { return lhs.messages.count > rhs.messages.count }
      return (lhs.lastMessage ?? .distantPast) > (rhs.lastMessage ?? .distantPast)
    }.map { Entry(contact: $0, name: Array(MailSearchIndex.fold($0.name).utf8), email: Array(MailSearchIndex.fold($0.email).utf8)) }
    recent = contacts.sorted { ($0.lastMessage ?? .distantPast) > ($1.lastMessage ?? .distantPast) }
  }

  public var count: Int { entries.count }

  /// The most recent people not already chosen.
  public func recent(excluding: Set<String> = [], limit: Int = 4) -> [MailContact] {
    Array(recent.lazy.filter { !excluding.contains($0.email) }.prefix(limit))
  }

  /// Suggestions for an address field: people from downloaded mail first (best match, then most emailed),
  /// then people Gmail found beyond it, without duplicates or addresses already chosen.
  public func suggestions(_ text: String, remote: [MailContact] = [], excluding: Set<String> = [],
                          limit: Int = 6) -> [MailContact] {
    let query = Query(text)
    var buckets: [[MailContact]] = [[], [], []]
    for entry in entries {
      // Enough exact-prefix matches already: nothing later can outrank them.
      if buckets[0].count >= limit + excluding.count { break }
      if let rank = query.rank(name: entry.name, email: entry.email) { buckets[rank].append(entry.contact) }
    }
    var seen = excluding
    var result: [MailContact] = []
    let others = remote.filter {
      query.rank(name: Array(MailSearchIndex.fold($0.name).utf8), email: Array(MailSearchIndex.fold($0.email).utf8)) != nil
    }
    for contact in buckets[0] + buckets[1] + buckets[2] + others where result.count < limit && seen.insert(contact.email).inserted {
      result.append(contact)
    }
    return result
  }

  struct Query {
    let whole: [UInt8]
    let terms: [[UInt8]]
    init(_ text: String) {
      let folded = MailSearchIndex.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
      whole = Array(folded.utf8)
      terms = folded.split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
    }

    /// 0: the name or address starts with the query; 1: a word of the name starts with the first word;
    /// 2: every word appears somewhere; nil: no match.
    func rank(name: [UInt8], email: [UInt8]) -> Int? {
      guard terms.allSatisfy({ Self.contains(name, $0) || Self.contains(email, $0) }) else { return nil }
      if Self.hasPrefix(name, whole) || Self.hasPrefix(email, whole) { return 0 }
      if let first = terms.first, Self.wordStarts(name, with: first) { return 1 }
      return 2
    }

    static func hasPrefix(_ text: [UInt8], _ prefix: [UInt8]) -> Bool {
      prefix.count <= text.count && text.starts(with: prefix)
    }
    static func contains(_ text: [UInt8], _ needle: [UInt8]) -> Bool {
      guard !needle.isEmpty else { return true }
      guard needle.count <= text.count else { return false }
      return text.withUnsafeBufferPointer { hay in
        needle.withUnsafeBufferPointer { n in memmem(hay.baseAddress!, hay.count, n.baseAddress!, n.count) != nil }
      }
    }
    static func wordStarts(_ text: [UInt8], with word: [UInt8]) -> Bool {
      guard !word.isEmpty, word.count <= text.count else { return word.isEmpty }
      for start in 0...(text.count - word.count) where start == 0 || text[start - 1] == UInt8(ascii: " ") {
        if text[start..<(start + word.count)].elementsEqual(word) { return true }
      }
      return false
    }
  }
}
