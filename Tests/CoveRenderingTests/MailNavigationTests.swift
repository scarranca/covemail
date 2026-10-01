import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class MailNavigationTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
  private func fixture() throws -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(dir)
    let db = try Database(url: dir.appendingPathComponent("mail.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "test" }, syncClock: Date.init)
    store.isSample = true; store.screen = "mail"; store.folder = "Inbox"; store.priorityOnly = false
    store.mails = (0..<4).map { index in
      Mail(id: "mail-\(index)", sender: "Maya Chen", senderEmail: "maya@example.com", subject: "Project update \(index)", body: "Everything is ready for Thursday. Can you review the final designs?", date: Date().addingTimeInterval(Double(-index * 60)), labels: index % 2 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"])
    }
    store.selectedID = nil
    return store
  }
  private func event(_ code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  private func letter(_ text: String, code: UInt16, window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
  }
  func testUTogglesReadEArchivesThenOpensTheNextAndRReplies() async throws {
    _ = NSApplication.shared
    let store = try fixture()
    let view = MailNavigationShortcut.ShortcutView(store: store)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    defer { window.close() }
    let u = try letter("u", code: 32, window: window), e = try letter("e", code: 14, window: window)
    let r = try letter("r", code: 15, window: window)
    XCTAssertNotNil(view.handle(u), "nothing selected: U passes through")
    store.selectedID = "mail-0"
    XCTAssertNil(view.handle(u))
    for _ in 0..<20 where store.mails[0].isUnread { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(store.mails.first { $0.id == "mail-0" }!.isUnread, "U marks it read")
    XCTAssertNil(view.handle(r))
    XCTAssertEqual(store.replyRequestID, "mail-0", "R asks the open email for a reply")
    XCTAssertEqual(store.selectedID, "mail-0")
    store.replyRequestID = nil
    XCTAssertNil(view.handle(e))
    XCTAssertEqual(store.selectedID, "mail-1", "E moves straight to the next email")
    for _ in 0..<20 where store.mails[0].labels.contains("INBOX") { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(store.mails.first { $0.id == "mail-0" }!.labels.contains("INBOX"), "E archives")
    let editor = NSTextView(frame: view.bounds)
    view.addSubview(editor); window.makeFirstResponder(editor)
    XCTAssertNotNil(view.handle(r), "typing an r is just typing")
    XCTAssertNotNil(view.handle(e))
  }
  func testNavigationFromReaderRespectsOrderBoundsAndReturnToList() throws {
    _ = NSApplication.shared
    let store = try fixture()
    var returned = 0
    let view = MailNavigationShortcut.ShortcutView(store: store, onReturnToList: { returned += 1 })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    defer { window.close() }
    let down = try event(125, window: window); let up = try event(126, window: window)
    XCTAssertNil(view.handle(down)); XCTAssertEqual(store.selectedID, "mail-0")
    XCTAssertNil(view.handle(down)); XCTAssertEqual(store.selectedID, "mail-1")
    XCTAssertNil(view.handle(up)); XCTAssertEqual(store.selectedID, "mail-0")
    XCTAssertNil(view.handle(up)); XCTAssertEqual(store.selectedID, "mail-0")
    store.busy = true // Polling does not block navigating downloaded messages.
    XCTAssertNil(view.handle(down)); XCTAssertEqual(store.selectedID, "mail-1")
    XCTAssertNil(view.handle(try event(53, window: window))); XCTAssertNil(store.selectedID)
    XCTAssertEqual(returned, 1)
    XCTAssertNotNil(view.handle(try event(53, window: window)))
    XCTAssertNil(view.handle(up)); XCTAssertEqual(store.selectedID, "mail-3")
    XCTAssertNil(view.handle(down)); XCTAssertEqual(store.selectedID, "mail-3")
    XCTAssertNil(view.handle(try event(123, window: window))); XCTAssertNil(store.selectedID)
    XCTAssertEqual(returned, 2)
  }
  func testTypingSheetsOtherScreensAndModifiedKeysKeepNativeHandling() throws {
    _ = NSApplication.shared
    let store = try fixture()
    let view = MailNavigationShortcut.ShortcutView(store: store)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    defer { window.close() }
    let down = try event(125, window: window)
    let editor = NSTextView(frame: view.bounds)
    view.addSubview(editor); window.makeFirstResponder(editor)
    XCTAssertNotNil(view.handle(down)); XCTAssertNil(store.selectedID)
    editor.isEditable = false // Selectable email content is a native text view too.
    XCTAssertNil(view.handle(down)); XCTAssertEqual(store.selectedID, "mail-0")
    store.selectedID = nil
    window.makeFirstResponder(nil)
    for flags in [NSEvent.ModifierFlags.command, .option, .shift, .control] {
      XCTAssertNotNil(view.handle(try event(125, window: window, modifiers: flags)))
    }
    for screen in ["home", "calendar", "agents", "integrations"] {
      store.screen = screen; XCTAssertNotNil(view.handle(down))
    }
    store.screen = "mail"
    store.showComposer = true; XCTAssertNotNil(view.handle(down)); store.showComposer = false
    store.showAssistant = true; XCTAssertNotNil(view.handle(down)); store.showAssistant = false
    store.showConnections = true; XCTAssertNotNil(view.handle(down)); store.showConnections = false
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    window.beginSheet(sheet)
    XCTAssertNotNil(view.handle(down)); window.endSheet(sheet); sheet.close()
    XCTAssertNil(store.selectedID)
  }
  func testFilteredAndRemovedMessagesAreNotNavigationTargets() throws {
    _ = NSApplication.shared
    let store = try fixture()
    store.search = "update 2"
    store.moveSelection(by: 1); XCTAssertEqual(store.selectedID, "mail-2")
    store.moveSelection(by: -1); XCTAssertEqual(store.selectedID, "mail-2")
    store.queueTrash(store.mails[2], delay: 600)
    defer { store.undoQueuedTrash() }
    XCTAssertTrue(store.visible.isEmpty)
    store.moveSelection(by: 1); XCTAssertNil(store.selectedID)
  }
  func testInboxAndRowStatesRender() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let store = try fixture()
    for width in [900.0, 1200.0] {
      let host = NSHostingView(rootView: MailboxView(store: store).foregroundStyle(Palette.ink))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 880), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-mail-\(Int(width)).png"))
      window.close()
    }
    store.selectedID = store.mails[0].id
    let rows = VStack(spacing: 1) {
      MailListRow(store: store, mail: store.mails[0])
      MailRow(mail: store.mails[1], selected: false)
      MailRow(mail: store.mails[2], selected: false, hovered: true)
      MailRow(mail: store.mails[3], selected: false)
    }.frame(width: 392).background(Palette.line)
    let renderer = ImageRenderer(content: rows); renderer.scale = 2
    let image = try XCTUnwrap(renderer.nsImage)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-mail-row-states.png"))
  }
}
