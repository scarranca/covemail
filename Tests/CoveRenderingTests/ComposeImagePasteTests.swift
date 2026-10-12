import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class ComposeImagePasteTests: XCTestCase {
  private func pixels(_ type: NSBitmapImageRep.FileType = .png) throws -> Data {
    let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    image.setColor(.systemBlue, atX: 0, y: 0)
    return try XCTUnwrap(image.representation(using: type, properties: [:]))
  }

  func testPasteAddsOneImageWithoutReplacingSelectedTextAndConvertsTIFF() throws {
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
    XCTAssertEqual(editor.string, "Keep my draft")
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 4))
    let converted = try PastedImage.attachment(data: pixels(.tiff))
    XCTAssertEqual(converted.mimeType, "image/png")
    XCTAssertNotNil(NSImage(data: converted.data))
    for type in [NSBitmapImageRep.FileType.jpeg, .gif] {
      let original = try pixels(type)
      XCTAssertEqual(try PastedImage.attachment(data: original).data, original)
    }
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

  func testComposerPasteReachesDraftAttachmentStoreAndRendersChip() async throws {
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
    native.imagePasteboard = board
    native.paste(nil)
    XCTAssertEqual(store.attachments(for: target).count, 1)
    XCTAssertEqual(try db.load([OutgoingAttachment].self, key: "attachments.\(target)")?.count, 1)
    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
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
