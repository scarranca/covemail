import AppKit
import CoveCore
import Observation
import Quartz
import SwiftUI

final class AttachmentPreviewFile {
  static let maximumBytes = 25 * 1024 * 1024
  let url: URL
  private let directory: URL

  static func fileExtension(for attachment: MailAttachment) -> String? {
    let mime = attachment.mimeType.lowercased().split(separator: ";").first.map(String.init) ?? ""
    if mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(mime) { return "txt" }
    let types = ["application/pdf":"pdf", "image/png":"png", "image/jpeg":"jpg", "image/gif":"gif",
      "image/heic":"heic", "image/tiff":"tiff", "image/webp":"webp",
      "application/msword":"doc", "application/vnd.ms-excel":"xls", "application/vnd.ms-powerpoint":"ppt",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document":"docx",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":"xlsx",
      "application/vnd.openxmlformats-officedocument.presentationml.presentation":"pptx",
      "audio/mpeg":"mp3", "audio/mp4":"m4a", "audio/wav":"wav", "video/mp4":"mp4", "video/quicktime":"mov"]
    if let ext = types[mime] { return ext }
    guard mime.isEmpty || mime == "application/octet-stream" else { return nil }
    let ext = (attachment.filename as NSString).pathExtension.lowercased()
    if ["txt", "csv", "md", "log", "json", "xml"].contains(ext) { return "txt" }
    return Set(types.values).contains(ext) ? ext : nil
  }
  init(data: Data, attachment: MailAttachment) throws {
    guard data.count <= Self.maximumBytes else { throw CoveError.message("This file is too large to preview. Use Save to open it separately.") }
    guard let ext = Self.fileExtension(for: attachment) else { throw CoveError.message("Preview isn’t available for this file type. You can still save it.") }
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("Cove-Preview-" + UUID().uuidString, isDirectory: true)
    url = directory.appendingPathComponent("Preview." + ext)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Observable final class AttachmentPreviewState {
  private(set) var file: AttachmentPreviewFile?
  private(set) var loading = false
  private(set) var error: String?
  private var generation = UUID()
  func close() { generation = UUID(); file = nil; loading = false; error = nil }
  func load(_ attachment: MailAttachment, fetch: () async throws -> Data) async {
    close()
    let request = generation
    loading = true
    defer { if generation == request { loading = false } }
    do {
      guard AttachmentPreviewFile.fileExtension(for: attachment) != nil else {
        throw CoveError.message("Preview isn’t available for this file type. You can still save it.")
      }
      if let size = attachment.byteCount, size < 0 || size > AttachmentPreviewFile.maximumBytes {
        throw CoveError.message("This file is too large to preview. Use Save to open it separately.")
      }
      let data = try await fetch()
      try Task.checkCancellation()
      guard generation == request else { return }
      file = try AttachmentPreviewFile(data: data, attachment: attachment)
    } catch is CancellationError {
      if generation == request && !Task.isCancelled { error = "Preview was interrupted. Try again." }
    }
    catch { if generation == request { self.error = error.localizedDescription } }
  }
}

/// PDFKit and AppKit render common files directly; Quick Look handles other supported documents.
struct NativeAttachmentPreview: NSViewRepresentable {
  let file: AttachmentPreviewFile
  final class Coordinator { var file: AttachmentPreviewFile? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.setAccessibilityLabel("Attachment preview")
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    guard context.coordinator.file?.url != file.url else { return }
    for child in view.subviews { (child as? QLPreviewView)?.close(); child.removeFromSuperview() }
    context.coordinator.file = file
    let content: NSView
    if file.url.pathExtension == "pdf" {
      if let document = PDFDocument(url: file.url), document.pageCount > 0 {
        let scroll = NSScrollView(frame: view.bounds)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let pages = AttachmentPDFPages(document: document, width: scroll.contentSize.width)
        pages.autoresizingMask = [.width]
        scroll.documentView = pages
        content = scroll
      } else { content = unavailable() }
    } else if ["png", "jpg", "gif", "heic", "tiff", "webp"].contains(file.url.pathExtension) {
      if let image = NSImage(contentsOf: file.url) {
        let picture = NSImageView()
        picture.image = image; picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setAccessibilityLabel("Attachment image")
        content = picture
      } else { content = unavailable() }
    } else {
      let preview = QLPreviewView(frame: .zero, style: .normal)!
      preview.autostarts = false; preview.shouldCloseWithWindow = false
      preview.previewItem = file.url as NSURL
      content = preview
    }
    content.frame = view.bounds; content.autoresizingMask = [.width, .height]
    view.addSubview(content)
  }
  private func unavailable() -> NSView {
    let label = NSTextField(wrappingLabelWithString: "This file couldn’t be previewed. You can still save it.")
    label.font = .systemFont(ofSize: 12)
    return label
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    for child in view.subviews { (child as? QLPreviewView)?.close(); child.removeFromSuperview() }
    coordinator.file = nil
  }
}

/// Draw visible PDF pages directly: no form execution, external viewer, or remote preview service.
final class AttachmentPDFPages: NSView {
  let document: PDFDocument
  private var pages: [(PDFPage, NSRect)] = []
  override var isFlipped: Bool { true }
  init(document: PDFDocument, width: CGFloat) {
    self.document = document
    super.init(frame: .zero)
    setFrameSize(NSSize(width: width, height: 0))
    setAccessibilityRole(.image)
    setAccessibilityLabel("PDF preview, \(document.pageCount) pages")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func setFrameSize(_ size: NSSize) {
    let width = max(1, size.width - 24)
    var top: CGFloat = 12
    pages = (0..<document.pageCount).compactMap { index in
      guard let page = document.page(at: index) else { return nil }
      let bounds = page.bounds(for: .cropBox)
      guard bounds.width > 0, bounds.height > 0 else { return nil }
      let rect = NSRect(x: 12, y: top, width: width, height: width * bounds.height / bounds.width)
      top += rect.height + 12
      return (page, rect)
    }
    super.setFrameSize(NSSize(width: size.width, height: top))
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    for (page, rect) in pages where rect.intersects(dirtyRect) {
      NSColor.white.setFill(); rect.fill()
      let bounds = page.bounds(for: .cropBox)
      let scale = rect.width / bounds.width
      context.saveGState()
      context.translateBy(x: rect.minX, y: rect.maxY)
      context.scaleBy(x: scale, y: -scale)
      context.translateBy(x: -bounds.minX, y: -bounds.minY)
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
    }
  }
}

struct ReaderAttachments: View {
  let store: AppStore
  let mail: Mail
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(mail.availableAttachments.count == 1 ? "Attachment" : "Attachments").font(.coveControl)
      ForEach(mail.availableAttachments) { attachment in
        ReaderAttachment(store: store, mail: mail, attachment: attachment)
          .id(mail.id + ":" + attachment.id)
      }
    }
  }
}

struct ReaderAttachment: View {
  let store: AppStore
  let mail: Mail
  let attachment: MailAttachment
  @State private var preview = AttachmentPreviewState()
  @State private var expanded = false
  @State private var retry = 0
  init(store: AppStore, mail: Mail, attachment: MailAttachment, initiallyExpanded: Bool = false) {
    self.store = store; self.mail = mail; self.attachment = attachment
    _expanded = State(initialValue: initiallyExpanded)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { name; controls }
        VStack(alignment: .leading, spacing: 10) { name; controls }
      }
      if expanded {
        if preview.loading {
          HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading preview…").font(.coveSecondary) }
            .frame(maxWidth: .infinity, minHeight: 100)
        } else if let file = preview.file {
          NativeAttachmentPreview(file: file).frame(height: 420).clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let error = preview.error {
          Text(error).font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
          if AttachmentPreviewFile.fileExtension(for: attachment) != nil {
            Button("Try again") { retry += 1 }.buttonStyle(SecondaryButton(compact: true))
          }
        }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
      .task(id: "\(expanded):\(retry)") {
        guard expanded else { preview.close(); return }
        await preview.load(attachment) { try await store.readerAttachmentData(attachment, from: mail) }
      }
      .onDisappear { preview.close() }
  }
  private var name: some View {
    HStack(spacing: 10) {
      Image(systemName: "doc").foregroundStyle(Palette.body).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(attachment.filename).font(.coveLabel).lineLimit(2).textSelection(.enabled)
        if let count = attachment.byteCount, count >= 0 {
          Text(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file))
            .font(.coveMetadata).foregroundStyle(Palette.body)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var controls: some View {
    HStack(spacing: 8) {
      Button { expanded.toggle() } label: { Label(expanded ? "Close preview" : "Preview", systemImage: expanded ? "xmark" : "eye") }
        .buttonStyle(SecondaryButton(compact: true)).accessibilityLabel("\(expanded ? "Close preview of" : "Preview") \(attachment.filename)")
      Button { Task { await store.downloadAttachment(attachment, from: mail) } } label: { Label("Save", systemImage: "arrow.down.to.line") }
        .buttonStyle(SecondaryButton(compact: true)).disabled(store.busy).accessibilityLabel("Save \(attachment.filename)")
    }.fixedSize()
  }
}
