import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// A real mouse click on the Trash toast's Undo, in the full window with an HTML email open, the
/// Reply ▾ split button below it and the offline status line showing, restores the email.
@MainActor final class TrashUndoHitTests: XCTestCase {
  func testClickingUndoOnTheTrashToastRestoresTheEmail() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try Database(url: dir.appendingPathComponent("mail.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "test" }, syncClock: Date.init)
    store.isSample = true; store.screen = "mail"; store.folder = "Inbox"; store.priorityOnly = false; store.entered = true
    store.mails = (0..<4).map { index in
      Mail(id: "mail-\(index)", sender: "Maya Chen", senderEmail: "maya@example.com", to: "me@example.com, bob@example.com",
           subject: "Project update \(index)", body: "Everything is ready.", date: Date().addingTimeInterval(Double(-index * 60)), labels: ["INBOX"],
           htmlBody: "<html><body>" + String(repeating: "<p>Hello there, a long HTML email body line.</p>", count: 80) + "</body></html>",
           cc: "carol@example.com")
    }
    store.selectedID = "mail-0"
    store.connectionIssue = ConnectionIssue(offline: true, operation: "Syncing Gmail…")
    let host = NSHostingView(rootView: RootView(store: store))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    // Buttons only respond in an ordered window: transparent, far off-screen, the app never activated.
    window.alphaValue = 0
    window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
    window.orderFrontRegardless()
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    store.beginTriage([store.mails[0]], .trash)
    for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(store.canUndoTrash)
    // The toast's Undo at this size (located from a render of this layout).
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: 818, y: 800 - 753), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
      try await Task.sleep(for: .milliseconds(150))
    }
    let restored = !store.canUndoTrash
    if !restored { store.undoQueuedTrash() }
    XCTAssertTrue(restored, "the click must reach Undo")
    XCTAssertTrue(store.queuedTrashIDs.isEmpty)
    XCTAssertTrue(store.visible.contains { $0.id == "mail-0" })
  }
}
