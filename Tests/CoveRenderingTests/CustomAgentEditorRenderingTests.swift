import AppKit
import SwiftUI
import XCTest

@testable import Cove
@testable import CoveCore

@MainActor
final class CustomAgentEditorRenderingTests: XCTestCase {
  func testCreateAgentRendersCalmlyAtWideAndNarrowWidths() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(url: directory.appendingPathComponent("agents.sqlite"))
    let store = try AppStore(database: database, accountEmail: "alex@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "synthetic" }, syncClock: Date.init)
    for width in [1180.0, 820.0] {
      let host = NSHostingView(rootView: CustomAgentEditor(store: store, agent: CustomAgent())
        .foregroundStyle(Palette.ink))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      defer { window.close() }
      for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-agent-editor-\(Int(width)).png"))
    }
    // A built agent reads as plain steps: when this happens, it does that.
    let host = NSHostingView(rootView: CustomAgentEditor(store: store, agent: CustomAgentTemplate.all[0].make()).foregroundStyle(Palette.ink))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-agent-editor-plan.png"))
    // Inbox email: search and pick from a short list instead of a menu.
    store.mails = (1...4).map { Mail(id: "m\($0)", sender: ["Acme Studio", "Maya Chen", "This Week in Fintech", "Stripe"][$0 - 1],
      senderEmail: "s\($0)@example.com", subject: ["Invoice for June services", "Quick question about the proposal", "Don’t bet against stablecoins", "Your receipt"][$0 - 1],
      body: "Hello", date: Date().addingTimeInterval(Double(-$0) * 3600), labels: ["INBOX"]) }
    let inboxHost = NSHostingView(rootView: CustomAgentEditor(store: store, agent: CustomAgentTemplate.all[0].make(), source: .inbox).foregroundStyle(Palette.ink))
    let inboxWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    inboxWindow.isReleasedWhenClosed = false; inboxWindow.contentView = inboxHost
    defer { inboxWindow.close() }
    for _ in 0..<8 { inboxHost.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let inboxBitmap = try XCTUnwrap(inboxHost.bitmapImageRepForCachingDisplay(in: inboxHost.bounds))
    inboxHost.cacheDisplay(in: inboxHost.bounds, to: inboxBitmap)
    try XCTUnwrap(inboxBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-agent-editor-inbox.png"))
    XCTAssertTrue(store.customAgents.agents.isEmpty, "Rendering never saves an agent")
  }
}
