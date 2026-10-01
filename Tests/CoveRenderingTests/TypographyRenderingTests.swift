import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// Production screens missing from the existing offscreen route fixtures.
@MainActor final class TypographyRenderingTests: XCTestCase {
  func testRemainingRoutesAtCompactAndWideWidths() async throws {
    _ = NSApplication.shared
    DesignAssets.registerFonts()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AppStore(database: Database(url: directory.appendingPathComponent("mail.sqlite")),
      accountEmail: "alex@example.com", gmail: GmailClient(),
      gmailTokenProvider: { XCTFail("Typography fixtures must not access Gmail"); return "fixture" }, syncClock: Date.init)
    store.isSample = true; store.entered = true; store.mails = Samples.mail
    store.preferences.memories = ["I work with Maya on product design. Keep project updates concise and include next steps."]
    store.preferences.instructions = ["Ask before committing to a deadline or meeting."]
    store.events = [LocalEvent(title: "Product design review", start: Date(), end: Date().addingTimeInterval(3600))]
    let record = ContactRecord(name: "Maya Chen", email: "maya@example.com", company: "Northstar Studio", notes: "We work together on product design. Send the revised brief before our next meeting.")
    for width in [900.0, 1280.0] {
      try await render(WelcomeView(store: store), name: "welcome", width: width)
      try await render(AgentView(store: store), name: "your-agent", width: width)
      store.selectedContactID = nil
      try await render(ContactsView(store: store), name: "contacts-empty-selection", width: width)
      store.selectedContactID = store.contacts.first?.id
      try await render(ContactsView(store: store), name: "contacts-detail", width: width)
      let mail = Mail(id: "type-fixture", sender: "Maya Chen", senderEmail: "maya@example.com",
        subject: "Design review and next steps for the launch", body: String(repeating: "The updated design is ready to review. Please check the main flow, note any questions, and share your feedback before Thursday.\n\n", count: 4), date: Date(), labels: ["INBOX"])
      store.mails = [mail] + Samples.mail
      try await render(ReaderView(store: store, mail: mail), name: "reader", width: width)
    }
    store.respondingEventID = store.events[0].id
    try await render(VStack(alignment: .leading) {
      InvitationResponseButtons(store: store, event: store.events[0])
      Spacer(minLength: 0)
    }.padding(.vertical, 12), name: "rsvp-loading", width: 192)
    try await render(ContactEditor(store: store, record: record, onSave: { _ in XCTFail("Rendering must not save") }), name: "contact-editor", width: 490)
    try await render(CalendarEventEditor(store: store, draft: CalendarEventDraft(title: "Product design review")), name: "event-editor", width: 440)
    var invited = CalendarEventDraft(title: "Demo gigstack")
    invited.onGoogle = true; invited.guests = ["maya@example.com", "contacto@grupo-amx.com"]; invited.addMeet = true
    try await render(CalendarEventEditor(store: store, draft: invited), name: "event-editor-guests", width: 440)
    try await render(CalendarSearchView(store: store, select: { _ in XCTFail("Rendering must not select") }), name: "calendar-search", width: 390)
  }

  private func render<V: View>(_ view: V, name: String, width: CGFloat) async throws {
    let host = NSHostingView(rootView: view.font(.coveBody).foregroundStyle(Palette.ink).background(Palette.canvas))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(host.bounds.width, width, accuracy: 1)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/cove-type-\(name)-\(Int(width)).png"))
  }
}
