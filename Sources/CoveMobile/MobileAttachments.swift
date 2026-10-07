#if os(iOS)
import CoveCore
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Received attachments on iPhone and iPad, like the Mac's Attachment Preview: explicit and local.
/// Tap previews with Quick Look; the arrow saves to Files. Bytes come from Gmail only on that tap,
/// into a private temporary folder that is removed when the preview or export closes.
extension MobileMailbox {
  /// Gmail's limit, also the Mac's: known larger files are refused before downloading.
  static let attachmentLimit = 25 * 1024 * 1024

  func attachmentFile(_ attachment: MailAttachment, in mail: Mail) async throws -> URL {
    if let size = attachment.byteCount, size > Self.attachmentLimit {
      throw CoveError.message("“\(attachment.filename)” is larger than 25 MB. Open it in Gmail.")
    }
    let data: Data
    if auth.isSample {
      guard let embedded = attachment.data, let decoded = Data(base64URL: embedded) else {
        throw CoveError.message("This sample attachment has no file.")
      }
      data = decoded
    } else {
      data = try await GmailClient().attachmentData(messageID: mail.id, attachment: attachment, token: try await auth.token())
    }
    guard data.count <= Self.attachmentLimit else { throw CoveError.message("“\(attachment.filename)” is larger than 25 MB.") }
    return try MobileAttachmentFiles.write(data, named: attachment.filename, mimeType: attachment.mimeType)
  }
}

enum MobileAttachmentFiles {
  static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("CoveAttachments", isDirectory: true) }

  /// One private folder per file; HTML is shown as its source (never rendered), as on the Mac.
  static func write(_ data: Data, named name: String, mimeType: String) throws -> URL {
    var filename = name.precomposedStringWithCanonicalMapping
      .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if filename.isEmpty || filename.hasPrefix(".") { filename = "attachment" + filename }
    let ext = (filename as NSString).pathExtension.lowercased()
    if mimeType.lowercased().hasPrefix("text/html") || ["html", "htm", "xhtml", "svg"].contains(ext) { filename += ".txt" }
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.complete])
    let url = folder.appendingPathComponent(String(filename.prefix(180)))
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    return url
  }

  static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  /// Leftovers from a crash or force-quit, cleared when Cove starts.
  static func removeAll() { try? FileManager.default.removeItem(at: root) }
}

struct MobileAttachmentList: View {
  let mailbox: MobileMailbox
  let mail: Mail
  @State private var loading: String?
  @State private var error: String?
  @State private var preview: AttachmentFile?
  @State private var export: AttachmentFile?

  struct AttachmentFile: Identifiable { let id = UUID(); let url: URL }

  var body: some View {
    if !mail.availableAttachments.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(mail.availableAttachments) { attachment in
          HStack(spacing: 10) {
            Button { open(attachment, save: false) } label: {
              HStack(spacing: 10) {
                Group {
                  if loading == attachment.id { ProgressView() }
                  else { Image(systemName: icon(attachment)).font(.system(size: 15)).foregroundStyle(MobilePalette.body) }
                }
                .frame(width: 34, height: 34).background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                  Text(attachment.filename).font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1).truncationMode(.middle)
                  if let size = attachment.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                      .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
                  }
                }
                Spacer(minLength: 8)
              }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Preview \(attachment.filename)")
            Button { open(attachment, save: true) } label: {
              Image(systemName: "arrow.down.circle").font(.system(size: 20)).foregroundStyle(MobilePalette.body)
                .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Save \(attachment.filename) to Files")
          }
          .disabled(loading != nil)
        }
        if let error {
          Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).fixedSize(horizontal: false, vertical: true)
        }
      }
      .task {
        #if DEBUG
        // Screenshot check: `-CovePreviewAttachment` previews the first file.
        if ProcessInfo.processInfo.arguments.contains("-CovePreviewAttachment"), let first = mail.availableAttachments.first {
          open(first, save: false)
        }
        #endif
      }
      .sheet(item: $preview, onDismiss: cleanUp) { file in
        MobileQuickLook(url: file.url).ignoresSafeArea()
      }
      .sheet(item: $export, onDismiss: cleanUp) { file in
        MobileSaveToFiles(url: file.url).ignoresSafeArea()
      }
    }
  }

  /// The downloaded copy on screen; removed when its preview or export closes.
  @State private var current: URL?
  private func cleanUp() {
    if let current { MobileAttachmentFiles.remove(current) }
    current = nil
  }

  private func open(_ attachment: MailAttachment, save: Bool) {
    error = nil
    loading = attachment.id
    Task {
      defer { loading = nil }
      do {
        let url = try await mailbox.attachmentFile(attachment, in: mail)
        current = url
        if save { export = AttachmentFile(url: url) } else { preview = AttachmentFile(url: url) }
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  private func icon(_ attachment: MailAttachment) -> String {
    let type = attachment.mimeType.lowercased()
    if type.hasPrefix("image/") { return "photo" }
    if type.hasPrefix("video/") { return "video" }
    if type == "application/pdf" { return "doc.richtext" }
    return "doc"
  }
}

/// Quick Look with its own Done and share buttons (share → Save to Files, Print, AirDrop).
struct MobileQuickLook: UIViewControllerRepresentable {
  let url: URL
  func makeCoordinator() -> Coordinator { Coordinator(url: url) }
  func makeUIViewController(context: Context) -> UINavigationController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    controller.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
      controller.dismiss(animated: true)
    })
    return UINavigationController(rootViewController: controller)
  }
  func updateUIViewController(_ controller: UINavigationController, context: Context) {}

  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
  }
}

/// The system "Save to Files" picker, saving a copy.
struct MobileSaveToFiles: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    UIDocumentPickerViewController(forExporting: [url], asCopy: true)
  }
  func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
#endif
