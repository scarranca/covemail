import Foundation

extension SourcePassages {
  /// Retrieval is local and lexical. Jev decides which of these original passages
  /// actually answer the question; candidate matches alone are never answers.
  public init(mailbox messages: [Mail], query: String, limit: Int = 20) throws {
    let eligible = Self.eligibleForAssistant(messages)
    let terms = MailboxRetrieval.terms(query)
    var candidates: [MailboxRetrieval.Candidate] = []
    for mail in eligible {
      try Task.checkCancellation()
      let candidate = try MailboxRetrieval.candidate(mail, terms: terms)
      guard !candidate.passages.isEmpty else { continue }
      candidates.append(candidate)
      candidates.sort {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.mail.date != $1.mail.date { return $0.mail.date > $1.mail.date }
        return $0.mail.id < $1.mail.id
      }
      if candidates.count > limit { candidates.removeLast() }
    }
    self.init(
      selected: candidates.map(\.mail),
      prepared: candidates.map { ($0.passages, $0.limited) }, totalMessages: eligible.count)
  }
}

private enum MailboxRetrieval {
  struct Candidate {
    let mail: Mail
    let passages: [String]
    let limited: Bool
    let score: Int
  }
  struct Chunk {
    let text: String
    let position: Int
    let score: Int
  }
  // Ignore question scaffolding, not dates, names or topic words. This only orders
  // candidates; Jev receives the complete bounded question, including negations.
  static let stopWords = Set(
    "a an the i me my mine we our you your it its this that these those is are was were be been do does did have has had can could would should will please what which who when where how why about from to for of on in at by with and or as any all email emails mail message messages inbox mailbox tell find show give need needs want mentioned mentions mention que cual cuales quien cuando donde como por para con los las el la un una unos unas mi mis tus su sus correo correos mensaje mensajes tengo tiene hay me puedes mostrar buscar"
      .split(separator: " ").map(String.init))

  static func words(_ text: String) -> Set<String> {
    Set(
      text.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
  }
  static func terms(_ query: String) -> Set<String> {
    words(JevClient.boundedText(query, limit: 2_000)).subtracting(stopWords)
  }
  static func candidate(_ mail: Mail, terms: Set<String>) throws -> Candidate {
    let headerMatches = words(mail.subject + " " + mail.sender + " " + mail.senderEmail)
      .intersection(terms)
    var matched = headerMatches
    var chunks: [Chunk] = []
    var count = 0
    var skipped = false
    // Scan the entire cached body, retaining at most 24 best chunks. A useful
    // detail at the end of a long message must compete with its opening text.
    // Overlapping windows keep neighboring lines together (e.g. an event title
    // followed by its date) and avoid losing words at a chunk boundary.
    var rest = mail.body[...]
    while !rest.isEmpty {
      try Task.checkCancellation()
      let part = JevClient.boundedPrefix(rest, limit: 1_000)
      if part.isEmpty {
        rest = rest.dropFirst()
        skipped = true
        continue
      }
      let advance = JevClient.boundedPrefix(part, limit: 800)
      let next =
        part.endIndex == rest.endIndex || advance.isEmpty ? part.endIndex : advance.endIndex
      rest = rest[next...]
      let text = String(part).trimmingCharacters(in: JevClient.contentPadding)
      guard JevClient.hasVisibleContent(text) else { continue }
      let matches = terms.isEmpty ? Set<String>() : words(text).intersection(terms)
      matched.formUnion(matches)
      chunks.append(Chunk(text: text, position: count, score: matches.count))
      count += 1
      chunks.sort { $0.score == $1.score ? $0.position < $1.position : $0.score > $1.score }
      if chunks.count > 24 { chunks.removeLast() }
    }
    try Task.checkCancellation()
    return Candidate(
      mail: mail, passages: chunks.map(\.text), limited: skipped || count > chunks.count,
      score: matched.count * 10 + headerMatches.count * 2)
  }
}
