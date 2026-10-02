import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class MeetingMenuBarTests: XCTestCase {
  private func store() throws -> AppStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveMenuBar-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.entered = true; store.isSample = true
    return store
  }

  func testCountdownPulseAndPanel() throws {
    let key = MeetingMenuBarModel.enabledKey
    let previous = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(true, forKey: key)
    addTeardownBlock { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    let store = try store()
    let now = Date()
    var standup = LocalEvent(title: "Standup", start: now.addingTimeInterval(30), end: now.addingTimeInterval(1_830))
    standup.meetURL = "https://meet.google.com/abc-defg-hij"
    standup.attendees = [CalendarAttendee(name: "Me", email: "me@example.com", response: "accepted", isSelf: true),
                         CalendarAttendee(name: "Maya Chen", email: "maya@example.com", response: "accepted", isSelf: nil),
                         CalendarAttendee(name: "Luis", email: "luis@example.com", response: "accepted", isSelf: nil)]
    let review = LocalEvent(title: "Design review", start: now.addingTimeInterval(7_200), end: now.addingTimeInterval(9_000))
    store.events = [standup, review]
    let model = MeetingMenuBarModel(store: store)
    model.clock = { now }
    let wait = model.tick()
    XCTAssertEqual(model.alert?.title(), "Join Standup")
    XCTAssertTrue(model.alert?.prominent == true)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      XCTAssertEqual(wait, 700, "pulses while a call with guests is starting")
    }
    XCTAssertEqual(model.later.map(\.title), Calendar.current.isDate(review.start, inSameDayAs: now) ? ["Design review"] : [])

    let host = NSHostingView(rootView: MeetingMenuPanel(store: store, model: model))
    store.isSample = false; store.calendarConnected = true
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-meeting-menu-panel.png"))

    UserDefaults.standard.set(false, forKey: key)
    model.tick()
    XCTAssertNil(model.alert, "off means nothing is tracked")
  }
}
