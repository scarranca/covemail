import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class ComposeImagePasteTests: XCTestCase {
  private func pixels(_ type: NSBitmapImageRep.FileType = .png, width: Int = 8, height: Int = 8) throws -> Data {
    let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<width { for y in 0..<height { image.setColor(NSColor(deviceRed: 0.1, green: 0.45, blue: 0.8, alpha: 1), atX: x, y: y) } }
    return try XCTUnwrap(image.representation(using: type, properties: [:]))
  }

  func testPasteInsertsAtSelectionAndConvertsTIFF() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let item = NSPasteboardItem()
    let png = try pixels()
    item.setData(png, forType: .png)
    item.setData(try pixels(.tiff), forType: .tiff)
    board.writeObjects([item])
    let editor = ComposePasteTextView(usingTextLayoutManager: false)
    editor.imagePasteboard = board
    editor.string = "Keep my draft"
    editor.setSelectedRange(NSRange(location: 0, length: 4))
    var files: [OutgoingAttachment] = []
    editor.onPasteImages = { added, errors in files += added; XCTAssertTrue(errors.isEmpty) }
    editor.paste(nil)
    XCTAssertEqual(files.count, 1, "PNG and TIFF are representations of the same image")
    XCTAssertEqual(files.first?.data, png)
    XCTAssertEqual(editor.string, "\u{fffc} my draft")
    XCTAssertEqual(editor.bodyText, try XCTUnwrap(files.first).bodyToken + " my draft")
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertNotNil(editor.attributedString().attribute(.attachment, at: 0, effectiveRange: nil))
    let converted = try PastedImage.attachment(data: pixels(.tiff))
    XCTAssertEqual(converted.mimeType, "image/png")
    XCTAssertNotNil(NSImage(data: converted.data))
    for type in [NSBitmapImageRep.FileType.jpeg, .gif] {
      let original = try pixels(type)
      XCTAssertEqual(try PastedImage.attachment(data: original).data, original)
    }
  }

  func testInlineSelectionUndoAndReopen() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let editor = ComposePasteTextView(usingTextLayoutManager: false)
    editor.isRichText = true
    editor.allowsUndo = true
    editor.plainAttributes = [.font: NSFont.systemFont(ofSize: 14)]
    editor.onPasteImages = { _, _ in }
    window.contentView = editor
    editor.string = "👋 Before After"
    let start = ("👋 Before " as NSString).length
    editor.setSelectedRange(NSRange(location: start, length: 0))
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.setData(try pixels(), forType: .png)
    let undo = try XCTUnwrap(editor.undoManager)
    undo.beginUndoGrouping()
    editor.pasteImages(from: board)
    undo.endUndoGrouping()
    let body = editor.bodyText
    let file = try XCTUnwrap(editor.inlineFiles.first)
    XCTAssertEqual(body, "👋 Before " + file.bodyToken + "After")
    let caret = InlineImageText.modelRange(editor.selectedRange(), in: editor.attributedString())
    XCTAssertEqual(caret.location, start + (file.bodyToken as NSString).length)
    XCTAssertEqual(InlineImageText.nativeRange(caret, in: editor.attributedString()), editor.selectedRange())
    undo.undo()
    XCTAssertEqual(editor.bodyText, "👋 Before After")
    undo.redo()
    XCTAssertEqual(editor.bodyText, body)
    undo.beginUndoGrouping()
    editor.deleteBackward(nil)
    undo.endUndoGrouping()
    XCTAssertEqual(editor.bodyText, "👋 Before After")
    undo.undo()
    XCTAssertEqual(editor.bodyText, body)
    let reopened = ComposePasteTextView(usingTextLayoutManager: false)
    reopened.inlineFiles = try JSONDecoder().decode([OutgoingAttachment].self, from: JSONEncoder().encode(editor.inlineFiles))
    reopened.showBody(body)
    XCTAssertEqual(reopened.bodyText, body)
    XCTAssertEqual(reopened.string, "👋 Before \u{fffc}After")
    XCTAssertNotNil(reopened.attributedString().attribute(.attachment, at: start, effectiveRange: nil))
  }

  func testTextPasteStaysNativeAndReadOnlyEditorDoesNotAttach() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.setString("Hola 👋", forType: .string)
    let editor = ComposePasteTextView(usingTextLayoutManager: false)
    editor.isRichText = false
    editor.onPasteImages = { _, _ in XCTFail("Text must not become an attachment") }
    XCTAssertFalse(editor.pasteImages(from: board))
    XCTAssertTrue(editor.readSelection(from: board, type: .string))
    XCTAssertEqual(editor.string, "Hola 👋")
    board.clearContents(); board.setData(try pixels(), forType: .png)
    editor.isEditable = false
    XCTAssertFalse(editor.pasteImages(from: board))
  }

  func testCopiedImageFileUsesOriginalInsteadOfThumbnailAndErrorsAreVisible() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    let png = try pixels(); try png.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setString(url.absoluteString, forType: .fileURL)
    item.setData(try pixels(.tiff), forType: .tiff)
    board.writeObjects([item])
    let editor = ComposePasteTextView(usingTextLayoutManager: false)
    var files: [OutgoingAttachment] = [], errors: [String] = []
    editor.onPasteImages = { files = $0; errors = $1 }
    XCTAssertTrue(editor.pasteImages(from: board))
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files.first?.filename, url.lastPathComponent)
    XCTAssertEqual(files.first?.data, png)
    board.clearContents(); board.setData(Data("broken".utf8), forType: .png)
    XCTAssertTrue(editor.pasteImages(from: board))
    XCTAssertTrue(files.isEmpty)
    XCTAssertFalse(errors.isEmpty)
    XCTAssertThrowsError(try PastedImage.attachment(data: Data(count: OutgoingAttachment.totalLimit + 1)))
  }

  func testReplyPasteIsSavedOnItsOwnMessage() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("mail.sqlite"), encryptionKey: Data(repeating: 4, count: 32), namespace: "inline-reply")
    let store = try AppStore(database: db, accountEmail: "alex@example.com", gmail: GmailClient(transport: PasteFixtureHTTP()), gmailTokenProvider: { "synthetic" }, syncClock: { Date() })
    store.isSample = true
    var mail = Mail(id: "inline-reply", sender: "Ana", senderEmail: "ana@example.com", subject: "Review", body: "What do you think?", date: Date())
    mail.draft = "Before After"
    store.mails = [mail]
    let host = NSHostingView(rootView: ReaderView(store: store, mail: mail))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    func find(_ view: NSView) -> ComposePasteTextView? {
      if let editor = view as? ComposePasteTextView { return editor }
      return view.subviews.compactMap(find).first
    }
    let editor = try XCTUnwrap(find(host))
    editor.setSelectedRange(NSRange(location: 7, length: 0))
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.setData(try pixels(), forType: .png)
    editor.pasteImages(from: board)
    try await Task.sleep(for: .milliseconds(800))
    let target = AttachmentTarget.reply(mail.id)
    XCTAssertEqual(store.attachments(for: target).count, 1)
    XCTAssertEqual(store.mails.first?.draft, editor.bodyText)
    XCTAssertTrue(editor.bodyText.hasPrefix("Before ![image]"))
    XCTAssertTrue(editor.bodyText.hasSuffix("After"))
    XCTAssertEqual(try db.load([OutgoingAttachment].self, key: "attachments.\(target)")?.first?.inline, true)
  }

  func testComposerPastePersistsAndRendersInline() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("mail.sqlite"), encryptionKey: Data(repeating: 4, count: 32), namespace: "paste-fixture")
    let store = try AppStore(database: db, accountEmail: "alex@example.com", gmail: GmailClient(transport: PasteFixtureHTTP()),
      gmailTokenProvider: { "synthetic" }, syncClock: { Date() })
    store.newDraft(present: false)
    let target = AttachmentTarget.draft(try XCTUnwrap(store.composeID))
    let host = NSHostingView(rootView: ComposerView(store: store, availableSize: CGSize(width: 1100, height: 820)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1036, height: 756), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    func editor(in view: NSView) -> ComposePasteTextView? {
      if let match = view as? ComposePasteTextView { return match }
      return view.subviews.compactMap { editor(in: $0) }.first
    }
    let native = try XCTUnwrap(editor(in: host))
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.setData(try pixels(), forType: .png)
    board.clearContents(); board.setData(try pixels(width: 400, height: 180), forType: .png)
    native.imagePasteboard = board
    native.insertText("Before\nAfter", replacementRange: NSRange(location: 0, length: 0))
    native.setSelectedRange(NSRange(location: 7, length: 0))
    native.paste(nil)
    XCTAssertTrue(native.bodyText.hasPrefix("Before\n![image]"))
    XCTAssertTrue(native.bodyText.hasSuffix("After"))
    XCTAssertEqual(store.attachments(for: target).count, 1)
    XCTAssertEqual(try db.load([OutgoingAttachment].self, key: "attachments.\(target)")?.count, 1)
    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    try await Task.sleep(for: .milliseconds(700))
    let savedBody = try XCTUnwrap(store.mails.first { $0.id == store.composeID }).body
    XCTAssertEqual(savedBody, native.bodyText)
    let reopened = ComposePasteTextView(usingTextLayoutManager: false)
    reopened.inlineFiles = try XCTUnwrap(db.load([OutgoingAttachment].self, key: "attachments.\(target)"))
    reopened.showBody(savedBody)
    XCTAssertEqual(reopened.string, "Before\n\u{fffc}After")
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-pasted-image.png"))
  }
}

private struct PasteFixtureHTTP: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (Data(#"{"sendAs":[{"sendAsEmail":"alex@example.com","isPrimary":true}]}"#.utf8),
     HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
