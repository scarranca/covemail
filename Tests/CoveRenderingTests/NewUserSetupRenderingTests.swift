import AppKit
@testable import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// What a brand-new user sees: Gmail connected, nothing else.
@MainActor final class NewUserSetupRenderingTests: XCTestCase {
  func testConnectionsHomeChecklistAndAgentsGateGuideANewUser() async throws {
    _ = NSApplication.shared
    DesignAssets.registerFonts()
    let previous = UserDefaults.standard.object(forKey: "setup.jevKeySaved")
    UserDefaults.standard.set(false, forKey: "setup.jevKeySaved")
    UserDefaults.standard.set(false, forKey: "setup.checklistDismissed")
    defer {
      if let previous { UserDefaults.standard.set(previous, forKey: "setup.jevKeySaved") }
      else { UserDefaults.standard.removeObject(forKey: "setup.jevKeySaved") }
      UserDefaults.standard.removeObject(forKey: "setup.checklistDismissed")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AppStore(database: Database(url: directory.appendingPathComponent("mail.sqlite")),
      accountEmail: "new@example.com", gmail: GmailClient(), gmailTokenProvider: { "t" }, syncClock: Date.init)
    store.calendarConnected = false
    store.tasksConnected = false
    XCTAssertFalse(store.isSample)
    XCTAssertTrue(Setup.remaining(store).contains(.jev))
    XCTAssertFalse(Setup.remaining(store).contains(.gmail))

    let suite = "cove-new-user-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AIProviderSettings(defaults: defaults, readSecret: { _ in nil })
    try await render(IntegrationsView(store: store, settings: settings), size: CGSize(width: 1100, height: 1300), name: "setup-connections")
    try await render(SetupChecklistCard(store: store).frame(width: 720).padding(20), size: CGSize(width: 760, height: 560), name: "setup-home-checklist")
    try await render(CustomAgentsView(store: store), size: CGSize(width: 1000, height: 700), name: "setup-agents-gate")
  }

  private func render<V: View>(_ view: V, size: CGSize, name: String) async throws {
    let host = NSHostingView(rootView: view.background(Palette.canvas).foregroundStyle(Palette.ink))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-\(name).png"))
  }
}
