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
    XCTAssertTrue(store.customAgents.agents.isEmpty, "Rendering never saves an agent")
  }
}
