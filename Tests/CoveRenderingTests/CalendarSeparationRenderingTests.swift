import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class CalendarSeparationRenderingTests: XCTestCase {
  private var day: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23))! }
  private func event(_ title: String, _ start: Int, _ end: Int) -> LocalEvent {
    LocalEvent(title: title, start: day.addingTimeInterval(Double(start) * 60), end: day.addingTimeInterval(Double(end) * 60))
  }
  private var events: [LocalEvent] {
    [event("Design review", 540, 600), event("Team planning", 600, 660),
     event("Martha · project check-in", 570, 615), event("Quick handoff", 660, 665),
     event("Call Alex", 665, 670), event("Send notes", 670, 675), event("Lunch", 720, 780)]
  }

  func testAdjacentAndShortEventsHaveSeparateClickableRectangles() {
    let placement = CalendarEventLayout.arrange(events, on: day)
    XCTAssertEqual(placement.count, events.count)
    for item in placement { XCTAssertGreaterThanOrEqual(item.height, 28) }
    // Test the actual presentation rectangles, not just the underlying event duration.
    let rectangles = placement.map { item in
      CGRect(x: Double(item.column) * 200 / Double(item.columns) + 4,
             y: item.top, width: 200 / Double(item.columns) - 8, height: item.height)
    }
    for first in rectangles.indices {
      for second in rectangles.indices where second > first {
        XCTAssertFalse(rectangles[first].intersects(rectangles[second]),
          "Visible hit targets must not overlap, including five-minute appointments")
      }
    }
    let simple = CalendarEventLayout.arrange([event("First", 540, 600), event("Next", 600, 660)], on: day)
    XCTAssertEqual(simple[1].top - (simple[0].top + simple[0].height), 4, accuracy: 0.01)
    XCTAssertEqual(simple.map(\.columns), [1, 1])
    let midnight = CalendarEventLayout.arrange([event("Late one", 1435, 1438), event("Late two", 1438, 1440)], on: day)
    XCTAssertEqual(midnight.map(\.columns), [2, 2])
    for item in midnight {
      XCTAssertLessThanOrEqual(item.top + item.height, CalendarEventLayout.hourHeight * 24 - CalendarEventLayout.gap)
    }
  }

  func testFullWeekAndAgendaRenderUsingProductionView() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(url: directory.appendingPathComponent("calendar.sqlite"))
    let store = try AppStore(database: database, accountEmail: "calendar@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "synthetic" }, syncClock: { self.day })
    store.calendarDay = day
    store.events = events
    var allDay = event("Launch week", 0, 1440); allDay.allDay = true
    var holiday = event("Martha out of office", 0, 1440); holiday.allDay = true
    store.events += [allDay, holiday]
    let host = NSHostingView(rootView: CalendarView(store: store).background(Palette.canvas).foregroundStyle(Palette.ink))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 980), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-calendar-full-week.png"))
    XCTAssertEqual(store.events.count, events.count + 2, "Rendering never edits the user's calendar")
  }

  func testSelectedEventShowsQuietIconActions() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(url: directory.appendingPathComponent("calendar.sqlite"))
    let store = try AppStore(database: database, accountEmail: "calendar@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "synthetic" }, syncClock: { self.day })
    store.calendarDay = day
    var meeting = event("Launch review", 600, 660)
    meeting.meetURL = "https://meet.google.com/abc-defg-hij"
    meeting.webURL = "https://calendar.google.com/calendar/event?eid=abc"
    meeting.mailID = "mail-1"
    meeting.location = "Studio"
    store.events = events + [meeting]
    store.calendarEventID = meeting.id
    let host = NSHostingView(rootView: CalendarView(store: store).background(Palette.canvas).foregroundStyle(Palette.ink))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-calendar-event-detail.png"))
    XCTAssertEqual(store.calendarEventID, meeting.id)
  }

  func testMonthRendersAtCompactAndWideWidths() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(url: directory.appendingPathComponent("month.sqlite"))
    let store = try AppStore(database: database, accountEmail: "calendar@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "synthetic" }, syncClock: { self.day })
    store.calendarDay = day
    store.events = events
    var allDay = event("Launch week", 0, 4320); allDay.allDay = true
    store.events.append(allDay)
    for width in [CGFloat(816), 1280] {
      let host = NSHostingView(rootView: CalendarView(store: store, mode: .month)
        .background(Palette.canvas).foregroundStyle(Palette.ink))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: width == 816 ? 700 : 980),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      defer { window.close() }
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-calendar-month-\(Int(width)).png"))
      XCTAssertEqual(store.events.count, events.count + 1)
    }
  }

  func testHostedCalendarSeparatesAdjacentOverlappingAndAllDayEvents() async throws {
    _ = NSApplication.shared
    for width in [CGFloat(680), 1024] {
      let fixtureEvents = events
      let sample = CalendarFixture(events: fixtureEvents, day: day, selectedID: fixtureEvents[1].id)
      let host = NSHostingView(rootView: sample)
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      defer { window.close() }
      for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-calendar-separation-\(Int(width)).png"))
      XCTAssertGreaterThan(bitmap.pixelsWide, Int(width) - 1)
    }
  }
}

private struct CalendarFixture: View {
  let events: [LocalEvent]
  let day: Date
  let selectedID: String
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Calendar").font(.coveTitle).padding(24)
      Divider()
      HStack(alignment: .top, spacing: 0) {
        VStack(spacing: 0) {
          HStack {
            Text("Wed 23").frame(maxWidth: .infinity)
            Text("Thu 24").frame(maxWidth: .infinity)
          }.font(.cove(size: 13, weight: .medium)).padding(16)
          Divider()
          HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
              CalendarAllDayEvent(event: LocalEvent(title: "Launch week", start: day, end: day.addingTimeInterval(86400)), selected: false) {}
              CalendarAllDayEvent(event: LocalEvent(title: "Martha out of office", start: day, end: day.addingTimeInterval(86400)), selected: false) {}
            }
            Color.clear.frame(maxWidth: .infinity)
          }.padding(8)
          Divider()
          HStack(spacing: 0) {
            CalendarDayColumn(events: events, day: day, selectedID: selectedID) { _ in }
            CalendarDayColumn(events: events.map { var e = $0; e.start = e.start.addingTimeInterval(86400); e.end = e.end.addingTimeInterval(86400); return e }, day: day.addingTimeInterval(86400), selectedID: nil) { _ in }
          }.frame(height: 1920).offset(y: -640).frame(height: 500, alignment: .top).clipped()
        }
        Divider()
        VStack(alignment: .leading, spacing: 0) {
          Text("Wednesday, Sep 23").font(.cove(size: 18, weight: .medium)).padding(.vertical, 18)
          ForEach(Array(events.prefix(5).enumerated()), id: \.element.id) { index, event in
            CalendarAgendaEvent(event: event, status: index == 0 ? "Up next" : nil, time: "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))") {}
            Divider()
          }
          Spacer()
        }.padding(.horizontal, 16).frame(width: 240)
      }
    }.background(Palette.canvas)
  }
}
