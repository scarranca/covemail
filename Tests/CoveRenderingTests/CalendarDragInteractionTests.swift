import AppKit
import SwiftUI
import XCTest

@testable import Cove
@testable import CoveCore

/// Drives the day column with synthesized mouse events in a window that is never shown.
@MainActor
final class CalendarDragInteractionTests: XCTestCase {
  private final class Log {
    var selected: [String] = []
    var created: [(Date, Date)] = []
    var moved: [(String, Date, Date)] = []
  }
  private let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23))!
  private func at(_ minute: Double) -> Date { day.addingTimeInterval(minute * 60) }

  private func host(_ events: [LocalEvent], log: Log) async throws -> NSWindow {
    _ = NSApplication.shared
    let column = CalendarDayColumn(
      events: events, day: day, selectedID: nil, dayRange: 0...0,
      select: { log.selected.append($0.id) },
      create: { log.created.append(($0, $1)) },
      reschedule: { log.moved.append(($0.id, $1, $2)) })
      .frame(width: 300, height: CalendarEventLayout.hourHeight * 24)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: CalendarEventLayout.hourHeight * 24),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: column)
    // SwiftUI only runs gestures in an ordered window. This one is transparent and far off every
    // screen, and the app is never activated, so nothing appears or takes focus on the user's Mac.
    window.alphaValue = 0
    window.ignoresMouseEvents = false
    window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
    window.orderFrontRegardless()
    for _ in 0..<5 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    return window
  }
  /// `y` is measured from the top of the grid, like SwiftUI.
  private func drag(_ window: NSWindow, from: Double, to: Double, x: Double = 150) async throws {
    let height = window.frame.height
    func send(_ type: NSEvent.EventType, _ y: Double) async throws {
      let event = NSEvent.mouseEvent(
        with: type, location: NSPoint(x: x, y: height - y), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
      window.sendEvent(event)
      try await Task.sleep(for: .milliseconds(25))
    }
    try await send(.leftMouseDown, from)
    if from != to {
      for step in 1...6 { try await send(.leftMouseDragged, from + (to - from) * Double(step) / 6) }
    }
    try await send(.leftMouseUp, to)
    try await Task.sleep(for: .milliseconds(60))
  }

  func testClickSelectsDragMovesEdgeResizesAndBlankCreates() async throws {
    let log = Log()
    let meeting = LocalEvent(title: "Launch review", start: at(600), end: at(660))  // 10:00–11:00
    let window = try await host([meeting], log: log)
    defer { window.close() }
    let hour = CalendarEventLayout.hourHeight

    try await drag(window, from: 10 * hour + 20, to: 10 * hour + 20)
    XCTAssertEqual(log.selected, [meeting.id], "A click still opens the event")
    XCTAssertTrue(log.moved.isEmpty)

    try await drag(window, from: 10 * hour + 20, to: 11 * hour + 20)
    XCTAssertEqual(log.moved.count, 1)
    XCTAssertEqual(log.moved.first?.1, at(660)); XCTAssertEqual(log.moved.first?.2, at(720))

    // The bottom edge (event height is one hour minus the 4-point gap) changes only the end.
    try await drag(window, from: 11 * hour - 7, to: 11 * hour - 7 + hour / 2)
    XCTAssertEqual(log.moved.count, 2)
    XCTAssertEqual(log.moved.last?.1, at(600)); XCTAssertEqual(log.moved.last?.2, at(690))

    try await drag(window, from: 14 * hour + 5, to: 15 * hour + 35)
    XCTAssertEqual(log.created.count, 1)
    XCTAssertEqual(log.created.first?.0, at(840)); XCTAssertEqual(log.created.first?.1, at(930))
    XCTAssertEqual(log.selected.count, 1, "Dragging never counts as a click")
  }

  func testInvitationsAndAllDayEventsDoNotMove() async throws {
    let log = Log()
    var invite = LocalEvent(title: "Board meeting", start: at(600), end: at(660))
    invite.googleID = "abc"; invite.isOrganizer = false
    let window = try await host([invite], log: log)
    defer { window.close() }
    let hour = CalendarEventLayout.hourHeight
    try await drag(window, from: 10 * hour + 20, to: 12 * hour + 20)
    XCTAssertTrue(log.moved.isEmpty)
    try await drag(window, from: 10 * hour + 20, to: 10 * hour + 20)
    XCTAssertEqual(log.selected, [invite.id])
  }
}
