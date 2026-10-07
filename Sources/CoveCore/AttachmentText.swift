import Foundation
import PDFKit

/// Readable text from an email's attachments, for agents and Ask Cove on Mac, iPhone and iPad: PDFs
/// (also `.pdf` files Gmail labels application/octet-stream) and plain text; the first five files,
/// 5 MB each, 20 PDF pages. Images and scans have no text layer; they become warnings, never guesses.
public enum AttachmentText {
  public static let maxFiles = 5
  public static let maxBytes = 5_000_000
  public static let maxPages = 20

  public static func isPDF(_ attachment: MailAttachment) -> Bool {
    attachment.mimeType.lowercased() == "application/pdf" || attachment.filename.lowercased().hasSuffix(".pdf")
  }
  public static func readable(_ attachment: MailAttachment) -> Bool {
    isPDF(attachment) || attachment.mimeType.lowercased().hasPrefix("text/")
  }

  /// `fetch` returns the file's bytes, or nil when there are none to read (a sample without data).
  public static func read(_ mail: Mail, fetch: (MailAttachment) async throws -> Data?) async throws
    -> ([AgentAttachmentText], [String])
  {
    var texts: [AgentAttachmentText] = []
    var warnings: [String] = []
    let attachments = mail.availableAttachments
    if attachments.count > maxFiles { warnings.append("Only the first five attachments were inspected.") }
    for attachment in attachments.prefix(maxFiles) {
      try Task.checkCancellation()
      guard readable(attachment) else {
        warnings.append("\(attachment.filename): this file type needs manual review."); continue
      }
      guard let size = attachment.byteCount, size <= maxBytes, size >= 0 else {
        warnings.append("\(attachment.filename): file is too large or its size is unknown."); continue
      }
      let data: Data
      if let embedded = attachment.data, let decoded = Data(base64URL: embedded) { data = decoded }
      else if let fetched = try await fetch(attachment) { data = fetched }
      else { warnings.append("\(attachment.filename): sample attachment is not available."); continue }
      guard data.count <= maxBytes else { warnings.append("\(attachment.filename): file is too large."); continue }
      let text: String
      if isPDF(attachment) {
        guard let document = PDFDocument(data: data), !document.isLocked else {
          warnings.append("\(attachment.filename): PDF could not be read."); continue
        }
        if document.pageCount > maxPages { warnings.append("\(attachment.filename): only the first 20 pages were inspected.") }
        let pages = (0..<min(document.pageCount, maxPages)).map { document.page(at: $0)?.string ?? "" }
        if pages.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
          warnings.append("\(attachment.filename): some pages have no readable text.")
        }
        text = pages.joined(separator: "\n")
      } else {
        text = String(data: data, encoding: .utf8) ?? ""
      }
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        warnings.append("\(attachment.filename): no readable text; scanned images need manual review.")
      } else {
        texts.append(AgentAttachmentText(name: attachment.filename, text: text))
      }
    }
    return (texts, warnings)
  }
}
