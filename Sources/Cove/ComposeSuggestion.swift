import CoveCore
import Foundation

/// The exact draft used for a suggestion. Never overwrite edits made while the provider worked.
struct ComposeSuggestion {
  let original: String
  let selection: NSRange?
  var text: String

  init(original: String, selection: NSRange? = nil, text: String) {
    self.original = original
    if let selection, selection.length > 0, Range(selection, in: original) != nil {
      self.selection = selection
    } else {
      self.selection = nil
    }
    self.text = text
  }

  var sourceText: String {
    guard let selection, let range = Range(selection, in: original) else { return original }
    return String(original[range])
  }

  func applying(to current: String) throws -> String {
    guard current == original else {
      throw CoveError.message("Your draft changed while this suggestion was open. Keep your edits and generate a new suggestion.")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoveError.message("The suggestion is empty. Add text or keep your original.")
    }
    guard let selection, let range = Range(selection, in: current) else { return text }
    return current.replacingCharacters(in: range, with: text)
  }

  static func instruction(_ request: String, voice: String, instructions: [String], selection: Bool,
                          profile: VoiceProfile? = nil, memories: String? = nil) -> String {
    var parts = ["Current user request:\n" + request, "Writing voice: \(voice). Preserve facts, names, dates, and commitments."]
    if let profile { parts.append(profile.promptText) }
    if let memories { parts.append(memories) }
    if !instructions.isEmpty {
      parts.append("Saved writing preferences:\n" + instructions.joined(separator: "\n"))
    }
    if selection { parts.append("Rewrite only the supplied selected passage. Return only its replacement text.") }
    return parts.joined(separator: "\n\n")
  }
}

/// Captures the exact pending passage before a refinement. The final suggestion keeps
/// its original draft snapshot and outer selection, even when refining a smaller passage.
struct ComposeRefinement {
  let base: ComposeSuggestion
  let passage: ComposeSuggestion
  init(base: ComposeSuggestion, selection: NSRange?) throws {
    if let selection, !Self.validSelection(selection, in: base.text) {
      throw CoveError.message("Select the text you want to rewrite again. Your suggestion hasn’t changed.")
    }
    self.base = base
    passage = ComposeSuggestion(original: base.text, selection: selection, text: "")
  }
  static func validSelection(_ selection: NSRange, in text: String) -> Bool {
    guard selection.length > 0, let range = Range(selection, in: text) else { return false }
    return range.lowerBound.samePosition(in: text.unicodeScalars) != nil
      && range.upperBound.samePosition(in: text.unicodeScalars) != nil
      && NSRange(range, in: text) == selection
  }
  var sourceText: String { passage.sourceText }
  func merging(_ replacement: String) throws -> ComposeSuggestion {
    var edit = passage
    edit.text = replacement
    return ComposeSuggestion(original: base.original, selection: base.selection,
      text: try edit.applying(to: base.text))
  }
}
