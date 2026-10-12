import Foundation
import ImageIO
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Drafts keep stable image tokens beside encrypted attachment bytes. Native editors show each token
/// as one attachment character; selections are translated so scoped rewrites use the saved text.
public enum InlineImageText {
  public static let tokenKey = NSAttributedString.Key("CoveInlineImageToken")

  public static func serialized(_ text: NSAttributedString) -> String {
    guard text.string.contains("\u{fffc}") else { return text.string }
    let result = NSMutableString(string: text.string)
    var replacements: [(NSRange, String)] = []
    text.enumerateAttribute(tokenKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
      if let token = value as? String { replacements.append((range, token)) }
    }
    for (range, token) in replacements.reversed() { result.replaceCharacters(in: range, with: token) }
    return result as String
  }

  public static func modelRange(_ range: NSRange, in text: NSAttributedString) -> NSRange {
    let start = min(range.location, text.length)
    let end = min(NSMaxRange(range), text.length)
    let prefix = serialized(text.attributedSubstring(from: NSRange(location: 0, length: start)))
    let selected = serialized(text.attributedSubstring(from: NSRange(location: start, length: end - start)))
    return NSRange(location: (prefix as NSString).length, length: (selected as NSString).length)
  }

  public static func nativeRange(_ range: NSRange, in text: NSAttributedString) -> NSRange {
    func offset(_ model: Int) -> Int {
      var extra = 0
      var found: Int?
      text.enumerateAttribute(tokenKey, in: NSRange(location: 0, length: text.length)) { value, part, stop in
        guard let token = value as? String else { return }
        let start = part.location + extra
        let length = (token as NSString).length
        if model > start && model < start + length { found = part.location; stop.pointee = true }
        else if model >= start + length { extra += length - part.length }
      }
      return min(text.length, max(0, found ?? (model - extra)))
    }
    let start = offset(range.location)
    return NSRange(location: start, length: max(0, offset(NSMaxRange(range)) - start))
  }

  @MainActor public static func rendered(_ body: String, files: [OutgoingAttachment], attributes: [NSAttributedString.Key: Any], width: CGFloat) -> NSAttributedString {
    let result = NSMutableAttributedString(string: body, attributes: attributes)
    for file in files where file.inline == true {
      var search = NSRange(location: 0, length: result.length)
      while search.length > 0 {
        let range = (result.string as NSString).range(of: file.bodyToken, range: search)
        guard range.location != NSNotFound else { break }
        let attachment = NSTextAttachment()
        let source = CGImageSourceCreateWithData(file.data as CFData, nil)
        let thumbnail = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 640,
        ] as CFDictionary) }
        #if os(macOS)
        if let thumbnail {
          let image = NSImage(cgImage: thumbnail, size: .zero)
          let scale = min(1, max(40, width) / max(1, image.size.width), 320 / max(1, image.size.height))
          image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
          attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        }
        #else
        if let thumbnail {
          let image = UIImage(cgImage: thumbnail)
          let scale = min(1, max(40, width) / max(1, image.size.width), 320 / max(1, image.size.height))
          attachment.image = image
          attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        }
        #endif
        let imageText = NSMutableAttributedString(attachment: attachment)
        imageText.addAttributes(attributes, range: NSRange(location: 0, length: 1))
        imageText.addAttribute(tokenKey, value: file.bodyToken, range: NSRange(location: 0, length: 1))
        result.replaceCharacters(in: range, with: imageText)
        search = NSRange(location: range.location + 1, length: result.length - range.location - 1)
      }
    }
    return result
  }
}
