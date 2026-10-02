import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class LinkedTasksTests: XCTestCase {
  private func store() throws -> AppStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveLinkedTasks-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(transport: OfflineHTTP()), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
  }

  func testAnEmailFindsTasksMadeFromItOrItsConversation() throws {
    let store = try store()
    var first = Mail(id: "m1", sender: "Siegrist", senderEmail: "pagos@example.com", subject: "Solicitud de pago", body: "Paga", labels: ["INBOX"])
    first.threadID = "thread9"
    var check = MailTaskCheck(found: true, confidence: 0.9); check.createdTaskIDs = ["fromSheet"]
    first.taskCheck = check
    var reply = Mail(id: "m2", sender: "Me", senderEmail: "me@example.com", subject: "Re: Solicitud de pago", body: "Listo", labels: ["SENT"])
    reply.threadID = "thread9"
    store.mails = [first, reply]
    store.googleTasks = [
      GoogleTask(id: "fromSheet", title: "Pay Siegrist $4,800"),
      GoogleTask(id: "fromTasks", title: "Send receipt", notes: "From: Siegrist\nhttps://mail.google.com/mail/u/0/#all/thread9"),
      GoogleTask(id: "other", title: "Unrelated", notes: "https://mail.google.com/mail/u/0/#all/elsewhere"),
    ]
    XCTAssertEqual(Set(store.tasks(for: reply).map(\.id)), ["fromSheet", "fromTasks"], "any message in the conversation shows its tasks")

    let host = NSHostingView(rootView: LinkedTasksStrip(store: store, mail: first).padding(24).frame(width: 620).background(Color.white))
    host.frame = NSRect(x: 0, y: 0, width: 620, height: host.fittingSize.height)
    host.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-linked-tasks.png"))
  }
}

private struct OfflineHTTP: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTFail("No network in linked task tests: \(request.url!)")
    return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class FirstOpenSpotTests: XCTestCase {
  func testFindsTheFirstOpenSpotAroundBusyTimeAndSkipsWeekends() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveOpenSpot-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(transport: OfflineHTTP()), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.isSample = true; store.entered = true
    let zone = TimeZone(identifier: "America/Mexico_City")!
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    // Friday Oct 2 2026, 8:00 local. Busy 9:00–10:00, plus a zero-length reminder at 10:00.
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 8))!
    let nine = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!
    let ten = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 10))!
    store.events = [LocalEvent(title: "Standup", start: nine, end: ten), LocalEvent(title: "Pin", start: ten, end: ten)]
    let today = try await store.firstOpenSpot(.init(day: nil, durationMinutes: 30, startMinute: 540, endMinute: 1020), now: now, timeZone: zone)
    XCTAssertEqual(today?.start, ten, "right after the busy hour; a zero-length reminder doesn't block or break the check")
    // A full Friday rolls over the weekend to Monday.
    store.events = [LocalEvent(title: "Offsite", start: nine, end: calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 17))!)]
    let next = try await store.firstOpenSpot(.init(day: nil, durationMinutes: 30, startMinute: 540, endMinute: 1020), now: now, timeZone: zone)
    XCTAssertEqual(next.map { calendar.component(.weekday, from: $0.start) }, 2, "Monday")
  }
}

@MainActor final class CalendarDeleteShortcutTests: XCTestCase {
  func testCommandDeleteAsksToDeleteTheSelectedEventButNotWhileTyping() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveCalDelete-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(transport: OfflineHTTP()), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.entered = true; store.screen = "calendar"
    let event = LocalEvent(title: "Demo", start: Date(), end: Date().addingTimeInterval(1800))
    store.events = [event]
    var asked: [String] = []
    let view = CalendarDeleteShortcut.ShortcutView(store: store) { asked.append($0.id) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    defer { window.close() }
    let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
    XCTAssertNotNil(view.handle(key), "no event selected: the key passes through")
    store.calendarEventID = event.id
    let editor = NSTextView(frame: view.bounds)
    view.addSubview(editor); window.makeFirstResponder(editor)
    XCTAssertNotNil(view.handle(key), "typing keeps ⌘Delete"); XCTAssertTrue(asked.isEmpty)
    window.makeFirstResponder(nil)
    store.screen = "mail"
    XCTAssertNotNil(view.handle(key), "Mail owns ⌘Delete there")
    store.screen = "calendar"
    XCTAssertNil(view.handle(key))
    XCTAssertEqual(asked, [event.id], "it asks, through the same confirmation as the trash button")
  }
}

@MainActor final class DefaultSenderTests: XCTestCase {
  func testDefaultFromAndRepliesFromTheAddressTheEmailWasSentTo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveSender-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(transport: OfflineHTTP()), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.entered = true
    store.sendingAliases = ["me@example.com", "santiago@gigstack.io", "hola@cove.ai"]
    XCTAssertEqual(store.defaultSender, "me@example.com")
    store.setDefaultSender("santiago@gigstack.io")
    XCTAssertEqual(store.defaultSender, "santiago@gigstack.io")
    var toAlias = Mail(id: "a", sender: "Ana", senderEmail: "ana@example.com", subject: "Hi", body: "x")
    toAlias.to = "Cove <hola@cove.ai>"
    XCTAssertEqual(store.replySender(for: toAlias), "hola@cove.ai", "reply from the address it was sent to")
    var toBoth = toAlias; toBoth.to = "hola@cove.ai"; toBoth.cc = "Santiago <santiago@gigstack.io>"
    XCTAssertEqual(store.replySender(for: toBoth), "santiago@gigstack.io", "several matches: the default wins")
    var elsewhere = toAlias; elsewhere.to = "team@list.example.com"
    XCTAssertEqual(store.replySender(for: elsewhere), "santiago@gigstack.io", "a list address falls back to the default")
    store.sendingAliases = ["me@example.com"]
    XCTAssertEqual(store.defaultSender, "me@example.com", "a removed alias is never used")
    store.setDefaultSender("me@example.com")
    XCTAssertNil(store.preferences.defaultSender)
  }
}

@MainActor final class AgentCaptionTests: XCTestCase {
  func testCaptionSubjectsDropPrefixesAndStayShort() {
    XCTAssertEqual(AgentsHeader.shortSubject("Re: [disruptive-learning/backend] fix(discovery,proserver): address release review notes"),
                   "fix(discovery,proserver): address release revie…")
    XCTAssertEqual(AgentsHeader.shortSubject("Fwd: RE: Invoice #2048"), "Invoice #2048")
    XCTAssertEqual(AgentsHeader.shortSubject("  "), "an email")
  }
}
