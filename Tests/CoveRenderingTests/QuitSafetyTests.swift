import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// Quitting must not lose what the user already did: typed drafts are saved when the app terminates, and
/// a send or Gmail write still in flight is awaited (bounded) before AppKit is allowed to quit.
@MainActor final class QuitSafetyTests: XCTestCase {
  func testQuitWaitsOnlyWhenWorkIsPending() {
    XCTAssertFalse(CoveAppDelegate.quitNeedsSettling(pendingSend: false, queuedTrash: false, trashCommitting: false))
    XCTAssertTrue(CoveAppDelegate.quitNeedsSettling(pendingSend: true, queuedTrash: false, trashCommitting: false))
    XCTAssertTrue(CoveAppDelegate.quitNeedsSettling(pendingSend: false, queuedTrash: true, trashCommitting: false))
    XCTAssertTrue(CoveAppDelegate.quitNeedsSettling(pendingSend: false, queuedTrash: false, trashCommitting: true))
    XCTAssertTrue(CoveAppDelegate.quitNeedsSettling(pendingSend: false, queuedTrash: false, trashCommitting: false, labelWork: true))
  }

  func testReplyToQuitComesOnlyAfterSettleFinishes() async {
    var events: [String] = []
    await CoveAppDelegate.settleThenReply(
      settle: {
        events.append("settle started")
        try? await Task.sleep(for: .milliseconds(60))
        events.append("settle finished")
        return true
      }, reply: { events.append("reply") })
    XCTAssertEqual(events, ["settle started", "settle finished", "reply"])
  }

  func testQuitStillRepliesWhenSettleFails() async {
    var replied = false
    await CoveAppDelegate.settleThenReply(settle: { false }, reply: { replied = true })
    XCTAssertTrue(replied, "A failed or timed-out settle must not trap the user in the app")
  }

  func testPendingSendIsDeliveredBeforeQuitReply() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoveQuit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AppStore(database: Database(url: directory.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(transport: FailingTransport()), gmailTokenProvider: { "x" }, syncClock: Date.init)
    store.isSample = true
    store.queueSend(to: "maya@example.com", subject: "Hi", body: "Hello", draftID: nil, from: "me@example.com", attachmentTarget: nil)
    XCTAssertNotNil(store.pendingSend)
    XCTAssertTrue(CoveAppDelegate.quitNeedsSettling(pendingSend: store.pendingSend != nil, queuedTrash: false, trashCommitting: false))
    var sendWasGone = false
    await CoveAppDelegate.settleThenReply(
      settle: { await store.settleBeforeLeavingMailbox(timeout: .seconds(3)) },
      reply: { sendWasGone = store.pendingSend == nil })
    XCTAssertTrue(sendWasGone, "The Undo window is cut short by quitting, not left undelivered")
  }

  func testComposerSavesPendingEditWhenAppTerminates() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoveQuit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AppStore(database: Database(url: directory.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(transport: FailingTransport()), gmailTokenProvider: { "x" }, syncClock: Date.init)
    store.isSample = true; store.screen = "mail"
    store.newDraft()
    let id = try XCTUnwrap(store.composeID)
    store.saveComposition(id: id, to: "maya@example.com", subject: "Plan", body: "Start", from: "me@example.com")
    let host = NSHostingView(rootView: ComposerView(store: store, availableSize: CGSize(width: 1280, height: 920)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1216, height: 856), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
    editor.string = "Typed just before quitting"
    editor.didChangeText()
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertEqual(store.mails.first { $0.id == id }?.body, "Start", "The 600 ms autosave has not run yet")
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
    XCTAssertEqual(store.mails.first { $0.id == id }?.body, "Typed just before quitting")
  }

  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}

private struct FailingTransport: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw URLError(.notConnectedToInternet)
  }
}
