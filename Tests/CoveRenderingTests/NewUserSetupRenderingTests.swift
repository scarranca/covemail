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
    try await render(CustomAgentsView(store: store), size: CGSize(width: 1000, height: 1250), name: "setup-agents-gate")

    // With an agent at work, the portrait's captions show what it really did.
    var agent = CustomAgentTemplate.all[0].make()
    agent.status = .active
    var run = CustomAgentRun(agent: agent, mail: Mail(id: "m1", sender: "Acme", senderEmail: "billing@acme.example", subject: "Invoice #2048", body: ""))
    run.appliedLabel = "Finance / Invoices"; run.completed = true
    store.customAgents.agents = [agent]
    store.customAgents.runs = [run]
    try await render(AgentsHeader(store: store, previewTime: 3).padding(20), size: CGSize(width: 1000, height: 340), name: "setup-agents-header")
  }

  func testAgentFacePortrait() async throws {
    _ = NSApplication.shared
    try await render(AgentFaceView(previewTime: 0).frame(width: 320, height: 250)
      .background(Color(red: 0.114, green: 0.125, blue: 0.165)), size: CGSize(width: 320, height: 250), name: "agent-face")
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

@MainActor final class AgentPortraitHalftoneTests: XCTestCase {
  /// Dark areas of the portrait become dots in the same place; white areas stay empty.
  func testDotsFollowTheDarkPartOfThePortraitUpright() throws {
    let size = 40
    let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // CoreGraphics' origin is bottom-left: this darkens the image's top half.
    context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
    let image = try XCTUnwrap(context.makeImage())
    let dots = AgentPortrait.dots(image, width: 100, height: 100, spacing: 4)
    XCTAssertFalse(dots.isEmpty)
    XCTAssertTrue(dots.allSatisfy { $0.y < 55 }, "dots belong to the dark top half")
    XCTAssertTrue(dots.contains { $0.y < 10 })
  }
}
