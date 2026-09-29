import Foundation

/// A description of how the user writes, learned once from their own sent mail.
/// It holds style observations only; sent-mail bodies are never stored in it.
public struct VoiceProfile: Codable, Equatable, Sendable {
  public var summary: String
  public var greetings: [String]
  public var signoffs: [String]
  public var traits: [String]
  public var phrases: [String]
  public var languages: [String]
  public var learnedAt: Date
  public var sampleCount: Int
  public var model: String

  public init(
    summary: String, greetings: [String] = [], signoffs: [String] = [], traits: [String] = [],
    phrases: [String] = [], languages: [String] = [], learnedAt: Date, sampleCount: Int, model: String
  ) {
    self.summary = summary; self.greetings = greetings; self.signoffs = signoffs; self.traits = traits
    self.phrases = phrases; self.languages = languages; self.learnedAt = learnedAt
    self.sampleCount = sampleCount; self.model = model
  }

  /// Style guidance added to writing prompts. The request's language rules still take precedence.
  public var promptText: String {
    var lines = ["Learned writing style (from the user's own sent mail): " + summary]
    if !traits.isEmpty { lines.append("Style traits: " + traits.joined(separator: "; ")) }
    if !greetings.isEmpty { lines.append("Typical greetings: " + greetings.joined(separator: " | ")) }
    if !signoffs.isEmpty { lines.append("Typical sign-offs: " + signoffs.joined(separator: " | ")) }
    if !phrases.isEmpty { lines.append("Characteristic phrasing: " + phrases.joined(separator: " | ")) }
    if !languages.isEmpty { lines.append("Languages the user writes in: " + languages.joined(separator: ", ")) }
    lines.append("Match this style naturally. It never overrides the requested language, facts or commitments.")
    return lines.joined(separator: "\n")
  }

  /// Parses the model's JSON defensively: unknown fields are ignored, lists and strings are bounded.
  public static func parse(_ text: String, sampleCount: Int, model: String, now: Date = Date()) throws -> VoiceProfile {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
      let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    else { throw CoveError.message("The writing model didn’t return a readable voice profile. Try again.") }
    func clean(_ value: Any?, limit: Int) -> String {
      let raw = (value as? String ?? "").replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return String(raw.prefix(limit))
    }
    func list(_ key: String, count: Int, limit: Int) -> [String] {
      var seen = Set<String>()
      return ((object[key] as? [Any]) ?? []).map { clean($0, limit: limit) }
        .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(count).map { $0 }
    }
    let summary = clean(object["summary"], limit: 600)
    guard !summary.isEmpty else {
      throw CoveError.message("The writing model didn’t describe a voice. Try again.")
    }
    return VoiceProfile(
      summary: summary, greetings: list("greetings", count: 4, limit: 60),
      signoffs: list("signoffs", count: 4, limit: 60), traits: list("traits", count: 8, limit: 140),
      phrases: list("phrases", count: 8, limit: 80), languages: list("languages", count: 4, limit: 30),
      learnedAt: now, sampleCount: sampleCount, model: String(model.prefix(120)))
  }

  /// Bounded excerpts of what the user actually wrote: quoted replies, forwarded blocks and
  /// very short notes are removed. Newest first.
  public static func samples(from mails: [Mail], accountEmail: String, limit: Int = 25, bytes: Int = 1_200) -> [Mail] {
    let own = ContactDirectory.normalizedEmail(accountEmail)
    let sent = mails.filter {
      $0.labels.contains("SENT") && !$0.labels.contains("DRAFT")
        && ContactDirectory.normalizedEmail($0.senderEmail) == own
    }.sorted { $0.date > $1.date }
    var result: [Mail] = []
    for mail in sent where result.count < limit {
      let text = ownText(mail.body)
      guard text.count >= 40 else { continue }
      var excerpt = mail
      excerpt.body = String(text.prefix(bytes))
      excerpt.htmlBody = nil; excerpt.attachments = nil; excerpt.draft = ""; excerpt.decision = nil
      result.append(excerpt)
    }
    return result
  }

  /// The part of a sent message the user wrote, before any quoted or forwarded content.
  public static func ownText(_ body: String) -> String {
    var kept: [String] = []
    let markers = [
      #"^On .+ wrote:\s*$"#, #"^El .+ escribió:\s*$"#, #"^Le .+ a écrit\s*:\s*$"#, #"^Am .+ schrieb .+:\s*$"#,
      #"^-{2,}\s*(Original Message|Forwarded message|Mensaje original|Mensaje reenviado)"#,
      #"^(From|De|Von):\s.+"#,
    ]
    for line in body.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if markers.contains(where: { trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { break }
      if trimmed.hasPrefix(">") { continue }
      kept.append(line)
    }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
