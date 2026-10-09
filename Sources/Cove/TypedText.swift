import AppKit
import SwiftUI

/// Text being typed in a native editor, kept outside the view that shows it.
///
/// The editor already draws every letter. When the text (and the caret, and the pending save) lived in
/// `@State` on the reader or composer, each letter made SwiftUI rebuild and re-measure the whole view
/// around the editor, the full conversation included: most of a keystroke's cost. Here a letter changes
/// nothing SwiftUI observes unless something visible depends on it:
/// - `isBlank` flips when the text becomes empty or not (Send, the writing tools);
/// - `highlight` changes when a selection starts, changes or ends (scoped rewrites), not when the caret
///   moves as you type;
/// - `revision` bumps when the text is replaced from outside the editor (a template, an applied
///   suggestion, another draft), so the editor shows it.
/// Views read these inside a `TypedTextReader`; actions read `text` and `selection` when they run.
@Observable @MainActor final class TypedText {
  @ObservationIgnored private(set) var text: String
  @ObservationIgnored private(set) var selection = NSRange(location: 0, length: 0)
  private(set) var revision = 0
  private(set) var isBlank: Bool
  private(set) var highlight = NSRange(location: 0, length: 0)
  /// Words in the text, when asked for (`countsWords`): changes about once per word, not per letter.
  private(set) var wordCount = 0
  @ObservationIgnored private let countsWords: Bool
  /// The delayed save, its target and the last saved text: bookkeeping no view shows.
  @ObservationIgnored var saveTask: Task<Void, Never>?
  @ObservationIgnored var pendingID: String?
  @ObservationIgnored var saved = ""

  init(_ text: String = "", countsWords: Bool = false) {
    self.text = text
    self.countsWords = countsWords
    isBlank = Self.blank(text)
    if countsWords { wordCount = Self.words(text) }
  }

  /// Text set from outside the editor: the editor is told to show it.
  func replace(_ value: String) {
    text = value
    revision &+= 1
    refreshBlank()
  }

  /// Text the user typed: the editor already shows it.
  func edited(_ value: String) {
    text = value
    refreshBlank()
  }

  func select(_ range: NSRange) {
    selection = range
    let shown = range.length > 0 ? range : NSRange(location: 0, length: 0)
    if shown != highlight { highlight = shown }
  }

  private func refreshBlank() {
    let blank = Self.blank(text)
    if blank != isBlank { isBlank = blank }
    if countsWords {
      let words = Self.words(text)
      if words != wordCount { wordCount = words }
    }
  }

  /// Runs of non-whitespace, counted without building substrings.
  static func words(_ text: String) -> Int {
    var count = 0
    var inWord = false
    for character in text {
      if character.isWhitespace { inWord = false } else if !inWord { inWord = true; count += 1 }
    }
    return count
  }

  /// Only whitespace; stops at the first visible character, so it's cheap on every keystroke.
  static func blank(_ text: String) -> Bool { !text.contains { !$0.isWhitespace } }
}

/// Builds `content` in its own body, so whatever it reads from a `TypedText` redraws only this view,
/// not the one that contains it.
struct TypedTextReader<Content: View>: View {
  @ViewBuilder var content: () -> Content
  var body: some View { content() }
}

/// A one-line field's text (To, Subject) in an observable box, so typing in it redraws only the views that
/// read `value` (the field and its suggestions, inside a `TypedTextReader`), not the whole composer.
/// `isBlank` changes only when the field empties or fills.
@Observable @MainActor final class FieldText {
  var value: String {
    didSet {
      let blank = TypedText.blank(value)
      if blank != isBlank { isBlank = blank }
    }
  }
  private(set) var isBlank: Bool
  init(_ value: String = "") { self.value = value; isBlank = TypedText.blank(value) }
}
