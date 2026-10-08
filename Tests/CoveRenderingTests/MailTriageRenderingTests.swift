import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// The inbox-zero UI: snooze chooser, chosen rows with the selection bar, the Undo toast, the empty
/// Important tab's Archive-all button and the shortcut sheet. Renders go to /tmp/cove-triage-*.png.
@MainActor final class MailTriageRenderingTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

  private func fixture(bulk: Bool = false) throws -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(dir)
    let db = try Database(url: dir.appendingPathComponent("mail.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "test" }, syncClock: Date.init)
    store.isSample = true; store.entered = true; store.screen = "mail"; store.folder = "Inbox"; store.priorityOnly = false
    store.mails = (0..<6).map { index in
      var mail = Mail(id: "mail-\(index)", sender: ["Maya Chen", "Acme News", "Jordan Lee"][index % 3], senderEmail: "s\(index)@example.com",
        subject: "Project update \(index)", body: "Everything is ready for Thursday. Can you review the final designs?",
        date: Date().addingTimeInterval(Double(-index * 3600)), labels: index % 2 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"])
      if bulk { mail.isBulkOrAutomated = true }
      return mail
    }
    store.selectedID = nil
    return store
  }

  private func png<V: View>(_ view: V, size: CGSize, name: String) async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let host = NSHostingView(rootView: view.font(.coveBody).foregroundStyle(Palette.ink).background(Palette.canvas))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-triage-\(name).png"))
  }

  // A popover can't render headless, so capture the content it shows.
  func testSnoozeChooserRenders() async throws {
    try await png(SnoozeChooser(detail: "Saved on this Mac", snoozed: true) { _ in }, size: CGSize(width: 310, height: 330), name: "snooze-chooser")
    try await png(SnoozeChooser(detail: nil, snoozed: false, startsPicking: true) { _ in }, size: CGSize(width: 292, height: 400), name: "snooze-picker")
  }

  func testChosenRowsSelectionBarAndUndoToastRender() async throws {
    let store = try fixture()
    store.selectedIDs = ["mail-0", "mail-2"]
    store.triageUndo = TriageUndo(message: "Archived 2 emails", reselect: nil, restore: {})
    try await png(MailboxView(store: store), size: CGSize(width: 1000, height: 640), name: "list-selection")
    XCTAssertEqual(store.triageTargets(for: nil).map(\.id).sorted(), ["mail-0", "mail-2"])
    // Narrow list: the bar falls back to icons.
    try await png(MailboxView(store: store), size: CGSize(width: 760, height: 640), name: "list-selection-narrow")
  }

  func testToastUndoRunsRestoreAndClears() async throws {
    let store = try fixture()
    var restored = false
    store.triageUndo = TriageUndo(message: "Snoozed until Tomorrow 9:00 AM", reselect: nil, restore: { restored = true })
    try await png(TriageUndoToast(store: store).padding(20).frame(width: 392).background(Palette.surface), size: CGSize(width: 392, height: 80), name: "toast")
    await store.undoLastTriage()
    XCTAssertTrue(restored)
    XCTAssertNil(store.triageUndo)
  }

  func testEmptyImportantOffersToArchiveOther() async throws {
    let store = try fixture(bulk: true)
    XCTAssertTrue(store.visible.isEmpty, "all six emails are automated, so Important is empty")
    XCTAssertEqual(store.inboxMails(in: .other).count, 6)
    try await png(MailboxView(store: store), size: CGSize(width: 1000, height: 640), name: "empty-important")
    store.mails = []
    try await png(MailboxView(store: store), size: CGSize(width: 1000, height: 640), name: "empty-important-clear")
  }

  func testShortcutSheetRenders() async throws {
    try await png(ShortcutHelpView {}, size: CGSize(width: 560, height: 720), name: "shortcuts")
    try await png(UnselectedMailView(store: try fixture()), size: CGSize(width: 640, height: 520), name: "unselected")
  }
}
