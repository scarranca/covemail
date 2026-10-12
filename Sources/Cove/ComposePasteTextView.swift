import AppKit
import CoveCore
import UniformTypeIdentifiers

/// Keep native plain-text editing, intercepting only an explicit image paste.
final class ComposePasteTextView: NSTextView {
  var onPasteImages: (([OutgoingAttachment], [String]) -> Void)?
  // Injectable so tests never read or overwrite the user's clipboard.
  var imagePasteboard: NSPasteboard = .general

  private static let imageTypes: [NSPasteboard.PasteboardType] = [.png,
    NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier),
    .tiff, NSPasteboard.PasteboardType(UTType.heic.identifier)]

  override func paste(_ sender: Any?) {
    guard !pasteImages(from: imagePasteboard) else { return }
    super.paste(sender)
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
        do { files.append(try OutgoingAttachment(contentsOf: url)) }
        catch { problems.append(error.localizedDescription) }
      } else if let type = item.availableType(from: Self.imageTypes) {
        handled = true
        do {
          guard let data = item.data(forType: type) else { throw CoveError.message("Cove couldn’t read the copied image.") }
          files.append(try PastedImage.attachment(data: data, name: "Pasted image \(files.count + 1)"))
        } catch { problems.append(error.localizedDescription) }
      }
    }
    if handled { onPasteImages(files, problems) }
    return handled
  }
}
