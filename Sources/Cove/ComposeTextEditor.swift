import AppKit
import SwiftUI

/// A native plain-text editor, with selection exposed for scoped AI rewrites.
struct ComposeTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var selection: NSRange
  var accessibilityName = "Message body"
  var isEditable = true

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let editor = NSTextView()
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
    editor.textContainerInset = NSSize(width: 22, height: 18)
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
    if editor.string != text {
      editor.string = text
    }
    let safeRange = Range(selection, in: text) != nil ? selection : NSRange(location: 0, length: 0)
    if editor.selectedRange() != safeRange { editor.setSelectedRange(safeRange) }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ComposeTextEditor
    var updating = false
    init(_ parent: ComposeTextEditor) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard !updating, let editor = notification.object as? NSTextView else { return }
      parent.text = editor.string
      if parent.selection != editor.selectedRange() { parent.selection = editor.selectedRange() }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard !updating, let editor = notification.object as? NSTextView else { return }
      if parent.selection != editor.selectedRange() { parent.selection = editor.selectedRange() }
    }
  }
}
