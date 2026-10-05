import Foundation

/// What the user tells Cove about themselves: who they are, what they're working on, notes to keep
/// in mind, and how they sign off. It reaches every draft and Ask Cove answer as the user's own words,
/// never as facts from email, and stays on the device that holds it (the Mac's `memories` are the
/// same idea; this adds structure).
public struct PersonalContext: Codable, Equatable, Sendable {
  public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var detail: String
    public init(name: String, detail: String = "") { self.name = name; self.detail = detail }
  }

  public var name = ""
  public var role = ""
  public var company = ""
  /// One or two sentences: what the user does, for whom.
  public var about = ""
  public var projects: [Project] = []
  /// Free notes, one per line ("I'm in Mexico City, CST", "Call my manager Ana, not Ana María").
  public var notes: [String] = []
  /// How the user signs emails ("Best,\nSantiago").
  public var signature = ""
  public var enabled = true
  public var updatedAt: Date?

  public init() {}

  public var isEmpty: Bool {
    [name, role, company, about, signature].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      && projects.isEmpty && notes.isEmpty
  }

  /// Bounded text for prompts (about 2,500 bytes, like the Mac's memories), or nil when off or empty.
  public var promptText: String? {
    guard enabled, !isEmpty else { return nil }
    func clean(_ text: String, _ limit: Int) -> String {
      String(text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
    var lines = ["About the user, in their own words (not facts from email; use when relevant, never invent beyond it):"]
    let identity = [clean(name, 80), clean(role, 80), clean(company, 80)].filter { !$0.isEmpty }
    if !identity.isEmpty { lines.append("- Who: " + identity.joined(separator: ", ")) }
    if !clean(about, 400).isEmpty { lines.append("- What they do: " + clean(about, 400)) }
    // Identity and sign-off come first: a long list of notes is what gets cut.
    if !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("- Signs emails as: " + String(signature.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        .replacingOccurrences(of: "\n", with: " / "))
    }
    let current = projects.prefix(8).map { project in
      clean(project.name, 80) + (clean(project.detail, 200).isEmpty ? "" : " — " + clean(project.detail, 200))
    }.filter { !$0.isEmpty }
    if !current.isEmpty { lines.append("- Working on: " + current.joined(separator: "; ")) }
    for note in notes.prefix(20) where !clean(note, 200).isEmpty { lines.append("- " + clean(note, 200)) }
    var text = lines.joined(separator: "\n")
    while text.utf8.count > 2_500 { text.removeLast() }
    return text
  }

  // MARK: Remember / forget (Ask Cove)

  public enum Command: Equatable, Sendable { case remember(String), forget(String) }

  /// "Remember that I…" / "Recuerda que…" adds a note; "Forget …" / "Olvida …" removes matching notes.
  /// Only the user's own words become notes; nothing from email.
  public static func command(in text: String) -> Command? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    for prefix in ["remember that ", "remember ", "recuerda que ", "recuerda "] where lower.hasPrefix(prefix) {
      let note = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
      return note.isEmpty ? nil : .remember(String(note.prefix(200)))
    }
    for prefix in ["forget that ", "forget ", "olvida que ", "olvida "] where lower.hasPrefix(prefix) {
      let note = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
      return note.isEmpty ? nil : .forget(note)
    }
    return nil
  }

  /// Applies a remember/forget. Returns what changed, for the confirmation.
  @discardableResult
  public mutating func apply(_ command: Command, now: Date = Date()) -> [String] {
    switch command {
    case .remember(let note):
      guard !notes.contains(where: { $0.caseInsensitiveCompare(note) == .orderedSame }) else { return [] }
      notes.append(note)
      updatedAt = now
      return [note]
    case .forget(let phrase):
      let folded = phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      let removed = notes.filter { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(folded) }
      notes.removeAll { removed.contains($0) }
      if !removed.isEmpty { updatedAt = now }
      return removed
    }
  }

  // MARK: Suggestions from sent mail

  /// Parses the model's suggestion (strict JSON). Only fills fields the user left empty, and projects
  /// not already listed; the user reviews before saving.
  public func merging(suggestion text: String) throws -> PersonalContext {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
          let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    else { throw CoveError.message("The model didn’t return a readable suggestion. Try again.") }
    func string(_ key: String, _ limit: Int) -> String {
      String((object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
    var result = self
    if result.name.isEmpty { result.name = string("name", 80) }
    if result.role.isEmpty { result.role = string("role", 80) }
    if result.company.isEmpty { result.company = string("company", 80) }
    if result.about.isEmpty { result.about = string("about", 400) }
    if result.signature.isEmpty { result.signature = string("signature", 200) }
    for item in (object["projects"] as? [[String: Any]] ?? []).prefix(6) {
      let name = String((item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
      guard !name.isEmpty, !result.projects.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
      result.projects.append(Project(name: name, detail: String((item["detail"] as? String ?? "").prefix(200))))
    }
    return result
  }

  /// The request for that suggestion.
  public static let suggestionInstruction = """
    From these emails I wrote, describe me for my own writing assistant. Return exactly one JSON object, no code fences:
    {"name":"","role":"","company":"","about":"one or two sentences on what I do","signature":"how I sign off","projects":[{"name":"","detail":"one short line"}]}
    Use only what the emails clearly show about me (signatures, how I describe my work, recurring projects). Leave a field empty when unsure. Never include other people's private details, credentials or email text.
    """
}
