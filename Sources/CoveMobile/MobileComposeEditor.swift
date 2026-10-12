#if os(iOS)
import CoveCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileComposeEditor: UIViewRepresentable {
  @Binding var text: String
  @Binding var focused: Bool
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
    view.accessibilityLabel = "Message body"
    view.delegate = context.coordinator
    view.onPasteImages = onPasteImages
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateUIView(_ view: MobilePasteTextView, context: Context) {
    context.coordinator.parent = self
    view.onPasteImages = onPasteImages
    if view.markedTextRange == nil, view.text != text { view.text = text }
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
      parent.text = textView.text
    }
    func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
    func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
  }
}

final class MobilePasteTextView: UITextView {
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
    onPasteImages(files, problems)
  }
}
#endif
