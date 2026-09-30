import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// The inline "ask" line that replaced the Write with AI pop-up and the composer's side panel.
@MainActor final class InlineWritingRenderingTests: XCTestCase {
  func testInlineAskLineRendersWithAConnectedModel() async throws {
    _ = NSApplication.shared
    let suite = "cove-inline-writing-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "ai.saved.openAI")
    let settings = AIProviderSettings(defaults: defaults, readSecret: { _ in XCTFail("No credentials needed"); return nil })
    settings.provider = .openAI; settings.setModel("gpt-6-sol", provider: .openAI)
    var draft = "Thanks Maya, Thursday works."
    let view = VStack(alignment: .leading, spacing: 12) {
      Text(draft).font(.coveBody)
      WritingThinkingBar(stage: "Looking up conversations")
      AIWritingPanel(draft: Binding(get: { draft }, set: { draft = $0 }), inline: true, providerSettings: settings, onApply: { _ in })
    }.padding(20).frame(width: 720).background(Palette.canvas)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-inline-writing.png"))
    XCTAssertEqual(draft, "Thanks Maya, Thursday works.", "Rendering never changes the draft")
  }
}
