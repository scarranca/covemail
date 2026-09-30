import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// The sidebar keeps one set of destinations on every screen; only the contextual group changes.
@MainActor final class SidebarNavigationRenderingTests: XCTestCase {
  func testSidebarRendersForEveryDestinationOffscreen() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    let store = try AppStore(database: database, accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.isSample = true
    store.mails = (0..<4).map {
      Mail(id: "m\($0)", sender: "Maya Chen", senderEmail: "maya@example.com", subject: "Update \($0)", body: "", date: Date(), labels: ["INBOX", "UNREAD"])
    }
    for screen in ["home", "mail", "calendar", "contacts", "agents", "integrations"] {
      if screen == "mail" { store.chooseFolder("Inbox") } else { store.screen = screen }
      XCTAssertEqual(store.screen, screen)
      let host = NSHostingView(rootView: Sidebar(store: store).frame(width: 224, height: 900))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 224, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      XCTAssertFalse(window.isVisible)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: "/tmp/cove-ui-sidebar-\(screen).png"))
      window.close()
    }
    // Home's "Your day & people" extras: today, invitations (one RSVP note, as a tooltip) and weather.
    store.screen = "home"
    let now = Date()
    var invite = LocalEvent(title: "Quarterly planning", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000))
    invite.id = "invite"; invite.googleID = "g1"; invite.organizerName = "Priya Shah"
    invite.attendees = [CalendarAttendee(name: "Me", email: "me@example.com", response: "needsAction", isSelf: true)]
    store.events = [LocalEvent(title: "Design review", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600)), invite]
    let weather = HomeWeatherController(defaults: UserDefaults(suiteName: "Cove-UI-Weather-" + UUID().uuidString)!)
    let extras = VStack(alignment: .leading, spacing: 28) {
      HomeCalendarView(store: store)
      HomeWeatherView(weather: weather)
    }.padding(24).frame(width: 460, height: 900, alignment: .top).background(Palette.canvas)
    let host = NSHostingView(rootView: extras)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/cove-ui-home-extras.png"))
  }
}
