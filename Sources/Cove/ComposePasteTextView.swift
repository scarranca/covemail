import AppKit
import CoveCore
import UniformTypeIdentifiers

/// Keep native plain-text editing, intercepting only an explicit image paste.
final class ComposePasteTextView: NSTextView {
  var onPasteImages: (([OutgoingAttachment], [String]) -> Void)?
  var inlineFiles: [OutgoingAttachment] = []
  var plainAttributes: [NSAttributedString.Key: Any] = [:]
  var bodyText: String { InlineImageText.serialized(attributedString()) }

  func showBody(_ body: String) {
    textStorage?.setAttributedString(InlineImageText.rendered(body, files: inlineFiles,
      attributes: plainAttributes, width: max(180, bounds.width - textContainerInset.width * 2)))
    typingAttributes = plainAttributes
  }

  // Injectable so tests never read or overwrite the user's clipboard.
  var imagePasteboard: NSPasteboard = .general

  private static let imageTypes: [NSPasteboard.PasteboardType] = [.png,
    NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier),
    .tiff, NSPasteboard.PasteboardType(UTType.heic.identifier)]

  override func paste(_ sender: Any?) {
    guard !pasteImages(from: imagePasteboard) else { return }
    pasteAsPlainText(sender)
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(paste(_:)), isEditable, onPasteImages != nil,
       imagePasteboard.pasteboardItems?.contains(where: { item in
         if item.availableType(from: Self.imageTypes) != nil { return true }
         guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else { return false }
         return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
       }) == true { return true }
    return super.validateUserInterfaceItem(item)
  }

  @discardableResult
  func pasteImages(from pasteboard: NSPasteboard) -> Bool {
    guard isEditable, let onPasteImages else { return false }
    var files: [OutgoingAttachment] = []
    var problems: [String] = []
    var handled = false
    for item in pasteboard.pasteboardItems ?? [] {
      // Finder can provide both the file and a thumbnail. Attach the original only once.
      if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL,
         UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
        handled = true
        do { files.append(try PastedImage.attachment(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)) }
        catch { problems.append(error.localizedDescription) }
      } else if let type = item.availableType(from: Self.imageTypes) {
        handled = true
        do {
          guard let data = item.data(forType: type) else { throw CoveError.message("Cove couldn’t read the copied image.") }
          files.append(try PastedImage.attachment(data: data, name: "Pasted image \(files.count + 1)"))
        } catch { problems.append(error.localizedDescription) }
      }
    }
    if handled {
      files = files.map { var file = $0; file.inline = true; return file }
      let result = OutgoingAttachment.adding(files, to: inlineFiles)
      let accepted = result.files.filter { file in files.contains { $0.id == file.id } }
      if let problem = result.problem { problems.append(problem) }
      onPasteImages(accepted, problems)
      inlineFiles = result.files
      if !accepted.isEmpty {
        let value = InlineImageText.rendered(accepted.map(\.bodyToken).joined(), files: accepted,
          attributes: plainAttributes, width: max(180, bounds.width - textContainerInset.width * 2))
        insertText(value, replacementRange: selectedRange())
        typingAttributes = plainAttributes
      }
    }
    return handled
  }
}
