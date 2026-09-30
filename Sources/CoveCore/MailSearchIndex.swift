import Foundation

/// Instant local search. Each email's sender, address, subject and body are folded once (case- and
/// accent-insensitive) into bytes and matched with a byte search; entries refresh only when an
/// email's searchable fields change. Every word of the query must appear, in any order.
public final class MailSearchIndex {
  private struct Entry {
    let subject: String
    let sender: String
    let senderEmail: String
    let bodyCount: Int
    let bytes: ContiguousArray<UInt8>
  }
  private var entries: [String: Entry] = [:]

  public init() {}

  public static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  /// Folded query words; an empty result means "no search".
  public static func terms(_ query: String) -> [ContiguousArray<UInt8>] {
    fold(query).split(whereSeparator: \.isWhitespace).map { ContiguousArray($0.utf8) }
  }

  public func matches(_ mail: Mail, terms: [ContiguousArray<UInt8>]) -> Bool {
    guard !terms.isEmpty else { return true }
    let haystack = entry(for: mail).bytes
    return haystack.withUnsafeBufferPointer { hay in
      terms.allSatisfy { term in
        term.withUnsafeBufferPointer { needle in
          guard let h = hay.baseAddress, let n = needle.baseAddress, needle.count <= hay.count else { return needle.isEmpty }
          return memmem(h, hay.count, n, needle.count) != nil
        }
      }
    }
  }

  /// Drops entries for emails no longer in the mailbox.
  public func retain(ids: Set<String>) {
    if entries.count > ids.count + 256 { entries = entries.filter { ids.contains($0.key) } }
  }

  private func entry(for mail: Mail) -> Entry {
    if let cached = entries[mail.id], cached.bodyCount == mail.body.utf8.count, cached.subject == mail.subject,
      cached.sender == mail.sender, cached.senderEmail == mail.senderEmail
    {
      return cached
    }
    let text = Self.fold(mail.sender + "\n" + mail.senderEmail + "\n" + mail.subject + "\n" + mail.body)
    let entry = Entry(subject: mail.subject, sender: mail.sender, senderEmail: mail.senderEmail,
                      bodyCount: mail.body.utf8.count, bytes: ContiguousArray(text.utf8))
    entries[mail.id] = entry
    return entry
  }
}
