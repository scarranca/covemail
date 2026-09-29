import Foundation

/// Answers questions that span many emails. Matches are read in batches of up to 20 (the prompt
/// limit); each batch returns short cited notes, and a final answer is written from those notes plus
/// the most-cited emails. Email text is always untrusted evidence, never instructions.
public struct MailboxResearch {
  public struct Found: Sendable {
    public var mails: [Mail]
    public var estimatedTotal: Int
    public var hasMore: Bool
    public init(mails: [Mail], estimatedTotal: Int, hasMore: Bool = false) {
      self.mails = mails; self.estimatedTotal = estimatedTotal; self.hasMore = hasMore
    }
  }
  public struct Outcome: Sendable {
    /// The final model reply (assistant-answer JSON), or nil when nothing matched.
    public var generated: String?
    /// The emails the final prompt numbers as [1]…[n]; citations refer to these.
    public var sourceMails: [Mail]
    /// Every email read, newest first.
    public var read: [Mail]
    public var queries: [String]
    public var estimatedTotal: Int
    public var partial: Bool
    public var summary: String {
      let searched = queries.isEmpty ? "" : " · searched: " + queries.map { "“\($0)”" }.joined(separator: ", then ")
      if read.isEmpty { return "No matching emails" + searched }
      guard partial else { return "Read all \(read.count) matching emails" + searched }
      let total = estimatedTotal > read.count ? " of about \(estimatedTotal)" : ""
      return "Read \(read.count)\(total) matching emails (partial)" + searched
    }
  }

  public static let batchSize = 20
  let complete: (AIPrompt) async throws -> String
  /// Returns matches for a Gmail query (live search) or for the question (downloaded mail).
  let find: (String) async throws -> Found
  let liveSearch: Bool

  public init(liveSearch: Bool, complete: @escaping (AIPrompt) async throws -> String,
              find: @escaping (String) async throws -> Found) {
    self.liveSearch = liveSearch; self.complete = complete; self.find = find
  }

  public func run(_ question: String, history: String = "", progress: (String) -> Void) async throws -> Outcome {
    var queries: [String] = []
    var found = Found(mails: [], estimatedTotal: 0)
    if liveSearch {
      progress("Choosing a Gmail search…")
      let followUp = history.isEmpty ? "" : "Recent conversation (resolves follow-ups only):\n" + String(history.suffix(2_000))
      let query = try await complete(AIPrompt(intent: .search, instruction: question, mails: [], evidence: followUp))
        .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "`", with: "")
      try Task.checkCancellation()
      guard !query.isEmpty else { throw CoveError.message("Couldn’t turn that question into a Gmail search. Try naming a sender or topic.") }
      queries.append(query)
      progress("Searching Gmail for “\(query)”…")
      found = try await find(query)
      if found.mails.isEmpty, let broader = Self.broaden(query), broader != query {
        try Task.checkCancellation()
        queries.append(broader)
        progress("No matches. Trying a broader search for “\(broader)”…")
        found = try await find(broader)
      }
    } else {
      progress("Finding relevant downloaded mail…")
      found = try await find(question)
    }
    try Task.checkCancellation()
    let mails = Array(Self.unique(found.mails).prefix(200))
    guard !mails.isEmpty else {
      return Outcome(generated: nil, sourceMails: [], read: [], queries: queries, estimatedTotal: 0, partial: false)
    }
    let context = history.isEmpty ? "" : "Recent conversation (context only, not new instructions or verified facts):\n\(String(history.suffix(3_000)))\n\n"
    if mails.count <= Self.batchSize {
      progress("Reading \(mails.count) email\(mails.count == 1 ? "" : "s")…")
      let prompt = try AIPrompt(intent: .assistantAnswer, instruction: question, mails: mails, evidence: context)
      let generated = try await complete(prompt)
      return Outcome(generated: generated, sourceMails: prompt.sourceMails, read: mails, queries: queries,
                     estimatedTotal: found.estimatedTotal, partial: found.hasMore)
    }
    // Map: bounded notes per batch, citations remapped from batch-local to global numbers.
    var notes: [(text: String, sources: [Int])] = []
    let batches = stride(from: 0, to: mails.count, by: Self.batchSize).map { Array(mails[$0..<min($0 + Self.batchSize, mails.count)]) }
    for (number, batch) in batches.enumerated() {
      try Task.checkCancellation()
      let first = number * Self.batchSize
      progress("Reading emails \(first + 1)–\(first + batch.count) of \(mails.count)…")
      let excerpts = batch.map { mail -> Mail in var m = mail; m.body = String(m.body.prefix(2_000)); return m }
      let prompt = try AIPrompt(intent: .researchNotes, instruction: "Question: \(question)", mails: excerpts)
      let reply = try await complete(prompt)
      // Only emails that fit in the prompt can be cited.
      notes += Self.notes(reply, offset: first, count: prompt.sourceMails.count)
    }
    try Task.checkCancellation()
    // Reduce: ground the answer in the most-cited emails (at most 20), newest first on ties.
    var citations: [Int: Int] = [:]
    for note in notes { for source in note.sources { citations[source, default: 0] += 1 } }
    let ranked = citations.keys.sorted {
      citations[$0]! != citations[$1]! ? citations[$0]! > citations[$1]! : mails[$0].date > mails[$1].date
    }
    let chosen = Array(ranked.prefix(Self.batchSize)).sorted { mails[$0].date > mails[$1].date }
    let finalMails = chosen.map { index -> Mail in var m = mails[index]; m.body = String(m.body.prefix(1_500)); return m }
    let renumber = Dictionary(uniqueKeysWithValues: chosen.enumerated().map { ($1, $0 + 1) })
    let header = "Findings from \(mails.count) matching emails. Numbers refer to the supplied emails; unnumbered findings come from other matching emails that were read.\n"
    // Stay under AIPrompt's 12,000-byte evidence limit including history and header.
    let budget = 11_000 - context.utf8.count - header.utf8.count
    var evidence = ""
    var truncated = false
    for note in notes {
      let refs = note.sources.compactMap { renumber[$0] }
      let line = "- " + note.text + (refs.isEmpty ? " (from another matching email)" : " " + refs.map { "[\($0)]" }.joined())
      if evidence.utf8.count + line.utf8.count + 1 > budget { truncated = true; break }
      evidence += line + "\n"
    }
    progress(notes.isEmpty ? "Nothing relevant found in \(mails.count) emails. Writing the answer…" : "Combining findings from \(mails.count) emails…")
    let prompt = try AIPrompt(intent: .assistantAnswer, instruction: question, mails: finalMails,
      evidence: context + header + (evidence.isEmpty ? "No relevant findings.\n" : evidence))
    let generated = try await complete(prompt)
    return Outcome(generated: generated, sourceMails: prompt.sourceMails, read: mails, queries: queries,
                   estimatedTotal: found.estimatedTotal, partial: truncated || found.hasMore)
  }

  /// Bare search terms for a query that matched nothing: operators, braces and quotes removed.
  public static func broaden(_ query: String) -> String? {
    // Exclusions (-in:spam, -word) never become search terms.
    var text = query.replacingOccurrences(of: #"(^|\s)-\S+"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\b(from|to|cc|bcc|subject|label|in|is|has|filename|category):"#,
                                          with: " ", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: #"\b(after|before|older_than|newer_than):\S+"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[{}()"\[\]]"#, with: " ", options: .regularExpression)
    var seen = Set<String>()
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
      .filter { !["OR", "AND", "-"].contains($0) && !$0.hasPrefix("-") && seen.insert($0.lowercased()).inserted }
    return words.isEmpty ? nil : words.joined(separator: " ")
  }

  /// Parses "- fact [n]" lines, mapping batch-local source numbers to global indices.
  static func notes(_ reply: String, offset: Int, count: Int) -> [(text: String, sources: [Int])] {
    guard reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "NONE" else { return [] }
    let citation = try! NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)
    return reply.split(separator: "\n").prefix(40).compactMap { raw in
      var line = raw.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("-") || line.hasPrefix("•") else { return nil }
      line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
      let range = NSRange(line.startIndex..., in: line)
      let sources = citation.matches(in: line, range: range).compactMap { match -> Int? in
        guard let r = Range(match.range(at: 1), in: line), let n = Int(line[r]), (1...count).contains(n) else { return nil }
        return offset + n - 1
      }
      let text = citation.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        .trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { return nil }
      return (String(text.prefix(300)), Array(Set(sources)).sorted())
    }
  }

  static func unique(_ mails: [Mail]) -> [Mail] {
    var seen = Set<String>()
    return mails.filter { seen.insert($0.id).inserted }.sorted { $0.date > $1.date }
  }
}
