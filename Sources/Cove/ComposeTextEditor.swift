import AppKit
import SwiftUI

/// A native plain-text editor, with selection exposed for scoped AI rewrites.
struct ComposeTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var selection: NSRange
  var accessibilityName = "Message body"
  var isEditable = true
  /// Increment to move keyboard focus into the editor.
  var focusRequest = 0
  var inset = NSSize(width: 22, height: 18)

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    // TextKit 1. TextKit 2 adds a drawing subview for each new line or paragraph, and every added
    // subview tells SwiftUI the layout changed, so it re-measured the whole reader or composer around
    // the editor (the window's minimum size) while typing. TextKit 1 draws in place.
    let editor = NSTextView(usingTextLayoutManager: false)
    editor.isRichText = false
    editor.isEditable = isEditable
    editor.allowsUndo = true
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.minSize = .zero
    editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    editor.font = CoveTypography.nativeBody
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = CoveTypography.bodyLineSpacing
    editor.defaultParagraphStyle = paragraph
    editor.typingAttributes = [.font: CoveTypography.nativeBody, .paragraphStyle: paragraph]
    editor.textColor = NSColor(Palette.ink)
    editor.backgroundColor = NSColor(Palette.canvas)
    editor.textContainerInset = inset
    editor.setAccessibilityLabel(accessibilityName)
    scroll.documentView = editor
    editor.string = text
    editor.delegate = context.coordinator
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = scroll.documentView as? NSTextView else { return }
    context.coordinator.updating = true
    defer { context.coordinator.updating = false }
    editor.isEditable = isEditable
    if !isEditable, editor.window?.firstResponder === editor {
      editor.window?.makeFirstResponder(nil)
    }
    // While an accent or other composed character is pending (´ waiting for its vowel, or an input
    // method's candidate), the text holds a temporary mark. Re-setting the string here would drop it
    // and send the cursor to the start, so leave the editor alone until the character is committed.
    if editor.hasMarkedText() {
      if focusRequest != context.coordinator.focusRequest { context.coordinator.focusRequest = focusRequest }
      return
    }
    if editor.string != text {
      editor.string = text
    }
    if focusRequest != context.coordinator.focusRequest {
      context.coordinator.focusRequest = focusRequest
      DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
    }
    // An out-of-date selection lands at the end of the text, never the start.
    let end = NSRange(location: (text as NSString).length, length: 0)
    let safeRange = Range(selection, in: text) != nil ? selection : end
    if editor.selectedRange() != safeRange { editor.setSelectedRange(safeRange) }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ComposeTextEditor
    var updating = false
    var focusRequest: Int
    init(_ parent: ComposeTextEditor) { self.parent = parent; focusRequest = parent.focusRequest }
    func textDidChange(_ notification: Notification) {
      // A pending accent isn't text yet; it's reported once the character is committed.
      guard !updating, let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
      parent.text = editor.string
      if parent.selection != editor.selectedRange() { parent.selection = editor.selectedRange() }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard !updating, let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
      if parent.selection != editor.selectedRange() { parent.selection = editor.selectedRange() }
    }
  }
}
