#if os(iOS)
import CoveCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileComposeEditor: UIViewRepresentable {
  @Binding var text: String
  @Binding var focused: Bool
  var inlineFiles: [OutgoingAttachment] = []
  var isEditable = true
  var onPasteImages: ([OutgoingAttachment], [String]) -> Void

  func makeUIView(context: Context) -> MobilePasteTextView {
    let view = MobilePasteTextView()
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Inter-Regular", size: 15) ?? .systemFont(ofSize: 15))
    view.adjustsFontForContentSizeCategory = true
    view.textColor = UIColor(MobilePalette.ink)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 6
    view.typingAttributes = [.font: view.font!, .foregroundColor: view.textColor!, .paragraphStyle: paragraph]
    view.plainAttributes = view.typingAttributes
    view.inlineFiles = inlineFiles
    view.accessibilityLabel = "Message body"
    view.delegate = context.coordinator
    view.isEditable = isEditable
    view.onPasteImages = onPasteImages
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateUIView(_ view: MobilePasteTextView, context: Context) {
    context.coordinator.parent = self
    view.isEditable = isEditable
    view.onPasteImages = onPasteImages
    let filesChanged = view.inlineFiles.map(\.id) != inlineFiles.map(\.id)
    view.inlineFiles = inlineFiles
    if view.markedTextRange == nil, (view.bodyText != text || filesChanged) {
      let selected = InlineImageText.modelRange(view.selectedRange, in: view.attributedText)
      view.attributedText = InlineImageText.rendered(text, files: inlineFiles, attributes: view.plainAttributes, width: max(180, view.bounds.width))
      view.selectedRange = InlineImageText.nativeRange(selected, in: view.attributedText)
      view.typingAttributes = view.plainAttributes
    }
    if focused != view.isFirstResponder {
      if focused { view.becomeFirstResponder() } else { view.resignFirstResponder() }
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: MobilePasteTextView, context: Context) -> CGSize? {
    guard let width = proposal.width else { return nil }
    return CGSize(width: width, height: max(260, uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: MobileComposeEditor
    init(_ parent: MobileComposeEditor) { self.parent = parent }
    func textViewDidChange(_ textView: UITextView) {
      guard textView.markedTextRange == nil else { return }
      guard let view = textView as? MobilePasteTextView else { return }
      parent.text = view.bodyText
      view.typingAttributes = view.plainAttributes
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
      guard let view = textView as? MobilePasteTextView, view.markedTextRange == nil else { return }
      view.typingAttributes = view.plainAttributes
    }
    func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
    func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
  }
}

final class MobilePasteTextView: UITextView {
  var inlineFiles: [OutgoingAttachment] = []
  var plainAttributes: [NSAttributedString.Key: Any] = [:]
  var bodyText: String { InlineImageText.serialized(attributedText) }

  private func replaceSelection(with value: NSAttributedString) {
    let old = NSAttributedString(attributedString: attributedText)
    let selection = selectedRange
    undoManager?.registerUndo(withTarget: self) { view in view.restore(old, selection: selection) }
    textStorage.replaceCharacters(in: selection, with: value)
    selectedRange = NSRange(location: selection.location + value.length, length: 0)
    typingAttributes = plainAttributes
    delegate?.textViewDidChange?(self)
  }

  private func restore(_ text: NSAttributedString, selection: NSRange) {
    let old = NSAttributedString(attributedString: attributedText)
    let oldSelection = selectedRange
    undoManager?.registerUndo(withTarget: self) { view in view.restore(old, selection: oldSelection) }
    attributedText = text
    selectedRange = selection
    typingAttributes = plainAttributes
    delegate?.textViewDidChange?(self)
  }

  var onPasteImages: (([OutgoingAttachment], [String]) -> Void)?
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    // hasImages checks availability only. Read pixels only after the user chooses Paste or ⌘V.
    if action == #selector(paste(_:)), isEditable, onPasteImages != nil, UIPasteboard.general.hasImages { return true }
    return super.canPerformAction(action, withSender: sender)
  }

  override func paste(_ sender: Any?) {
    guard isEditable, let onPasteImages, UIPasteboard.general.hasImages else { super.paste(sender); return }
    var files: [OutgoingAttachment] = []
    var problems: [String] = []
    for item in UIPasteboard.general.items {
      let types = [UTType.png, .jpeg, .gif, .tiff, .heic]
      let data = types.compactMap { item[$0.identifier] as? Data }.first
        ?? item.first(where: { UTType($0.key)?.conforms(to: .image) == true })?.value as? Data
        ?? item.values.compactMap { ($0 as? UIImage)?.pngData() }.first
      do {
        guard let data else { throw CoveError.message("Cove couldn’t read the copied image.") }
        files.append(try PastedImage.attachment(data: data, name: "Pasted image \(files.count + 1)"))
      } catch { problems.append(error.localizedDescription) }
    }
    files = files.map { var file = $0; file.inline = true; return file }
    let result = OutgoingAttachment.adding(files, to: inlineFiles)
    let accepted = result.files.filter { file in files.contains { $0.id == file.id } }
    if let problem = result.problem { problems.append(problem) }
    onPasteImages(accepted, problems)
    inlineFiles = result.files
    if !accepted.isEmpty {
      replaceSelection(with: InlineImageText.rendered(accepted.map(\.bodyToken).joined(), files: accepted,
        attributes: plainAttributes, width: max(180, bounds.width)))
    }
  }
}
#endif
